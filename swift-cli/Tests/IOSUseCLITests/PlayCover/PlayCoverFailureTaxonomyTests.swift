import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverFailureTaxonomyTests: XCTestCase {
    func testPrepareAndLaunchFailuresHaveStableMachineClassification() {
        let cases: [(PlayCoverBackendError, String, String, String, Bool)] = [
            (
                .malformedMachO("bad header"),
                "validation",
                "playcover_malformed_macho",
                "playcover_macho",
                false
            ),
            (
                .machOTransformFailed("inject failed"),
                "internal",
                "playcover_macho_transform_failed",
                "playcover_macho",
                false
            ),
            (
                .entitlementFailed("compose failed"),
                "validation",
                "playcover_entitlement_failed",
                "playcover_entitlements",
                false
            ),
            (
                .codeSigningFailed("nested sign failed"),
                "internal",
                "playcover_codesign_failed",
                "playcover_codesign",
                false
            ),
            (
                .launchFailed("dyld failed"),
                "internal",
                "playcover_dyld_launch_failed",
                "playcover_dyld_launch",
                false
            ),
            (
                .stdioLogFailed("exact identity mismatch"),
                "internal",
                "playcover_stdio_log_failed",
                "playcover_stdio_setup",
                false
            ),
            (
                .launchTimedOut("hello timed out"),
                "timeout",
                "playcover_runtime_hello_timed_out",
                "playcover_runtime_hello",
                true
            ),
        ]

        for (error, category, code, phase, retryable) in cases {
            let classified = MachineOutput.classify(error)
            XCTAssertEqual(classified.category, category, "\(error)")
            XCTAssertEqual(classified.code, code, "\(error)")
            XCTAssertEqual(classified.phase, phase, "\(error)")
            XCTAssertEqual(classified.retryable, retryable, "\(error)")
            XCTAssertFalse(classified.fatal, "\(error)")
            XCTAssertFalse(classified.mutationMayHaveApplied, "\(error)")
        }
    }

    func testUnterminatedLaunchRemainsASeparateFatalRollbackFailure() {
        let classified = MachineOutput.classify(
            PlayCoverUnterminatedLaunchError(
                sessionID: "test-session",
                pid: 42,
                bundleIdentifier: "com.example.fixture",
                executablePath: "/tmp/Fixture",
                appPath: "/tmp/Fixture.app",
                generationKey: "generation",
                runtimeSocketPath: "/tmp/runtime.sock",
                originalError: "dyld failed",
                rollbackError: "SIGKILL failed"
            )
        )

        XCTAssertEqual(classified.category, "session")
        XCTAssertEqual(classified.code, "playcover_launch_rollback_failed")
        XCTAssertEqual(classified.phase, "playcover_dyld_launch")
        XCTAssertFalse(classified.retryable)
        XCTAssertTrue(classified.fatal)
        XCTAssertTrue(classified.mutationMayHaveApplied)
    }

    func testLoggedLaunchPreservesUnderlyingMachineClassification() {
        let classified = MachineOutput.classify(
            PlayCoverSessionLoggedLaunchError(
                logPath: "/tmp/stdio-session.log",
                underlying: PlayCoverBackendError.launchTimedOut(
                    "hello timed out"
                )
            )
        )

        XCTAssertEqual(classified.category, "timeout")
        XCTAssertEqual(
            classified.code,
            "playcover_runtime_hello_timed_out"
        )
        XCTAssertEqual(classified.phase, "playcover_runtime_hello")
        XCTAssertTrue(classified.retryable)
        XCTAssertFalse(classified.fatal)
        XCTAssertFalse(classified.mutationMayHaveApplied)
        XCTAssertTrue(
            classified.message.contains(
                "Mac log: /tmp/stdio-session.log"
            )
        )
    }

    func testLoggedUnterminatedLaunchPreservesFatalRollbackTaxonomy() {
        let underlying = PlayCoverUnterminatedLaunchError(
            sessionID: "test-session",
            pid: 42,
            bundleIdentifier: "com.example.fixture",
            executablePath: "/tmp/Fixture",
            appPath: "/tmp/Fixture.app",
            generationKey: "generation",
            runtimeSocketPath: "/tmp/runtime.sock",
            originalError: "hello timed out",
            rollbackError: "SIGKILL failed"
        )
        let classified = MachineOutput.classify(
            PlayCoverSessionUnterminatedLaunchError(
                result: .init(
                    sessionID: "test-session",
                    appPath: "/tmp/Fixture.app",
                    bundleIdentifier: "com.example.fixture",
                    executablePath: "/tmp/Fixture",
                    generationKey: "generation",
                    productType: "iPhone16,2",
                    pid: 42,
                    runtimeSocketPath: "/tmp/runtime.sock",
                    logPath: "/tmp/stdio-session.log",
                    reused: false
                ),
                underlying: underlying
            )
        )

        XCTAssertEqual(classified.category, "session")
        XCTAssertEqual(
            classified.code,
            "playcover_launch_rollback_failed"
        )
        XCTAssertEqual(classified.phase, "playcover_dyld_launch")
        XCTAssertFalse(classified.retryable)
        XCTAssertTrue(classified.fatal)
        XCTAssertTrue(classified.mutationMayHaveApplied)
        XCTAssertTrue(
            classified.message.contains(
                "Mac log: /tmp/stdio-session.log"
            )
        )
    }

    func testLoggedFailureMachineEnvelopeCarriesTypedRetainedPath()
        throws
    {
        let result = MachineOutput.failure(
            command: "start",
            error: PlayCoverSessionLoggedLaunchError(
                logPath: "/tmp/stdio-session.log",
                underlying: PlayCoverBackendError.stdioLogFailed(
                    "exact identity mismatch"
                )
            )
        )

        XCTAssertEqual(result.exitCode, 1)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(result.stderr.utf8)
            ) as? [String: Any]
        )
        let data = try XCTUnwrap(
            envelope["data"] as? [String: Any]
        )
        XCTAssertEqual(
            data["playcoverLogPath"] as? String,
            "/tmp/stdio-session.log"
        )
        let error = try XCTUnwrap(
            envelope["error"] as? [String: Any]
        )
        XCTAssertEqual(
            error["code"] as? String,
            "playcover_stdio_log_failed"
        )
        XCTAssertEqual(
            error["phase"] as? String,
            "playcover_stdio_setup"
        )
    }

    func testLaunchCleanupFailureIsRetryableMutationAndRetainsLog()
        throws
    {
        let result = MachineOutput.failure(
            command: "start",
            error: PlayCoverSessionCleanupError(
                operation: .launch,
                cleanupError:
                    PlayCoverBackendError.cacheTampered(
                        "facade cleanup failed"
                    ),
                originalError:
                    PlayCoverBackendError.launchTimedOut(
                        "hello timed out"
                    ),
                logPath: "/tmp/stdio-session.log"
            )
        )

        XCTAssertEqual(result.exitCode, 1)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(result.stderr.utf8)
            ) as? [String: Any]
        )
        let error = try XCTUnwrap(
            envelope["error"] as? [String: Any]
        )
        XCTAssertEqual(error["category"] as? String, "session")
        XCTAssertEqual(
            error["code"] as? String,
            "playcover_launch_cleanup_failed"
        )
        XCTAssertEqual(
            error["phase"] as? String,
            "playcover_launch_cleanup"
        )
        XCTAssertEqual(error["retryable"] as? Bool, true)
        XCTAssertEqual(error["fatal"] as? Bool, false)
        XCTAssertEqual(
            error["mutationMayHaveApplied"] as? Bool,
            true
        )
        let data = try XCTUnwrap(
            envelope["data"] as? [String: Any]
        )
        XCTAssertEqual(
            data["playcoverLogPath"] as? String,
            "/tmp/stdio-session.log"
        )
    }
}
