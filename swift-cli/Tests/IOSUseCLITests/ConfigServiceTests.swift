import XCTest
@testable import IOSUseCLI

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

    func testReusableBundleIdIgnoresMissingSentinel() {
        XCTAssertNil(ConfigService.reusableBundleId(from: nil))
        XCTAssertNil(ConfigService.reusableBundleId(from: DeviceConfigEntry(udid: "A-UDID", bundleId: "", port: "8100")))
        XCTAssertNil(ConfigService.reusableBundleId(from: DeviceConfigEntry(udid: "A-UDID", bundleId: "(missing)", port: "8100")))
        XCTAssertEqual(
            ConfigService.reusableBundleId(from: DeviceConfigEntry(udid: "A-UDID", bundleId: "com.example.runner", port: "8100")),
            "com.example.runner"
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

    func testWriteSimulatorSessionUsesTsCompatibleShape() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])

        try SessionService.writeSimulatorSession(
            udid: "SIM-1",
            deviceName: "IOSUseTest",
            deviceVersion: "26.0",
            paths: paths
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/state/session.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((json["sessionId"] as? String)?.hasPrefix("session-") == true)
        XCTAssertEqual(json["udid"] as? String, "SIM-1")
        XCTAssertEqual(json["port"] as? Int, 8100)
        XCTAssertEqual(json["deviceName"] as? String, "IOSUseTest")
        XCTAssertEqual(json["deviceVersion"] as? String, "26.0")
        XCTAssertEqual(json["deviceType"] as? String, "simulator")
        XCTAssertNotNil(json["createdAt"])
    }

    func testPrepareDriverSessionFastPathsMatchingSimulatorSession() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        SessionService.simulatorDriverReachableForTesting = { true }
        addTeardownBlock {
            SessionService.simulatorDriverReachableForTesting = nil
            SessionService.simulatorDriverLauncherForTesting = nil
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-FAST":{"bundleId":"com.iosuse.xcuidriver.xctrunner","port":"8100"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeSimulatorSession(
            udid: "SIM-FAST",
            deviceName: "IOSUseTest",
            deviceVersion: "26.0",
            paths: paths
        )

        XCTAssertNoThrow(try SessionService.prepareDriverSession(SessionOptions(udid: "SIM-FAST"), paths: paths))
    }

    func testPrepareDriverSessionLaunchesRequestedSimulatorWhenSessionDoesNotMatch() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-A":{"bundleId":"com.iosuse.xcuidriver.xctrunner","port":"8100"},"SIM-B":{"bundleId":"com.iosuse.xcuidriver.xctrunner","port":"8100"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeSimulatorSession(
            udid: "SIM-A",
            deviceName: "Other",
            deviceVersion: "26.0",
            paths: paths
        )
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [IOSDevice(name: "Requested", version: "26.0", udid: "SIM-B", kind: .simulator)] : []
        }
        var launched: [String] = []
        SessionService.simulatorDriverReachableForTesting = { true }
        SessionService.simulatorDriverLauncherForTesting = { launched.append($0) }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.simulatorDriverReachableForTesting = nil
            SessionService.simulatorDriverLauncherForTesting = nil
        }

        try SessionService.prepareDriverSession(SessionOptions(udid: "SIM-B"), paths: paths)

        XCTAssertEqual(launched, ["SIM-B"])
        XCTAssertEqual(SessionService.read(paths: paths)?.udid, "SIM-B")
    }

    private func temporaryRoot() throws -> String {
        let root = NSTemporaryDirectory() + "ios-use-swift-config-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        return root
    }
}
