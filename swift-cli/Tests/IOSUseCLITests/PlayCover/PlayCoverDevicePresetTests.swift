import XCTest
@testable import IOSUseCLI

final class PlayCoverDevicePresetTests: XCTestCase {
    func testConfigPersistsSelectionWithoutSigningAndRejectsUnknownPreset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["IOS_USE_HOME": directory.path]
        let cli = IOSUseCLI(environment: environment)
        let paths = IOSUsePaths.resolve(environment: environment)
        let original = try PlayCoverDevicePreset.configured(paths: paths)
        XCTAssertEqual(original.logicalSize, CGSize(width: 430, height: 932))

        XCTAssertEqual(cli.run(arguments: ["config", "--mac", "--device-model", "ipad-pro-11", "--json"]).exitCode, 0)
        let configured = try PlayCoverDevicePreset.configured(paths: paths)
        XCTAssertEqual(configured.logicalSize, CGSize(width: 834, height: 1194))
        XCTAssertEqual(configured.nativeSize, CGSize(width: 1668, height: 2388))
        XCTAssertNotEqual(cli.run(arguments: ["config", "--mac", "--device-model", "unknown", "--json"]).exitCode, 0)
        XCTAssertEqual(try PlayCoverDevicePreset.configured(paths: paths).logicalSize, configured.logicalSize)
        XCTAssertThrowsError(try CLIParser.parse(["config", "--device-model", "ipad-pro-11"]))
    }
}
