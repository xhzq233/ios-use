import XCTest

final class Session {
    static let shared = Session()

    private var _app: XCUIApplication?

    func cache(app: XCUIApplication) {
        _app = app
        invalidateSnapshot()
    }

    func ensureActive() throws -> XCUIApplication {
        if let app = _app, app.state == .runningForeground {
            return app
        }
        if let detected = GetActiveApplication() {
            _app = detected
            invalidateSnapshot()
            return detected
        }
        throw DriverError.noSession
    }
}
