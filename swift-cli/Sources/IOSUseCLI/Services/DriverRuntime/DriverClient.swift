import Darwin
import Foundation
import IOSUseProtocol

enum DriverClientError: Error, CustomStringConvertible {
    case socketCreateFailed(Int32)
    case connectFailed(Int32)
    case connectFailedMessage(String, recoverable: Bool)
    case readFailed
    case writeFailed
    case invalidFrameLength
    case maxFrameSizeExceeded
    case driverError(String)

    var description: String {
        switch self {
        case .socketCreateFailed(let errno): return "socket create failed: \(errno)"
        case .connectFailed(let errno): return "driver TCP connect failed: \(errno). Is the Simulator driver running?"
        case .connectFailedMessage(let message, _): return "driver TCP connect failed: \(message)"
        case .readFailed: return "driver TCP read failed"
        case .writeFailed: return "driver TCP write failed"
        case .invalidFrameLength: return "invalid driver frame length"
        case .maxFrameSizeExceeded: return "driver frame exceeds max size"
        case .driverError(let message):
            return message
        }
    }

    var isRecoverableConnectFailure: Bool {
        switch self {
        case .connectFailed:
            return true
        case .connectFailedMessage(_, let recoverable):
            return recoverable
        default:
            return false
        }
    }

}

protocol DriverCommandClient: AnyObject {
    func close()
    func dom(raw: Bool, fresh: Bool, waitQuiescence: Bool) throws -> ForyDomPayload
    func find(label: String, traits: String?, cindex: Int32?) throws -> ForyFindPayload
    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload
    func screenshot() throws -> Data
    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload
    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload
    func input(tap: ForyTarget?, content: String) throws
    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload
    func activateApp(bundleId: String) throws
    func terminateApp(bundleId: String) throws
    func home() throws
    func dismissAlert(index: Int?) throws -> ForyAlertPayload
    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload
}

enum DriverCommandExecution {
    static var clientFactoryForTesting: ((SessionService.Info) -> DriverCommandClient)?

    static func withLockedClient<T>(paths: IOSUsePaths, verbose: Bool = false, _ body: (DriverCommandClient) throws -> T) throws -> T {
        let session = LockedDriverClientSession(paths: paths, verbose: verbose)
        defer { session.close() }
        return try session.run(body)
    }
}

final class LockedDriverClientSession {
    private let paths: IOSUsePaths
    private let verbose: Bool
    private var info: SessionService.Info?
    private var client: DriverCommandClient?
    private var didRecoverConnectFailure = false

    init(paths: IOSUsePaths, verbose: Bool = false) {
        self.paths = paths
        self.verbose = verbose
    }

    func run<T>(_ body: (DriverCommandClient) throws -> T) throws -> T {
        let lock = try lockedInfo()
        do {
            return try body(currentClient(for: lock))
        } catch {
            guard (error as? DriverClientError)?.isRecoverableConnectFailure == true,
                  !didRecoverConnectFailure else {
                throw error
            }
            didRecoverConnectFailure = true
            let recoveredLock = try relaunchDriver(for: lock)
            return try body(replaceClient(for: recoveredLock))
        }
    }

    func close() {
        closeClient()
    }

    private func lockedInfo() throws -> SessionService.Info {
        if let info {
            return info
        }
        let lock = try SessionService.requireDriverLock(paths: paths)
        info = lock
        return lock
    }

    private func currentClient(for info: SessionService.Info) -> DriverCommandClient {
        if let client {
            return client
        }
        return replaceClient(for: info)
    }

    private func replaceClient(for info: SessionService.Info) -> DriverCommandClient {
        closeClient()
        let next = DriverCommandExecution.clientFactoryForTesting?(info) ?? DriverClient(session: info, paths: paths)
        client = next
        return next
    }

    private func relaunchDriver(for lock: SessionService.Info) throws -> SessionService.Info {
        closeClient()
        let holderResult = DriverLifecycleService.terminateFullXCTestHolderIfNeeded(info: lock, paths: paths)
        if holderResult != .notApplicable {
            CLILogService.append(paths: paths, ["[cli-lifecycle] XCTest holder cleanup before relaunch: \(holderResult)"])
        }
        let recoveredLock: SessionService.Info
        if let metadata = try SessionService.launchDriver(for: lock, paths: paths, verbose: verbose) {
            recoveredLock = lock.applying(metadata)
            try SessionService.writeDriverLock(info: recoveredLock, paths: paths)
        } else {
            recoveredLock = lock
        }
        info = recoveredLock
        return recoveredLock
    }

    private func closeClient() {
        client?.close()
        client = nil
    }
}

private extension ForyTarget {
    func withLookup(traits: String?, cindex: Int32?) -> ForyTarget {
        ForyTarget(label: label, point: point, traits: traits ?? self.traits, cindex: cindex ?? self.cindex)
    }
}

final class DriverClient: DriverCommandClient {
    static var usbmuxConnectorForTesting: ((String, Int) throws -> Int32)?

