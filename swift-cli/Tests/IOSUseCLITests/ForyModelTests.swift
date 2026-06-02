import XCTest
import IOSUseProtocol

final class ForyModelTests: XCTestCase {
    func testForyRegistryCanSerializeRequestFrame() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyFindArgs(target: ForyTarget(label: "General", traits: "Cell", cindex: -1)))
        let frame = ForyRequestFrame(command: DriverCommand.find.rawValue, payload: payload)
        let encoded = try fory.serialize(frame)
        let decoded = try fory.deserialize(encoded, as: ForyRequestFrame.self)

        XCTAssertEqual(decoded.command, "find")
        let args = try fory.deserialize(decoded.payload, as: ForyFindArgs.self)
        XCTAssertEqual(args.target.label, "General")
        XCTAssertEqual(args.target.traits, "Cell")
        XCTAssertEqual(args.target.cindex, -1)
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

    func testForyRegistryCanSerializeProxyCAPushArgs() throws {
        let fory = ForyRegistry.create()
        let encoded = try fory.serialize(ForyProxyCAPushArgs(caBase64: "abc123"))
        let decoded = try fory.deserialize(encoded, as: ForyProxyCAPushArgs.self)

        XCTAssertEqual(decoded.caBase64, "abc123")
    }
}
