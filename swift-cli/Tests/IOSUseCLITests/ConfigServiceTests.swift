import XCTest
@testable import IOSUseCLI

final class ConfigServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        Shell.runOverrideForTesting = nil
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.usbDeviceUdidsOverrideForTesting = nil
        DeviceService.resetCacheForTesting()
        SessionService.simulatorDriverReachableForTesting = nil
        SessionService.simulatorDriverLauncherForTesting = nil
        SessionService.simulatorDriverTerminatorForTesting = nil
        SessionService.realDriverReachableForTesting = nil
        SessionService.realDriverLauncherForTesting = nil
        SessionService.realDriverTerminatorForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        super.tearDown()
    }

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
            DeviceConfigEntry(udid: "A-UDID", bundleId: "com.example.a"),
            DeviceConfigEntry(udid: "B-UDID", bundleId: "com.example.b")
        ])
        XCTAssertEqual(
            ConfigService.formatList(ConfigService.listEntries(paths: paths)),
            """
            Configured devices:
              A-UDID → bundleId: com.example.a, driverVersion: (missing)
              B-UDID → bundleId: com.example.b, driverVersion: (missing)
            """ + "\n"
        )
    }

    func testReusableBundleIdIgnoresMissingSentinel() {
        XCTAssertNil(ConfigService.reusableBundleId(from: nil))
        XCTAssertNil(ConfigService.reusableBundleId(from: DeviceConfigEntry(udid: "A-UDID", bundleId: "")))
        XCTAssertNil(ConfigService.reusableBundleId(from: DeviceConfigEntry(udid: "A-UDID", bundleId: "(missing)")))
        XCTAssertEqual(
            ConfigService.reusableBundleId(from: DeviceConfigEntry(udid: "A-UDID", bundleId: "com.example.runner")),
            "com.example.runner"
        )
    }

    func testDriverAssetPathFollowsBuildConfiguration() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])

        let cwd = FileManager.default.currentDirectoryPath
        let localDriver = "\(cwd)/assets/driver.ipa"
        let localSimulatorDriver = "\(cwd)/assets/driver-sim.ipa"
        let expectedDriver = FileManager.default.fileExists(atPath: localDriver) ? localDriver : "\(root)/driver.ipa"
        let expectedSimulatorDriver = FileManager.default.fileExists(atPath: localSimulatorDriver) ? localSimulatorDriver : "\(root)/driver-sim.ipa"
        XCTAssertEqual(
            ConfigService.deviceIPAPath(paths: paths),
            expectedDriver
        )
        XCTAssertEqual(
            ConfigService.simulatorIPAPath(paths: paths),
            expectedSimulatorDriver
        )

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: "\(root)/driver.ipa"))
        try Data().write(to: URL(fileURLWithPath: "\(root)/driver-sim.ipa"))
        XCTAssertEqual(ConfigService.deviceIPAPath(paths: paths), expectedDriver)
        XCTAssertEqual(ConfigService.simulatorIPAPath(paths: paths), expectedSimulatorDriver)
    }

    func testDriverLockRejectsInvalidShapeAndDoesNotFallbackToSessionJSON() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try """
        {"sessionId":"legacy","udid":"SESSION-ONLY","deviceType":"simulator"}
        """.write(toFile: paths.session, atomically: true, encoding: .utf8)
        try """
        {"udid":"LOCK-ONLY"}
        """.write(toFile: paths.driverLock, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SessionService.requireDriverLock(paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid driver.lock: missing udid/deviceType."))
        }
        XCTAssertNil(SessionService.readDriverLock(paths: paths))

        try FileManager.default.removeItem(atPath: paths.driverLock)
        XCTAssertNil(SessionService.read(paths: paths))
    }

    func testStopWithoutDriverLockFailsWithoutDiscoveryOrStateCleanup() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try "{}".write(toFile: paths.session, atomically: true, encoding: .utf8)
        try "nslog".write(toFile: "\(root)/state/nslog.lock", atomically: true, encoding: .utf8)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("stop without driver.lock must not discover devices")
            return []
        }
        SessionService.realDriverTerminatorForTesting = { _ in
            XCTFail("stop without driver.lock must not terminate real driver")
            return true
        }
        SessionService.simulatorDriverTerminatorForTesting = { _ in
            XCTFail("stop without driver.lock must not terminate simulator driver")
            return true
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("No active driver. Run `ios-use start <UDID>` first."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.session))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root)/state/nslog.lock"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))
    }

    func testStopTerminatesRealDriverAndOnlyClearsDriverLock() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try writeDriverLock(udid: "REAL-1", deviceType: "real", paths: paths)
        try "{}".write(toFile: paths.session, atomically: true, encoding: .utf8)
        try "nslog".write(toFile: "\(root)/state/nslog.lock", atomically: true, encoding: .utf8)
        var terminated: [String] = []
        SessionService.realDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return true
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver app terminated on device\nDriver stopped\n")
        XCTAssertEqual(terminated, ["REAL-1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.session))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root)/state/nslog.lock"))
    }

    func testStopClearsStaleSimulatorDriverLockWhenAppAlreadyStopped() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-1", deviceType: "simulator", paths: paths)
        var terminated: [String] = []
        SessionService.simulatorDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return false
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver app was not running on simulator\nDriver stopped\n")
        XCTAssertNil(SessionService.readDriverLock(paths: paths))
        XCTAssertEqual(terminated, ["SIM-1"])
    }

    func testStartCommandCreatesFullSimulatorDriverLockWithoutSessionJSON() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-START":{"bundleId":"com.iosuse.xcuidriver.xctrunner","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [IOSDevice(name: "IOSUseTest", version: "26.0", udid: "SIM-START", kind: .simulator)] : []
        }
        var launched: [String] = []
        SessionService.simulatorDriverReachableForTesting = { !launched.isEmpty }
        SessionService.simulatorDriverLauncherForTesting = { launched.append($0) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "SIM-START"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver started for SIM-START\n")
        XCTAssertEqual(launched, ["SIM-START"])
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.udid, "SIM-START")
        XCTAssertEqual(lock.deviceType, "simulator")
        XCTAssertEqual(lock.deviceName, "IOSUseTest")
        XCTAssertEqual(lock.deviceVersion, "26.0")
        XCTAssertGreaterThan(lock.startedAt, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.session))
    }

    func testStartCommandCreatesFullRealDriverLockWithoutSessionJSON() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-START":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-START"] }
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [] : [IOSDevice(name: "Phone", version: "26.0", udid: "REAL-START", kind: .real)]
        }
        var launched: [(String, String)] = []
        SessionService.realDriverReachableForTesting = { _ in !launched.isEmpty }
        SessionService.realDriverLauncherForTesting = { udid, bundleId in launched.append((udid, bundleId)) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "REAL-START"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(launched.map(\.0), ["REAL-START"])
        XCTAssertEqual(launched.map(\.1), ["com.example.driver"])
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.udid, "REAL-START")
        XCTAssertEqual(lock.deviceType, "real")
        XCTAssertEqual(lock.deviceName, "Phone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.session))
    }

    func testStartRejectsExistingLockAndPreservesIt() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-A", deviceType: "simulator", paths: paths, startedAt: 42)
        SessionService.simulatorDriverLauncherForTesting = { _ in
            XCTFail("start with existing driver.lock must not launch")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "SIM-B"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Driver already started for SIM-A"))
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.udid, "SIM-A")
        XCTAssertEqual(lock.startedAt, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.session))
    }

    func testStartRejectsUnconfiguredOutdatedAndMissingDevicesWithoutLock() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        var result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "SIM-MISSING"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("No signing config found for device SIM-MISSING"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))

        try """
        {"devices":{"REAL-OLD":{"bundleId":"com.example.driver","driverVersion":"0.9.0"},"REAL-NOTFOUND":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "REAL-OLD"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("installed: 0.9.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))

        DeviceService.usbDeviceUdidsOverrideForTesting = { [] }
        DeviceService.listDevicesOverrideForTesting = { _, _ in [] }
        result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "REAL-NOTFOUND"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Device REAL-NOTFOUND not found."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))
    }

    func testStartLaunchFailureDoesNotLeaveDriverLock() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-FAIL":{"bundleId":"com.iosuse.xcuidriver.xctrunner","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [IOSDevice(name: "IOSUseTest", version: "26.0", udid: "SIM-FAIL", kind: .simulator)] : []
        }
        SessionService.simulatorDriverLauncherForTesting = { _ in
            throw CLIParseError.invalidValue("launch failed")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "SIM-FAIL"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("launch failed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.session))
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
        XCTAssertFalse(result.stdout.contains("port:"))
    }

    private func writeDriverLock(udid: String, deviceType: String, paths: IOSUsePaths, startedAt: Int = 1) throws {
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: udid,
                deviceName: deviceType == "simulator" ? "IOSUseTest" : "Phone",
                deviceVersion: "26.0",
                deviceType: deviceType,
                startedAt: startedAt
            ),
            paths: paths
        )
    }

    private func temporaryRoot() throws -> String {
        let root = NSTemporaryDirectory() + "ios-use-swift-config-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        return root
    }

}
