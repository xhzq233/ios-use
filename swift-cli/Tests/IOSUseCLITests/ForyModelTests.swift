import XCTest
import IOSUseProtocol

final class ForyModelTests: XCTestCase {
    func testForyRegistryCanSerializeRequestFrame() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyWaitForArgs(target: ForyTarget(label: "General", traits: "Cell", cindex: -1), timeout: 1.5))
        let frame = ForyRequestFrame(command: DriverCommand.waitFor.rawValue, payload: payload)
        let encoded = try fory.serialize(frame)
        let decoded = try fory.deserialize(encoded, as: ForyRequestFrame.self)

        XCTAssertEqual(decoded.command, "waitFor")
        let args = try fory.deserialize(decoded.payload, as: ForyWaitForArgs.self)
        XCTAssertEqual(args.target.label, "General")
        XCTAssertEqual(args.target.traits, "Cell")
        XCTAssertEqual(args.target.cindex, -1)
        XCTAssertEqual(args.timeout, 1.5)
    }

    func testForyRegistryCanSerializeResponseFrame() throws {
        let fory = ForyRegistry.create()
        let frame = ForyResponseFrame(ok: true, payload: Data([1, 2, 3]))

        let encoded = try fory.serialize(frame)
        let decoded = try fory.deserialize(encoded, as: ForyResponseFrame.self)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.payload, Data([1, 2, 3]))
    }

    func testForyTargetSerializesNilAndPositiveCindex() throws {
        let fory = ForyRegistry.create()
        let nilEncoded = try fory.serialize(ForyTarget(label: "General", traits: "Cell"))
        let nilDecoded = try fory.deserialize(nilEncoded, as: ForyTarget.self)
        XCTAssertEqual(nilDecoded.label, "General")
        XCTAssertEqual(nilDecoded.traits, "Cell")
        XCTAssertNil(nilDecoded.cindex)

        let positiveEncoded = try fory.serialize(ForyTarget(label: "General", traits: "Cell", cindex: 2))
        let positiveDecoded = try fory.deserialize(positiveEncoded, as: ForyTarget.self)
        XCTAssertEqual(positiveDecoded.cindex, 2)
    }

    func testForyDomArgsSerializesWaitQuiescence() throws {
        let fory = ForyRegistry.create()
        let encoded = try fory.serialize(ForyDomArgs(raw: false, fresh: true, waitQuiescence: true))
        let decoded = try fory.deserialize(encoded, as: ForyDomArgs.self)

        XCTAssertFalse(decoded.raw)
        XCTAssertTrue(decoded.fresh)
        XCTAssertTrue(decoded.waitQuiescence)
    }

    func testForyRegistryCanSerializeProxyCAPushArgs() throws {
        let fory = ForyRegistry.create()
        let encoded = try fory.serialize(ForyProxyCAPushArgs(caBase64: "abc123"))
        let decoded = try fory.deserialize(encoded, as: ForyProxyCAPushArgs.self)

        XCTAssertEqual(decoded.caBase64, "abc123")
    }
}
