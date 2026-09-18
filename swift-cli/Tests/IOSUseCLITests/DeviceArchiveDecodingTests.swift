import Foundation
import XCTest
@testable import IOSUseCLI

final class DeviceArchiveDecodingTests: XCTestCase {
    func testXCTestCapabilitiesDecodeWithoutHostXCTestFramework() throws {
        let data = try XCTestCapabilitiesPayload.encode(["XCTIssue capability": 1])
        let values = try XCTUnwrap(DTXStreamTransport.unarchivePayload(data) as? [String: Int])
        XCTAssertEqual(values["XCTIssue capability"], 1)
    }

    func testUnsupportedRemoteClassThrowsInsteadOfCrashingHost() throws {
        let data = try XCTestConfigurationPayload(
            testBundlePath: "/tmp/Driver.xctest", sessionIdentifier: UUID()
        ).encode()
        var archive = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        var objects = try XCTUnwrap(archive["$objects"] as? [Any])
        for index in objects.indices {
            if var record = objects[index] as? [String: Any], record["$classname"] as? String == "XCTestConfiguration" {
                record["$classname"] = "IOSUseUnavailableRemoteClass"
                record["$classes"] = ["IOSUseUnavailableRemoteClass", "NSObject"]
                objects[index] = record
            }
        }
        archive["$objects"] = objects
        let unsupported = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        XCTAssertThrowsError(try DTXStreamTransport.unarchivePayload(unsupported))
    }
}
