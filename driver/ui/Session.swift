import XCTest

final class Session {
    static let shared = Session()

    private var _app: XCUIApplication?
    private var _bundleId: String?

    var bundleId: String? { _bundleId }

    func create(bundleId: String?) throws {
        if let bundleId = bundleId {
            NSLog("[session] create called with bundleId=\(bundleId)")
            let app: XCUIApplication
            if let existing = _app, _bundleId == bundleId {
                app = existing
            } else {
                app = XCUIApplication(bundleIdentifier: bundleId)
            }

            let state = app.state
            NSLog("[session] app state=\(state.rawValue) (0=unknown,1=notRunning,2=suspended,3=background,4=foreground)")
            guard state != .unknown else {
                NSLog("[session] ERROR: app not found, state=unknown bundleId=\(bundleId)")
                throw DriverError.appNotFound(bundleId)
            }
            if state != .notRunning && state != .unknown {
                NSLog("[session] terminating app for cold start...")
                app.terminate()
                try waitForTermination(app)
            }

            // Explicit bundleId means cold-start the target app: terminate if
            // needed, then relaunch via LaunchServices so the new session is
            // not constrained by the previously foregrounded app.
            NSLog("[session] launching app via LaunchServices...")
            guard OpenApplicationWithBundleId(bundleId) else {
                NSLog("[session] ERROR: LaunchServices could not open bundleId=\(bundleId)")
                throw DriverError.appNotFound(bundleId)
            }
            NSLog("[session] openApplicationWithBundleID() returned")
            try waitForForeground(app, bundleId: bundleId)
            _app = app
            _bundleId = bundleId
            NSLog("[session] session created, final state=\(app.state.rawValue)")
            invalidateSnapshot()
        } else {
            // Device session: do not bind to any specific app
            NSLog("[session] device session created (no app bound)")
            _app = nil
            _bundleId = nil
            invalidateSnapshot()
        }
    }

    private func waitForForeground(_ app: XCUIApplication, bundleId: String? = nil) throws {
        NSLog("[session] waiting for app to enter foreground...")
        let deadline = CFAbsoluteTimeGetCurrent() + 10
        var state = app.state
        while state != .runningForeground && CFAbsoluteTimeGetCurrent() < deadline {
            // Short RunLoop spin (50ms) lets the system breathe and avoids
            // the iOS watchdog (0x8badf00d) that kills apps blocking the
            // main thread for too long. We keep the duration very short so
            // other GCD main-queue blocks (new TCP commands) rarely get a
            // chance to interleave, preventing command reentrancy.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            state = app.state
        }
        guard state == .runningForeground else {
            NSLog("[session] ERROR: app failed to enter foreground, state=\(state.rawValue)")
            if state == .unknown, let bundleId, !bundleId.isEmpty {
                throw DriverError.appNotFound(bundleId)
            }
            throw DriverError.appNotFound("app failed to enter foreground (state=\(state.rawValue))")
        }
        NSLog("[session] launch completed, state=\(state.rawValue)")
    }

    private func waitForTermination(_ app: XCUIApplication) throws {
        NSLog("[session] waiting for app to terminate...")
        let deadline = CFAbsoluteTimeGetCurrent() + 5
        var state = app.state
        while state != .notRunning && state != .unknown && CFAbsoluteTimeGetCurrent() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            state = app.state
        }
        guard state == .notRunning || state == .unknown else {
            NSLog("[session] ERROR: app failed to terminate, state=\(state.rawValue)")
            throw DriverError.appNotFound("app failed to terminate (state=\(state.rawValue))")
        }
        NSLog("[session] terminate completed, state=\(state.rawValue)")
    }

    func destroy() {
        NSLog("[session] destroy called")
        _app = nil
        _bundleId = nil
        // doc 4.3 — drop snapshot cache so next session starts fresh.
        invalidateSnapshot()
    }

    func activate() throws {
        guard let app = _app else { return }
        let bundleId = _bundleId
        if app.state == .unknown {
            throw DriverError.appNotFound(bundleId ?? "unknown")
        }
        app.activate()
        try waitForForeground(app, bundleId: bundleId)
        syncBundleId(from: app)
        invalidateSnapshot()
    }

    private func syncBundleId(from app: XCUIApplication) {
        if let bundle = app.value(forKey: "bundleID") as? String, !bundle.isEmpty {
            _bundleId = bundle
        }
    }

    /// Returns the cached foreground app when possible, otherwise performs
    /// WDA-style active-app detection with the current bundleId as a hint.
    /// Time complexity: O(1) on cache hit; O(a) on fallback, where a is the
    /// number of active applications reported by XCTest.
    var activeApp: XCUIApplication? {
        if let app = _app, app.state == .runningForeground {
            syncBundleId(from: app)
            return app
        }
        if let detected = GetActiveApplicationWithDefaultBundleId(_bundleId) {
            _app = detected
            syncBundleId(from: detected)
            return detected
        }
        return nil
    }

    func ensureActive() throws -> XCUIApplication {
        if let app = activeApp {
            return app
        }
        throw DriverError.noSession
    }
}