    private let host: String
    private let port: UInt16
    private let udid: String?
    private let deviceType: String?
    private let cliLogPath: String?
    private let socketTimeoutSeconds: Int
    private let fory = ForyRegistry.create()
    private var fd: Int32?

    init(
        host: String = "127.0.0.1",
        port: UInt16 = IOSUseProtocol.defaultDriverPort,
        udid: String? = nil,
        deviceType: String? = nil,
        cliLogPath: String? = nil,
        socketTimeoutSeconds: Int = IOSUseProtocol.commandSocketReadTimeoutSeconds
    ) {
        self.host = host
        self.port = port
        self.udid = udid
        self.deviceType = deviceType
        self.cliLogPath = cliLogPath
        self.socketTimeoutSeconds = socketTimeoutSeconds
    }

    convenience init(
        session: SessionService.Info,
        paths: IOSUsePaths? = nil,
        socketTimeoutSeconds: Int = IOSUseProtocol.commandSocketReadTimeoutSeconds
    ) {
        self.init(
            udid: session.udid,
            deviceType: session.deviceType,
            cliLogPath: paths.map { CLILogService.logPath(paths: $0) },
            socketTimeoutSeconds: socketTimeoutSeconds
        )
    }

    deinit {
        close()
    }

    func close() {
        if let fd {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            self.fd = nil
        }
    }

    func dom(raw: Bool, fresh: Bool, waitQuiescence: Bool = false) throws -> ForyDomPayload {
        try send(DomCommand.self, args: ForyDomArgs(raw: raw, fresh: fresh, waitQuiescence: waitQuiescence))
    }

