import XCTest
import IOSUseCLI
import IOSUseProtocol

final class IOSUseCLITests: XCTestCase {
    func testHelpContainsMigrationStatusAndDefaultExecutable() {
        let result = IOSUseCLI().run(arguments: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Swift CLI for ios-use"))
        XCTAssertTrue(result.stdout.contains("dist/ios-use"))
        XCTAssertTrue(result.stdout.contains("shared IOSUseProtocol/Fory model source"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testVersionMatchesCurrentPackageVersion() {
        let result = IOSUseCLI().run(arguments: ["--version"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "1.0.0\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testUnknownOptionFailsBeforeAnySessionWork() {
        let result = IOSUseCLI().run(arguments: ["--not-a-real-option"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("unknown option '--not-a-real-option'"))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testProxyDoctorReportsLocalProxyStatus() {
        let result = IOSUseCLI().run(arguments: ["proxy", "doctor"])

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
        XCTAssertEqual(IOSUseProtocol.defaultDriverPort, 8100)
        XCTAssertEqual(IOSUseProtocol.maxFrameSizeBytes, 50 * 1024 * 1024)
        XCTAssertEqual(IOSUseProtocol.commandTimeoutSeconds, 45)
        XCTAssertEqual(IOSUseProtocol.commandCompletionTimeoutSeconds, 120)
        XCTAssertEqual(IOSUseProtocol.nsloggerDefaultPort, 50_000)
        XCTAssertEqual(IOSUseProtocol.proxyMitmdumpPort, 9080)
        XCTAssertEqual(IOSUseProtocol.springboardBundleId, "com.apple.springboard")
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
