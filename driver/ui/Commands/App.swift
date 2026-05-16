import XCTest
import UIKit
import Fory

func foregroundWaitFailureError(state: XCUIApplication.State, bundleId: String?) -> DriverError {
    if state == .unknown, let bundleId, !bundleId.isEmpty {
        return DriverError.appNotFound(bundleId)
    }
    return DriverError.appNotFound("app failed to enter foreground (state=\(state.rawValue))")
}

func terminationWaitFailureError(state: XCUIApplication.State) -> DriverError {
    DriverError.appNotFound("app failed to terminate (state=\(state.rawValue))")
}

func shouldLaunchViaLaunchServices(state: XCUIApplication.State) -> Bool {
    state != .runningForeground
}

enum App {
    static func activateApp(bundleId: String) throws -> XCUIApplication {
        NSLog("[app] activate called with bundleId=\(bundleId)")
        let app = XCUIApplication(bundleIdentifier: bundleId)
        let state = app.state
        NSLog("[app] app state=\(state.rawValue) (0=unknown,1=notRunning,2=suspended,3=background,4=foreground)")

        if shouldLaunchViaLaunchServices(state: state) {
            NSLog("[app] launching app via LaunchServices...")
            guard OpenApplicationWithBundleId(bundleId) else {
                NSLog("[app] ERROR: LaunchServices could not open bundleId=\(bundleId)")
                throw DriverError.appNotFound(bundleId)
            }
            NSLog("[app] openApplicationWithBundleID() returned")
        } else {
            NSLog("[app] app already in foreground, skipping activate")
        }

        try waitForForeground(app, bundleId: bundleId)
        Session.shared.cache(app: app)
        NSLog("[app] activate completed, final state=\(app.state.rawValue)")
        return app
    }

    static func terminateApp(bundleId: String) throws {
        NSLog("[app] terminate called with bundleId=\(bundleId)")
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate()
        try waitForTermination(app)
    }

    private static func waitForForeground(_ app: XCUIApplication, bundleId: String?) throws {
        NSLog("[app] waiting for app to enter foreground...")
        let deadline = CFAbsoluteTimeGetCurrent() + IOSUseProtocol.appForegroundTimeoutSeconds
        var state = app.state
        while state != .runningForeground && CFAbsoluteTimeGetCurrent() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: IOSUseProtocol.appStatePollIntervalSeconds))
            state = app.state
        }
        guard state == .runningForeground else {
            NSLog("[app] ERROR: app failed to enter foreground, state=\(state.rawValue)")
            throw foregroundWaitFailureError(state: state, bundleId: bundleId)
        }
        NSLog("[app] foreground wait completed, state=\(state.rawValue)")
    }

    private static func waitForTermination(_ app: XCUIApplication) throws {
        NSLog("[app] waiting for app to terminate...")
        let deadline = CFAbsoluteTimeGetCurrent() + IOSUseProtocol.appTerminationTimeoutSeconds
        var state = app.state
        while state != .notRunning && state != .unknown && CFAbsoluteTimeGetCurrent() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: IOSUseProtocol.appStatePollIntervalSeconds))
            state = app.state
        }
        guard state == .notRunning || state == .unknown else {
            NSLog("[app] ERROR: app failed to terminate, state=\(state.rawValue)")
            throw terminationWaitFailureError(state: state)
        }
        NSLog("[app] terminate completed, state=\(state.rawValue)")
    }
}

// MARK: - App commands (doc 1.2 — activateApp/terminateApp/openURL)

enum AppCommands {

    /// doc 1.2 — activate (foreground) the app with given bundleId.
    static func activateApp(_ args: ForyActivateAppArgs) throws -> ForyResponseFrame {
        _ = try App.activateApp(bundleId: args.bundleId)
        return Codec.foryOK()
    }

    /// doc 1.2 — terminate the app. Polls for up to 5s because terminate()
    /// is asynchronous.
    static func terminateApp(_ args: ForyTerminateAppArgs) throws -> ForyResponseFrame {
        try App.terminateApp(bundleId: args.bundleId)
        return Codec.foryOK()
    }

    static func home() throws -> ForyResponseFrame {
        XCUIDevice.shared.press(.home)
        return Codec.foryOK()
    }

    static func openURL(_ args: ForyOpenURLArgs) throws -> ForyResponseFrame {
        guard let url = URL(string: args.url) else {
            throw DriverError.invalidArgs("invalid url: \(args.url)")
        }

        guard OpenURLViaLaunchServices(args.url) else {
            throw DriverError.invalidArgs("no app registered for URL scheme: \(url.scheme ?? "unknown")")
        }
        return try Codec.foryOK(ForySimpleStringPayload(value: args.url))
    }
}
