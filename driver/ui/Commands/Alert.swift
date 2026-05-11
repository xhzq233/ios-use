import XCTest
import Fory

// MARK: - System alert handling

enum AlertCommands {

    /// Dismiss system alert on SpringBoard or current app.
    static func dismissAlert(_ args: ForyDismissAlertArgs?) throws -> ForyResponseFrame {
        let index = args.map { Int($0.index) } ?? -1

        // 1. Check SpringBoard for system alerts
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if let result = tryDismissAlert(in: springboard, index: index) {
            return result
        }

        // 2. Check current foreground app
        if let app = Session.shared.activeApp {
            if let result = tryDismissAlert(in: app, index: index) {
                return result
            }
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

    private static func tryDismissAlert(in app: XCUIApplication, index: Int) -> ForyResponseFrame? {
        guard let alertElement = findAlertElement(in: app) else { return nil }

        let alertText = collectAlertText(alertElement)

        let buttons = alertElement.descendants(matching: .button).allElementsBoundByIndex
        guard let resolvedIdx = resolveButtonIndex(buttonCount: buttons.count, requestedIndex: index >= 0 ? index : nil) else {
            let payload = ForyAlertPayload(dismissed: false, text: alertText, button: "", reason: "alert has no buttons")
            return try? Codec.foryOK(payload)
        }

        let targetButton = buttons[resolvedIdx]

        let tappedLabel = targetButton.label
        targetButton.tap()
        let appId = app.value(forKey: "bundleID") as? String ?? "unknown"
        NSLog("[alert] dismissed: tapped '\(tappedLabel)' (index \(index)) in \(appId)")

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
