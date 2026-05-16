import XCTest
import IOSUseProtocol

final class ForyModelTests: XCTestCase {
    func testForyRegistryCanSerializeRequestFrame() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyFindArgs(label: "General", traits: "Cell"))
        let frame = ForyRequestFrame(command: DriverCommand.find.rawValue, payload: payload)
        let encoded = try fory.serialize(frame)
        let decoded = try fory.deserialize(encoded, as: ForyRequestFrame.self)

        XCTAssertEqual(decoded.command, "find")
        let args = try fory.deserialize(decoded.payload, as: ForyFindArgs.self)
        XCTAssertEqual(args.label, "General")
        XCTAssertEqual(args.traits, "Cell")
    }
}
