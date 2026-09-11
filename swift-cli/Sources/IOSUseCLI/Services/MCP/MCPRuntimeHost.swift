import Darwin
import Foundation
import IOSUseProtocol

final class MCPDriverSessionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: LockedDriverClientSession] = [:]
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func session(paths: IOSUsePaths) -> LockedDriverClientSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[paths.driverLock] {
            return existing
        }
        let created = LockedDriverClientSession(paths: paths)
        sessions[paths.driverLock] = created
        return created
    }

    func close() {
        lock.lock()
        let current = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        current.forEach { $0.close() }
    }

    deinit {
        close()
    }
}

private struct MCPHostRequest: Decodable {
    let id: Int
    let arguments: [String]?
    let imagePath: String?
    let deviceID: String?
    let observation: MCPObservationRequest?
    let interaction: MCPInteractionRequest?
}

private struct MCPInteractionRequest: Decodable {
    let name: String
    let target: MCPInteractionTarget?
    let text: String?
    let prefix: String?
    let suffix: String?
    let selectionType: String?
    let clickCount: Int?
}

private struct MCPInteractionTarget: Decodable {
    let label: String?
    let point: [Double]?

    func foryTarget() throws -> ForyTarget {
        if let point, point.count == 2, point.allSatisfy(\.isFinite), label == nil {
            return ForyTarget(point: ForyPoint(x: point[0], y: point[1]))
        }
        if let label, !label.isEmpty, point == nil { return ForyTarget(label: label) }
        throw CLIParseError.invalidValue("Expected a label or an [x,y] point")
    }
}

private struct MCPObservationRequest: Decodable {
    let ax: Bool
    let screenshot: Bool
    let waitQuiescence: Bool
}

private struct MCPHostResponse: Encodable {
    let id: Int
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let imageBase64: String?
    var data: MachineValue? = nil
}

final class MCPRuntimeHost: @unchecked Sendable {
    let port: Int

    private let paths: IOSUsePaths
    private var listenerFD: Int32
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let work = DispatchGroup()
    private let pool = MCPDriverSessionPool()
    private var clientFD: Int32 = -1
    private var stopped = false

    init(paths: IOSUsePaths) throws {
        self.paths = paths
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIParseError.invalidValue("failed to create JavaScript host socket")
        }
        listenerFD = fd
        setSocketNoSigPipe(fd)

