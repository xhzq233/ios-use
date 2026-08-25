import XCTest

final class SessionTests: XCTestCase {
    func testForegroundWaitFailureError_UnknownStateUsesBundleId() {
        let error = foregroundWaitFailureError(
            state: .unknown,
            bundleId: "com.example.missing"
        )

        guard case .appNotFound(let bundleID) = error else {
            return XCTFail("expected appNotFound")
        }
        XCTAssertEqual(bundleID, "com.example.missing")
    }

    func testActivateAppLaunchesAnyNonForegroundStateViaLaunchServices() {
        XCTAssertTrue(shouldLaunchViaLaunchServices(state: .unknown))
        XCTAssertTrue(shouldLaunchViaLaunchServices(state: .notRunning))
        XCTAssertTrue(shouldLaunchViaLaunchServices(state: .runningBackground))
        XCTAssertTrue(shouldLaunchViaLaunchServices(state: .runningBackgroundSuspended))
        XCTAssertFalse(shouldLaunchViaLaunchServices(state: .runningForeground))
    }

    func testURLReadinessRequiresSnapshotFromAcceptedHandler() {
        XCTAssertTrue(AppCommands.snapshotBundleAccepted("com.apple.Preferences", acceptedBundleIds: []))
        XCTAssertTrue(AppCommands.snapshotBundleAccepted(
            "com.apple.mobilesafari",
            acceptedBundleIds: ["com.apple.mobilesafari", "com.example.browser"]
        ))
        XCTAssertFalse(AppCommands.snapshotBundleAccepted(
            "com.apple.Preferences",
            acceptedBundleIds: ["com.apple.mobilesafari", "com.example.browser"]
        ))
    }

    func testActivateReadinessAllowsSystemOverlayOnlyWhileExpectedAppRemainsForeground() {
        XCTAssertTrue(AppCommands.snapshotBundleAccepted(
            "com.apple.Preferences",
            expectedBundleId: "com.apple.Preferences",
            expectedAppForeground: true,
            acceptedBundleIds: []
        ))
        XCTAssertTrue(AppCommands.snapshotBundleAccepted(
            IOSUseProtocol.springboardBundleId,
            expectedBundleId: "com.apple.Preferences",
            expectedAppForeground: true,
            hasSystemAlert: true,
            acceptedBundleIds: []
        ))
        XCTAssertFalse(AppCommands.snapshotBundleAccepted(
            "com.example.other",
            expectedBundleId: "com.apple.Preferences",
            expectedAppForeground: false,
            acceptedBundleIds: []
        ))
        XCTAssertFalse(AppCommands.snapshotBundleAccepted(
            "com.apple.mobilesafari",
            expectedBundleId: "com.apple.Preferences",
            expectedAppForeground: true,
            hasSystemAlert: true,
            acceptedBundleIds: []
        ))
        XCTAssertFalse(AppCommands.snapshotBundleAccepted(
            IOSUseProtocol.springboardBundleId,
            expectedBundleId: "com.apple.Preferences",
            expectedAppForeground: true,
            hasSystemAlert: false,
            acceptedBundleIds: []
        ))
    }

    func testActivateReadinessOnlySnapshotsExpectedAppOrSpringBoardCandidate() {
        XCTAssertTrue(AppCommands.snapshotBundleMayBeAccepted(
            "com.apple.Preferences",
            expectedBundleId: "com.apple.Preferences",
            expectedAppForeground: true,
            acceptedBundleIds: []
        ))
        XCTAssertTrue(AppCommands.snapshotBundleMayBeAccepted(
            IOSUseProtocol.springboardBundleId,
            expectedBundleId: "com.apple.Preferences",
            expectedAppForeground: true,
            acceptedBundleIds: []
        ))
        XCTAssertFalse(AppCommands.snapshotBundleMayBeAccepted(
            "com.apple.mobilesafari",
            expectedBundleId: "com.apple.Preferences",
            expectedAppForeground: true,
            acceptedBundleIds: []
        ))
    }

    func testActivateReadinessRequiresAnObservedForegroundBundle() {
        XCTAssertFalse(AppCommands.foregroundBundleAccepted(
            nil,
            expectedBundleId: "com.apple.Preferences"
        ))
        XCTAssertFalse(AppCommands.foregroundBundleAccepted(
            "com.apple.mobilesafari",
            expectedBundleId: "com.apple.Preferences"
        ))
        XCTAssertTrue(AppCommands.foregroundBundleAccepted(
            "com.apple.Preferences",
            expectedBundleId: "com.apple.Preferences"
        ))
        XCTAssertTrue(AppCommands.foregroundBundleAccepted(
            IOSUseProtocol.springboardBundleId,
            expectedBundleId: "com.apple.Preferences"
        ))
    }

}
