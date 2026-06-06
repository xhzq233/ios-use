import Darwin
import Foundation
import IOSUseProtocol

struct XCTestSessionHolderControlRequest: Codable, Equatable {
    let command: String
}

struct XCTestSessionHolderControlResponse: Codable, Equatable {
    let status: String
    let holderPid: Int?
    let runnerPid: Int?
    let sessionIdentifier: String?
    let bundleId: String?
    let controlSocketPath: String?
    let error: String?
}

final class XCTestSessionHolderControlState {
    enum Phase: String {
        case starting
        case ready
        case failed
        case stopping
        case stopped
    }

    private let condition = NSCondition()
    private var phase: Phase = .starting
    private let holderPid: Int
    private let bundleId: String
    private let controlSocketPath: String
    private var runnerPid: Int?
    private var sessionIdentifier: String?
    private var error: String?
    private var stopRequested = false

    init(holderPid: Int, bundleId: String, controlSocketPath: String) {
        self.holderPid = holderPid
        self.bundleId = bundleId
        self.controlSocketPath = controlSocketPath
    }

    var shouldStop: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopRequested
    }

    func markReady(runnerPid: Int, sessionIdentifier: String) {
        condition.lock()
        self.phase = .ready
        self.runnerPid = runnerPid
        self.sessionIdentifier = sessionIdentifier
        condition.broadcast()
        condition.unlock()
    }

    func markFailed(_ error: Error) {
        condition.lock()
        self.phase = .failed
        self.error = String(describing: error)
        condition.broadcast()
        condition.unlock()
    }

    func requestStop() -> XCTestSessionHolderControlResponse {
        condition.lock()
        stopRequested = true
        if phase != .stopped {
            phase = .stopping
        }
        let response = currentResponseLocked()
        condition.broadcast()
        condition.unlock()
        return response
    }

    func markStopped() {
        condition.lock()
        phase = .stopped
        condition.broadcast()
        condition.unlock()
    }

    func status() -> XCTestSessionHolderControlResponse {
        condition.lock()
        defer { condition.unlock() }
        return currentResponseLocked()
    }

    func waitForStartResult() -> XCTestSessionHolderControlResponse {
        condition.lock()
        while phase == .starting {
            condition.wait()
        }
        let response = currentResponseLocked()
        condition.unlock()
        return response
    }

    private func currentResponseLocked() -> XCTestSessionHolderControlResponse {
        XCTestSessionHolderControlResponse(
            status: phase.rawValue,
            holderPid: holderPid,
            runnerPid: runnerPid,
            sessionIdentifier: sessionIdentifier,
            bundleId: bundleId,
            controlSocketPath: controlSocketPath,
            error: error
        )
    }
}

final class XCTestSessionHolderControlServer {
    private let socketPath: String
    private let state: XCTestSessionHolderControlState
    private let eventSink: ((String) -> Void)?
    private let queue = DispatchQueue(label: "ios-use.xctest-holder.control")
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var stopped = false

    init(socketPath: String, state: XCTestSessionHolderControlState, eventSink: ((String) -> Void)? = nil) {
        self.socketPath = socketPath
        self.state = state
        self.eventSink = eventSink
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: socketPath).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIParseError.invalidValue("failed to create holder control socket: errno \(errno)")
        }
        setSocketNoSigPipe(fd)
        do {
            try bindUnixSocket(fd: fd, path: socketPath)
            guard Darwin.listen(fd, IOSUseProtocol.XCConstants.xctestHolderControlListenBacklog) == 0 else {
                throw CLIParseError.invalidValue("failed to listen on holder control socket: errno \(errno)")
            }
            lock.lock()
            listenerFD = fd
            lock.unlock()
            queue.async { [weak self] in
                self?.acceptLoop()
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            let fd = listenerFD
            guard fd >= 0 else { return }
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if isStopped { return }
                if errno == EINTR { continue }
                eventSink?("holder control accept failed errno=\(errno)")
                continue
            }
            setSocketNoSigPipe(client)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handle(clientFD: client)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer {
            Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
        }
        do {
            let request = try XCTestSessionHolderControlSocketCodec.readRequest(
                fd: clientFD,
                timeoutSeconds: IOSUseProtocol.XCConstants.xctestHolderControlReadTimeoutSeconds
            )
            let response: XCTestSessionHolderControlResponse
            switch request.command {
            case "startStatus":
                response = state.waitForStartResult()
            case "status":
                response = state.status()
            case "stop":
                response = state.requestStop()
            default:
                response = XCTestSessionHolderControlResponse(
                    status: "error",
                    holderPid: nil,
                    runnerPid: nil,
                    sessionIdentifier: nil,
                    bundleId: nil,
                    controlSocketPath: nil,
                    error: "unknown holder control command \(request.command)"
                )
            }
            try XCTestSessionHolderControlSocketCodec.writeResponse(response, fd: clientFD)
        } catch {
            eventSink?("holder control client failed: \(error)")
        }
    }
}

