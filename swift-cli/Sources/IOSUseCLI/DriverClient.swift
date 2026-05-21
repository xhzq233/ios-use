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
    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload
    func find(label: String, traits: String?, cindex: Int32?) throws -> ForyFindPayload
    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload
    func screenshot() throws -> Data
    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload
    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload
    func input(label: String, content: String, traits: String?, cindex: Int32?) throws
    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload
    func activateApp(bundleId: String) throws
    func terminateApp(bundleId: String) throws
    func home() throws
    func openURL(url: String) throws -> ForySimpleStringPayload
    func dismissAlert(index: Int?) throws -> ForyAlertPayload
    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload
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
    private let fory = ForyRegistry.create()
    private var fd: Int32?

    init(host: String = "127.0.0.1", port: UInt16 = IOSUseProtocol.defaultDriverPort, udid: String? = nil, deviceType: String? = nil) {
        self.host = host
        self.port = port
        self.udid = udid
        self.deviceType = deviceType
    }

    convenience init(session: SessionService.Info?) {
        self.init(
            udid: session?.udid,
            deviceType: session?.deviceType
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

    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload {
        try send(DomCommand.self, args: ForyDomArgs(raw: raw, fresh: fresh))
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

    func input(label: String, content: String, traits: String?, cindex: Int32? = nil) throws {
        _ = try sendRaw(InputCommand.self, args: ForyInputArgs(target: ForyTarget(label: label, traits: traits ?? "", cindex: cindex), content: content))
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

    func openURL(url: String) throws -> ForySimpleStringPayload {
        try send(OpenURLCommand.self, args: ForyOpenURLArgs(url: url))
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
        do {
            let fd = try connectedFD()
            let frameData = try fory.serialize(ForyRequestFrame(command: command, payload: payload))
            try writeLengthPrefixed(fd, data: frameData)
            let responseData = try readLengthPrefixed(fd)
            let response = try fory.deserialize(responseData, as: ForyResponseFrame.self)
            guard response.ok else {
                close()
                throw DriverClientError.driverError(response.error)
            }
            return response.payload
        } catch {
            if shouldCloseConnection(after: error) {
                close()
            }
            throw error
        }
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
        case DriverClientError.readFailed,
             DriverClientError.writeFailed,
             DriverClientError.invalidFrameLength,
             DriverClientError.maxFrameSizeExceeded,
             DriverClientError.driverError:
            return true
        default:
            return false
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
            } catch {
                let message = String(describing: error)
                throw DriverClientError.connectFailedMessage(
                    message,
                    recoverable: message.contains("usbmux Connect failed")
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
