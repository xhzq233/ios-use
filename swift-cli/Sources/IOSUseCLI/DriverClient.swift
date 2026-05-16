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
    private let fory = ForyRegistry.create()

    init(host: String = "127.0.0.1", port: UInt16 = IOSUseProtocol.defaultDriverPort) {
        self.host = host
        self.port = port
    }

    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload {
        let payload = try send(command: DriverCommand.dom.rawValue, args: ForyDomArgs(raw: raw, fresh: fresh))
        return try fory.deserialize(payload, as: ForyDomPayload.self)
    }

    func find(label: String, traits: String?) throws -> ForyFindPayload {
        let payload = try send(command: DriverCommand.find.rawValue, args: ForyFindArgs(label: label, traits: traits ?? ""))
        return try fory.deserialize(payload, as: ForyFindPayload.self)
    }

    func waitFor(label: String, timeout: Double?, traits: String?) throws -> ForyWaitForPayload {
        let payload = try send(command: DriverCommand.waitFor.rawValue, args: ForyWaitForArgs(label: label, timeout: timeout ?? 0, traits: traits ?? ""))
        return try fory.deserialize(payload, as: ForyWaitForPayload.self)
    }

    func screenshot() throws -> Data {
        let payload = try sendRawPayload(command: DriverCommand.screenshot.rawValue, payload: Data())
        let decoded = try fory.deserialize(payload, as: ForyScreenshotPayload.self)
        return decoded.jpeg
    }

    private func send<Args>(command: String, args: Args) throws -> Data {
        let payload = try fory.serialize(args)
        return try sendRawPayload(command: command, payload: payload)
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
