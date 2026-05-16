import XCTest
import IOSUseCLI

final class ConfigServiceTests: XCTestCase {
    func testConfigListFormatsEntriesInStableOrder() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let config = """
        {
          "devices": {
            "B-UDID": { "bundleId": "com.example.b", "port": 8100 },
            "A-UDID": { "bundleId": "com.example.a" }
          }
        }
        """
        try config.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)

        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])

        XCTAssertEqual(ConfigService.listEntries(paths: paths), [
            DeviceConfigEntry(udid: "A-UDID", bundleId: "com.example.a", port: "(missing)"),
            DeviceConfigEntry(udid: "B-UDID", bundleId: "com.example.b", port: "8100")
        ])
        XCTAssertEqual(
            ConfigService.formatList(ConfigService.listEntries(paths: paths)),
            """
            Configured devices:
              A-UDID → bundleId: com.example.a, port: (missing)
              B-UDID → bundleId: com.example.b, port: 8100
            """ + "\n"
        )
    }

    func testStopClearsOnlyIsolatedSessionFile() throws {
        let root = try temporaryRoot()
        let sessionDir = "\(root)/state"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        try "{}".write(toFile: "\(sessionDir)/session.json", atomically: true, encoding: .utf8)

        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])
        let result = cli.run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Session stopped\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(sessionDir)/session.json"))
    }

    func testConfigListThroughCLIUsesIsolatedHome() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-1":{"bundleId":"com.iosuse.xcuidriver.xctrunner","port":"8100"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["config", "--list"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("SIM-1"))
        XCTAssertTrue(result.stdout.contains("com.iosuse.xcuidriver.xctrunner"))
    }

    private func temporaryRoot() throws -> String {
        let root = NSTemporaryDirectory() + "ios-use-swift-config-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        return root
    }
}
