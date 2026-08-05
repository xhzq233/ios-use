import Fory
import UIKit
import XCTest

// MARK: - System alert handling

enum AlertCommands {
    private struct LiveAlertInspection {
        let app: XCUIApplication
        let snapshot: AlertSnapshot
        let buttons: [XCUIElement]
    }

    private struct AlertActionFailure: Error {
        let message: String
        let code: String
        let category: String
        let phase: String
        let retryable: Bool
        let snapshot: AlertSnapshot
        let selection: AlertButtonSelection
    }

    /// Dismiss a guarded SpringBoard or foreground-App alert.
    static func dismissAlert(_ args: ForyDismissAlertArgs) throws -> ForyResponseFrame {
        precondition(Thread.isMainThread)

        guard args.wait.isFinite,
              args.wait >= 0,
              args.wait <= IOSUseProtocol.alertWaitMaximumTimeoutSeconds else {
            return try Codec.foryError(
                "dismissAlert: --wait must be between 0 and \(formatSeconds(IOSUseProtocol.alertWaitMaximumTimeoutSeconds))s",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation
            )
        }
        guard let scope = IOSUseAlertScope(rawValue: args.scope) else {
            return try Codec.foryError(
                "dismissAlert: unsupported scope \(args.scope)",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation
            )
        }
        let selection: AlertButtonSelection
        switch IOSUseAlertSelectionMode(rawValue: args.selection) {
        case .onlyButton:
            selection = .onlyButton
        case .index:
            guard args.index >= 0 else {
                return try Codec.foryError(
                    "dismissAlert: --index must be non-negative",
                    category: IOSUseErrorCategory.validation,
                    code: IOSUseErrorCode.invalidArguments,
                    phase: IOSUseErrorPhase.validation
                )
            }
            selection = .index(Int(args.index))
        case .label:
            guard !AlertSelectionEngine.normalizeText(args.label).isEmpty else {
                return try Codec.foryError(
                    "dismissAlert: --label must not be empty",
                    category: IOSUseErrorCategory.validation,
                    code: IOSUseErrorCode.invalidArguments,
                    phase: IOSUseErrorPhase.validation
                )
            }
            selection = .label(args.label)
        case .visualPrimary:
            selection = .visualPrimary
        case nil:
            return try Codec.foryError(
                "dismissAlert: unsupported selection \(args.selection)",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation
            )
        }

        let deadline = Date().addingTimeInterval(args.wait)
        while true {
            if let live = inspect(scope: scope) {
                switch selectRevalidateAndTap(live, selection: selection) {
                case .success(let payload):
                    return try Codec.foryOK(payload)
                case .failure(let failure):
                    return try failureResponse(failure)
                }
            }

            guard args.wait > 0 else {
                return try missingAlertResponse(
                    code: IOSUseErrorCode.alertNotFound,
                    message: "no alert found",
                    retryable: true
                )
            }
            guard Date() < deadline else {
                return try missingAlertResponse(
                    code: IOSUseErrorCode.alertWaitTimedOut,
                    message: "no alert appeared within \(formatSeconds(args.wait))s",
                    retryable: true
                )
            }
            _ = RunLoop.current.run(
                mode: .default,
                before: min(
                    deadline,
                    Date().addingTimeInterval(IOSUseProtocol.alertPollIntervalSeconds)
                )
            )
        }
    }

    /// Compatibility for PlayCover generations that still send the dedicated
    /// exact-label command while the public CLI uses the unified alert request.
    static func dismissAlertByLabel(
        _ args: ForyDismissAlertByLabelArgs
    ) throws -> ForyResponseFrame {
        try dismissAlert(ForyDismissAlertArgs(
            selection: IOSUseAlertSelectionMode.label.rawValue,
            label: args.label,
            scope: IOSUseAlertScope.any.rawValue
        ))
    }

