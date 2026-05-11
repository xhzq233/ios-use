import XCTest
import UIKit
import Fory

// MARK: - App commands (doc 1.2 — createSession/deleteSession/activateApp/terminateApp)

enum AppCommands {

    /// doc 1.2 — bundleId is optional. Omitted → device session (no app bound).
    static func createSession(_ args: ForyCreateSessionArgs?) throws -> ForyResponseFrame {
        let bundleId = (args?.bundleId.isEmpty ?? true) ? nil : args?.bundleId
        let terminate = args?.terminate ?? false
        try Session.shared.create(bundleId: bundleId, terminate: terminate)
        return try Codec.foryOK(ForySimpleStringPayload(value: bundleId ?? ""))
    }

    /// doc 1.2 — destroy session. No args.
    static func deleteSession() -> ForyResponseFrame {
        Session.shared.destroy()
        return Codec.foryOK()
    }

    /// doc 1.2 — activate (foreground) the app with given bundleId.
    static func activateApp(_ args: ForyActivateAppArgs) throws -> ForyResponseFrame {
        if Session.shared.bundleId == args.bundleId {
            try Session.shared.activate()
        } else {
            try Session.shared.create(bundleId: args.bundleId)
        }
        return Codec.foryOK()
    }

    /// doc 1.2 — terminate the app. Polls for up to 5s because terminate()
    /// is asynchronous.
    static func terminateApp(_ args: ForyTerminateAppArgs) throws -> ForyResponseFrame {
        let app = XCUIApplication(bundleIdentifier: args.bundleId)
        app.terminate()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let state = app.state
            if state == .notRunning || state == .unknown {
                if Session.shared.bundleId == args.bundleId {
                    Session.shared.destroy()
                }
                invalidateSnapshot()
                return Codec.foryOK()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return Codec.foryError("terminate failed: app state is \(app.state)")
    }

    static func openURL(_ args: ForyOpenURLArgs) throws -> ForyResponseFrame {
        guard let url = URL(string: args.url) else {
            throw DriverError.invalidArgs("invalid url: \(args.url)")
        }

        XCUIDevice.shared.system.open(url)
        return try Codec.foryOK(ForySimpleStringPayload(value: args.url))
    }
}
