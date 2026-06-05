import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class ConfigServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        Shell.runOverrideForTesting = nil
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.usbDeviceUdidsOverrideForTesting = nil
        DeviceService.realDeviceResolverForTesting = nil
        DeviceService.resetCacheForTesting()
        ConfigService.altsignRunnerForTesting = nil
        ConfigService.realDeviceInstallerForTesting = nil
        ConfigService.installedDriverVersionProviderForTesting = nil
        ConfigService.driverIPAPathProviderForTesting = nil
        SessionService.simulatorDriverReachableForTesting = nil
        SessionService.simulatorDriverLauncherForTesting = nil
        SessionService.simulatorDriverTerminatorForTesting = nil
        SessionService.realDriverTerminatorForTesting = nil
        DriverLifecycleService.holderLauncherForTesting = nil
        DriverLifecycleService.holderTerminatorForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        RealDeviceOSLogService.collectorForTesting = nil
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
        let explicitRoot = try temporaryRoot()
        let explicitPaths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": explicitRoot])

        XCTAssertEqual(
            ConfigService.deviceIPAPath(paths: explicitPaths),
            "\(explicitRoot)/driver.ipa"
        )
        XCTAssertEqual(
            ConfigService.simulatorIPAPath(paths: explicitPaths),
            "\(explicitRoot)/driver-sim.ipa"
        )

        let implicitRoot = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["HOME": implicitRoot])
        #if DEBUG
        let cwd = try temporaryRoot()
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let oldCwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(cwd))
        addTeardownBlock {
            _ = FileManager.default.changeCurrentDirectoryPath(oldCwd)
        }
        let canonicalCwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(ConfigService.deviceIPAPath(paths: paths), "\(canonicalCwd)/.ios-use/driver.ipa")
        XCTAssertEqual(ConfigService.simulatorIPAPath(paths: paths), "\(canonicalCwd)/.ios-use/driver-sim.ipa")
        #else
        XCTAssertEqual(ConfigService.deviceIPAPath(paths: paths), "\(implicitRoot)/.ios-use/driver.ipa")
        XCTAssertEqual(ConfigService.simulatorIPAPath(paths: paths), "\(implicitRoot)/.ios-use/driver-sim.ipa")
        #endif
    }

    func testDriverAssetPathProviderForTestingOverridesBuildConfiguration() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        ConfigService.driverIPAPathProviderForTesting = { assetName, receivedPaths in
            XCTAssertEqual(receivedPaths.root, paths.root)
            return "\(root)/override-\(assetName)"
        }

        XCTAssertEqual(ConfigService.deviceIPAPath(paths: paths), "\(root)/override-driver.ipa")
        XCTAssertEqual(ConfigService.simulatorIPAPath(paths: paths), "\(root)/override-driver-sim.ipa")
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

    func testDriverLockWritesXCTestHolderMetadataWithoutStartMode() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-HOLDER",
                deviceName: "Phone",
                deviceVersion: "26.2",
                deviceType: "real",
                startedAt: 123,
                holderPid: 456,
                runnerPid: 789,
                sessionIdentifier: "SESSION-1",
                bundleId: "com.example.driver.xctrunner"
            ),
            paths: paths
        )

        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))

        XCTAssertEqual(lock.holderPid, 456)
        XCTAssertEqual(lock.runnerPid, 789)
        XCTAssertNil(lock.startMode)
        XCTAssertEqual(lock.sessionIdentifier, "SESSION-1")
        XCTAssertEqual(lock.bundleId, "com.example.driver.xctrunner")
        let raw = try String(contentsOfFile: paths.driverLock, encoding: .utf8)
        XCTAssertFalse(raw.contains("startMode"))
    }

    func testDriverLockReadsLegacyStartModeForCompatibility() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try """
        {
          "udid": "REAL-HOLDER",
          "deviceName": "Phone",
          "deviceVersion": "26.2",
          "deviceType": "real",
          "startedAt": 123,
          "holderPid": 456,
          "runnerPid": 789,
          "startMode": "full-xctest",
          "sessionIdentifier": "SESSION-1",
          "bundleId": "com.example.driver.xctrunner"
        }
        """.write(toFile: paths.driverLock, atomically: true, encoding: .utf8)

        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))

        XCTAssertEqual(lock.startMode, "full-xctest")
        XCTAssertEqual(lock.holderPid, 456)
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
        XCTAssertTrue(result.stderr.contains("No active driver. Run `ios-use start` first."))
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

    func testStopReportsFailureWhenDriverLockCannotBeRemoved() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let stateDir = "\(root)/state"
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try writeDriverLock(udid: "REAL-LOCKED", deviceType: "real", paths: paths)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDir)
        }
        var terminated: [String] = []
        SessionService.realDriverTerminatorForTesting = { udid in
            terminated.append(udid)
            return true
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Driver stopped, but failed to remove"))
        XCTAssertEqual(terminated, ["REAL-LOCKED"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.driverLock))
    }

    func testStopRealDeviceDefaultsToNativeXCTestHolderCleanupWithoutDevicectl() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-HOLDER-NATIVE":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-HOLDER-NATIVE",
                deviceName: "Phone",
                deviceVersion: "26.2",
                deviceType: "real",
                startedAt: 1,
                holderPid: 777,
                runnerPid: 888,
                startMode: "full-xctest",
                sessionIdentifier: "SESSION-NATIVE",
                bundleId: "com.example.driver"
            ),
            paths: paths
        )
        var holderStops: [SessionService.Info] = []
        DriverLifecycleService.holderTerminatorForTesting = { info, receivedPaths in
            XCTAssertEqual(receivedPaths.root, paths.root)
            holderStops.append(info)
            return .terminated
        }
        Shell.runOverrideForTesting = { executable, _, _, _ in
            if executable == "xcrun" {
                XCTFail("real stop default path must not call xcrun/devicectl")
            }
            return ""
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver app terminated on device\nDriver stopped\n")
        XCTAssertEqual(holderStops.map(\.holderPid), [777])
        XCTAssertNil(SessionService.readDriverLock(paths: paths))
    }

    func testStopRealDeviceWithoutHolderPidSkipsDeviceTerminateAndClearsLock() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-NO-HOLDER":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "REAL-NO-HOLDER", deviceType: "real", paths: paths)
        Shell.runOverrideForTesting = { executable, _, _, _ in
            if executable == "xcrun" {
                XCTFail("real stop without holder must not call xcrun/devicectl")
            }
            return ""
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver app was not running on device\nDriver stopped\n")
        XCTAssertNil(try SessionService.readDriverLockInfo(paths: paths))
    }

    func testStopRealDeviceRefusesUnexpectedHolderPidAndPreservesLock() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-REFUSE-HOLDER",
                deviceName: "Phone",
                deviceVersion: "26.2",
                deviceType: "real",
                startedAt: 1,
                holderPid: 999,
                runnerPid: 1000,
                startMode: "full-xctest",
                sessionIdentifier: "SESSION-REFUSE",
                bundleId: "com.example.driver"
            ),
            paths: paths
        )
        DriverLifecycleService.holderTerminatorForTesting = { _, _ in .refused }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Refused to stop XCTest holder"))
        XCTAssertNotNil(try SessionService.readDriverLockInfo(paths: paths))
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
            if simulatorOnly {
                XCTFail("real start must not inspect Simulator devices")
                return []
            }
            return [IOSDevice(name: "Phone", version: "26.0", udid: "REAL-START", kind: .real)]
        }
        var holderLaunches: [(String, String)] = []
        DriverLifecycleService.holderLauncherForTesting = { udid, bundleId, _, _ in
            holderLaunches.append((udid, bundleId))
            return DriverLifecycleService.LaunchMetadata(
                holderPid: 101,
                runnerPid: 202,
                sessionIdentifier: "SESSION-START",
                bundleId: bundleId
            )
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "REAL-START"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(holderLaunches.map(\.0), ["REAL-START"])
        XCTAssertEqual(holderLaunches.map(\.1), ["com.example.driver"])
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.udid, "REAL-START")
        XCTAssertEqual(lock.deviceType, "real")
        XCTAssertEqual(lock.deviceName, "Phone")
        XCTAssertEqual(lock.holderPid, 101)
        XCTAssertNil(lock.startMode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.session))
    }

    func testStartWithoutUdidDefaultsToFirstConnectedRealDevice() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-FIRST":{"bundleId":"com.example.first","driverVersion":"\(IOSUseCLI.version)"},"REAL-SECOND":{"bundleId":"com.example.second","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-FIRST", "REAL-SECOND"] }
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                XCTFail("start without udid must not inspect Simulator devices")
                return []
            }
            return [
                IOSDevice(name: "First Phone", version: "26.0", udid: "REAL-FIRST", kind: .real),
                IOSDevice(name: "Second Phone", version: "26.0", udid: "REAL-SECOND", kind: .real),
            ]
        }
        var holderLaunches: [(String, String)] = []
        DriverLifecycleService.holderLauncherForTesting = { udid, bundleId, _, _ in
            holderLaunches.append((udid, bundleId))
            return DriverLifecycleService.LaunchMetadata(
                holderPid: 303,
                runnerPid: 404,
                sessionIdentifier: "SESSION-FIRST",
                bundleId: bundleId
            )
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver started for REAL-FIRST\n")
        XCTAssertEqual(holderLaunches.map(\.0), ["REAL-FIRST"])
        XCTAssertEqual(holderLaunches.map(\.1), ["com.example.first"])
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.udid, "REAL-FIRST")
        XCTAssertEqual(lock.deviceType, "real")
        XCTAssertEqual(lock.deviceName, "First Phone")
    }

    func testStartCommandUsesNativeXCTestLifecycleByDefaultWithoutDevicectl() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-NATIVE":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-NATIVE"] }
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                XCTFail("real native start must not inspect Simulator devices")
                return []
            }
            return [IOSDevice(name: "Phone", version: "26.0", udid: "REAL-NATIVE", kind: .real)]
        }
        var holderLaunches: [(String, String)] = []
        DriverLifecycleService.holderLauncherForTesting = { udid, bundleId, _, _ in
            holderLaunches.append((udid, bundleId))
            return DriverLifecycleService.LaunchMetadata(
                holderPid: 505,
                runnerPid: 606,
                sessionIdentifier: "SESSION-NATIVE",
                bundleId: bundleId
            )
        }
        Shell.runOverrideForTesting = { executable, _, _, _ in
            if executable == "xcrun" {
                XCTFail("real start default path must not call xcrun/devicectl")
            }
            return ""
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "REAL-NATIVE"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(holderLaunches.map(\.0), ["REAL-NATIVE"])
        XCTAssertEqual(holderLaunches.map(\.1), ["com.example.driver"])
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.udid, "REAL-NATIVE")
        XCTAssertEqual(lock.deviceType, "real")
        XCTAssertEqual(lock.holderPid, 505)
        XCTAssertNil(lock.startMode)
    }

    func testStartCommandRecordsNativeXCTestHolderMetadata() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-HOLDER":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-HOLDER"] }
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                XCTFail("real holder start must not inspect Simulator devices")
                return []
            }
            return [IOSDevice(name: "Phone", version: "26.2", udid: "REAL-HOLDER", kind: .real)]
        }
        DriverLifecycleService.holderLauncherForTesting = { udid, bundleId, receivedPaths, verbose in
            XCTAssertEqual(udid, "REAL-HOLDER")
            XCTAssertEqual(bundleId, "com.example.driver")
            XCTAssertEqual(receivedPaths.root, paths.root)
            XCTAssertFalse(verbose)
            return DriverLifecycleService.LaunchMetadata(
                holderPid: 111,
                runnerPid: 222,
                sessionIdentifier: "SESSION-2",
                bundleId: bundleId
            )
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "REAL-HOLDER"])

        XCTAssertEqual(result.exitCode, 0)
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.holderPid, 111)
        XCTAssertEqual(lock.runnerPid, 222)
        XCTAssertNil(lock.startMode)
        XCTAssertEqual(lock.sessionIdentifier, "SESSION-2")
        XCTAssertEqual(lock.bundleId, "com.example.driver")
        let rawLock = try String(contentsOfFile: paths.driverLock, encoding: .utf8)
        XCTAssertFalse(rawLock.contains("startMode"))
    }

    func testStartFailsWhenNativeXCTestLifecycleFailsWithoutFallback() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-CORE-FAIL":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-CORE-FAIL"] }
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                XCTFail("real native start failure path must not inspect Simulator devices")
                return []
            }
            return [IOSDevice(name: "Phone", version: "26.0", udid: "REAL-CORE-FAIL", kind: .real)]
        }
        DriverLifecycleService.holderLauncherForTesting = { _, _, _, _ in
            throw CLIParseError.invalidValue("holder unavailable")
        }
        Shell.runOverrideForTesting = { executable, _, _, _ in
            if executable == "xcrun" {
                XCTFail("real start failure path must not call xcrun/devicectl")
            }
            return ""
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "REAL-CORE-FAIL"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Native real-device launch failed. XCTest:"))
        XCTAssertTrue(result.stderr.contains("holder unavailable"))
        XCTAssertNil(try SessionService.readDriverLockInfo(paths: paths))
    }

    func testStopTerminatesNativeXCTestHolderFromLock() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-HOLDER-STOP":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-HOLDER-STOP",
                deviceName: "Phone",
                deviceVersion: "26.2",
                deviceType: "real",
                startedAt: 1,
                holderPid: 333,
                runnerPid: 444,
                startMode: "full-xctest",
                sessionIdentifier: "SESSION-3",
                bundleId: "com.example.driver"
            ),
            paths: paths
        )
        SessionService.realDriverTerminatorForTesting = { udid in
            XCTAssertEqual(udid, "REAL-HOLDER-STOP")
            return false
        }
        var holderStops: [SessionService.Info] = []
        DriverLifecycleService.holderTerminatorForTesting = { info, receivedPaths in
            XCTAssertEqual(receivedPaths.root, paths.root)
            holderStops.append(info)
            return .terminated
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver app terminated on device\nDriver stopped\n")
        XCTAssertEqual(holderStops.map(\.holderPid), [333])
        XCTAssertNil(try SessionService.readDriverLockInfo(paths: paths))
    }

    func testStopDisconnectedRealDeviceStillTerminatesNativeXCTestHolderAndClearsLock() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-HOLDER-DISCONNECT":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-HOLDER-DISCONNECT",
                deviceName: "Phone",
                deviceVersion: "26.2",
                deviceType: "real",
                startedAt: 1,
                holderPid: 555,
                runnerPid: 666,
                startMode: "full-xctest",
                sessionIdentifier: "SESSION-DISCONNECT",
                bundleId: "com.example.driver"
            ),
            paths: paths
        )
        var holderStops: [SessionService.Info] = []
        DriverLifecycleService.holderTerminatorForTesting = { info, receivedPaths in
            XCTAssertEqual(receivedPaths.root, paths.root)
            holderStops.append(info)
            return .terminated
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["stop"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Driver app terminated on device\nDriver stopped\n")
        XCTAssertEqual(holderStops.map(\.holderPid), [555])
        XCTAssertNil(try SessionService.readDriverLockInfo(paths: paths))
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

    func testStartDoesNotLaunchWhenDriverLockCannotBeWritten() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
        {"devices":{"SIM-LOCKFAIL":{"bundleId":"com.iosuse.xcuidriver.xctrunner","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try "not a directory".write(toFile: "\(root)/state", atomically: true, encoding: .utf8)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [IOSDevice(name: "IOSUseTest", version: "26.0", udid: "SIM-LOCKFAIL", kind: .simulator)] : []
        }
        var launched: [String] = []
        SessionService.simulatorDriverLauncherForTesting = { launched.append($0) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "SIM-LOCKFAIL"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.session))
    }

    func testStartRejectsUnconfiguredOutdatedAndMissingDevicesWithoutLock() throws {
        let root = try temporaryRoot()
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        DeviceService.usbDeviceUdidsOverrideForTesting = { [] }
        DeviceService.listDevicesOverrideForTesting = { _, _ in [] }
        var result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("No --udid and no USB real devices detected."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))

        result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["start", "SIM-MISSING"])
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

    func testRealDeviceConfigInstallsSignedIpaThroughNativeInstallerWithoutDevicectl() throws {
        let root = try temporaryRoot()
        let workspace = try temporaryRoot()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let oldCwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(workspace))
        addTeardownBlock {
            _ = FileManager.default.changeCurrentDirectoryPath(oldCwd)
        }

        let altsign = "\(root)/altsign-cli/altsign-cli"
        try FileManager.default.createDirectory(atPath: "\(root)/altsign-cli", withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(toFile: altsign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: altsign)
        try makeMinimalDriverIpa(path: "\(root)/driver.ipa")
        ConfigService.driverIPAPathProviderForTesting = { _, _ in "\(root)/driver.ipa" }

        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                XCTFail("real device config must not inspect Simulator devices")
                return []
            }
            return [IOSDevice(name: "Phone", version: "26.2", udid: "REAL-CONFIG", kind: .real)]
        }
        Shell.runOverrideForTesting = { executable, arguments, cwd, combineStderr in
            if executable == "xcrun" {
                XCTFail("real device config must not call xcrun/devicectl")
            }
            if executable == altsign, arguments == ["list"] {
                return "Using cached session for user@example.com\n"
            }
            return try self.runProcess(executable: executable, arguments: arguments, cwd: cwd, combineStderr: combineStderr)
        }
        ConfigService.altsignRunnerForTesting = { executable, arguments in
            XCTAssertEqual(executable, altsign)
            guard let outputIndex = arguments.firstIndex(of: "--output") else {
                XCTFail("altsign args missing --output")
                return
            }
            let output = arguments[arguments.index(after: outputIndex)]
            guard let inputIndex = arguments.firstIndex(of: "--ipa") else {
                XCTFail("altsign args missing --ipa")
                return
            }
            let input = arguments[arguments.index(after: inputIndex)]
            try FileManager.default.copyItem(atPath: input, toPath: output)
        }
        var installs: [(String, String, String)] = []
        ConfigService.realDeviceInstallerForTesting = { signedIpa, udid, bundleId in
            installs.append((signedIpa, udid, bundleId))
            XCTAssertTrue(FileManager.default.fileExists(atPath: signedIpa))
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["config", "--udid", "REAL-CONFIG"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(installs.map(\.1), ["REAL-CONFIG"])
        XCTAssertEqual(installs.map(\.2), ["com.ios-use.driver.user-example-com.xctrunner"])
        XCTAssertTrue(result.stdout.contains("Driver installed to device"))
        XCTAssertTrue(result.stdout.contains("Run `ios-use start REAL-CONFIG` before driver-backed commands."))
        XCTAssertFalse(result.stdout.contains("activateApp"))
        XCTAssertEqual(
            ConfigService.listEntries(paths: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])),
            [DeviceConfigEntry(udid: "REAL-CONFIG", bundleId: "com.ios-use.driver.user-example-com.xctrunner", driverVersion: IOSUseCLI.version)]
        )
    }

    func testRealDeviceConfigSkipsInstallWhenCurrentDriverAlreadyInstalled() throws {
        let root = try temporaryRoot()
        let workspace = try temporaryRoot()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let oldCwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(workspace))
        addTeardownBlock {
            _ = FileManager.default.changeCurrentDirectoryPath(oldCwd)
        }

        let altsign = "\(root)/altsign-cli/altsign-cli"
        try FileManager.default.createDirectory(atPath: "\(root)/altsign-cli", withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(toFile: altsign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: altsign)
        try makeMinimalDriverIpa(path: "\(root)/driver.ipa")
        ConfigService.driverIPAPathProviderForTesting = { _, _ in "\(root)/driver.ipa" }
        try """
        {"devices":{"REAL-CONFIG":{"bundleId":"com.ios-use.driver.user-example-com.xctrunner","driverVersion":"old"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)

        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                XCTFail("real device config must not inspect Simulator devices")
                return []
            }
            return [IOSDevice(name: "Phone", version: "26.2", udid: "REAL-CONFIG", kind: .real)]
        }
        Shell.runOverrideForTesting = { executable, arguments, cwd, combineStderr in
            if executable == altsign, arguments == ["list"] {
                return "Using cached session for user@example.com\n"
            }
            return try self.runProcess(executable: executable, arguments: arguments, cwd: cwd, combineStderr: combineStderr)
        }
        ConfigService.altsignRunnerForTesting = { _, arguments in
            let outputIndex = try XCTUnwrap(arguments.firstIndex(of: "--output"))
            let inputIndex = try XCTUnwrap(arguments.firstIndex(of: "--ipa"))
            try FileManager.default.copyItem(
                atPath: arguments[arguments.index(after: inputIndex)],
                toPath: arguments[arguments.index(after: outputIndex)]
            )
        }
        ConfigService.installedDriverVersionProviderForTesting = { udid, bundleId in
            XCTAssertEqual(udid, "REAL-CONFIG")
            XCTAssertEqual(bundleId, "com.ios-use.driver.user-example-com.xctrunner")
            return IOSUseCLI.version
        }
        ConfigService.realDeviceInstallerForTesting = { _, _, _ in
            XCTFail("current installed driver should not be reinstalled")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["config", "--udid", "REAL-CONFIG"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Driver already installed on device"))
        XCTAssertEqual(
            ConfigService.listEntries(paths: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])),
            [DeviceConfigEntry(udid: "REAL-CONFIG", bundleId: "com.ios-use.driver.user-example-com.xctrunner", driverVersion: IOSUseCLI.version)]
        )
    }

    func testRealDeviceConfigInstallFailureDoesNotSaveConfigOrPrintSuccess() throws {
        let root = try temporaryRoot()
        let workspace = try temporaryRoot()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let oldCwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(workspace))
        addTeardownBlock {
            _ = FileManager.default.changeCurrentDirectoryPath(oldCwd)
        }

        let altsign = "\(root)/altsign-cli/altsign-cli"
        try FileManager.default.createDirectory(atPath: "\(root)/altsign-cli", withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(toFile: altsign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: altsign)
        try makeMinimalDriverIpa(path: "\(root)/driver.ipa")
        ConfigService.driverIPAPathProviderForTesting = { _, _ in "\(root)/driver.ipa" }

        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                XCTFail("real device config failure path must not inspect Simulator devices")
                return []
            }
            return [IOSDevice(name: "Phone", version: "26.2", udid: "REAL-CONFIG-FAIL", kind: .real)]
        }
        Shell.runOverrideForTesting = { executable, arguments, cwd, combineStderr in
            if executable == altsign, arguments == ["list"] {
                return "Using cached session for user@example.com\n"
            }
            return try self.runProcess(executable: executable, arguments: arguments, cwd: cwd, combineStderr: combineStderr)
        }
        ConfigService.altsignRunnerForTesting = { _, arguments in
            let outputIndex = try XCTUnwrap(arguments.firstIndex(of: "--output"))
            let inputIndex = try XCTUnwrap(arguments.firstIndex(of: "--ipa"))
            try FileManager.default.copyItem(
                atPath: arguments[arguments.index(after: inputIndex)],
                toPath: arguments[arguments.index(after: outputIndex)]
            )
        }
        ConfigService.realDeviceInstallerForTesting = { _, _, _ in
            throw CLIParseError.invalidValue("install failed")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["config", "--udid", "REAL-CONFIG-FAIL"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("install failed"))
        XCTAssertFalse(result.stdout.contains("Device config complete"))
        XCTAssertEqual(
            ConfigService.listEntries(paths: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])),
            []
        )
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

    private func makeMinimalDriverIpa(path: String, version: String = IOSUseCLI.version) throws {
        let tmp = try temporaryRoot()
        let appPath = "\(tmp)/Payload/IOSUseDriver-Runner.app"
        let xctestPath = "\(appPath)/PlugIns/IOSUseDriver.xctest"
        try FileManager.default.createDirectory(atPath: xctestPath, withIntermediateDirectories: true)
        try writePlist([
            "CFBundleIdentifier": "com.iosuse.xcuidriver.xctrunner",
            "CFBundleShortVersionString": version,
        ], path: "\(appPath)/Info.plist")
        try writePlist(["CFBundleIdentifier": "com.iosuse.xcuidriver"], path: "\(xctestPath)/Info.plist")
        _ = try runProcess(executable: "zip", arguments: ["-r", "-q", path, "Payload"], cwd: tmp, combineStderr: false)
    }

    private func writePlist(_ plist: [String: Any], path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func runProcess(executable: String, arguments: [String], cwd: String?, combineStderr: Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw CLIParseError.invalidValue(stderr.isEmpty ? "\(executable) failed with exit \(process.terminationStatus)" : stderr)
        }
        return combineStderr ? stdout + stderr : stdout
    }

}
