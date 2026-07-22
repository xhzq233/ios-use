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
        let app = try requestActivation(bundleId: bundleId)
        try waitForForeground(app, bundleId: bundleId)
        Session.shared.cache(app: app)
        DriverLog.info("[app] activate completed, final state=\(app.state.rawValue)")
        return app
    }

    static func requestActivation(bundleId: String) throws -> XCUIApplication {
        DriverLog.info("[app] activate called with bundleId=\(bundleId)")
        let app = XCUIApplication(bundleIdentifier: bundleId)
        let state = app.state
        DriverLog.info("[app] app state=\(state.rawValue) (0=unknown,1=notRunning,2=suspended,3=background,4=foreground)")

        if shouldLaunchViaLaunchServices(state: state) {
            DriverLog.info("[app] launching app via LaunchServices...")
            guard OpenApplicationWithBundleId(bundleId) else {
                DriverLog.error("[app] ERROR: LaunchServices could not open bundleId=\(bundleId)")
                throw DriverError.appNotFound(bundleId)
            }
            DriverLog.info("[app] openApplicationWithBundleID() returned")
        } else {
            DriverLog.info("[app] app already in foreground, skipping activate")
        }

        return app
    }

    static func terminateApp(bundleId: String) throws {
        DriverLog.info("[app] terminate called with bundleId=\(bundleId)")
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate()
        try waitForTermination(app)
    }

    static func waitForForeground(_ app: XCUIApplication, bundleId: String?) throws {
        DriverLog.info("[app] waiting for app to enter foreground...")
        let deadline = CFAbsoluteTimeGetCurrent() + IOSUseProtocol.appForegroundTimeoutSeconds
        var state = app.state
        while state != .runningForeground && CFAbsoluteTimeGetCurrent() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: IOSUseProtocol.appStatePollIntervalSeconds))
            state = app.state
        }
        guard state == .runningForeground else {
            DriverLog.error("[app] ERROR: app failed to enter foreground, state=\(state.rawValue)")
            throw foregroundWaitFailureError(state: state, bundleId: bundleId)
        }
        DriverLog.info("[app] foreground wait completed, state=\(state.rawValue)")
    }

    private static func waitForTermination(_ app: XCUIApplication) throws {
        DriverLog.info("[app] waiting for app to terminate...")
        let deadline = CFAbsoluteTimeGetCurrent() + IOSUseProtocol.appTerminationTimeoutSeconds
        var state = app.state
        while state != .notRunning && state != .unknown && CFAbsoluteTimeGetCurrent() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: IOSUseProtocol.appStatePollIntervalSeconds))
            state = app.state
        }
        guard state == .notRunning || state == .unknown else {
            DriverLog.error("[app] ERROR: app failed to terminate, state=\(state.rawValue)")
            throw terminationWaitFailureError(state: state)
        }
        DriverLog.info("[app] terminate completed, state=\(state.rawValue)")
    }
}

// MARK: - App commands (doc 1.2 — activateApp/terminateApp)

enum AppCommands {

