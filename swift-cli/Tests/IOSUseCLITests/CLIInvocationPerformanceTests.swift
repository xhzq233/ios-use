import Dispatch
import Foundation
import XCTest
@testable import IOSUseCLI

final class CLIInvocationPerformanceTests: XCTestCase {
    override func tearDown() {
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.resetCacheForTesting()
        super.tearDown()
    }

    func testMachineFinalizationPreservesDataPerformanceAndAddsSubmillisecondMetrics()
        throws
    {
        let collector = CLIInvocationPerformanceCollector(
            startedAt: 1,
            now: { 1.000625 }
        )
        collector.recordRuntimeRoundTrip(elapsedMs: 0.25)
        collector.recordRuntimeRoundTrip(elapsedMs: 0.25)
        collector.recordRuntimeRequest(elapsedMs: 0.125)
        collector.recordAlertRefresh(elapsedMs: 0.375)
        collector.recordWarning("runtime interaction is pending")
        collector.recordInteractionState(
            .object([
                "blocking": .boolean(true),
                "kind": .string("inProcessAlert"),
            ])
        )

        let result = CLIInvocationPerformanceContext
            .$current.withValue(collector) {
                MachineOutput.success(
                    command: "fixture",
                    data: .object([
                        "performance": .object([
                            "driverElapsedMs": .double(12.5)
                        ])
                    ]),
                    warnings: ["existing warning"]
                )
            }

        let envelope = try machineEnvelope(result.stdout)
        let performance = try XCTUnwrap(
            envelope["performance"] as? [String: Any]
        )
        XCTAssertEqual(
            try XCTUnwrap(
                performance["totalElapsedMs"] as? Double
            ),
            0.625,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            performance["runtimeRoundTripElapsedMs"] as? Double,
            0.5
        )
        XCTAssertEqual(
            performance["runtimeRoundTripCount"] as? Int,
            2
        )
        XCTAssertEqual(
            performance["runtimeRequestElapsedMs"] as? Double,
            0.125
        )
        XCTAssertEqual(
            performance["runtimeRequestCount"] as? Int,
            1
        )
        XCTAssertEqual(
            performance["alertRefreshElapsedMs"] as? Double,
            0.375
        )
        XCTAssertEqual(
            performance["alertRefreshCount"] as? Int,
            1
        )
        let data = try XCTUnwrap(
            envelope["data"] as? [String: Any]
        )
        let dataPerformance = try XCTUnwrap(
            data["performance"] as? [String: Any]
        )
        XCTAssertEqual(
            dataPerformance["driverElapsedMs"] as? Double,
            12.5
        )
        XCTAssertEqual(
            envelope["warnings"] as? [String],
            [
                "existing warning",
                "runtime interaction is pending",
            ]
        )
        let interaction = try XCTUnwrap(
            envelope["interaction"] as? [String: Any]
        )
        XCTAssertEqual(interaction["blocking"] as? Bool, true)
        XCTAssertEqual(
            interaction["kind"] as? String,
            "inProcessAlert"
        )
        XCTAssertTrue(
            result.stdout.contains(
                #""runtimeRequestElapsedMs" : 0.125"#
            )
        )
    }

    func testCollectorClaimsOneRefreshAndAccumulatesConcurrently() {
        let collector = CLIInvocationPerformanceCollector()
        let claimsLock = NSLock()
        var successfulClaims = 0

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if collector.claimAlertRefresh() {
                claimsLock.lock()
                successfulClaims += 1
                claimsLock.unlock()
            }
            collector.recordRuntimeRoundTrip(elapsedMs: 0.25)
            collector.recordRuntimeRequest(elapsedMs: 0.125)
            collector.recordWarning("same warning")
        }

