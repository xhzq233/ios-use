import XCTest
@testable import IOSUseDaemonRuntime

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
              A-UDID → bundleId: com.example.a, port: (missing), driverVersion: (missing)
              B-UDID → bundleId: com.example.b, port: 8100, driverVersion: (missing)
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

    func testDriverAssetPathFollowsBuildConfiguration() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])

        #if DEBUG
        let cwd = FileManager.default.currentDirectoryPath
        let localDriver = "\(cwd)/assets/driver.ipa"
        let localSimulatorDriver = "\(cwd)/assets/driver-sim.ipa"
        XCTAssertEqual(
            ConfigService.deviceIPAPath(paths: paths),
            FileManager.default.fileExists(atPath: localDriver) ? localDriver : "\(root)/driver.ipa"
        )
        XCTAssertEqual(
            ConfigService.simulatorIPAPath(paths: paths),
            FileManager.default.fileExists(atPath: localSimulatorDriver) ? localSimulatorDriver : "\(root)/driver-sim.ipa"
        )
        #else
        XCTAssertEqual(ConfigService.deviceIPAPath(paths: paths), "\(root)/driver.ipa")
        XCTAssertEqual(ConfigService.simulatorIPAPath(paths: paths), "\(root)/driver-sim.ipa")
        #endif
    }

    func testStopDeletesResidualSessionFile() throws {
        let root = try temporaryRoot()
        let state = "\(root)/state"
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        try "{}".write(toFile: "\(state)/session.json", atomically: true, encoding: .utf8)

        let result = executeTestCLI(environment: ["IOS_USE_HOME": root], arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Daemon stopped\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(state)/session.json"))
    }

    func testDriverBootstrapLaunchesRequestedSimulatorWithoutTrustingExistingLocalhostPort() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-B":{"bundleId":"com.iosuse.xcuidriver.xctrunner","port":"8100","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [IOSDevice(name: "Requested", version: "26.0", udid: "SIM-B", kind: .simulator)] : []
        }
        var launched: [String] = []
        var terminated: [String] = []
        DriverBootstrap.simulatorDriverReachableForTesting = { true }
        DriverBootstrap.simulatorDriverLauncherForTesting = { launched.append($0) }
        DriverBootstrap.simulatorDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return true
        }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            DriverBootstrap.simulatorDriverReachableForTesting = nil
            DriverBootstrap.simulatorDriverLauncherForTesting = nil
            DriverBootstrap.simulatorDriverTerminatorForTesting = nil
        }

        let endpoint = try DriverBootstrap.resolveEndpoint(session: SessionOptions(udid: "SIM-B"), current: nil, paths: paths)

        XCTAssertEqual(endpoint.udid, "SIM-B")
        XCTAssertEqual(endpoint.deviceType, "simulator")
        XCTAssertEqual(launched, ["SIM-B"])
        XCTAssertEqual(terminated, ["SIM-B"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/state/session.json"))
    }

    func testDriverBootstrapRelaunchesSimulatorWhenSwitchingUdids() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-A":{"bundleId":"com.iosuse.xcuidriver.xctrunner","port":"8100","driverVersion":"\(IOSUseCLI.version)"},"SIM-B":{"bundleId":"com.iosuse.xcuidriver.xctrunner","port":"8100","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [
                IOSDevice(name: "Current", version: "26.0", udid: "SIM-A", kind: .simulator),
                IOSDevice(name: "Requested", version: "26.0", udid: "SIM-B", kind: .simulator),
            ] : []
        }
        var launched: [String] = []
        var terminated: [String] = []
        DriverBootstrap.simulatorDriverReachableForTesting = { true }
        DriverBootstrap.simulatorDriverLauncherForTesting = { launched.append($0) }
        DriverBootstrap.simulatorDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return true
        }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            DriverBootstrap.simulatorDriverReachableForTesting = nil
            DriverBootstrap.simulatorDriverLauncherForTesting = nil
            DriverBootstrap.simulatorDriverTerminatorForTesting = nil
        }

        let endpoint = try DriverBootstrap.resolveEndpoint(
            session: SessionOptions(udid: "SIM-B"),
            current: DriverEndpoint(udid: "SIM-A", deviceName: "Current", deviceVersion: "26.0", deviceType: "simulator"),
            paths: paths
        )

        XCTAssertEqual(endpoint.udid, "SIM-B")
        XCTAssertEqual(endpoint.deviceType, "simulator")
        XCTAssertEqual(launched, ["SIM-B"])
        XCTAssertEqual(terminated, ["SIM-A", "SIM-B"])
    }

    func testDriverBootstrapUsesUsbFastPathForExplicitRealDevice() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-FAST":{"bundleId":"com.example.driver","port":"8100","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)

        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-FAST"] }
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly, "explicit USB real-device path should not call xctrace real-device listing")
            return []
        }
        var launched: [String] = []
        DriverBootstrap.realDriverReachableForTesting = { udid in
            launched.contains(udid)
        }
        DriverBootstrap.realDriverLauncherForTesting = { udid, bundleId in
            launched.append(udid)
            XCTAssertEqual(bundleId, "com.example.driver")
        }
        addTeardownBlock {
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.listDevicesOverrideForTesting = nil
            DriverBootstrap.realDriverReachableForTesting = nil
            DriverBootstrap.realDriverLauncherForTesting = nil
        }

        let endpoint = try DriverBootstrap.resolveEndpoint(session: SessionOptions(udid: "REAL-FAST"), current: nil, paths: paths)

        XCTAssertEqual(launched, ["REAL-FAST"])
        XCTAssertEqual(endpoint.udid, "REAL-FAST")
        XCTAssertEqual(endpoint.deviceType, "real")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/state/session.json"))
    }

    func testDriverBootstrapRejectsOutdatedDriverVersion() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-OLD":{"bundleId":"com.example.driver","port":"8100","driverVersion":"0.9.0"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DriverBootstrap.resolveEndpoint(session: SessionOptions(udid: "REAL-OLD"), current: nil, paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("current CLI is \(IOSUseCLI.version)"))
            XCTAssertTrue(String(describing: error).contains("ios-use config --udid REAL-OLD"))
        }
    }

    private func temporaryRoot() throws -> String {
        let root = NSTemporaryDirectory() + "ios-use-swift-config-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        return root
    }
}
