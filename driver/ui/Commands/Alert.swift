import XCTest
import Fory

// MARK: - System alert handling

enum AlertCommands {

    /// Dismiss system alert on SpringBoard or current app.
    static func dismissAlert(_ args: ForyDismissAlertArgs?) throws -> ForyResponseFrame {
        let index = args.map { Int($0.index) } ?? Int(IOSUseProtocol.XCConstants.defaultAlertButtonIndex)
        return try dismissAlert(index: index, label: nil)
    }

    static func dismissAlertByLabel(
        _ args: ForyDismissAlertByLabelArgs
    ) throws -> ForyResponseFrame {
        guard !args.label.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return try Codec.foryError(
                "dismissAlert label must not be empty",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation
            )
        }
        return try dismissAlert(index: -1, label: args.label)
    }

    private static func dismissAlert(
        index: Int,
        label: String?
    ) throws -> ForyResponseFrame {
        // 1. Check SpringBoard for system alerts
        let springboard = XCUIApplication(bundleIdentifier: IOSUseProtocol.springboardBundleId)
        if let result = tryDismissAlert(in: springboard, index: index, label: label) {
            return result
        }

        // 2. Check current foreground app
        if let app = try? Session.shared.ensureActive() {
            if let result = tryDismissAlert(in: app, index: index, label: label) {
                return result
            }
        }

        if let label {
            return try Codec.foryError(
                "no visible alert contains the exact button label '\(label)'",
                category: IOSUseErrorCategory.lookup,
                code: IOSUseErrorCode.elementNotFound,
                phase: IOSUseErrorPhase.lookup,
                retryable: true,
                target: ForyTarget(label: label, traits: "Button")
            )
        }
        let payload = ForyAlertPayload(dismissed: false, text: "", button: "", reason: "no alert found")
        return try Codec.foryOK(payload)
    }

    // MARK: - Private

    static func resolveButtonIndex(buttonCount: Int, requestedIndex: Int?) -> Int? {
        guard buttonCount > 0 else { return nil }
        if let idx = requestedIndex, idx >= 0, idx < buttonCount {
            return idx
        }
        return buttonCount - 1
    }

    static func resolveButtonLabelIndex(
        buttonLabels: [String],
        requestedLabel: String
    ) -> Int? {
        let matches = buttonLabels.indices.filter {
            buttonLabels[$0] == requestedLabel
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func tryDismissAlert(
        in app: XCUIApplication,
        index: Int,
        label: String?
    ) -> ForyResponseFrame? {
        guard let alertElement = findAlertElement(in: app) else { return nil }

        let alertText = collectAlertText(alertElement)

        let buttons = alertElement.descendants(matching: .button).allElementsBoundByIndex
        let resolvedIdx: Int?
        if let label {
            resolvedIdx = resolveButtonLabelIndex(
                buttonLabels: buttons.map(\.label),
                requestedLabel: label
            )
        } else {
            resolvedIdx = resolveButtonIndex(
                buttonCount: buttons.count,
                requestedIndex: index >= 0 ? index : nil
            )
        }
        guard let resolvedIdx else {
            if let label {
                let matches = buttons.filter { $0.label == label }.count
                return try? Codec.foryError(
                    matches == 0
                        ? "alert has no button with the exact label '\(label)'"
                        : "alert has multiple buttons with the exact label '\(label)'",
                    category: IOSUseErrorCategory.lookup,
                    code: matches == 0
                        ? IOSUseErrorCode.elementNotFound
                        : IOSUseErrorCode.elementAmbiguous,
                    phase: IOSUseErrorPhase.lookup,
                    retryable: true,
                    target: ForyTarget(label: label, traits: "Button"),
                    candidateCount: matches
                )
            }
            let payload = ForyAlertPayload(
                dismissed: false,
                text: alertText,
                button: "",
                reason: "alert has no buttons"
            )
            return try? Codec.foryOK(payload)
        }

        let targetButton = buttons[resolvedIdx]
        if let label,
           (!targetButton.exists ||
            !targetButton.isEnabled ||
            !targetButton.isHittable) {
            return try? Codec.foryError(
                "alert button with the exact label '\(label)' is not actionable",
                category: IOSUseErrorCategory.action,
                code: IOSUseErrorCode.elementNotActionable,
                phase: IOSUseErrorPhase.interaction,
                retryable: true,
                target: ForyTarget(label: label, traits: "Button"),
                candidateCount: 1
            )
        }

        let tappedLabel = targetButton.label
        targetButton.tap()
        if let label,
           !alertElement.waitForNonExistence(timeout: 1.0) {
            return try? Codec.foryError(
                "alert remained visible after tapping the exact button label '\(label)'",
                category: IOSUseErrorCategory.postcondition,
                code: IOSUseErrorCode.postconditionFailed,
                phase: IOSUseErrorPhase.postcondition,
                retryable: true,
                target: ForyTarget(label: label, traits: "Button"),
                candidateCount: 1
            )
        }
        let appId = app.value(forKey: "bundleID") as? String ?? "unknown"
        let selection = label == nil ? "index \(index)" : "exact label"
        DriverLog.info("[alert] dismissed: tapped '\(tappedLabel)' (\(selection)) in \(appId)")

        let payload = ForyAlertPayload(dismissed: true, text: alertText, button: tappedLabel, reason: "")
        return try? Codec.foryOK(payload)
    }

    private static func findAlertElement(in app: XCUIApplication) -> XCUIElement? {
        let alerts = app.alerts
        if alerts.count > 0 {
            return alerts.firstMatch
        }

        let sheets = app.sheets
        if sheets.count > 0 {
            return sheets.firstMatch
        }

        return nil
    }

    private static func collectAlertText(_ alert: XCUIElement) -> String {
        let allTexts = alert.descendants(matching: .staticText).allElementsBoundByIndex
        let buttonLabels = Set(alert.descendants(matching: .button).allElementsBoundByIndex.map { $0.label })
        var result: [String] = []
        for text in allTexts {
            let label = text.label
            if !label.isEmpty && !buttonLabels.contains(label) {
                result.append(label)
            }
        }
        return result.joined(separator: "\n")
    }
}