    static func handleTriggeredPhotosAddPermissionPrompt(
        deadline: Date,
        canTrigger: @escaping () -> Bool,
        trigger: @escaping () -> Void,
        shouldStop: @escaping () -> Bool,
        completion: @escaping (PhotosPermissionPromptOutcome) -> Void
    ) {
        precondition(Thread.isMainThread)
        let springboard = XCUIApplication(bundleIdentifier: IOSUseProtocol.springboardBundleId)

        guard canTrigger() else {
            completion(.notHandled)
            return
        }
        if let preexisting = inspectAlert(in: springboard, surface: .springboard) {
            completion(.interactionRequired(
                code: IOSUseErrorCode.preexistingAlert,
                diagnostic: "a pre-existing SpringBoard \(preexisting.snapshot.kind.rawValue) blocked the Photos request",
                alert: makePayload(
                    snapshot: preexisting.snapshot,
                    selection: .visualPrimary,
                    resolution: nil,
                    dismissed: false,
                    reason: "pre-existing alert"
                )
            ))
            return
        }

        trigger()

        func poll() {
            if shouldStop() {
                completion(.notHandled)
                return
            }

            if let live = inspectAlert(in: springboard, surface: .springboard) {
                let names = runnerIdentityCandidates()
                guard !names.isEmpty,
                      names.contains(where: {
                          AlertSelectionEngine.containsIdentity($0, in: live.snapshot.text)
                      }) else {
                    completion(.interactionRequired(
                        code: IOSUseErrorCode.photosPermissionInteractionRequired,
                        diagnostic: "the newly observed alert did not identify the ios-use Runner",
                        alert: makePayload(
                            snapshot: live.snapshot,
                            selection: .visualPrimary,
                            resolution: nil,
                            dismissed: false,
                            reason: "Runner identity mismatch"
                        )
                    ))
                    return
                }

                let hittableCount = live.snapshot.buttons.filter(\.isHittable).count
                guard live.snapshot.buttons.count == 2, hittableCount == 2 else {
                    completion(.interactionRequired(
                        code: IOSUseErrorCode.photosPermissionInteractionRequired,
                        diagnostic: "the Runner permission alert had \(live.snapshot.buttons.count) buttons, \(hittableCount) hittable; expected exactly two",
                        alert: makePayload(
                            snapshot: live.snapshot,
                            selection: .visualPrimary,
                            resolution: nil,
                            dismissed: false,
                            reason: "unexpected permission alert shape"
                        )
                    ))
                    return
                }

                switch selectRevalidateAndTap(live, selection: .visualPrimary) {
                case .success(let payload):
                    completion(.handled(text: payload.text, button: payload.button))
                case .failure(let failure):
                    completion(.interactionRequired(
                        code: failure.code,
                        diagnostic: failure.message,
                        alert: makePayload(
                            snapshot: failure.snapshot,
                            selection: failure.selection,
                            resolution: nil,
                            dismissed: false,
                            reason: failure.message
                        )
                    ))
                }
                return
            }

            guard Date() < deadline else {
                completion(.interactionRequired(
                    code: IOSUseErrorCode.alertWaitTimedOut,
                    diagnostic: "the Runner Photos permission alert did not appear before the deadline",
                    alert: nil
                ))
                return
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + IOSUseProtocol.alertPollIntervalSeconds,
                execute: poll
            )
        }

        poll()
    }