        let snapshot = collector.snapshot()
        XCTAssertEqual(successfulClaims, 1)
        XCTAssertEqual(snapshot.runtimeRoundTripElapsedMs, 25)
        XCTAssertEqual(snapshot.runtimeRoundTripCount, 100)
        XCTAssertEqual(snapshot.runtimeRequestElapsedMs, 12.5)
        XCTAssertEqual(snapshot.runtimeRequestCount, 100)
        XCTAssertEqual(snapshot.warnings, ["same warning"])
    }

    func testLifecycleSuppressionPreventsAlertRefreshClaim() {
        let collector = CLIInvocationPerformanceCollector()

        collector.suppressAlertRefresh()

        XCTAssertFalse(collector.claimAlertRefresh())
        XCTAssertEqual(collector.snapshot().alertRefreshCount, 0)
    }

    func testPublicMachineSuccessParseFailureAndCommandFailureCarryPerformance()
        throws
    {
        let root = temporaryRoot("machine")
        DeviceService.listDevicesOverrideForTesting = { _, _ in [] }
        defer {
            try? FileManager.default.removeItem(atPath: root)
        }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": root]
        )

        let success = cli.run(arguments: ["status", "--json"])
        let parseFailure = cli.run(
            arguments: ["tap", "General", "extra", "--json"]
        )
        let commandFailure = cli.run(
            arguments: ["open", "://missing", "--json"]
        )

        XCTAssertEqual(success.exitCode, 0)
        XCTAssertGreaterThanOrEqual(
            try totalElapsedMs(in: success.stdout),
            0
        )
        let successPerformance =
            try performance(in: success.stdout)
        XCTAssertTrue(
            successPerformance["runtimeRoundTripElapsedMs"]
                is NSNull
        )
        XCTAssertEqual(
            successPerformance["runtimeRoundTripCount"] as? Int,
            0
        )
        XCTAssertTrue(
            successPerformance["runtimeRequestElapsedMs"]
                is NSNull
        )
        XCTAssertEqual(
            successPerformance["runtimeRequestCount"] as? Int,
            0
        )
        XCTAssertTrue(
            successPerformance["alertRefreshElapsedMs"]
                is NSNull
        )
        XCTAssertEqual(
            successPerformance["alertRefreshCount"] as? Int,
            0
        )
        XCTAssertEqual(parseFailure.exitCode, 64)
        XCTAssertGreaterThanOrEqual(
            try totalElapsedMs(in: parseFailure.stderr),
            0
        )
        XCTAssertEqual(commandFailure.exitCode, 1)
        XCTAssertGreaterThanOrEqual(
            try totalElapsedMs(in: commandFailure.stderr),
            0
        )

        let log = try String(
            contentsOfFile: CLILogService.logPath(paths: cli.paths),
            encoding: .utf8
        )
        XCTAssertTrue(
            log.contains(
                "[cli-performance] command=status ok=true "
            )
        )
        XCTAssertTrue(
            log.contains(
                "[cli-performance] command=tap ok=false "
            )
        )
        XCTAssertTrue(
            log.contains(
                "[cli-performance] command=open ok=false "
            )
        )
    }

    func testHumanHelpKeepsStdoutAndWritesPerformanceLog() throws {
        let root = temporaryRoot("help")
        defer {
            try? FileManager.default.removeItem(atPath: root)
        }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": root]
        )

        let result = cli.run(arguments: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, IOSUseCLI.helpText)
        XCTAssertTrue(result.stderr.isEmpty)
        let log = try String(
            contentsOfFile: CLILogService.logPath(paths: cli.paths),
            encoding: .utf8
        )
        XCTAssertTrue(
            log.contains(
                "[cli-performance] command=help ok=true "
            )
        )
        XCTAssertTrue(log.contains("totalElapsedMs="))
    }

    func testJSONFlagDoesNotTurnImmediateHelpIntoMachineEnvelope()
        throws
    {
        let root = temporaryRoot("json-help")
        defer {
            try? FileManager.default.removeItem(atPath: root)
        }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": root]
        )

        let result = cli.run(arguments: ["--json", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, IOSUseCLI.helpText)
        XCTAssertFalse(result.stdout.contains(#""performance""#))
        XCTAssertTrue(result.stderr.isEmpty)
        let log = try String(
            contentsOfFile: CLILogService.logPath(paths: cli.paths),
            encoding: .utf8
        )
        XCTAssertTrue(
            log.contains(
                "[cli-performance] command=help ok=true "
            )
        )
    }

    func testInvocationWarningKeepsHumanStdoutAndUsesOneStderrLine() {
        let collector = CLIInvocationPerformanceCollector()
        collector.recordWarning("runtime state is pending\nretry the read")

        let result = MachineOutput.finalizeInvocation(
            CLIResult(exitCode: 0, stdout: "done\n"),
            expectsMachineOutput: false,
            snapshot: collector.snapshot()
        )

        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertEqual(
            result.stderr,
            "warning: runtime state is pending retry the read\n"
        )
    }

    private func totalElapsedMs(in output: String) throws -> Double {
        let performance = try performance(in: output)
        return try XCTUnwrap(
            performance["totalElapsedMs"] as? Double
        )
    }

    private func performance(
        in output: String
    ) throws -> [String: Any] {
        let envelope = try machineEnvelope(output)
        return try XCTUnwrap(
            envelope["performance"] as? [String: Any]
        )
    }

    private func machineEnvelope(
        _ output: String
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(output.utf8)
            ) as? [String: Any]
        )
    }

    private func temporaryRoot(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-cli-performance-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
            .path
    }
}
