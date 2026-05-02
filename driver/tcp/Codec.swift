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
        let payload = responseJSONObject(resp)
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw FrameError.writeFailed
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
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

    // MARK: - JSON sanitation

    private static func responseJSONObject(_ resp: ResponseFrame) -> [String: Any] {
        var obj: [String: Any] = ["ok": resp.ok]
        if let error = resp.error {
            obj["error"] = error
        } else {
            obj["error"] = NSNull()
        }
        if let data = resp.data {
            obj["data"] = sanitizeJSONValue(data.value)
        } else {
            obj["data"] = NSNull()
        }
        return obj
    }

    private static func sanitizeJSONValue(_ value: Any) -> Any {
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSString { return String(v) }
        if let v = value as? Bool { return v }
        if let v = value as? Int { return v }
        if let v = value as? Int8 { return Int(v) }
        if let v = value as? Int16 { return Int(v) }
        if let v = value as? Int32 { return Int(v) }
        if let v = value as? Int64 { return v }
        if let v = value as? UInt { return v }
        if let v = value as? UInt8 { return UInt(v) }
        if let v = value as? UInt16 { return UInt(v) }
        if let v = value as? UInt32 { return UInt(v) }
        if let v = value as? UInt64 { return v }
        if let v = value as? Double { return v.isFinite ? v : NSNull() }
        if let v = value as? Float { return v.isFinite ? Double(v) : NSNull() }
        if let v = value as? NSNumber { return v }

        if let arr = value as? [Any] { return arr.map { sanitizeJSONValue($0) } }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = sanitizeJSONValue(v)
            }
            return out
        }

        // Encodable fallback — best-effort generic serialization.
        if let encodable = value as? Encodable,
           let data = try? JSONEncoder().encode(AnyEncodableWrapper(encodable)),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []) {
            return obj
        }

        return NSNull()
    }

    // MARK: - Helpers

    static func makeOK(_ data: Any? = nil) -> ResponseFrame {
        ResponseFrame(ok: true, error: nil, data: data.map { AnyCodable($0) })
    }

    static func makeError(_ msg: String) -> ResponseFrame {
        ResponseFrame(ok: false, error: msg, data: nil)
    }
}

// Type-erasing Encodable wrapper (used only as a fallback in sanitizeJSONValue).
private struct AnyEncodableWrapper: Encodable {
    let encode: (Encoder) throws -> Void
    init(_ encodable: Encodable) {
        self.encode = { enc in try encodable.encode(to: enc) }
    }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