    func find(label: String, traits: String?, cindex: Int32? = nil) throws -> ForyFindPayload {
        try send(FindCommand.self, args: ForyFindArgs(target: ForyTarget(label: label, traits: traits ?? "", cindex: cindex)))
    }

    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32? = nil) throws -> ForyWaitForPayload {
        try send(WaitForCommand.self, args: ForyWaitForArgs(target: ForyTarget(label: label, traits: traits ?? "", cindex: cindex), timeout: timeout ?? 0))
    }

    func screenshot() throws -> Data {
        let payload = try sendRawPayload(command: DriverCommand.screenshot.rawValue, payload: Data())
        let decoded = try fory.deserialize(payload, as: ForyScreenshotPayload.self)
        return decoded.jpeg
    }

    func tap(target: ForyTarget, traits: String?, cindex: Int32? = nil, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload {
        try send(TapCommand.self, args: ForyTapArgs(target: target.withLookup(traits: traits, cindex: cindex), offset: offset, ratio: ratio))
    }

    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32? = nil) throws -> ForyElementPayload {
        let durationSeconds = durationMs.map { Double($0) / 1000.0 } ?? 0
        return try send(LongPressCommand.self, args: ForyLongPressArgs(target: target.withLookup(traits: traits, cindex: cindex), duration: durationSeconds))
    }

    func input(tap: ForyTarget?, content: String) throws {
        _ = try sendRaw(InputCommand.self, args: ForyInputArgs(target: tap ?? ForyTarget(), content: content))
    }

    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32? = nil) throws -> ForySwipePayload {
        let dirValue: Int32
        switch dir {
        case "forth": dirValue = 0
        case "back": dirValue = 1
        default: dirValue = -1
        }
        return try send(SwipeCommand.self, args: ForySwipeArgs(toTarget: to.withLookup(traits: traits, cindex: cindex), fromTarget: from, distance: distance ?? 0, dir: dirValue))
    }

    func activateApp(bundleId: String) throws {
        _ = try sendRaw(ActivateAppCommand.self, args: ForyActivateAppArgs(bundleId: bundleId))
    }

    func terminateApp(bundleId: String) throws {
        _ = try sendRaw(TerminateAppCommand.self, args: ForyTerminateAppArgs(bundleId: bundleId))
    }

    func home() throws {
        _ = try sendRawPayload(command: DriverCommand.home.rawValue, payload: Data())
    }

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        try send(DismissAlertCommand.self, args: ForyDismissAlertArgs(index: Int32(index ?? -1)))
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        try send(ProxyCAPushCommand.self, args: ForyProxyCAPushArgs(caBase64: caBase64))
    }

    private func send<B: DriverCommandBinding>(_ binding: B.Type, args: B.Args) throws -> B.Payload {
        let payload = try sendRaw(binding, args: args)
        return try fory.deserialize(payload, as: B.Payload.self)
    }

    private func sendRaw<B: DriverCommandBinding>(_ binding: B.Type, args: B.Args) throws -> Data {
        let payload = try fory.serialize(args)
        return try sendRawPayload(command: binding.command.rawValue, payload: payload)
    }

    private func sendRawPayload(command: String, payload: Data) throws -> Data {
        let startedAt = CFAbsoluteTimeGetCurrent()
        var requestBytes = 0
        var responseBytes = 0
        var loggedResponse = false
        var didUseConnection = false
        do {
            let frameData = try fory.serialize(ForyRequestFrame(command: command, payload: payload))
            requestBytes = frameData.count
            let fd = try connectedFD()
            didUseConnection = true
            try writeLengthPrefixed(fd, data: frameData)
            let responseData = try readLengthPrefixed(fd)
            responseBytes = responseData.count
            let response = try fory.deserialize(responseData, as: ForyResponseFrame.self)
            appendDriverCommandLog(
                command: command,
                ok: response.ok,
                error: response.error,
                requestBytes: requestBytes,
                responseBytes: responseBytes,
                elapsedMs: elapsedMilliseconds(since: startedAt)
            )
            loggedResponse = true
            guard response.ok else {
                if response.error.hasPrefix("[FATAL]") {
                    close()
                }
                throw DriverClientError.driverError(response.error)
            }
            return response.payload
        } catch {
            if !loggedResponse {
                appendDriverCommandLog(
                    command: command,
                    ok: false,
                    error: "\(error)",
                    requestBytes: requestBytes,
                    responseBytes: responseBytes,
                    elapsedMs: elapsedMilliseconds(since: startedAt)
                )
            }
            if didUseConnection && shouldCloseConnection(after: error) {
                close()
            }
            throw error
        }
    }

    private func appendDriverCommandLog(command: String, ok: Bool, error: String, requestBytes: Int, responseBytes: Int, elapsedMs: Int) {
        guard let cliLogPath else { return }
        let status = ok ? "ok=true" : "ok=false error=\(error)"
        let lines = [
            "[cli-command] command=\(command) \(status) requestBytes=\(requestBytes) responseBytes=\(responseBytes) elapsed=\(elapsedMs)ms"
        ]
        CLILogService.append(logPath: cliLogPath, lines)
    }

    private func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond)
    }

    private func connectedFD() throws -> Int32 {
        if let fd {
            return fd
        }
        let newFD = try connect()
        fd = newFD
        return newFD
    }

    private func shouldCloseConnection(after error: Error) -> Bool {
        switch error {
        case DriverClientError.driverError(let message):
            return message.hasPrefix("[FATAL]")
        default:
            return true
        }
    }

    private func connect() throws -> Int32 {
        if deviceType == "real", let udid {
            do {
                let connector = Self.usbmuxConnectorForTesting ?? { try Usbmux.connect(udid: $0, port: $1) }
                let fd = try connector(udid, Int(port))
                configureSocket(fd)
                return fd
            } catch let error as DriverClientError {
                throw error
            } catch let error as UsbmuxError {
                switch error {
                case .connectFailed:
                    throw DriverClientError.connectFailedMessage(error.description, recoverable: true)
                default:
                    throw DriverClientError.connectFailedMessage(error.description, recoverable: false)
                }
            } catch {
                throw DriverClientError.connectFailedMessage(
                    String(describing: error),
                    recoverable: false
                )
            }
        }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DriverClientError.socketCreateFailed(errno) }
        configureSocket(fd)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            throw DriverClientError.connectFailed(err)
        }
        return fd
    }

    private func configureSocket(_ fd: Int32) {
        var noDelay: Int32 = 1
        Darwin.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: time_t(socketTimeoutSeconds), tv_usec: 0)
        Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readLengthPrefixed(_ fd: Int32) throws -> Data {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        try readExact(fd, into: &lengthBytes, count: 4)
        let length = Int((UInt32(lengthBytes[0]) << 24) | (UInt32(lengthBytes[1]) << 16) | (UInt32(lengthBytes[2]) << 8) | UInt32(lengthBytes[3]))
        guard length > 0 else { throw DriverClientError.invalidFrameLength }
        guard length <= IOSUseProtocol.maxFrameSizeBytes else { throw DriverClientError.maxFrameSizeExceeded }

        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw DriverClientError.readFailed }
            try readExact(fd, into: base, count: length)
        }
        return data
    }

    private func writeLengthPrefixed(_ fd: Int32, data: Data) throws {
        guard data.count <= IOSUseProtocol.maxFrameSizeBytes else { throw DriverClientError.maxFrameSizeExceeded }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { buffer in
            guard let base = buffer.baseAddress else { throw DriverClientError.writeFailed }
            try writeExact(fd, base, count: 4)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw DriverClientError.writeFailed }
            try writeExact(fd, base, count: data.count)
        }
    }

    private func readExact(_ fd: Int32, into buffer: inout [UInt8], count: Int) throws {
        try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { throw DriverClientError.readFailed }
            try readExact(fd, into: base, count: count)
        }
    }

    private func readExact(_ fd: Int32, into pointer: UnsafeMutableRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, pointer.advanced(by: offset), count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw DriverClientError.readFailed
            }
            if n == 0 { throw DriverClientError.readFailed }
            offset += n
        }
    }

    private func writeExact(_ fd: Int32, _ pointer: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, pointer.advanced(by: offset), count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw DriverClientError.writeFailed
            }
            if n == 0 { throw DriverClientError.writeFailed }
            offset += n
        }
    }
}
