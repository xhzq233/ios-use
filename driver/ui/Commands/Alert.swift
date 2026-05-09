import XCTest

// MARK: - System alert handling

enum AlertCommands {

    /// Dismiss system alert on SpringBoard or current app.
    /// Args: { index?: Int }
    /// - index: 0-based button index to tap. Default: last button.
    static func dismissAlert(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = decodeArgsOptional(rawArgs, as: DismissAlertArgs.self)
        let index = args?.index

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

        return Codec.makeOK(["dismissed": false, "reason": "no alert found"] as [String: Any])
    }

    // MARK: - Private

    /// Resolve which button index to tap.
    /// - Returns: resolved index, or nil if buttonCount == 0
    static func resolveButtonIndex(buttonCount: Int, requestedIndex: Int?) -> Int? {
        guard buttonCount > 0 else { return nil }
        if let idx = requestedIndex, idx >= 0, idx < buttonCount {
            return idx
        }
        return buttonCount - 1 // default: last
    }

    private static func tryDismissAlert(in app: XCUIApplication, index: Int?) -> ResponseFrame? {
        guard let alertElement = findAlertElement(in: app) else { return nil }

        let alertText = collectAlertText(alertElement)

        let buttons = alertElement.descendants(matching: .button).allElementsBoundByIndex
        guard let resolvedIdx = resolveButtonIndex(buttonCount: buttons.count, requestedIndex: index) else {
            return Codec.makeOK(["dismissed": false, "reason": "alert has no buttons", "text": alertText] as [String: Any])
        }

        let targetButton = buttons[resolvedIdx]

        let tappedLabel = targetButton.label
        targetButton.tap()
        let appId = app.value(forKey: "bundleID") as? String ?? "unknown"
        NSLog("[alert] dismissed: tapped '\(tappedLabel)' (index \(index ?? -1)) in \(appId)")

        return Codec.makeOK([
            "dismissed": true,
            "text": alertText,
            "button": tappedLabel,
        ] as [String: Any])
    }

    /// Find alert element (Alert, Sheet) in an app.
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

    /// Collect text from alert (static texts that are NOT inside buttons).
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

struct DismissAlertArgs: Codable {
    let index: Int?
}
