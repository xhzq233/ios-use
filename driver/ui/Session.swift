import XCTest

final class Session {
    static let shared = Session()

    private var _app: XCUIApplication?

    func cache(app: XCUIApplication) {
        _app = app
        invalidateSnapshot()
    }

    func ensureActive() throws -> XCUIApplication {
        // Fast path: cached non-springboard app still in foreground — return directly.
        // Springboard is excluded because its state is always .runningForeground,
        // even when the user has switched to another app.
        if let app = _app, app.state == .runningForeground {
            let bid = app.value(forKey: "bundleID") as? String ?? ""
            if bid != IOSUseProtocol.springboardBundleId {
                return app
            }
        }
        // Slow path: cached app gone/suspended, or it was springboard.
        if let detected = GetActiveApplication() {
            if detected !== _app {
                invalidateSnapshot()
            }
            _app = detected
            return detected
        }
        throw DriverError.noSession
    }
}
