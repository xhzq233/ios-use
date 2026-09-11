import Darwin
import Foundation

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
}

private struct MCPHostResponse: Encodable {
    let id: Int
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let imageBase64: String?
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
            if let arguments = request.arguments {
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
            let requestID = (try? JSONDecoder().decode(
                MCPHostRequest.self,
                from: data
            ).id) ?? 0
            response = MCPHostResponse(
                id: requestID,
                exitCode: 1,
                stdout: "",
                stderr: "\(error)",
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
}
