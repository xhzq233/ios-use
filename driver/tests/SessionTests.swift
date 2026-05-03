import XCTest

final class SessionTests: XCTestCase {
    func testActiveAppResolutionStrategy_DeviceSessionAlwaysDetectsWithoutBundleHint() {
        let strategy = activeAppResolutionStrategy(
            isDeviceSession: true,
            cachedAppState: .runningForeground,
            bundleIdHint: "com.apple.mobilesafari"
        )

        XCTAssertEqual(strategy, .detect(bundleIdHint: nil))
    }

    func testActiveAppResolutionStrategy_AppSessionUsesCachedForegroundApp() {
        let strategy = activeAppResolutionStrategy(
            isDeviceSession: false,
            cachedAppState: .runningForeground,
            bundleIdHint: "com.apple.Preferences"
        )

        XCTAssertEqual(strategy, .useCachedForegroundApp)
    }

    func testActiveAppResolutionStrategy_AppSessionFallsBackToBundleHintWhenCacheMisses() {
        let strategy = activeAppResolutionStrategy(
            isDeviceSession: false,
            cachedAppState: .notRunning,
            bundleIdHint: "com.apple.Preferences"
        )

        XCTAssertEqual(strategy, .detect(bundleIdHint: "com.apple.Preferences"))
    }

    func testActiveAppResolutionStrategy_AppSessionWithoutBundleHintFallsBackToGenericDetection() {
        let strategy = activeAppResolutionStrategy(
            isDeviceSession: false,
            cachedAppState: nil,
            bundleIdHint: nil
        )

        XCTAssertEqual(strategy, .detect(bundleIdHint: nil))
    }
}
