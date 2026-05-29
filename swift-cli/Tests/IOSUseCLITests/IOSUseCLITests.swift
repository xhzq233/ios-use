import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class IOSUseCLITests: XCTestCase {
    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.usbDeviceUdidsOverrideForTesting = nil
        DeviceService.realDeviceResolverForTesting = nil
        DeviceService.resetCacheForTesting()
        DriverClient.usbmuxConnectorForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
        OpenURLService.realDeviceURLLauncherForTesting = nil
        AppManagementService.installerForTesting = nil
        AppManagementService.uninstallerForTesting = nil
        AppManagementService.appsProviderForTesting = nil
        SessionService.realDriverLauncherForTesting = nil
        SessionService.realDriverReachableForTesting = nil
        SessionService.coreDeviceLifecycleFactoryForTesting = nil
        SessionService.simulatorDriverLauncherForTesting = nil
        SessionService.simulatorDriverReachableForTesting = nil
        RealDeviceOSLogService.collectorForTesting = nil
        _ = OSLogService.clear()
        Shell.runOverrideForTesting = nil
        Shell.runResultOverrideForTesting = nil
        super.tearDown()
    }

    func testHelpContainsRootUsageAndCommands() {
        let result = IOSUseCLI().run(arguments: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Swift CLI for ios-use"))
        XCTAssertTrue(result.stdout.contains("Usage: ios-use [--help] [--version] <command>"))
        XCTAssertTrue(result.stdout.contains("devices, config, start, stop, dom"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testUnknownOptionFailsBeforeAnySessionWork() {
        let result = IOSUseCLI().run(arguments: ["--not-a-real-option"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("unknown option '--not-a-real-option'"))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testPerCommandHelpShortCircuitsInCLI() {
        let result = IOSUseCLI().run(arguments: ["oslog", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage: ios-use oslog"))
        XCTAssertTrue(result.stdout.contains("--bundle-id <bundleId>"))
        XCTAssertFalse(result.stdout.contains("Usage: ios-use [--help]"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testHelpCommandReturnsPerCommandHelp() {
        let result = IOSUseCLI().run(arguments: ["help", "tap"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage: ios-use tap <target>"))
        XCTAssertTrue(result.stdout.contains("--offset-ratio <x,y>"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testAllDocumentedCommandsReturnPerCommandHelp() {
        let cases: [(arguments: [String], usage: String)] = [
            (["devices", "--help"], "Usage: ios-use devices"),
            (["config", "--help"], "Usage: ios-use config"),
            (["start", "--help"], "Usage: ios-use start"),
            (["stop", "--help"], "Usage: ios-use stop"),
            (["dom", "--help"], "Usage: ios-use dom"),
            (["find", "--help"], "Usage: ios-use find"),
            (["waitFor", "--help"], "Usage: ios-use waitFor"),
            (["screenshot", "--help"], "Usage: ios-use screenshot"),
            (["tap", "--help"], "Usage: ios-use tap"),
            (["longpress", "--help"], "Usage: ios-use longpress"),
            (["input", "--help"], "Usage: ios-use input"),
            (["swipe", "--help"], "Usage: ios-use swipe"),
            (["activateApp", "--help"], "Usage: ios-use activateApp"),
            (["terminateApp", "--help"], "Usage: ios-use terminateApp"),
            (["home", "--help"], "Usage: ios-use home"),
            (["open", "--help"], "Usage: ios-use open"),
            (["install", "--help"], "Usage: ios-use install"),
            (["uninstall", "--help"], "Usage: ios-use uninstall"),
            (["apps", "--help"], "Usage: ios-use apps"),
            (["dismissAlert", "--help"], "Usage: ios-use dismissAlert"),
            (["flow", "--help"], "Usage: ios-use flow"),
            (["proxy", "--help"], "Usage: ios-use proxy"),
            (["proxy", "start", "--help"], "Usage: ios-use proxy start"),
            (["proxy", "stop", "--help"], "Usage: ios-use proxy stop"),
            (["proxy", "configca", "--help"], "Usage: ios-use proxy configca"),
            (["proxy", "doctor", "--help"], "Usage: ios-use proxy doctor"),
            (["oslog", "--help"], "Usage: ios-use oslog"),
            (["nslog", "--help"], "Usage: ios-use nslog"),
        ]

        for entry in cases {
            let result = IOSUseCLI().run(arguments: entry.arguments)

            XCTAssertEqual(result.exitCode, 0, entry.arguments.joined(separator: " "))
            XCTAssertTrue(result.stdout.contains(entry.usage), entry.arguments.joined(separator: " "))
            XCTAssertFalse(result.stdout.contains("Usage: ios-use [--help]"), entry.arguments.joined(separator: " "))
            XCTAssertTrue(result.stderr.isEmpty, entry.arguments.joined(separator: " "))
        }
    }

    func testInstallCommandWithExplicitUdidIsHostOnlyAndDoesNotWriteDriverLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-host-only-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app")
        var installs: [(String, String, String?)] = []
        AppManagementService.installerForTesting = { ipa, udid, bundleID in
            installs.append((ipa, udid, bundleID))
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("install is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", ipaPath, "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(installs.map(\.0), [ipaPath])
        XCTAssertEqual(installs.map(\.1), ["REAL-1"])
        XCTAssertEqual(installs.map(\.2), ["com.example.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root]).driverLock))
    }

    func testInstallCommandUsesActiveDriverLockWhenUdidIsOmitted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-active-lock-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "LOCK-REAL", deviceType: "real", paths: paths)
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app")
        var installs: [(String, String, String?)] = []
        AppManagementService.installerForTesting = { ipa, udid, bundleID in
            installs.append((ipa, udid, bundleID))
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("install is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", ipaPath])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(installs.map(\.1), ["LOCK-REAL"])
        XCTAssertTrue(result.stdout.contains("Installed IPA on LOCK-REAL"))
    }

    func testInstallCommandWithoutUdidOrDriverLockFailsBeforeInstaller() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-no-target-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app")
        AppManagementService.installerForTesting = { _, _, _ in
            XCTFail("install without a target must not call installation_proxy")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", ipaPath])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("install requires --udid or an active driver"))
    }

    func testAppsCommandJsonRendersProviderResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-apps-host-only-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        AppManagementService.appsProviderForTesting = { udid, includeSystem in
            XCTAssertEqual(udid, "REAL-1")
            XCTAssertTrue(includeSystem)
            return [
                AppManagementService.AppInfo(bundleID: "com.example.b", displayName: "B", version: "2", applicationType: "User"),
                AppManagementService.AppInfo(bundleID: "com.example.a", displayName: "A", version: "1", applicationType: "System"),
            ]
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["apps", "--udid", "REAL-1", "--system", "--json"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains(#""bundleId" : "com.example.a""#))
        XCTAssertTrue(result.stdout.contains(#""applicationType" : "System""#))
    }

    func testAppsCommandUsesActiveDriverLockWhenUdidIsOmitted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-apps-active-lock-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "LOCK-REAL", deviceType: "real", paths: paths)
        AppManagementService.appsProviderForTesting = { udid, includeSystem in
            XCTAssertEqual(udid, "LOCK-REAL")
            XCTAssertFalse(includeSystem)
            return [
                AppManagementService.AppInfo(bundleID: "com.example.app", displayName: "Example", version: "1", applicationType: "User")
            ]
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("apps is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["apps"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("com.example.app | Example | 1 | User"))
    }

    func testAppsCommandExplicitUdidOverridesActiveDriverLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-apps-explicit-udid-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "LOCK-REAL", deviceType: "real", paths: paths)
        AppManagementService.appsProviderForTesting = { udid, includeSystem in
            XCTAssertEqual(udid, "EXPLICIT-REAL")
            XCTAssertFalse(includeSystem)
            return []
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["apps", "--udid", "EXPLICIT-REAL"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "No apps found on EXPLICIT-REAL\n")
    }

    func testAppsCommandWithoutUdidOrDriverLockFailsAtExecution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-apps-no-target-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        AppManagementService.appsProviderForTesting = { _, _ in
            XCTFail("apps without a target must not query installation_proxy")
            return []
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["apps"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("apps requires --udid or an active driver"))
    }

    func testUninstallCommandWithExplicitUdidIsHostOnlyAndDoesNotWriteDriverLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-uninstall-host-only-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        var uninstalls: [(String, String)] = []
        AppManagementService.uninstallerForTesting = { bundleID, udid in
            uninstalls.append((bundleID, udid))
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("uninstall is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["uninstall", "com.example.app", "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(uninstalls.map(\.0), ["com.example.app"])
        XCTAssertEqual(uninstalls.map(\.1), ["REAL-1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root]).driverLock))
    }

    func testUninstallCommandUsesActiveDriverLockWhenUdidIsOmitted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-uninstall-active-lock-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "LOCK-REAL", deviceType: "real", paths: paths)
        var uninstalls: [(String, String)] = []
        AppManagementService.uninstallerForTesting = { bundleID, udid in
            uninstalls.append((bundleID, udid))
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("uninstall is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["uninstall", "com.example.app"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(uninstalls.map(\.0), ["com.example.app"])
        XCTAssertEqual(uninstalls.map(\.1), ["LOCK-REAL"])
        XCTAssertEqual(result.stdout, "Uninstalled com.example.app from LOCK-REAL\n")
    }

    func testUninstallCommandWithoutUdidOrDriverLockFailsBeforeInstaller() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-uninstall-no-target-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        AppManagementService.uninstallerForTesting = { _, _ in
            XCTFail("uninstall without a target must not call installation_proxy")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["uninstall", "com.example.app"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("uninstall requires --udid or an active driver"))
    }

    func testProxyDoctorReportsLocalProxyStatus() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-proxy-doctor-\(UUID().uuidString)")
            .path
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": home]).run(arguments: ["proxy", "doctor"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Wi-Fi LAN IP"))
        XCTAssertTrue(result.stdout.contains("Proxy: not running"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testMissingRequiredArgumentFailsBeforeExecution() {
        let result = IOSUseCLI().run(arguments: ["find"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("missing required argument 'label'"))
    }

    func testProtocolConstantsMatchDriverDefaults() {
        XCTAssertEqual(IOSUseProtocol.defaultDriverPort, 8102)
        XCTAssertEqual(IOSUseProtocol.maxFrameSizeBytes, 50 * 1024 * 1024)
        XCTAssertEqual(IOSUseProtocol.maxDriverConnections, 1)
        XCTAssertEqual(IOSUseProtocol.driverConnectionHandoffTimeoutMilliseconds, 250)
        XCTAssertEqual(IOSUseProtocol.driverConnectionHandoffPollMicroseconds, 1_000)
        XCTAssertEqual(IOSUseProtocol.driverStartReadinessInitialDelayMicroseconds, 400_000)
        XCTAssertEqual(IOSUseProtocol.driverStartReadinessPollIntervalMicroseconds, 100_000)
        XCTAssertEqual(IOSUseProtocol.driverStartReadinessProbeHoldMicroseconds, 10_000)
        XCTAssertEqual(IOSUseProtocol.driverStartReadinessTimeoutSeconds, 30.0)
        XCTAssertEqual(IOSUseProtocol.commandTimeoutSeconds, 45)
        XCTAssertEqual(IOSUseProtocol.commandCompletionTimeoutSeconds, 120)
        XCTAssertEqual(IOSUseProtocol.nsloggerDefaultPort, 50_000)
        XCTAssertEqual(IOSUseProtocol.proxyMitmdumpPort, 9080)
        XCTAssertEqual(IOSUseProtocol.springboardBundleId, "com.apple.springboard")
    }

    func testDriverCommandRetriesAfterInitialConnectFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-driver-retry-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try """
        {"devices":{"REAL-CMD":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "REAL-CMD", deviceType: "real", paths: paths)

        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("direct driver command must not discover devices")
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = {
            XCTFail("direct driver command must not inspect USB devices")
            return []
        }
        var launched: [(String, String)] = []
        SessionService.realDriverLauncherForTesting = { udid, bundleId in
            launched.append((udid, bundleId))
        }
        SessionService.realDriverReachableForTesting = { _ in
            !launched.isEmpty
        }
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTAssertEqual(session.udid, "REAL-CMD")
            XCTAssertEqual(session.deviceType, "real")
            attempts += 1
            if attempts == 1 {
                return FakeDriverCommandClient(domHandler: {
                    throw DriverClientError.connectFailed(61)
                })
            }
            return FakeDriverCommandClient(domHandler: {
                ForyDomPayload(app: "com.example.app", windowSize: ForyPoint(x: 100, y: 200))
            })
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("App: com.example.app"))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(launched.map(\.0), ["REAL-CMD"])
        XCTAssertEqual(launched.map(\.1), ["com.example.driver"])
    }

    func testDriverCommandReconnectRecoveryUsesCoreDeviceDefaultWithoutXcode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-driver-core-retry-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try """
        {"devices":{"REAL-CORE-CMD":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "REAL-CORE-CMD", deviceType: "real", paths: paths)
        let lifecycle = FakeIOSUseCLICoreDeviceLifecycle()
        SessionService.coreDeviceLifecycleFactoryForTesting = { _ in lifecycle }
        Shell.runOverrideForTesting = { executable, _, _, _ in
            if executable == "xcrun" {
                XCTFail("real reconnect recovery default path must not call xcrun/devicectl")
            }
            return ""
        }
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            attempts += 1
            if attempts == 1 {
                return FakeDriverCommandClient(domHandler: {
                    throw DriverClientError.connectFailed(61)
                })
            }
            return FakeDriverCommandClient(domHandler: {
                ForyDomPayload(app: "com.example.app", windowSize: ForyPoint(x: 100, y: 200))
            })
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(lifecycle.launches.map(\.0), ["REAL-CORE-CMD"])
        XCTAssertEqual(lifecycle.launches.map(\.1), ["com.example.driver"])
    }

    func testDriverCommandWithoutLockFailsBeforeClientOrDiscovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-driver-no-lock-\(UUID().uuidString)")
            .path
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("direct driver command without lock must not discover devices")
            return []
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("direct driver command without lock must not create a client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("No active driver. Run `ios-use start <UDID>` first."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/state/session.json"))
    }

    func testDriverCommandUsesLockInsteadOfStaleSessionJSONAndDoesNotRetryReadFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-driver-lock-over-session-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try """
        {"sessionId":"legacy","udid":"SESSION-UDID","deviceType":"real"}
        """.write(toFile: paths.session, atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "SIM-LOCK", deviceType: "simulator", paths: paths)
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { session in
            attempts += 1
            XCTAssertEqual(session.udid, "SIM-LOCK")
            XCTAssertEqual(session.deviceType, "simulator")
            return FakeDriverCommandClient(domHandler: {
                throw DriverClientError.readFailed
            })
        }
        SessionService.simulatorDriverLauncherForTesting = { _ in
            XCTFail("read/write failures after command send must not relaunch")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("driver TCP read failed"))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(SessionService.readDriverLock(paths: paths), "SIM-LOCK")
    }

    func testRealDeviceUsbmuxConnectFailureIsRecoverable() {
        DriverClient.usbmuxConnectorForTesting = { _, _ in
            throw CLIParseError.invalidValue("usbmux Connect failed with code 2")
        }
        addTeardownBlock {
            DriverClient.usbmuxConnectorForTesting = nil
        }

        let client = DriverClient(udid: "REAL-CMD", deviceType: "real")

        XCTAssertThrowsError(try client.dom(raw: false, fresh: false)) { error in
            let driverError = error as? DriverClientError
            XCTAssertEqual(driverError?.isRecoverableConnectFailure, true)
            XCTAssertTrue(String(describing: error).contains("usbmux Connect failed with code 2"))
        }
    }

    func testRealDeviceMissingFromUsbmuxIsNotRecoverable() {
        DriverClient.usbmuxConnectorForTesting = { _, _ in
            throw CLIParseError.invalidValue("Device REAL-CMD not found via usbmux. USB connection is required.")
        }
        addTeardownBlock {
            DriverClient.usbmuxConnectorForTesting = nil
        }

        let client = DriverClient(udid: "REAL-CMD", deviceType: "real")

        XCTAssertThrowsError(try client.dom(raw: false, fresh: false)) { error in
            let driverError = error as? DriverClientError
            XCTAssertEqual(driverError?.isRecoverableConnectFailure, false)
            XCTAssertTrue(String(describing: error).contains("Device REAL-CMD not found via usbmux"))
        }
    }

    func testOpenURLActiveSimulatorUsesSimctlWithoutDriver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-active-sim-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-1", deviceType: "simulator", paths: paths)
        var shellCalls: [(String, [String])] = []
        Shell.runResultOverrideForTesting = { executable, arguments, _ in
            shellCalls.append((executable, arguments))
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("open URL for active simulator should not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            Shell.runResultOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "retouch://debug"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Opened URL: retouch://debug\n")
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertEqual(shellCalls.count, 1)
        XCTAssertEqual(shellCalls.first?.0, "xcrun")
        XCTAssertEqual(shellCalls.first?.1, ["simctl", "openurl", "SIM-1", "retouch://debug"])
    }

    func testOpenURLExplicitBootedSimulatorUsesSimctlWithoutConfig() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-explicit-sim-\(UUID().uuidString)")
            .path
        let simulatorUdid = "00000000-0000-0000-0000-000000000001"
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
            return [IOSDevice(name: "iPhone", version: "26.0", udid: simulatorUdid, kind: .simulator)]
        }
        var shellCalls: [(String, [String])] = []
        Shell.runResultOverrideForTesting = { executable, arguments, _ in
            shellCalls.append((executable, arguments))
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("open URL for explicit booted simulator should not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runResultOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", simulatorUdid])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Opened URL: https://example.com\n")
        XCTAssertEqual(shellCalls.map(\.0), ["xcrun"])
        XCTAssertEqual(shellCalls.first?.1, ["simctl", "openurl", simulatorUdid, "https://example.com"])
    }

    func testOpenURLInvalidURLFailsBeforeDriverOrShell() {
        Shell.runOverrideForTesting = { _, _, _, _ in
            XCTFail("invalid URL should fail before shell")
            return ""
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("invalid URL should fail before driver")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI().run(arguments: ["open", "://missing"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Invalid URL: ://missing"))
    }

    func testOpenURLExplicitRealDeviceUsesNativeLauncherWithoutDevicectl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("explicit real-device open must not inspect Simulator devices")
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-CMD"] }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "https" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: ["com.apple.mobilesafari"], lookupFailed: false)
            }
            return nil
        }
        var nativeLaunches: [(String, String)] = []
        OpenURLService.realDeviceURLLauncherForTesting = { url, udid in
            nativeLaunches.append((url, udid))
        }
        var shellCalls: [(String, [String])] = []
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun", arguments.contains("devicectl") {
                XCTFail("real-device open must not call devicectl")
            }
            shellCalls.append((executable, arguments))
            return ""
        }
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTFail("open URL for real device should not create a driver client, got session \(String(describing: session))")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", "REAL-CMD"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Opened URL: https://example.com (handler: com.apple.mobilesafari)"))
        XCTAssertEqual(nativeLaunches.map(\.0), ["https://example.com"])
        XCTAssertEqual(nativeLaunches.map(\.1), ["REAL-CMD"])
        XCTAssertTrue(shellCalls.isEmpty)
    }

    func testOpenURLActiveRealDriverLockUsesNativeLauncherWithoutDevicectl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-active-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "REAL-LOCK", deviceType: "real", paths: paths)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("active real-device open must not inspect USB devices")
            return []
        }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "https" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: ["com.apple.mobilesafari"], lookupFailed: false)
            }
            return nil
        }
        var nativeLaunches: [(String, String)] = []
        OpenURLService.realDeviceURLLauncherForTesting = { url, udid in
            nativeLaunches.append((url, udid))
        }
        var shellCalls: [(String, [String])] = []
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun", arguments.contains("devicectl") {
                XCTFail("real-device open must not call devicectl")
            }
            shellCalls.append((executable, arguments))
            return ""
        }
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTFail("open URL for active real device should not create a driver client, got session \(String(describing: session))")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Opened URL: https://example.com (handler: com.apple.mobilesafari)"))
        XCTAssertEqual(nativeLaunches.map(\.0), ["https://example.com"])
        XCTAssertEqual(nativeLaunches.map(\.1), ["REAL-LOCK"])
        XCTAssertTrue(shellCalls.isEmpty)
    }

    func testOpenURLDoesNotAutoSelectDefaultUsbRealDevice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-default-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("open without --udid or driver.lock must not auto-select a USB device")
            return [IOSDevice(name: "iPhone", version: "26.0", udid: "REAL-DEFAULT", kind: .real)]
        }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "https" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: ["com.apple.mobilesafari"], lookupFailed: false)
            }
            return nil
        }
        var nativeLaunches: [(String, String)] = []
        OpenURLService.realDeviceURLLauncherForTesting = { url, udid in
            nativeLaunches.append((url, udid))
        }
        var shellCalls: [(String, [String])] = []
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun", arguments.contains("devicectl") {
                XCTFail("real-device open must not call devicectl")
            }
            shellCalls.append((executable, arguments))
            return ""
        }
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTFail("open URL for default real device should not create a driver client, got session \(String(describing: session))")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("open requires --udid or an active driver"))
        XCTAssertTrue(nativeLaunches.isEmpty)
        XCTAssertTrue(shellCalls.isEmpty)
    }

    func testOpenURLWithoutHostSideTargetFailsWithoutDriverFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-no-target-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in [] }
        Shell.runOverrideForTesting = { _, _, _, _ in
            XCTFail("open URL without a host-side target should fail before shell")
            return ""
        }
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTFail("open URL without a host-side target should not fall back to driver, got session \(String(describing: session))")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("open requires --udid or an active driver"))
    }

    func testOpenURLSimulatorUnregisteredSchemeReportsError() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-sim-unregistered-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try? writeDriverLock(udid: "SIM-1", deviceType: "simulator", paths: paths)
        Shell.runResultOverrideForTesting = { _, _, _ in
            Shell.RunResult(stdout: "", stderr: "Simulator device failed to open notexist://test", exitCode: 194)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            Shell.runResultOverrideForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "notexist://test"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("URL scheme \"notexist\" not registered on device"))
    }

    func testOpenURLRealDeviceUnregisteredSchemeReportsError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-real-unregistered-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("explicit real-device open must not inspect Simulator devices")
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-1"] }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "notexist" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: [], lookupFailed: false)
            }
            return nil
        }
        Shell.runOverrideForTesting = { _, _, _, _ in
            XCTFail("unregistered scheme should not invoke devicectl")
            return ""
        }
        OpenURLService.realDeviceURLLauncherForTesting = { _, _ in
            XCTFail("unregistered scheme should not invoke native launcher")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "notexist://test", "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("URL scheme \"notexist\" not registered on device"))
    }

    func testOpenURLRealDeviceLookupFailureStillUsesNativeLauncherWithoutDevicectl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-real-lookup-fail-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-1"] }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { _, _ in
            OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: [], lookupFailed: true)
        }
        var nativeLaunches: [(String, String)] = []
        OpenURLService.realDeviceURLLauncherForTesting = { url, udid in
            nativeLaunches.append((url, udid))
        }
        var shellCalls: [(String, [String])] = []
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun", arguments.contains("devicectl") {
                XCTFail("real-device open must not call devicectl")
            }
            shellCalls.append((executable, arguments))
            return ""
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Sent URL request: https://example.com (unable to verify scheme registration)"))
        XCTAssertEqual(nativeLaunches.map(\.0), ["https://example.com"])
        XCTAssertEqual(nativeLaunches.map(\.1), ["REAL-1"])
        XCTAssertTrue(shellCalls.isEmpty)
    }

    func testOSLogExplicitRealDeviceUsesSyslogWithoutSimulatorProbe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-oslog-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("explicit real-device oslog must not inspect Simulator devices")
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-LOG"] }
        RealDeviceOSLogService.collectorForTesting = { udid, timeout in
            XCTAssertEqual(udid, "REAL-LOG")
            XCTAssertEqual(timeout, 0)
            return ["May 29 ready com.example.app"]
        }
        Shell.runOverrideForTesting = { executable, _, _, _ in
            if executable == "xcrun" {
                XCTFail("explicit real-device oslog must not call xcrun")
            }
            return ""
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            RealDeviceOSLogService.collectorForTesting = nil
            Shell.runOverrideForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["oslog", "--udid", "REAL-LOG", "--pattern", "ready", "--timeout", "0", "--name", "real-log"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("matched=1"))
        XCTAssertTrue(result.stdout.contains("real-log.log"))
    }

    func testDriverCommandNamesMatchWireCommands() {
        let commands = Set(DriverCommand.allCases.map(\.rawValue))

        XCTAssertTrue(commands.contains("dom"))
        XCTAssertTrue(commands.contains("find"))
        XCTAssertTrue(commands.contains("waitFor"))
        XCTAssertTrue(commands.contains("dismissAlert"))
        XCTAssertEqual(commands.count, 13)
    }

    func testDriverCommandMetadataBindsArgsAndPayloadTypes() {
        XCTAssertEqual(DriverCommand.find.metadata.argsTypeName, "ForyFindArgs")
        XCTAssertEqual(DriverCommand.find.metadata.payloadTypeName, "ForyFindPayload")
        XCTAssertEqual(FindCommand.command, .find)

        XCTAssertEqual(DriverCommand.tap.metadata.argsTypeName, "ForyTapArgs")
        XCTAssertEqual(DriverCommand.tap.metadata.payloadTypeName, "ForyElementPayload")
        XCTAssertTrue(DriverCommand.tap.metadata.mutatesUI)

        XCTAssertNil(DriverCommand.home.metadata.argsTypeName)
        XCTAssertNil(DriverCommand.home.metadata.payloadTypeName)
    }

    // MARK: - SchemeRegistry.parseSchemeHandlers

    func testParseSchemeHandlersFindsRegisteredBundleIDs() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.apple.mobilesafari": [
                    "CFBundleIdentifier": "com.apple.mobilesafari",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["https", "http"]],
                    ],
                ],
                "com.example.app": [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["myapp"]],
                    ],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "https", response: response)
        XCTAssertEqual(handlers, ["com.apple.mobilesafari"])
    }

    func testParseSchemeHandlersIsCaseInsensitive() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.example.App": [
                    "CFBundleIdentifier": "com.example.App",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["MyApp"]],
                    ],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "myapp", response: response)
        XCTAssertEqual(handlers, ["com.example.App"])
    }

    func testParseSchemeHandlersReturnsEmptyForUnregisteredScheme() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.apple.mobilesafari": [
                    "CFBundleIdentifier": "com.apple.mobilesafari",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["https"]],
                    ],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "notexist", response: response)
        XCTAssertEqual(handlers, [])
    }

    func testParseSchemeHandlersReturnsEmptyForMissingLookupResult() {
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "https", response: [:])
        XCTAssertEqual(handlers, [])
    }

    func testParseSchemeHandlersSkipsAppsMissingURLTypes() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.example.no-urltypes": [
                    "CFBundleIdentifier": "com.example.no-urltypes",
                ],
                "com.example.empty": [
                    "CFBundleIdentifier": "com.example.empty",
                    "CFBundleURLTypes": [],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "https", response: response)
        XCTAssertEqual(handlers, [])
    }

    func testParseSchemeHandlersDeduplicatesBundleIDs() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.example.app": [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["myapp"]],
                        ["CFBundleURLSchemes": ["myapp", "other"]],
                    ],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "myapp", response: response)
        XCTAssertEqual(handlers, ["com.example.app"])
    }

    func testPathsRespectIOSUseHomeOverrideWithoutWritingFiles() {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": "/tmp/ios-use-swift-test-home",
            "HOME": "/tmp/real-home-should-not-be-used"
        ])

        XCTAssertEqual(paths.root, "/tmp/ios-use-swift-test-home")
        XCTAssertEqual(paths.config, "/tmp/ios-use-swift-test-home/config.json")
        XCTAssertEqual(paths.session, "/tmp/ios-use-swift-test-home/state/session.json")
        XCTAssertEqual(paths.driverLock, "/tmp/ios-use-swift-test-home/state/driver.lock")
        XCTAssertEqual(paths.nslogLock, "/tmp/ios-use-swift-test-home/state/nslog.lock")
        XCTAssertEqual(paths.logs, "/tmp/ios-use-swift-test-home/logs")
        XCTAssertEqual(paths.artifacts, "/tmp/ios-use-swift-test-home/artifacts")
    }

    func testPathsDefaultToHomeDotIOSUse() {
        let paths = IOSUsePaths.resolve(environment: [
            "HOME": "/tmp/ios-use-swift-home"
        ])

        XCTAssertEqual(paths.root, "/tmp/ios-use-swift-home/.ios-use")
        XCTAssertEqual(paths.config, "/tmp/ios-use-swift-home/.ios-use/config.json")
    }

    func testCLIStoresResolvedPathsForFutureCommands() {
        let cli = IOSUseCLI(environment: [
            "IOS_USE_HOME": "/tmp/ios-use-swift-env"
        ])

        XCTAssertEqual(cli.paths.root, "/tmp/ios-use-swift-env")
    }

    func testErrorEnvelopeUsesStableExitCodeAndPrefix() {
        let result = CLIErrorEnvelope(message: "example failure").render()

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.stderr, "error: example failure\n")
        XCTAssertTrue(result.stdout.isEmpty)
    }

    private func makeMinimalIpa(path: String, bundleID: String) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-test-ipa-\(UUID().uuidString)", isDirectory: true)
            .path
        let appPath = "\(tmp)/Payload/App.app"
        try FileManager.default.createDirectory(atPath: appPath, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "App",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: "\(appPath)/Info.plist"))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        _ = try Shell.run("zip", arguments: ["-r", "-q", path, "Payload"], cwd: tmp)
    }

    private func writeDriverLock(udid: String, deviceType: String, paths: IOSUsePaths) throws {
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: udid,
                deviceName: deviceType == "simulator" ? "iPhone" : "Phone",
                deviceVersion: "26.0",
                deviceType: deviceType,
                startedAt: 1
            ),
            paths: paths
        )
    }
}

