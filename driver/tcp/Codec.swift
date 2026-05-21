import Foundation
import Fory

enum FrameError: Error {
    case readFailed
    case writeFailed
    case invalidLength
    case maxSizeExceeded
}

final class Codec {
    static let maxFrameSize = IOSUseProtocol.maxFrameSizeBytes
    static let sharedFory: Fory = createFory()

    // MARK: - Read

    /// Read a single length-prefixed Fory frame and deserialize as ForyRequestFrame.
    static func readFrame(_ fd: Int32) throws -> ForyRequestFrame {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        try readExact(fd, into: &lenBuf, count: 4)

        let length = Int((UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16) | (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3]))
        guard length > 0, length <= IOSUseProtocol.maxFrameSizeBytes else { throw FrameError.invalidLength }

        var body = Data(count: length)
        try body.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { throw FrameError.readFailed }
            try readExact(fd, into: base, count: length)
        }

        return try sharedFory.deserialize(body, as: ForyRequestFrame.self)
    }

    private static func readExact(_ fd: Int32, into ptr: UnsafeMutableRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, ptr.advanced(by: offset), count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw FrameError.readFailed
            }
            if n == 0 { throw FrameError.readFailed }
            offset += n
        }
    }

    private static func readExact(_ fd: Int32, into buf: inout [UInt8], count: Int) throws {
        guard count > 0, buf.count >= count else { return }
        try readExact(fd, into: &buf[0], count: count)
    }

    // MARK: - Write

    /// Serialize and write a ForyResponseFrame as a single length-prefixed frame.
    static func writeResponseFrame(_ fd: Int32, frame: ForyResponseFrame) throws {
        let data = try sharedFory.serialize(frame)
        try writeLengthPrefixedData(fd, data: data)
    }

    static func writeLengthPrefixedData(_ fd: Int32, data: Data) throws {
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

    private static func writeExact(_ fd: Int32, _ ptr: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, ptr.advanced(by: offset), count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw FrameError.writeFailed
            }
            if n == 0 { throw FrameError.writeFailed }
            offset += n
        }
    }

    // MARK: - ForyResponseFrame helpers

    static func foryOK() -> ForyResponseFrame {
        ForyResponseFrame(ok: true, error: "", payload: Data())
    }

    static func foryOK<P>(_ payload: P) throws -> ForyResponseFrame {
        let data = try sharedFory.serialize(payload)
        return ForyResponseFrame(ok: true, error: "", payload: data)
    }

    static func foryError(_ msg: String) -> ForyResponseFrame {
        ForyResponseFrame(ok: false, error: msg, payload: Data())
    }
}
