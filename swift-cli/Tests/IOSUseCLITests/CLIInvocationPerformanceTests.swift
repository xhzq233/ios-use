import Dispatch
import Foundation
import XCTest
@testable import IOSUseCLI

final class CLIInvocationPerformanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StatusService.macSigningResolutionForTesting = {
            PlayCoverSigningIdentityResolution(
                health: .healthy,
                evidence: nil
            )
        }
        StatusService.macRuntimeResolutionForTesting = { _ in
            "/test/IOSUsePlayRuntime.framework"
        }
    }

    override func tearDown() {
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.resetCacheForTesting()
        StatusService.macSigningResolutionForTesting = nil
        StatusService.macRuntimeResolutionForTesting = nil
        super.tearDown()
    }

    func testMachineOutputPreservesDataPerformanceWithoutInvocationPerformance()
        throws
    {
        let state = CLIInvocationState()
        state.recordWarning("runtime interaction is pending")
        state.recordInteractionState(
            .object([
                "blocking": .boolean(true),
                "kind": .string("inProcessAlert"),
            ])
        )

        let result = CLIInvocationContext
            .$current.withValue(state) {
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
        XCTAssertNil(envelope["performance"])
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
        XCTAssertFalse(result.stdout.contains("totalElapsedMs"))
        XCTAssertFalse(
            result.stdout.contains("runtimeRequestElapsedMs")
        )
    }

    func testInvocationStateClaimsOneRefreshAndDeduplicatesWarningsConcurrently() {
        let state = CLIInvocationState()
        let claimsLock = NSLock()
        var successfulClaims = 0

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if state.claimAlertRefresh() {
                claimsLock.lock()
                successfulClaims += 1
                claimsLock.unlock()
            }
            state.recordWarning("same warning")
        }

        let snapshot = state.snapshot()
        XCTAssertEqual(successfulClaims, 1)
        XCTAssertEqual(snapshot.warnings, ["same warning"])
    }

    func testLifecycleSuppressionPreventsAlertRefreshClaim() {
        let state = CLIInvocationState()

        state.suppressAlertRefresh()

        XCTAssertFalse(state.claimAlertRefresh())
    }

    func testPerformanceCollectorKeepsOnlyInternalElapsedValues() {
        let collector = CLIInvocationPerformanceCollector(
            startedAt: 1,
            now: { 1.000625 }
        )

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            collector.recordAlertRefresh(elapsedMs: 0.125)
        }
        collector.recordAlertRefresh(elapsedMs: -1)

        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.alertRefreshElapsedMs, 12.5)
        XCTAssertEqual(
            collector.freezeTotalElapsedMs(),
            0.625,
            accuracy: 0.000_001
        )
    }

    func testPublicMachineOutputsOmitInvocationPerformanceAndLogOneSummary()
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
        XCTAssertNil(
            try machineEnvelope(success.stdout)["performance"]
        )
        XCTAssertEqual(parseFailure.exitCode, 64)
        XCTAssertNil(
            try machineEnvelope(parseFailure.stderr)["performance"]
        )
        XCTAssertEqual(commandFailure.exitCode, 1)
        XCTAssertNil(
            try machineEnvelope(commandFailure.stderr)[
                "performance"
            ]
        )

        let log = try String(
            contentsOfFile: CLILogService.logPath(paths: cli.paths),
            encoding: .utf8
        )
        XCTAssertTrue(
            log.contains(
                "[cli] command=status ok=true commandElapsedMs="
            )
        )
        XCTAssertTrue(
            log.contains(
                "[cli] command=tap ok=false commandElapsedMs="
            )
        )
        XCTAssertTrue(
            log.contains(
                "[cli] command=open ok=false commandElapsedMs="
            )
        )
        XCTAssertFalse(log.contains("runtimeRoundTrip"))
        XCTAssertFalse(log.contains("runtimeRequest"))
        XCTAssertFalse(log.contains("interactionElapsedMs"))
        XCTAssertFalse(log.contains("Count="))
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
                "[cli] command=help ok=true commandElapsedMs="
            )
        )
        XCTAssertEqual(
            log.split(whereSeparator: \.isNewline).count,
            1
        )
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
                "[cli] command=help ok=true commandElapsedMs="
            )
        )
    }

    func testInvocationWarningKeepsHumanStdoutAndUsesOneStderrLine() {
        let state = CLIInvocationState()
        state.recordWarning("runtime state is pending\nretry the read")

        let result = MachineOutput.finalizeInvocation(
            CLIResult(exitCode: 0, stdout: "done\n"),
            expectsMachineOutput: false,
            snapshot: state.snapshot()
        )

        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertEqual(
            result.stderr,
            "warning: runtime state is pending retry the read\n"
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
