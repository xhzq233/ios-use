import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class IOSUseCLITests: XCTestCase {
    func testHelpContainsRootUsageAndCommands() {
        let result = IOSUseCLI().run(arguments: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Swift CLI for ios-use"))
        XCTAssertTrue(result.stdout.contains("Usage: ios-use [--help] [--version] <command>"))
        XCTAssertTrue(result.stdout.contains("devices, config, dom"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testVersionMatchesCurrentPackageVersion() {
        let result = IOSUseCLI().run(arguments: ["--version"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "1.0.2\n")
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
        try """
        {"devices":{"REAL-CMD":{"bundleId":"com.example.driver","port":"8102","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)

        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-CMD"] }
        var launched: [(String, String)] = []
        SessionService.realDriverLauncherForTesting = { udid, bundleId in
            launched.append((udid, bundleId))
        }
        SessionService.realDriverReachableForTesting = { _ in
            !launched.isEmpty
        }
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTAssertEqual(session?.udid, "REAL-CMD")
            XCTAssertEqual(session?.deviceType, "real")
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
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            SessionService.realDriverLauncherForTesting = nil
            SessionService.realDriverReachableForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom", "--udid", "REAL-CMD"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("App: com.example.app"))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(launched.map(\.0), ["REAL-CMD"])
        XCTAssertEqual(launched.map(\.1), ["com.example.driver"])
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

    func testDriverCommandNamesMatchWireCommands() {
        let commands = Set(DriverCommand.allCases.map(\.rawValue))

        XCTAssertTrue(commands.contains("dom"))
        XCTAssertTrue(commands.contains("find"))
        XCTAssertTrue(commands.contains("waitFor"))
        XCTAssertTrue(commands.contains("dismissAlert"))
        XCTAssertEqual(commands.count, 14)
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

    func testPathsRespectIOSUseHomeOverrideWithoutWritingFiles() {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": "/tmp/ios-use-swift-test-home",
            "HOME": "/tmp/real-home-should-not-be-used"
        ])

        XCTAssertEqual(paths.root, "/tmp/ios-use-swift-test-home")
        XCTAssertEqual(paths.config, "/tmp/ios-use-swift-test-home/config.json")
        XCTAssertEqual(paths.session, "/tmp/ios-use-swift-test-home/state/session.json")
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
}

private final class FakeDriverCommandClient: DriverCommandClient {
    private let domHandler: () throws -> ForyDomPayload

    init(domHandler: @escaping () throws -> ForyDomPayload) {
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

    func openURL(url: String) throws -> ForySimpleStringPayload {
        throw CLIParseError.invalidValue("unexpected openURL")
    }

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        throw CLIParseError.invalidValue("unexpected dismissAlert")
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        throw CLIParseError.invalidValue("unexpected proxyCAPush")
    }
}
