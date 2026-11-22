import XCTest
@testable import IOSUseCLI

final class DirectDeviceConnectionTests: XCTestCase {
    private func record(_ host: String = "test-host") throws -> PairRecord {
        try PairRecord.decode(PropertyListSerialization.data(fromPropertyList: [
            "HostID": host, "SystemBUID": "test-system",
            "HostPrivateKey": Data("test-key".utf8),
            "HostCertificate": Data("test-certificate".utf8)
        ], format: .binary, options: 0))
    }
    func testImportedIdentityIsScopedAndNestedOverridesRestore() throws {
        XCTAssertNil(DirectDeviceConnection.current)
        let outer = DirectDeviceConnection(host: "127.0.0.1", pairRecord: try record())
        try DirectDeviceConnection.$current.withValue(outer) {
            XCTAssertEqual(try PairRecord.load(udid: "self").hostID, "test-host")
            let inner = DirectDeviceConnection(host: "127.0.0.2", pairRecord: try record("nested"))
            try DirectDeviceConnection.$current.withValue(inner) {
                XCTAssertEqual(try PairRecord.load(udid: "self").hostID, "nested")
            }
            XCTAssertEqual(try PairRecord.load(udid: "self").hostID, "test-host")
        }
        XCTAssertNil(DirectDeviceConnection.current)
    }
    func testIncompleteImportedIdentityIsRejected() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["HostID":"test-host"], format: .xml, options: 0)
        XCTAssertThrowsError(try PairRecord.decode(data))
    }
}
