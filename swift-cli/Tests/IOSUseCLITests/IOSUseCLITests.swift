import XCTest
import IOSUseDaemonRuntime
import IOSUseProtocol

final class IOSUseCLITests: XCTestCase {
    func testVersionMatchesCurrentPackageVersion() {
        XCTAssertEqual(IOSUseCLI.version, "1.0.1")
    }

    func testDaemonRunnerRequiresACommand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-daemon-parse-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runner = daemonCommandRunner(root: root)

        guard case .result(let result) = runner.parse(DaemonRequest(id: "missing", argv: [], cwd: root)) else {
            return XCTFail("expected parse result")
        }

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("missing command"))
    }

    func testDaemonRunnerRejectsLeadingUnknownOptionBeforeParser() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-daemon-parse-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runner = daemonCommandRunner(root: root)

        guard case .result(let result) = runner.parse(DaemonRequest(id: "unknown", argv: ["--not-a-real-option"], cwd: root)) else {
            return XCTFail("expected parse result")
        }

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("unknown option '--not-a-real-option'"))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    private func daemonCommandRunner(root: String) -> DaemonCommandRunner {
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let logger = DaemonLogger(paths: paths)
        return DaemonCommandRunner(
            environment: ["IOS_USE_HOME": root],
            paths: paths,
            output: DaemonOutputHandles(stdout: nil, stderr: nil),
            driverChannel: DaemonDriverChannel(paths: paths, logger: logger),
            logger: logger
        )
    }

    func testProxyDoctorReportsLocalProxyStatus() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-proxy-doctor-\(UUID().uuidString)")
            .path
        let result = executeTestCLI(environment: ["IOS_USE_HOME": home], arguments: ["proxy", "doctor"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Wi-Fi LAN IP"))
        XCTAssertTrue(result.stdout.contains("Proxy: not running"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testMissingRequiredArgumentFailsBeforeExecution() {
        let result = executeTestCLI(arguments: ["find"])

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
        XCTAssertEqual(paths.nslogLock, "/tmp/ios-use-swift-test-home/state/nslog.lock")
        XCTAssertEqual(paths.daemonSocket, "/tmp/ios-use-swift-test-home/state/daemon.sock")
        XCTAssertEqual(paths.logs, "/tmp/ios-use-swift-test-home/logs")
        XCTAssertEqual(paths.artifacts, "/tmp/ios-use-swift-test-home/artifacts")
    }

    func testLongIOSUseHomeUsesShortDaemonSocketPath() {
        let longHome = "/Users/example/.ios-use/test-homes/simulator-commands/artifacts/simulator-command-tests/20260519T184011Z/empty-home"
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": longHome])

        XCTAssertEqual(paths.root, longHome)
        XCTAssertTrue(paths.daemonSocket.hasPrefix("/tmp/iud-"))
        XCTAssertTrue(paths.daemonSocket.hasSuffix(".sock"))
        XCTAssertLessThan(paths.daemonSocket.utf8.count, 100)
        XCTAssertEqual(paths.daemonPid, "\(longHome)/state/daemon.pid")
        XCTAssertEqual(paths.daemonLog, "\(longHome)/logs/daemon.log")
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
