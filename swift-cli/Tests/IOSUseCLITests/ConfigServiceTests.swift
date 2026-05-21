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

    func testStopClearsOnlyIsolatedSessionFile() throws {
        let root = try temporaryRoot()
        let sessionDir = "\(root)/state"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        try "{}".write(toFile: "\(sessionDir)/session.json", atomically: true, encoding: .utf8)

        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])
        let result = cli.run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "No active session\nSession stopped\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(sessionDir)/session.json"))
    }

    func testStopWithoutSessionDoesNotDiscoverOrTerminateRealDevice() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        var didListDevices = false
        var terminated: [String] = []
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            didListDevices = true
            return [IOSDevice(name: "Phone", version: "26.0", udid: "REAL-1", kind: .real)]
        }
        SessionService.realDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return true
        }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.realDriverTerminatorForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(didListDevices)
        XCTAssertEqual(terminated, [])
        XCTAssertEqual(result.stdout, "No active session\nSession stopped\n")
        XCTAssertNil(SessionService.read(paths: paths))
    }

    func testStopTerminatesRealDeviceDriverBeforeClearingSession() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeSession(
            udid: "REAL-1",
            deviceName: "Phone",
            deviceVersion: "26.0",
            deviceType: "real",
            paths: paths
        )
        var terminated: [String] = []
        SessionService.realDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return true
        }
        addTeardownBlock {
            SessionService.realDriverTerminatorForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(terminated, ["REAL-1"])
        XCTAssertEqual(result.stdout, "Driver app terminated on device\nSession stopped\n")
        XCTAssertNil(SessionService.read(paths: paths))
    }

    func testStopClearsSimulatorSessionWithoutTerminatingDriver() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeSimulatorSession(
            udid: "SIM-1",
            deviceName: "IOSUseTest",
            deviceVersion: "26.0",
            paths: paths
        )

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Session stopped\n")
        XCTAssertNil(SessionService.read(paths: paths))
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

    func testWriteSimulatorSessionUsesCurrentShapeWithoutPort() throws {
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
        XCTAssertNil(json["port"])
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
        {"devices":{"SIM-FAST":{"bundleId":"com.iosuse.xcuidriver.xctrunner","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeSimulatorSession(
            udid: "SIM-FAST",
            deviceName: "IOSUseTest",
            deviceVersion: "26.0",
            paths: paths
        )

        XCTAssertNoThrow(try SessionService.prepareDriverSession(SessionOptions(udid: "SIM-FAST"), paths: paths))
    }

    func testPrepareDriverSessionReusesActiveSimulatorSessionWithoutUdid() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-ACTIVE":{"bundleId":"com.iosuse.xcuidriver.xctrunner","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeSimulatorSession(
            udid: "SIM-ACTIVE",
            deviceName: "IOSUseTest",
            deviceVersion: "26.0",
            paths: paths
        )
        var deviceListCalls = 0
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            deviceListCalls += 1
            return []
        }
        SessionService.simulatorDriverReachableForTesting = { true }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.simulatorDriverReachableForTesting = nil
        }

        try SessionService.prepareDriverSession(SessionOptions(), paths: paths)

        XCTAssertEqual(deviceListCalls, 0)
        XCTAssertEqual(SessionService.read(paths: paths)?.udid, "SIM-ACTIVE")
    }

    func testPrepareDriverSessionLaunchesRequestedSimulatorWhenSessionWasStopped() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-STOPPED":{"bundleId":"com.iosuse.xcuidriver.xctrunner","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [IOSDevice(name: "IOSUseTest", version: "26.0", udid: "SIM-STOPPED", kind: .simulator)] : []
        }
        var launched: [String] = []
        SessionService.simulatorDriverReachableForTesting = { true }
        SessionService.simulatorDriverLauncherForTesting = { launched.append($0) }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.simulatorDriverReachableForTesting = nil
            SessionService.simulatorDriverLauncherForTesting = nil
        }

        try SessionService.prepareDriverSession(SessionOptions(udid: "SIM-STOPPED"), paths: paths)

        XCTAssertEqual(launched, ["SIM-STOPPED"])
        XCTAssertEqual(SessionService.read(paths: paths)?.udid, "SIM-STOPPED")
    }

    func testPrepareDriverSessionLaunchesRequestedSimulatorWhenSessionDoesNotMatch() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-A":{"bundleId":"com.iosuse.xcuidriver.xctrunner","driverVersion":"\(IOSUseCLI.version)"},"SIM-B":{"bundleId":"com.iosuse.xcuidriver.xctrunner","driverVersion":"\(IOSUseCLI.version)"}}}
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

    func testPrepareDriverSessionDoesNotProbeOrLaunchExplicitRealDevice() throws {
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
        let launched: [String] = []
        SessionService.realDriverReachableForTesting = { udid in
            XCTFail("prepareDriverSession should not probe real driver reachability before a command")
            return false
        }
        SessionService.realDriverLauncherForTesting = { udid, bundleId in
            XCTFail("prepareDriverSession should not launch real driver before a command")
        }
        addTeardownBlock {
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.realDriverReachableForTesting = nil
            SessionService.realDriverLauncherForTesting = nil
        }

        try SessionService.prepareDriverSession(SessionOptions(udid: "REAL-FAST"), paths: paths)

        XCTAssertEqual(launched, [])
        let session = try XCTUnwrap(SessionService.read(paths: paths))
        XCTAssertEqual(session.udid, "REAL-FAST")
        XCTAssertEqual(session.deviceType, "real")
    }

    func testLaunchPreparedDriverSessionStartsRealDriverAfterCommandConnectFailure() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-RETRY":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeSession(
            udid: "REAL-RETRY",
            deviceName: "Phone",
            deviceVersion: "26.0",
            deviceType: "real",
            paths: paths
        )

        var launched: [(String, String)] = []
        var reachabilityChecks = 0
        SessionService.realDriverReachableForTesting = { udid in
            XCTAssertEqual(udid, "REAL-RETRY")
            reachabilityChecks += 1
            return !launched.isEmpty
        }
        SessionService.realDriverLauncherForTesting = { udid, bundleId in
            launched.append((udid, bundleId))
        }
        addTeardownBlock {
            SessionService.realDriverReachableForTesting = nil
            SessionService.realDriverLauncherForTesting = nil
        }

        try SessionService.launchPreparedDriverSession(paths: paths, verbose: false)

        XCTAssertEqual(launched.map(\.0), ["REAL-RETRY"])
        XCTAssertEqual(launched.map(\.1), ["com.example.driver"])
        XCTAssertEqual(reachabilityChecks, 1)
    }

    func testPrepareDriverSessionRejectsOutdatedDriverVersion() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-OLD":{"bundleId":"com.example.driver","driverVersion":"0.9.0"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SessionService.prepareDriverSession(SessionOptions(udid: "REAL-OLD"), paths: paths)) { error in
            XCTAssertTrue(String(describing: error).contains("current CLI is \(IOSUseCLI.version)"))
            XCTAssertTrue(String(describing: error).contains("ios-use config --udid REAL-OLD"))
        }
    }

    func testPrepareDriverSessionIgnoresStaleSessionPortField() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-STALE":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try """
        {
          "sessionId": "session-old",
          "udid": "REAL-STALE",
          "port": 8100,
          "deviceName": "Phone",
          "deviceVersion": "26.0",
          "deviceType": "real",
          "createdAt": 1
        }
        """.write(toFile: "\(root)/state/session.json", atomically: true, encoding: .utf8)

        try SessionService.prepareDriverSession(SessionOptions(), paths: paths)

        let session = try XCTUnwrap(SessionService.read(paths: paths))
        XCTAssertEqual(session.udid, "REAL-STALE")
    }

    private func temporaryRoot() throws -> String {
        let root = NSTemporaryDirectory() + "ios-use-swift-config-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        return root
    }
}
