import XCTest

final class SessionTests: XCTestCase {
    func testForegroundWaitFailureError_UnknownStateUsesBundleId() {
        let error = foregroundWaitFailureError(
            state: .unknown,
            bundleId: "com.example.missing"
        )

        XCTAssertEqual(error.description, "app not found: com.example.missing")
    }

    func testForegroundWaitFailureError_NonUnknownStateIncludesState() {
        let error = foregroundWaitFailureError(
            state: .runningBackground,
            bundleId: "com.example.app"
        )

        XCTAssertEqual(error.description, "app not found: app failed to enter foreground (state=3)")
    }

    func testForegroundWaitFailureError_UnknownStateWithoutBundleUsesStateMessage() {
        let error = foregroundWaitFailureError(
            state: .unknown,
            bundleId: nil
        )

        XCTAssertEqual(error.description, "app not found: app failed to enter foreground (state=0)")
    }

    func testTerminationWaitFailureError_IncludesState() {
        let error = terminationWaitFailureError(state: .runningForeground)

        XCTAssertEqual(error.description, "app not found: app failed to terminate (state=4)")
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
            "com.apple.Preferences",
            acceptedBundleIds: ["com.apple.Preferences"]
        ))
        XCTAssertFalse(AppCommands.snapshotBundleAccepted(
            "com.apple.mobilesafari",
            acceptedBundleIds: ["com.apple.Preferences"]
        ))
        XCTAssertTrue(AppCommands.snapshotBundleAccepted(
            "com.apple.mobilesafari",
            acceptedBundleIds: ["com.apple.mobilesafari", "com.example.browser"]
        ))
        XCTAssertFalse(AppCommands.snapshotBundleAccepted(
            "com.apple.Preferences",
            acceptedBundleIds: ["com.apple.mobilesafari", "com.example.browser"]
        ))
    }

}
