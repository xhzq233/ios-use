import XCTest

final class Session {
    static let shared = Session()

    private var _app: XCUIApplication?

    func cache(app: XCUIApplication) {
        _app = app
        invalidateSnapshot()
    }

    /// Potentially expensive XCTest live operation.
    ///
    /// This may read live app state or ask XCTest accessibility infrastructure for
    /// the foreground application. Do not call it as a cheap session check; prefer
    /// carrying an existing `SafeSnapshot`/`CleanedSnapshot` through read-only
    /// paths, and only request `XCUIApplication` when a snapshot or live gesture
    /// operation really needs it.
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
