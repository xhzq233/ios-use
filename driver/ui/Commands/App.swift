import XCTest

// MARK: - App commands (doc 1.2 — createSession/deleteSession/activateApp/terminateApp)

enum AppCommands {

    /// doc 1.2 — bundleId is optional. Omitted → device session (no app bound).
    static func createSession(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = decodeArgsOptional(rawArgs, as: CreateSessionArgs.self)
        let bundleId = args?.bundleId
        try Session.shared.create(bundleId: bundleId)
        return Codec.makeOK(["bundleId": bundleId ?? ""])
    }

    /// doc 1.2 — destroy session. No args.
    static func deleteSession(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        Session.shared.destroy()
        return Codec.makeOK()
    }

    /// doc 1.2 — activate (foreground) the app with given bundleId.
    static func activateApp(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: ActivateAppArgs.self)
        if Session.shared.bundleId == args.bundleId {
            try Session.shared.activate()
        } else {
            try Session.shared.create(bundleId: args.bundleId)
        }
        return Codec.makeOK()
    }

    /// doc 1.2 — terminate the app. Polls for up to 5s because terminate()
    /// is asynchronous.
    static func terminateApp(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: TerminateAppArgs.self)
        let app = XCUIApplication(bundleIdentifier: args.bundleId)
        app.terminate()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let state = app.state
            if state == .notRunning || state == .unknown {
                invalidateSnapshot()
                return Codec.makeOK()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return Codec.makeError("terminate failed: app state is \(app.state)")
    }
}
