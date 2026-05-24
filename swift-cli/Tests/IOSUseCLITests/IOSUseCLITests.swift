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
        DeviceService.resetCacheForTesting()
        DriverClient.usbmuxConnectorForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
        SessionService.realDriverLauncherForTesting = nil
        SessionService.realDriverReachableForTesting = nil
        SessionService.simulatorDriverLauncherForTesting = nil
        SessionService.simulatorDriverReachableForTesting = nil
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
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
            return [IOSDevice(name: "iPhone", version: "26.0", udid: "SIM-1", kind: .simulator)]
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

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", "SIM-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Opened URL: https://example.com\n")
        XCTAssertEqual(shellCalls.map(\.0), ["xcrun"])
        XCTAssertEqual(shellCalls.first?.1, ["simctl", "openurl", "SIM-1", "https://example.com"])
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

    func testOpenURLExplicitRealDeviceUsesDevicectlSpringBoardWithoutDriver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-CMD"] }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "https" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: ["com.apple.mobilesafari"], lookupFailed: false)
            }
            return nil
        }
        var shellCalls: [(String, [String])] = []
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
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
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", "REAL-CMD"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Opened URL: https://example.com (handler: com.apple.mobilesafari)\n")
        XCTAssertEqual(shellCalls.count, 1)
        XCTAssertEqual(shellCalls.first?.0, "xcrun")
        XCTAssertEqual(shellCalls.first?.1, [
            "devicectl",
            "device",
            "process",
            "launch",
            "--device", "REAL-CMD",
            "--payload-url", "https://example.com",
            "com.apple.springboard",
        ])
    }

    func testOpenURLDefaultUsbRealDeviceUsesDevicectlWithoutDriver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-default-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertFalse(simulatorOnly)
            return [IOSDevice(name: "iPhone", version: "26.0", udid: "REAL-DEFAULT", kind: .real)]
        }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "https" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: ["com.apple.mobilesafari"], lookupFailed: false)
            }
            return nil
        }
        var shellCalls: [(String, [String])] = []
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
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
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Opened URL: https://example.com (handler: com.apple.mobilesafari)\n")
        XCTAssertEqual(shellCalls.count, 1)
        XCTAssertEqual(shellCalls.first?.0, "xcrun")
        XCTAssertEqual(shellCalls.first?.1, [
            "devicectl",
            "device",
            "process",
            "launch",
            "--device", "REAL-DEFAULT",
            "--payload-url", "https://example.com",
            "com.apple.springboard",
        ])
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
        XCTAssertTrue(result.stderr.contains("openURL requires a booted simulator, active driver, or USB real device"))
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
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
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
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "notexist://test", "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("URL scheme \"notexist\" not registered on device"))
    }

    func testOpenURLRealDeviceLookupFailsGradesToSentURLRequest() throws {
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
        var shellCalls: [(String, [String])] = []
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
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
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Sent URL request: https://example.com"))
        XCTAssertTrue(result.stdout.contains("unable to verify scheme registration"))
        XCTAssertEqual(shellCalls.count, 1)
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
