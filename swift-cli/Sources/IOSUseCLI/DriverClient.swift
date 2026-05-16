import Darwin
import Foundation
import IOSUseProtocol

enum DriverClientError: Error, CustomStringConvertible {
    case socketCreateFailed(Int32)
    case connectFailed(Int32)
    case readFailed
    case writeFailed
    case invalidFrameLength
    case maxFrameSizeExceeded
    case driverError(String)

    var description: String {
        switch self {
        case .socketCreateFailed(let errno): return "socket create failed: \(errno)"
        case .connectFailed(let errno): return "driver TCP connect failed: \(errno). Is the Simulator driver running?"
        case .readFailed: return "driver TCP read failed"
        case .writeFailed: return "driver TCP write failed"
        case .invalidFrameLength: return "invalid driver frame length"
        case .maxFrameSizeExceeded: return "driver frame exceeds max size"
        case .driverError(let message): return message
        }
    }
}

final class DriverClient {
    private let host: String
    private let port: UInt16
    private let udid: String?
    private let deviceType: String?
    private let fory = ForyRegistry.create()

    init(host: String = "127.0.0.1", port: UInt16 = IOSUseProtocol.defaultDriverPort, udid: String? = nil, deviceType: String? = nil) {
        self.host = host
        self.port = port
        self.udid = udid
        self.deviceType = deviceType
    }

    convenience init(session: SessionService.Info?) {
        self.init(
            port: UInt16(session?.port ?? Int(IOSUseProtocol.defaultDriverPort)),
            udid: session?.udid,
            deviceType: session?.deviceType
        )
    }

    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload {
        try send(DomCommand.self, args: ForyDomArgs(raw: raw, fresh: fresh))
    }

    func find(label: String, traits: String?) throws -> ForyFindPayload {
        try send(FindCommand.self, args: ForyFindArgs(label: label, traits: traits ?? ""))
    }

    func waitFor(label: String, timeout: Double?, traits: String?) throws -> ForyWaitForPayload {
        try send(WaitForCommand.self, args: ForyWaitForArgs(label: label, timeout: timeout ?? 0, traits: traits ?? ""))
    }

    func screenshot() throws -> Data {
        let payload = try sendRawPayload(command: DriverCommand.screenshot.rawValue, payload: Data())
        let decoded = try fory.deserialize(payload, as: ForyScreenshotPayload.self)
        return decoded.jpeg
    }

    func tap(target: ForyTarget, traits: String?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload {
        try send(TapCommand.self, args: ForyTapArgs(target: target, traits: traits ?? "", offset: offset, ratio: ratio))
    }

    func longPress(target: ForyTarget, durationMs: Int?, traits: String?) throws -> ForyElementPayload {
        let durationSeconds = durationMs.map { Double($0) / 1000.0 } ?? 0
        return try send(LongPressCommand.self, args: ForyLongPressArgs(target: target, duration: durationSeconds, traits: traits ?? ""))
    }

    func input(label: String, content: String, traits: String?) throws {
        _ = try sendRaw(InputCommand.self, args: ForyInputArgs(label: label, content: content, traits: traits ?? ""))
    }

    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?) throws -> ForySwipePayload {
        let dirValue: Int32
        switch dir {
        case "forth": dirValue = 0
        case "back": dirValue = 1
        default: dirValue = -1
        }
        return try send(SwipeCommand.self, args: ForySwipeArgs(toTarget: to, fromTarget: from, distance: distance ?? 0, dir: dirValue, traits: traits ?? ""))
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
        let fd = try connect()
        defer { Darwin.close(fd) }

        let frameData = try fory.serialize(ForyRequestFrame(command: command, payload: payload))
        try writeLengthPrefixed(fd, data: frameData)
        let responseData = try readLengthPrefixed(fd)
        let response = try fory.deserialize(responseData, as: ForyResponseFrame.self)
        guard response.ok else {
            throw DriverClientError.driverError(response.error)
        }
        return response.payload
    }

    private func connect() throws -> Int32 {
        if deviceType == "real", let udid {
            return try Usbmux.connect(udid: udid, port: Int(port))
        }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DriverClientError.socketCreateFailed(errno) }

        var noDelay: Int32 = 1
        Darwin.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

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