        var one: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &one,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let value = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue(
                "failed to bind JavaScript host socket: errno \(value)"
            )
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard inspected == 0 else {
            let value = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue(
                "failed to inspect JavaScript host socket: errno \(value)"
            )
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func start() {
        let listening = listenerFD
        work.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                stateLock.lock()
                listenerFD = -1
                Darwin.close(listening)
                stateLock.unlock()
                work.leave()
            }
            let accepted = Darwin.accept(listening, nil, nil)
            guard accepted >= 0 else { return }
            setSocketNoSigPipe(accepted)
            stateLock.lock()
            if stopped {
                stateLock.unlock()
                Darwin.close(accepted)
                return
            }
            clientFD = accepted
            stateLock.unlock()
            defer {
                writeLock.lock()
                defer { writeLock.unlock() }
                stateLock.lock()
                let ownsClient = clientFD == accepted
                if ownsClient {
                    clientFD = -1
                }
                stateLock.unlock()
                if ownsClient {
                    Darwin.shutdown(accepted, SHUT_RDWR)
                    Darwin.close(accepted)
                }
            }
            readRequests(from: accepted)
        }
    }

    func shutdown() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        if listenerFD >= 0 { Darwin.shutdown(listenerFD, SHUT_RDWR) }
        if clientFD >= 0 { Darwin.shutdown(clientFD, SHUT_RDWR) }
        stateLock.unlock()
        pool.cancel()
    }

    func stop() {
        shutdown()
        // Issued Device operations may finish, but must not hold the JS context
        // or its timeout/reset response hostage. Close sessions after they drain.
        work.notify(queue: .global(qos: .utility)) { [pool] in pool.close() }
    }

    private func readRequests(from descriptor: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                work.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { work.leave() }
                    handle(line, descriptor: descriptor)
                }
            }
        }
    }

    private func handle(_ data: Data, descriptor: Int32) {
        let response: MCPHostResponse
        do {
            stateLock.lock()
            let cancelled = stopped
            stateLock.unlock()
            if cancelled { return }
            let request = try JSONDecoder().decode(MCPHostRequest.self, from: data)
            if let observation = request.observation, let deviceID = request.deviceID {
                response = try observe(observation, deviceID: deviceID, requestID: request.id)
            } else if let interaction = request.interaction, let deviceID = request.deviceID {
                response = try interact(interaction, deviceID: deviceID, requestID: request.id)
            } else if let arguments = request.arguments {
                let cli = IOSUseCLI(
                    pathsForTesting: paths,
                    mcpDriverSessions: pool
                )
                let result = cli.run(arguments: arguments)
                response = MCPHostResponse(
                    id: request.id,
                    exitCode: result.exitCode,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    imageBase64: nil
                )
            } else if let imagePath = request.imagePath {
                let root = URL(fileURLWithPath: paths.root)
                    .standardizedFileURL.path
                let candidate = URL(fileURLWithPath: imagePath)
                    .standardizedFileURL.path
                guard candidate.hasPrefix(root + "/") else {
                    throw CLIParseError.invalidValue(
                        "Image path is outside IOS_USE_HOME"
                    )
                }
                let image = try Data(contentsOf: URL(fileURLWithPath: candidate))
                response = MCPHostResponse(
                    id: request.id,
                    exitCode: 0,
                    stdout: "",
                    stderr: "",
                    imageBase64: image.base64EncodedString()
                )
            } else {
                throw CLIParseError.invalidValue("invalid JavaScript host request")
            }
        } catch {
            let failedRequest = try? JSONDecoder().decode(
                MCPHostRequest.self,
                from: data
            )
            let requestID = failedRequest?.id ?? 0
            let failure = MachineOutput.failure(command: failedRequest?.interaction?.name ?? "observe", error: error, data: machineDriverErrorData(error))
            response = MCPHostResponse(
                id: requestID,
                exitCode: 1,
                stdout: failure.stdout,
                stderr: failure.stderr,
                imageBase64: nil
            )
        }
        do {
            var encoded = try JSONEncoder().encode(response)
            encoded.append(0x0A)
            writeLock.lock()
            defer { writeLock.unlock() }
            stateLock.lock()
            let canWrite = !stopped && clientFD == descriptor
            stateLock.unlock()
            guard canWrite else { return }
            try writeAll(fd: descriptor, data: encoded)
        } catch {
            return
        }
    }

    private func observe(_ options: MCPObservationRequest, deviceID: String, requestID: Int) throws -> MCPHostResponse {
        let context = try DeviceContextStore.activeContext(explicitDeviceID: deviceID, paths: paths)
        return try DeviceCommandLock.withExclusiveLock(paths: context.paths) {
            try pool.checkCancellation()
            return try pool.session(paths: context.paths).run { client in
                var data: [String: MachineValue] = [:]
                if options.ax {
                    data["ax"] = machineDom(try client.dom(raw: false, fresh: true, waitQuiescence: options.waitQuiescence))
                }
                var image: Data?
                if options.screenshot {
                    let capture = try ScreenshotCaptureCoordinator.capture(paths: context.paths) {
                        try client.screenshotCapture(waitQuiescence: options.waitQuiescence && !options.ax)
                    }
                    image = capture.jpeg
                    data["screenshot"] = .object([
                        "logicalSize": capture.logicalSize.map { .array([.double($0.x), .double($0.y)]) } ?? .null,
                        "pixelSize": capture.pixelSize.map { .array([.double($0.x), .double($0.y)]) } ?? .null,
                        "scale": capture.scale.map(MachineValue.double) ?? .null,
                    ])
                }
                return MCPHostResponse(id: requestID, exitCode: 0, stdout: "", stderr: "", imageBase64: image?.base64EncodedString(), data: .object(data))
            }
        }
    }

    private func interact(_ request: MCPInteractionRequest, deviceID: String, requestID: Int) throws -> MCPHostResponse {
        let context = try DeviceContextStore.activeContext(explicitDeviceID: deviceID, paths: paths)
        let target = try request.target?.foryTarget() ?? ForyTarget()
        return try DeviceCommandLock.withExclusiveLock(paths: context.paths) {
            try pool.checkCancellation()
            try pool.session(paths: context.paths).run { client in
                switch request.name {
                case "click": _ = try client.click(target: target, count: request.clickCount ?? 1)
                case "replace", "select", "key", "type":
                    _ = try client.textInput(ForyTextInputArgs(operation: request.name, target: target, text: request.text ?? "", prefix: request.prefix ?? "", suffix: request.suffix ?? "", selectionType: request.selectionType ?? "text"))
                default: throw CLIParseError.invalidValue("Unknown Device interaction: \(request.name)")
                }
            }
            return MCPHostResponse(id: requestID, exitCode: 0, stdout: "", stderr: "", imageBase64: nil)
        }
    }
}
