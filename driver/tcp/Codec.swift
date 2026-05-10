import Foundation

enum FrameError: Error {
    case readFailed
    case writeFailed
    case invalidLength
    case maxSizeExceeded
}

final class Codec {
    // doc 1.1 — protocol is 4-byte length prefix + JSON body; binary frame
    // follows the same length-prefix format.
    static let maxFrameSize = 10 * 1024 * 1024 // 10MB

    // MARK: - Read

    static func readFrame(_ fd: Int32) throws -> RequestFrame {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        try readExact(fd, into: &lenBuf, count: 4)

        let length = Int((UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16) | (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3]))
        guard length > 0, length <= maxFrameSize else { throw FrameError.invalidLength }

        var body = Data(count: length)
        try body.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { throw FrameError.readFailed }
            try readExact(fd, into: base, count: length)
        }

        return try JSONDecoder().decode(RequestFrame.self, from: body)
    }

    private static func readExact(_ fd: Int32, into ptr: UnsafeMutableRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, ptr.advanced(by: offset), count - offset)
            if n <= 0 { throw FrameError.readFailed }
            offset += n
        }
    }

    private static func readExact(_ fd: Int32, into buf: inout [UInt8], count: Int) throws {
        guard count > 0, buf.count >= count else { return }
        try readExact(fd, into: &buf[0], count: count)
    }

    // MARK: - Write

    static func encodeResponse(_ resp: ResponseFrame) throws -> Data {
        return try JSONEncoder().encode(resp)
    }

    /// Write a length-prefixed JSON frame. `data` is the JSON body.
    static func writeFrameData(_ fd: Int32, data: Data) throws {
        try writeLengthPrefixedData(fd, data: data)
    }

    /// doc 6.2 — binary frame. Same 4-byte length prefix as JSON frames,
    /// but the payload is raw bytes (e.g. JPEG for `screenshot`).
    static func writeBinaryFrame(_ fd: Int32, data: Data) throws {
        try writeLengthPrefixedData(fd, data: data)
    }

    private static func writeLengthPrefixedData(_ fd: Int32, data: Data) throws {
        guard data.count <= maxFrameSize else { throw FrameError.maxSizeExceeded }
        var lenBigEndian = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &lenBigEndian) { buf in
            guard let base = buf.baseAddress else { throw FrameError.writeFailed }
            try writeExact(fd, base, count: 4)
        }
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { throw FrameError.writeFailed }
            try writeExact(fd, base, count: data.count)
        }
    }

    static func writeResponse(_ fd: Int32, resp: ResponseFrame) throws {
        let data = try encodeResponse(resp)
        try writeFrameData(fd, data: data)
    }

    private static func writeExact(_ fd: Int32, _ ptr: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, ptr.advanced(by: offset), count - offset)
            if n <= 0 { throw FrameError.writeFailed }
            offset += n
        }
    }

    // MARK: - Helpers

    static func makeOK(_ data: Any? = nil) -> ResponseFrame {
        ResponseFrame(ok: true, error: nil, data: data.map { AnyCodable($0) })
    }

    static func makeError(_ msg: String) -> ResponseFrame {
        ResponseFrame(ok: false, error: msg, data: nil)
    }
}