    private static func selectRevalidateAndTap(
        _ live: LiveAlertInspection,
        selection: AlertButtonSelection
    ) -> Result<ForyAlertPayload, AlertActionFailure> {
        let direction = effectiveLayoutDirection()
        let resolution: AlertSelectionResolution
        switch AlertSelectionEngine.select(
            selection,
            in: live.snapshot,
            layoutDirection: direction
        ) {
        case .success(let selected):
            resolution = selected
        case .failure(let error):
            let code: String
            switch error {
            case .duplicateLabel, .multipleHittableButtons,
                 .unsupportedVisualCandidateCount, .ambiguousVisualLayout:
                code = IOSUseErrorCode.alertAmbiguous
            default:
                code = IOSUseErrorCode.alertSelectionInvalid
            }
            return .failure(AlertActionFailure(
                message: error.diagnostic,
                code: code,
                category: IOSUseErrorCategory.lookup,
                phase: IOSUseErrorPhase.lookup,
                retryable: false,
                snapshot: live.snapshot,
                selection: selection
            ))
        }

        guard let verified = inspectAlert(
            in: live.app,
            surface: live.snapshot.surface
        ),
        AlertSelectionEngine.sameGeneration(live.snapshot, verified.snapshot) else {
            return .failure(AlertActionFailure(
                message: "alert changed before the selected button could be tapped",
                code: IOSUseErrorCode.alertChangedBeforeAction,
                category: IOSUseErrorCategory.lookup,
                phase: IOSUseErrorPhase.interaction,
                retryable: true,
                snapshot: live.snapshot,
                selection: selection
            ))
        }
        guard let target = verified.buttons.enumerated().first(where: {
            $0.offset == resolution.queryIndex
        })?.element,
        target.isHittable else {
            return .failure(AlertActionFailure(
                message: "selected alert button is no longer hittable",
                code: IOSUseErrorCode.alertChangedBeforeAction,
                category: IOSUseErrorCategory.lookup,
                phase: IOSUseErrorPhase.interaction,
                retryable: true,
                snapshot: verified.snapshot,
                selection: selection
            ))
        }

        let label = clipped(target.label, limit: IOSUseProtocol.alertButtonTextLimit)
        target.tap()
        let payload = makePayload(
            snapshot: verified.snapshot,
            selection: selection,
            resolution: resolution,
            dismissed: true,
            button: label
        )
        DriverLog.info(
            "[alert] dismissed surface=\(payload.surface) kind=\(payload.kind) selection=\(payload.selectionStrategy) index=\(payload.selectedIndex)"
        )
        return .success(payload)
    }

    private static func inspect(scope: IOSUseAlertScope) -> LiveAlertInspection? {
        switch scope {
        case .springboard:
            let app = XCUIApplication(bundleIdentifier: IOSUseProtocol.springboardBundleId)
            return inspectAlert(in: app, surface: .springboard)
        case .activeApp:
            guard let app = try? Session.shared.ensureActive() else { return nil }
            return inspectAlert(in: app, surface: .activeApp)
        case .any:
            let springboard = XCUIApplication(bundleIdentifier: IOSUseProtocol.springboardBundleId)
            if let alert = inspectAlert(in: springboard, surface: .springboard) {
                return alert
            }
            guard let app = try? Session.shared.ensureActive() else { return nil }
            return inspectAlert(in: app, surface: .activeApp)
        }
    }

    private static func inspectAlert(
        in app: XCUIApplication,
        surface: AlertSurface
    ) -> LiveAlertInspection? {
        let alertElement: XCUIElement
        let kind: AlertKind
        if app.alerts.count > 0 {
            alertElement = app.alerts.firstMatch
            kind = .alert
        } else if app.sheets.count > 0 {
            alertElement = app.sheets.firstMatch
            kind = .sheet
        } else {
            return nil
        }

        let buttons = alertElement.descendants(matching: .button).allElementsBoundByIndex
        let snapshots = buttons.enumerated().map { index, button in
            AlertButtonSnapshot(
                queryIndex: index,
                label: clipped(button.label, limit: IOSUseProtocol.alertButtonTextLimit),
                identifier: clipped(button.identifier, limit: IOSUseProtocol.alertButtonTextLimit),
                isHittable: button.isHittable,
                frame: button.frame
            )
        }
        let snapshot = AlertSnapshot(
            surface: surface,
            kind: kind,
            text: collectAlertText(alertElement, buttonLabels: Set(snapshots.map(\.label))),
            frame: alertElement.frame,
            buttons: snapshots
        )
        return LiveAlertInspection(app: app, snapshot: snapshot, buttons: buttons)
    }

