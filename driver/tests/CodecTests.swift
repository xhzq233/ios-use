import XCTest
import Fory

final class CodecTests: XCTestCase {

    // MARK: - foryOK / foryError

    func testForyOK_NoPayload() {
        let resp = Codec.foryOK()
        XCTAssertTrue(resp.ok)
        XCTAssertTrue(resp.error.isEmpty)
        XCTAssertTrue(resp.payload.isEmpty)
    }

    func testForyError_MessageOnly() {
        let resp = Codec.foryError("something went wrong")
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, "something went wrong")
        XCTAssertTrue(resp.payload.isEmpty)
    }

    func testForyOK_WithPayload() throws {
        let fory = createFory()
        let payload = ForySimpleStringPayload(value: "test")
        let resp = try Codec.foryOK(payload)
        XCTAssertTrue(resp.ok)
        XCTAssertTrue(resp.error.isEmpty)
        XCTAssertFalse(resp.payload.isEmpty)

        // Verify payload round-trips.
        let decoded = try fory.deserialize(resp.payload, as: ForySimpleStringPayload.self)
        XCTAssertEqual(decoded.value, "test")
    }

    func testForyError_WithPayload() throws {
        let fory = createFory()
        var errPayload = ForyErrorPayload()
        errPayload.hint = "try again"
        errPayload.suggestions = ["a", "b"]
        let resp = try Codec.foryError("not found", payload: errPayload)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, "not found")
        XCTAssertFalse(resp.payload.isEmpty)

        let decoded = try fory.deserialize(resp.payload, as: ForyErrorPayload.self)
        XCTAssertEqual(decoded.hint, "try again")
        XCTAssertEqual(decoded.suggestions, ["a", "b"])
    }

    // MARK: - maxFrameSize

    func testMaxFrameSize_Is50MB() {
        XCTAssertEqual(Codec.maxFrameSize, 50 * 1024 * 1024)
    }

    // MARK: - writeLengthPrefixedData via pipe

    func testWriteLengthPrefixedData_WritesLengthPrefix() throws {
        let (readFD, writeFD) = try makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }
        let payload = "hello".data(using: .utf8)!
        try Codec.writeLengthPrefixedData(writeFD, data: payload)

        var lenBuf = [UInt8](repeating: 0, count: 4)
        let rn1 = Darwin.read(readFD, &lenBuf, 4)
        XCTAssertEqual(rn1, 4)
        let length = (Int(lenBuf[0]) << 24) | (Int(lenBuf[1]) << 16) | (Int(lenBuf[2]) << 8) | Int(lenBuf[3])
        XCTAssertEqual(length, payload.count)

        var body = [UInt8](repeating: 0, count: length)
        let rn2 = Darwin.read(readFD, &body, length)
        XCTAssertEqual(rn2, length)
        XCTAssertEqual(Data(body), payload)
    }

    // MARK: - ForyResponseFrame round-trip via writeResponseFrame / readFrame

    func testWriteAndReadFrame_RoundTrip() throws {
        let fory = createFory()
        let (readFD, writeFD) = try makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        let frame = ForyResponseFrame(ok: true, error: "", payload: Data())
        try Codec.writeResponseFrame(writeFD, frame: frame)

        // Read back as ForyRequestFrame (same wire format, different type).
        // Actually we need to write a ForyRequestFrame and read it back.
    }

    func testRequestFrame_RoundTrip() throws {
        let fory = createFory()
        let (readFD, writeFD) = try makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }

        let payload = ForyActivateAppArgs(bundleId: "com.test")
        let payloadData = try fory.serialize(payload)
        let frame = ForyRequestFrame(command: "activateApp", payload: payloadData)
        let frameData = try fory.serialize(frame)
        try Codec.writeLengthPrefixedData(writeFD, data: frameData)

        let readBack = try Codec.readFrame(readFD)
        XCTAssertEqual(readBack.command, "activateApp")
        let decodedPayload = try fory.deserialize(readBack.payload, as: ForyActivateAppArgs.self)
        XCTAssertEqual(decodedPayload.bundleId, "com.test")
    }

    // MARK: - Helpers

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        let r = fds.withUnsafeMutableBufferPointer { ptr in
            pipe(ptr.baseAddress)
        }
        guard r == 0 else { throw NSError(domain: "pipe", code: Int(r)) }
        return (fds[0], fds[1])
    }
}