enum XCTestSessionHolderControlClient {
    static func request(socketPath: String, command: String, timeoutSeconds: Double) throws -> XCTestSessionHolderControlResponse {
        let fd = try connect(path: socketPath)
        defer {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        try XCTestSessionHolderControlSocketCodec.writeRequest(
            XCTestSessionHolderControlRequest(command: command),
            fd: fd
        )
        return try XCTestSessionHolderControlSocketCodec.readResponse(fd: fd, timeoutSeconds: timeoutSeconds)
    }

    private static func connect(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIParseError.invalidValue("failed to create holder control client socket: errno \(errno)")
        }
        setSocketNoSigPipe(fd)
        do {
            var address = try unixSocketAddress(path: path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw CLIParseError.invalidValue("failed to connect holder control socket: errno \(errno)")
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
}

enum XCTestSessionHolderControlSocketCodec {
    static func readRequest(fd: Int32, timeoutSeconds: Double) throws -> XCTestSessionHolderControlRequest {
        try JSONDecoder().decode(XCTestSessionHolderControlRequest.self, from: readLine(fd: fd, timeoutSeconds: timeoutSeconds))
    }

    static func readResponse(fd: Int32, timeoutSeconds: Double) throws -> XCTestSessionHolderControlResponse {
        try JSONDecoder().decode(XCTestSessionHolderControlResponse.self, from: readLine(fd: fd, timeoutSeconds: timeoutSeconds))
    }

    static func writeRequest(_ request: XCTestSessionHolderControlRequest, fd: Int32) throws {
        try writeJSON(request, fd: fd)
    }

    static func writeResponse(_ response: XCTestSessionHolderControlResponse, fd: Int32) throws {
        try writeJSON(response, fd: fd)
    }

    private static func readLine(fd: Int32, timeoutSeconds: Double) throws -> Data {
        var data = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            guard waitForReadable(fd: fd, timeoutSeconds: max(0, min(IOSUseProtocol.XCConstants.xctestHolderControlReadPollSeconds, deadline.timeIntervalSinceNow))) else {
                continue
            }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == UInt8(ascii: "\n") {
                    return data
                }
                data.append(byte)
                continue
            }
            if count == 0 {
                throw CLIParseError.invalidValue("holder control socket closed before response")
            }
            if errno == EINTR || errno == EAGAIN {
                continue
            }
            throw CLIParseError.invalidValue("holder control socket read failed: errno \(errno)")
        }
        throw CLIParseError.invalidValue("holder control socket timed out")
    }

    private static func writeJSON<T: Encodable>(_ value: T, fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        try writeAll(fd: fd, data: data)
    }
}

private func bindUnixSocket(fd: Int32, path: String) throws {
    var address = try unixSocketAddress(path: path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        throw CLIParseError.invalidValue("failed to bind holder control socket: errno \(errno)")
    }
}

private func unixSocketAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    let maxLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard bytes.count <= maxLength else {
        throw CLIParseError.invalidValue("holder control socket path too long: \(path)")
    }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: Int8.self, capacity: maxLength + 1) { raw in
            for index in 0..<bytes.count {
                raw[index] = Int8(bitPattern: bytes[index])
            }
            raw[bytes.count] = 0
        }
    }
    return address
}
