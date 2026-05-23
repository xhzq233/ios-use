import XCTest
@testable import IOSUseCLI

final class ConfigServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        Shell.runOverrideForTesting = nil
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

    func testReadDriverIdentityFromInfoPlistReadsStampedFields() throws {
        let root = try temporaryRoot()
        let plist = "\(root)/Info.plist"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleShortVersionString</key>
          <string>1.2.3</string>
          <key>CFBundleVersion</key>
          <string>20260521000000-abcdef123456</string>
        </dict>
        </plist>
        """.write(toFile: plist, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try ConfigService.readDriverIdentityFromInfoPlist(plist),
            DriverIdentity(version: "1.2.3", build: "20260521000000-abcdef123456")
        )
    }

    func testParseDriverIdentityUsesOnlyTargetAppRecord() {
        let output = """
        Bundle Identifier: com.example.other
        CFBundleShortVersionString: 9.9.9
        CFBundleVersion: other-build

        Bundle Identifier: com.example.driver
        CFBundleShortVersionString: 1.0.3
        CFBundleVersion: 20260522010000-3d54a6c2d7cd
        """

        XCTAssertEqual(
            ConfigService.parseDriverIdentity(fromDeviceInfoAppsOutput: output, bundleId: "com.example.driver"),
            DriverIdentity(version: "1.0.3", build: "20260522010000-3d54a6c2d7cd")
        )
    }

    func testParseDevicectlAppsJSONUsesTargetBundleOnly() throws {
        let root = try temporaryRoot()
        let jsonPath = "\(root)/apps.json"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {
          "result": {
            "apps": [
              {
                "bundleIdentifier": "com.example.other",
                "version": "9.9.9",
                "bundleVersion": "other-build"
              },
              {
                "bundleIdentifier": "com.example.driver",
                "version": "1.0.3",
                "bundleVersion": "20260522010000-3d54a6c2d7cd"
              }
            ]
          }
        }
        """.write(toFile: jsonPath, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ConfigService.parseDriverIdentity(fromDevicectlAppsJSONAtPath: jsonPath, bundleId: "com.example.driver"),
            DriverIdentity(version: "1.0.3", build: "20260522010000-3d54a6c2d7cd")
        )
    }

    func testReadRealDeviceInstalledIdentityReadsDevicectlVersionAndBundleVersion() throws {
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun" {
                XCTAssertEqual(Array(arguments.prefix(7)), ["devicectl", "device", "info", "apps", "--device", "REAL-1", "--bundle-id"])
                let jsonIndex = try XCTUnwrap(arguments.firstIndex(of: "--json-output"))
                let jsonPath = arguments[jsonIndex + 1]
                try """
                {
                  "result": {
                    "apps": [
                      {
                        "bundleIdentifier": "com.example.driver",
                        "version": "\(IOSUseCLI.version)",
                        "bundleVersion": "20260522010000-3d54a6c2d7cd"
                      }
                    ]
                  }
                }
                """.write(toFile: jsonPath, atomically: true, encoding: .utf8)
                return ""
            }
            XCTFail("Unexpected command \(executable) \(arguments)")
            return ""
        }

        XCTAssertEqual(
            try ConfigService.readRealDeviceInstalledDriverIdentity(udid: "REAL-1", bundleId: "com.example.driver"),
            DriverIdentity(version: IOSUseCLI.version, build: "20260522010000-3d54a6c2d7cd")
        )
    }

    func testReadRealDeviceInstalledIdentityRejectsOldUnstampedDeviceBuild() {
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun" {
                let jsonIndex = try XCTUnwrap(arguments.firstIndex(of: "--json-output"))
                let jsonPath = arguments[jsonIndex + 1]
                try """
                {
                  "result": {
                    "apps": [
                      {
                        "bundleIdentifier": "com.example.driver",
                        "version": "1.0",
                        "bundleVersion": "1"
                      }
                    ]
                  }
                }
                """.write(toFile: jsonPath, atomically: true, encoding: .utf8)
                return ""
            }
            XCTFail("Unexpected command \(executable) \(arguments)")
            return ""
        }

        XCTAssertThrowsError(try ConfigService.readRealDeviceInstalledDriverIdentity(udid: "REAL-1", bundleId: "com.example.driver")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Unable to verify installed driver identity"))
            XCTAssertTrue(message.contains("does not match CLI version") || message.contains("not stamped"))
        }
    }

    func testReadSimulatorInstalledIdentityRejectsMissingInstalledPlistWithoutLocalFallback() {
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun", Array(arguments.prefix(3)) == ["simctl", "get_app_container", "SIM-1"] {
                throw CLIParseError.invalidValue("container missing")
            }
            XCTFail("Unexpected command \(executable) \(arguments)")
            return ""
        }

        XCTAssertThrowsError(try ConfigService.readSimulatorInstalledDriverIdentity(udid: "SIM-1", bundleId: ConfigService.simulatorBundleId)) { error in
            XCTAssertTrue(String(describing: error).contains("Unable to verify installed Simulator driver identity"))
        }
    }

    func testStopClearsOnlyIsolatedSessionFile() throws {
        let root = try temporaryRoot()
        let sessionDir = "\(root)/state"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        try "{}".write(toFile: "\(sessionDir)/session.json", atomically: true, encoding: .utf8)
        try SessionService.writeDriverLock(udid: "STALE-1", paths: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root]))

        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])
        let result = cli.run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "No active session\nSession stopped\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(sessionDir)/session.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(sessionDir)/driver.lock"))
    }

    func testStopWithoutSessionDoesNotDiscoverOrTerminateDriver() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        var didListDevices = false
        var terminatedReal: [String] = []
        var terminatedSimulator: [String] = []
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            didListDevices = true
            return [IOSDevice(name: "Phone", version: "26.0", udid: "REAL-1", kind: .real)]
        }
        SessionService.realDriverTerminatorForTesting = { udid in
            terminatedReal.append(udid)
            return true
        }
        SessionService.simulatorDriverTerminatorForTesting = { udid in
            terminatedSimulator.append(udid)
            return true
        }
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.realDriverTerminatorForTesting = nil
            SessionService.simulatorDriverTerminatorForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(didListDevices)
        XCTAssertEqual(terminatedReal, [])
        XCTAssertEqual(terminatedSimulator, [])
        XCTAssertEqual(result.stdout, "No active session\nSession stopped\n")
        XCTAssertNil(SessionService.read(paths: paths))
        XCTAssertNil(SessionService.readDriverLock(paths: paths))
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
        try SessionService.writeDriverLock(udid: "REAL-1", paths: paths)
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
        XCTAssertNil(SessionService.readDriverLock(paths: paths))
    }

    func testStopTerminatesSimulatorDriverBeforeClearingSession() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeSimulatorSession(
            udid: "SIM-1",
            deviceName: "IOSUseTest",
            deviceVersion: "26.0",
            paths: paths
        )
        try SessionService.writeDriverLock(udid: "SIM-1", paths: paths)
        var terminated: [String] = []
        SessionService.simulatorDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return true
        }
        addTeardownBlock {
            SessionService.simulatorDriverTerminatorForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(terminated, ["SIM-1"])
        XCTAssertEqual(result.stdout, "Driver app terminated on simulator\nSession stopped\n")
        XCTAssertNil(SessionService.read(paths: paths))
        XCTAssertNil(SessionService.readDriverLock(paths: paths))
    }

    func testStartCommandCreatesDriverLockAndSimulatorSession() throws {
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
        addTeardownBlock {
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.simulatorDriverReachableForTesting = nil
            SessionService.simulatorDriverLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "SIM-START"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver started for SIM-START\n")
        XCTAssertEqual(launched, ["SIM-START"])
        XCTAssertEqual(SessionService.readDriverLock(paths: paths), "SIM-START")
        let session = try XCTUnwrap(SessionService.read(paths: paths))
        XCTAssertEqual(session.udid, "SIM-START")
        XCTAssertEqual(session.deviceType, "simulator")
        XCTAssertEqual(session.deviceName, "IOSUseTest")
    }

    func testStartCommandCreatesDriverLockAndLaunchesRealDriver() throws {
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
        addTeardownBlock {
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.listDevicesOverrideForTesting = nil
            SessionService.realDriverReachableForTesting = nil
            SessionService.realDriverLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "REAL-START"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver started for REAL-START\n")
        XCTAssertEqual(launched.map(\.0), ["REAL-START"])
        XCTAssertEqual(launched.map(\.1), ["com.example.driver"])
        XCTAssertEqual(SessionService.readDriverLock(paths: paths), "REAL-START")
        let session = try XCTUnwrap(SessionService.read(paths: paths))
        XCTAssertEqual(session.udid, "REAL-START")
        XCTAssertEqual(session.deviceType, "real")
    }

    func testStartCommandRejectsUnconfiguredDevice() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "SIM-MISSING"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("No signing config found for device SIM-MISSING"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/state/driver.lock"))
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
            XCTAssertTrue(String(describing: error).contains("installed: 0.9.0"))
            XCTAssertTrue(String(describing: error).contains("expected: \(IOSUseCLI.version)"))
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

    private func writeDriverIPA(path: String, identity: DriverIdentity) throws {
        let root = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let payload = "\(root)/Payload/IOSUseDriver-Runner.app"
        try FileManager.default.createDirectory(atPath: payload, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleShortVersionString</key>
          <string>\(identity.version)</string>
          <key>CFBundleVersion</key>
          <string>\(identity.build)</string>
        </dict>
        </plist>
        """.write(toFile: "\(payload)/Info.plist", atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: path)
        _ = try Shell.run("zip", arguments: ["-r", "-q", path, "Payload"], cwd: root)
        try FileManager.default.removeItem(atPath: "\(root)/Payload")
    }
}
