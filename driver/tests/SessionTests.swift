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

    func testOpenURLUsesSystemOnlyWhenApplicationCanOpenURL() throws {
        let allowed = Set(["http", "https", "prefs"])
        let canOpen: (URL) -> Bool = { url in
            guard let scheme = url.scheme?.lowercased() else { return false }
            return allowed.contains(scheme)
        }

        XCTAssertTrue(shouldOpenURLViaSystem(try XCTUnwrap(URL(string: "http://127.0.0.1:9088/ca.cer")), canOpen: canOpen))
        XCTAssertTrue(shouldOpenURLViaSystem(try XCTUnwrap(URL(string: "https://example.com")), canOpen: canOpen))
        XCTAssertTrue(shouldOpenURLViaSystem(try XCTUnwrap(URL(string: "HTTPS://example.com")), canOpen: canOpen))
        XCTAssertTrue(shouldOpenURLViaSystem(try XCTUnwrap(URL(string: "prefs:root=WIFI")), canOpen: canOpen))

        XCTAssertFalse(shouldOpenURLViaSystem(try XCTUnwrap(URL(string: "xtretouch://open")), canOpen: canOpen))
        XCTAssertFalse(shouldOpenURLViaSystem(try XCTUnwrap(URL(string: "itms-services://?action=download-manifest")), canOpen: canOpen))
    }
}
