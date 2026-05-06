import XCTest

// Tests for Codec (doc 1.1 — length-prefixed JSON framing, 6.2 — binary frame).
final class CodecTests: XCTestCase {

    // MARK: - makeOK / makeError

    func testMakeOK_NoData() {
        let resp = Codec.makeOK()
        XCTAssertTrue(resp.ok)
        XCTAssertNil(resp.error)
        XCTAssertNil(resp.data)
    }

    func testMakeOK_WithString() {
        let resp = Codec.makeOK("hello")
        XCTAssertTrue(resp.ok)
        XCTAssertNil(resp.error)
        XCTAssertEqual(resp.data?.value as? String, "hello")
    }

    func testMakeOK_WithInt() {
        let resp = Codec.makeOK(42)
        XCTAssertTrue(resp.ok)
        XCTAssertNil(resp.error)
        XCTAssertEqual(resp.data?.value as? Int, 42)
    }

    func testMakeOK_WithDict() {
        let resp = Codec.makeOK(["a": 1, "b": "x"])
        XCTAssertTrue(resp.ok)
        let d = resp.data?.value as? [String: Any]
        XCTAssertEqual(d?["a"] as? Int, 1)
        XCTAssertEqual(d?["b"] as? String, "x")
    }

    func testMakeError() {
        let resp = Codec.makeError("something went wrong")
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, "something went wrong")
        XCTAssertNil(resp.data)
    }

    // MARK: - encodeResponse JSON shape (doc 1.1 — {ok, error, data})

    func testEncodeResponse_OK_String() throws {
        let data = try Codec.encodeResponse(Codec.makeOK("pong"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertTrue(obj?["error"] is NSNull)
        XCTAssertEqual(obj?["data"] as? String, "pong")
    }

    func testEncodeResponse_OK_Nil() throws {
        let data = try Codec.encodeResponse(Codec.makeOK())
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertTrue(obj?["error"] is NSNull)
        XCTAssertTrue(obj?["data"] is NSNull)
    }

    func testEncodeResponse_Error() throws {
        let data = try Codec.encodeResponse(Codec.makeError("timeout"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["error"] as? String, "timeout")
        XCTAssertTrue(obj?["data"] is NSNull)
    }

    func testEncodeResponse_NestedDict() throws {
        let resp = Codec.makeOK([
            "type": "Button",
            "rect": [10, 20, 30, 40],
            "flag": true,
        ])
        let data = try Codec.encodeResponse(resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let d = obj?["data"] as? [String: Any]
        XCTAssertEqual(d?["type"] as? String, "Button")
        XCTAssertEqual((d?["rect"] as? [Any])?.count, 4)
        XCTAssertEqual(d?["flag"] as? Bool, true)
    }

    func testEncodeResponse_NonFiniteDoubleBecomesNull() throws {
        let resp = Codec.makeOK(["x": Double.nan, "y": Double.infinity, "z": 1.5])
        let data = try Codec.encodeResponse(resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let d = obj?["data"] as? [String: Any]
        XCTAssertTrue(d?["x"] is NSNull)
        XCTAssertTrue(d?["y"] is NSNull)
        XCTAssertEqual(d?["z"] as? Double, 1.5)
    }

    // MARK: - RequestFrame decoding (doc 1.1 — {c, args})

    func testRequestFrame_CreateSession_WithBundleId() throws {
        let json = #"{"c":"createSession","args":{"bundleId":"com.apple.Preferences"}}"#
        let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(req.c, .createSession)
        let args = try decodeArgs(req.args, as: CreateSessionArgs.self)
        XCTAssertEqual(args.bundleId, "com.apple.Preferences")
    }

    func testRequestFrame_Tap_WithLabel() throws {
        let json = #"{"c":"tap","args":{"label":"Settings"}}"#
        let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(req.c, .tap)
        let args = try decodeArgs(req.args, as: TapArgs.self)
        XCTAssertEqual(args.label.asLabel, "Settings")
    }

    func testRequestFrame_Tap_WithPoint() throws {
        let json = #"{"c":"tap","args":{"label":[100,200]}}"#
        let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
        let args = try decodeArgs(req.args, as: TapArgs.self)
        XCTAssertEqual(args.label.asPoint, [100, 200])
    }

    func testRequestFrame_Tap_WithOffset() throws {
        let json = #"{"c":"tap","args":{"label":"Slider","offset":{"xRatio":0.8,"yRatio":0.5}}}"#
        let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
        let args = try decodeArgs(req.args, as: TapArgs.self)
        XCTAssertEqual(args.label.asLabel, "Slider")
        XCTAssertEqual(args.offset?.xRatio, 0.8)
        XCTAssertEqual(args.offset?.yRatio, 0.5)
    }

    func testRequestFrame_Swipe_WithDir() throws {
        let json = #"{"c":"swipe","args":{"dir":"forth","distance":300}}"#
        let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(req.c, .swipe)
        let args = try decodeArgs(req.args, as: SwipeArgs.self)
        XCTAssertEqual(args.dir, .forth)
        XCTAssertEqual(args.distance, 300)
    }

    func testRequestFrame_Oslog_Flags() throws {
        let json = #"{"c":"oslog","args":{"pattern":"ERROR","flags":"i","name":"err","clear":true,"bundleId":"com.apple.Preferences","timeout":2}}"#
        let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(req.c, .oslog)
        let args = try decodeArgs(req.args, as: OslogArgs.self)
        XCTAssertEqual(args.pattern, "ERROR")
        XCTAssertEqual(args.flags, "i")
        XCTAssertEqual(args.name, "err")
        XCTAssertEqual(args.clear, true)
        XCTAssertEqual(args.bundleId, "com.apple.Preferences")
        XCTAssertEqual(args.timeout, 2)
    }

    func testRequestFrame_WaitFor_Defaults() throws {
        let json = #"{"c":"waitFor","args":{"label":"Loading"}}"#
        let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(req.c, .waitFor)
        let args = try decodeArgs(req.args, as: WaitForArgs.self)
        XCTAssertEqual(args.label, "Loading")
        XCTAssertNil(args.timeout)
        XCTAssertNil(args.context)
    }

    // MARK: - maxFrameSize

    func testMaxFrameSize_IsTenMB() {
        XCTAssertEqual(Codec.maxFrameSize, 10 * 1024 * 1024)
    }

    // MARK: - writeBinaryFrame / writeFrameData via pipe (doc 6.2)

    func testWriteFrameData_WritesLengthPrefix() throws {
        let (readFD, writeFD) = try makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }
        let payload = "hello".data(using: .utf8)!
        try Codec.writeFrameData(writeFD, data: payload)

        // First 4 bytes = big-endian length.
        var lenBuf = [UInt8](repeating: 0, count: 4)
        let rn1 = Darwin.read(readFD, &lenBuf, 4)
        XCTAssertEqual(rn1, 4)
        let length = (Int(lenBuf[0]) << 24) | (Int(lenBuf[1]) << 16) | (Int(lenBuf[2]) << 8) | Int(lenBuf[3])
        XCTAssertEqual(length, payload.count)

        // Next `length` bytes = body.
        var body = [UInt8](repeating: 0, count: length)
        let rn2 = Darwin.read(readFD, &body, length)
        XCTAssertEqual(rn2, length)
        XCTAssertEqual(Data(body), payload)
    }

    func testWriteBinaryFrame_UsesSameLengthPrefix() throws {
        let (readFD, writeFD) = try makePipe()
        defer {
            close(readFD)
            close(writeFD)
        }
        // Arbitrary binary bytes (would be JPEG in real use).
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        try Codec.writeBinaryFrame(writeFD, data: payload)

        var lenBuf = [UInt8](repeating: 0, count: 4)
        _ = Darwin.read(readFD, &lenBuf, 4)
        let length = (Int(lenBuf[0]) << 24) | (Int(lenBuf[1]) << 16) | (Int(lenBuf[2]) << 8) | Int(lenBuf[3])
        XCTAssertEqual(length, payload.count)

        var body = [UInt8](repeating: 0, count: length)
        _ = Darwin.read(readFD, &body, length)
        XCTAssertEqual(Data(body), payload)
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