    private static func collectAlertText(
        _ alert: XCUIElement,
        buttonLabels: Set<String>
    ) -> String {
        var result: [String] = []
        let alertLabel = alert.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alertLabel.isEmpty, !buttonLabels.contains(alertLabel) {
            result.append(alertLabel)
        }
        for text in alert.descendants(matching: .staticText).allElementsBoundByIndex {
            let label = text.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty,
               !buttonLabels.contains(label),
               !result.contains(label) {
                result.append(label)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func failureResponse(
        _ failure: AlertActionFailure
    ) throws -> ForyResponseFrame {
        let alert = makePayload(
            snapshot: failure.snapshot,
            selection: failure.selection,
            resolution: nil,
            dismissed: false,
            reason: failure.message
        )
        return try Codec.foryError(
            failure.message,
            category: failure.category,
            code: failure.code,
            phase: failure.phase,
            retryable: failure.retryable,
            alert: alert
        )
    }

    private static func missingAlertResponse(
        code: String,
        message: String,
        retryable: Bool
    ) throws -> ForyResponseFrame {
        try Codec.foryError(
            message,
            category: code == IOSUseErrorCode.alertWaitTimedOut
                ? IOSUseErrorCategory.timeout
                : IOSUseErrorCategory.lookup,
            code: code,
            phase: code == IOSUseErrorCode.alertWaitTimedOut
                ? IOSUseErrorPhase.wait
                : IOSUseErrorPhase.lookup,
            retryable: retryable
        )
    }

    static func makePayload(
        snapshot: AlertSnapshot,
        selection: AlertButtonSelection,
        resolution: AlertSelectionResolution?,
        dismissed: Bool,
        button: String = "",
        reason: String = ""
    ) -> ForyAlertPayload {
        ForyAlertPayload(
            dismissed: dismissed,
            surface: snapshot.surface.rawValue,
            kind: snapshot.kind.rawValue,
            text: clipped(snapshot.text, limit: IOSUseProtocol.alertTextLimit),
            buttonCount: Int32(clamping: snapshot.buttons.count),
            buttons: snapshot.buttons.prefix(IOSUseProtocol.errorCandidateLimit).map {
                ForyAlertButton(
                    queryIndex: Int32(clamping: $0.queryIndex),
                    label: clipped($0.label, limit: IOSUseProtocol.alertButtonTextLimit),
                    identifier: clipped($0.identifier, limit: IOSUseProtocol.alertButtonTextLimit),
                    hittable: $0.isHittable,
                    frame: makeForyRect($0.frame)
                )
            },
            requestedSelection: selection.requestedStrategy,
            selectionStrategy: resolution?.strategy ?? "",
            selectedIndex: Int32(clamping: resolution?.queryIndex ?? -1),
            button: clipped(button, limit: IOSUseProtocol.alertButtonTextLimit),
            layoutDirection: resolution?.layoutDirection?.rawValue ?? "",
            layoutDirectionSource: resolution?.layoutDirectionSource?.rawValue ?? "",
            reason: clipped(reason, limit: IOSUseProtocol.alertTextLimit)
        )
    }

    private static func effectiveLayoutDirection() -> AlertLayoutDirection {
        UIView.userInterfaceLayoutDirection(for: .unspecified) == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    private static func runnerIdentityCandidates() -> [String] {
        var names: Set<String> = [ProcessInfo.processInfo.processName]

        func appendNames(from bundle: Bundle?) {
            guard let bundle else { return }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String,
                   !AlertSelectionEngine.normalizeText(value).isEmpty {
                    names.insert(value)
                }
            }
        }

        appendNames(from: Bundle.main)
        let mainURL = Bundle.main.bundleURL
        if mainURL.pathExtension == "xctest" {
            let appURL = mainURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if appURL.pathExtension == "app" {
                appendNames(from: Bundle(url: appURL))
            }
        } else if mainURL.pathExtension == "app" {
            appendNames(from: Bundle(url: mainURL))
        }

        return names
            .filter { AlertSelectionEngine.normalizeText($0).count >= 3 }
            .sorted { $0.count > $1.count }
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