private final class FakeDriverCommandClient: DriverCommandClient {
    private let domHandler: () throws -> ForyDomPayload

    init(
        domHandler: @escaping () throws -> ForyDomPayload = {
            throw CLIParseError.invalidValue("unexpected dom")
        }
    ) {
        self.domHandler = domHandler
    }

    func close() {}

    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload {
        try domHandler()
    }

    func find(label: String, traits: String?, cindex: Int32?) throws -> ForyFindPayload {
        throw CLIParseError.invalidValue("unexpected find")
    }

    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload {
        throw CLIParseError.invalidValue("unexpected waitFor")
    }

    func screenshot() throws -> Data {
        throw CLIParseError.invalidValue("unexpected screenshot")
    }

    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload {
        throw CLIParseError.invalidValue("unexpected tap")
    }

    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload {
        throw CLIParseError.invalidValue("unexpected longPress")
    }

    func input(label: String, content: String, traits: String?, cindex: Int32?) throws {
        throw CLIParseError.invalidValue("unexpected input")
    }

    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload {
        throw CLIParseError.invalidValue("unexpected swipe")
    }

    func activateApp(bundleId: String) throws {
        throw CLIParseError.invalidValue("unexpected activateApp")
    }

    func terminateApp(bundleId: String) throws {
        throw CLIParseError.invalidValue("unexpected terminateApp")
    }

    func home() throws {
        throw CLIParseError.invalidValue("unexpected home")
    }

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        throw CLIParseError.invalidValue("unexpected dismissAlert")
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        throw CLIParseError.invalidValue("unexpected proxyCAPush")
    }
}

private final class FakeIOSUseCLICoreDeviceLifecycle: CoreDeviceDriverLifecycleManaging {
    var launches: [(String, String, Double)] = []
    var terminations: [(String, String?)] = []

    func launchDriver(udid: String, bundleID: String, timeoutSeconds: Double) throws {
        launches.append((udid, bundleID, timeoutSeconds))
    }

    func terminateDriver(udid: String, bundleID: String?) throws -> Bool {
        terminations.append((udid, bundleID))
        return true
    }
}
