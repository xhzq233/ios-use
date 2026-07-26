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
}