    /// doc 1.2 — activate (foreground) the app with given bundleId.
    static func activateApp(_ args: ForyActivateAppArgs) throws -> ForyResponseFrame {
        _ = try App.requestActivation(bundleId: args.bundleId)
        let readiness = try waitAppForeground(ForyWaitAppForegroundArgs(expectedBundleId: args.bundleId))
        guard readiness.ok else { return readiness }
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

    /// Wait for the requested app (or any foreground UI when empty) and one
    /// fresh cleaned snapshot. Snapshot success is point-in-time readiness, not
    /// a stability or business-screen assertion.
    static func waitAppForeground(_ args: ForyWaitAppForegroundArgs) throws -> ForyResponseFrame {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard args.timeout.isFinite, args.timeout >= 0 else {
            return try Codec.foryError(
                "waitAppForeground: timeout must be finite and non-negative",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation
            )
        }
        let timeout = IOSUseProtocol.resolvedAppForegroundTimeoutSeconds(args.timeout)
        guard timeout <= IOSUseProtocol.waitForMaximumTimeoutSeconds else {
            return try Codec.foryError(
                "waitAppForeground: timeout must be at most \(IOSUseProtocol.waitForMaximumTimeoutSeconds)s",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation
            )
        }
        let deadline = startedAt + timeout
        let expected = args.expectedBundleId
        let accepted = expected.isEmpty
            ? Array(Set(args.acceptedBundleIds.filter { !$0.isEmpty })).sorted()
            : [expected]
        let reportedExpected = accepted.count == 1 ? accepted[0] : expected
        let expectedDescription = accepted.isEmpty ? "(any)" : accepted.joined(separator: ",")
        let requestedApp = accepted.count == 1 ? XCUIApplication(bundleIdentifier: accepted[0]) : nil
        var foregroundObserved = false
        var lastBundleId = ""
        var lastState = IOSUseAppState.unknown
        var lastSnapshotFailure = "snapshot unavailable"

        DriverLog.info("[app] waitAppForeground expected=\(expectedDescription) timeout=\(formatSeconds(timeout))s returnDom=\(args.returnDom)")

        while CFAbsoluteTimeGetCurrent() <= deadline {
            if let requestedApp {
                let nativeState = requestedApp.state
                lastState = appState(nativeState)
                lastBundleId = accepted[0]
                if nativeState == .runningForeground {
                    foregroundObserved = true
                    Session.shared.cache(app: requestedApp)
                    break
                }
                if let active = try? Session.shared.refreshActive() {
                    lastBundleId = bundleIdentifier(active)
                }
            } else if let active = try? Session.shared.refreshActive() {
                lastBundleId = bundleIdentifier(active)
                lastState = appState(active.state)
                if active.state == .runningForeground,
                   accepted.isEmpty || accepted.contains(lastBundleId) {
                    foregroundObserved = true
                    break
                }
            }
            runLoopPoll()
        }

        guard foregroundObserved else {
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            return try Codec.foryError(
                "waitAppForeground timed out: expected=\(expectedDescription) lastBundle=\(lastBundleId.isEmpty ? "(none)" : lastBundleId) lastState=\(lastState) elapsed=\(formatSeconds(elapsed))s",
                category: IOSUseErrorCategory.timeout,
                code: IOSUseErrorCode.appForegroundTimedOut,
                phase: IOSUseErrorPhase.wait,
                retryable: true
            )
        }

        while CFAbsoluteTimeGetCurrent() <= deadline {
            do {
                let active = try Session.shared.refreshActive()
                lastBundleId = bundleIdentifier(active)
                lastState = appState(active.state)
                guard snapshotBundleAccepted(
                    lastBundleId,
                    acceptedBundleIds: accepted
                ) else {
                    lastSnapshotFailure = "foreground snapshot app \(lastBundleId.isEmpty ? "(none)" : lastBundleId) is not accepted"
                    runLoopPoll()
                    continue
                }
                invalidateSnapshot()
                if let cs = getCleanedSnapshot() {
                    let dom: ForyDomPayload?
                    if args.returnDom {
                        dom = ForyDomPayload(
                            app: lastBundleId,
                            windowSize: ForyPoint(
                                x: Double(Int(cs.appFrame.size.width.rounded())),
                                y: Double(Int(cs.appFrame.size.height.rounded()))
                            ),
                            raw: "",
                            elements: serializeDomFlat(from: cs.elements)
                        )
                    } else {
                        dom = nil
                    }
                    let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                    let payload = ForyWaitAppForegroundPayload(
                        expectedBundleId: reportedExpected,
                        activeBundleId: lastBundleId,
                        appState: lastState.rawValue,
                        snapshotReady: true,
                        elapsed: elapsed.sanitized,
                        dom: dom
                    )
                    return try Codec.foryOK(payload)
                }
                lastSnapshotFailure = "cleaned snapshot unavailable"
            } catch {
                lastSnapshotFailure = String(describing: error)
            }
            runLoopPoll()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        return try Codec.foryError(
            "waitAppForeground snapshot timed out: expected=\(expectedDescription) lastBundle=\(lastBundleId.isEmpty ? "(none)" : lastBundleId) lastState=\(lastState) elapsed=\(formatSeconds(elapsed))s lastSnapshotFailure=\(lastSnapshotFailure)",
            category: IOSUseErrorCategory.timeout,
            code: IOSUseErrorCode.appSnapshotTimedOut,
            phase: IOSUseErrorPhase.snapshot,
            retryable: true
        )
    }

    private static func appState(_ state: XCUIApplication.State) -> IOSUseAppState {
        switch state {
        case .notRunning: return .notRunning
        case .runningBackground: return .background
        case .runningForeground: return .foreground
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    private static func bundleIdentifier(_ app: XCUIApplication) -> String {
        app.value(forKey: "bundleID") as? String ?? ""
    }

    static func snapshotBundleAccepted(_ bundleId: String, acceptedBundleIds: [String]) -> Bool {
        let accepted = acceptedBundleIds.filter { !$0.isEmpty }
        return accepted.isEmpty || accepted.contains(bundleId)
    }

    private static func runLoopPoll() {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: IOSUseProtocol.appStatePollIntervalSeconds)
        )
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

}
