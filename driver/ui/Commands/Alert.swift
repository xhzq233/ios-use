import XCTest
import Fory

// MARK: - System alert handling

enum AlertCommands {

    /// Dismiss system alert on SpringBoard or current app.
    static func dismissAlert(_ args: ForyDismissAlertArgs?) throws -> ForyResponseFrame {
        let index = args.map { Int($0.index) } ?? Int(IOSUseProtocol.XCConstants.defaultAlertButtonIndex)

        // 1. Check SpringBoard for system alerts
        let springboard = XCUIApplication(bundleIdentifier: IOSUseProtocol.springboardBundleId)
        if let result = tryDismissAlert(in: springboard, index: index) {
            return result
        }

        // 2. Check current foreground app
        if let app = try? Session.shared.ensureActive() {
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

    static func handlePhotosAddPermissionPrompt(
        deadline: Date,
        shouldStop: @escaping () -> Bool,
        completion: @escaping (PhotosPermissionPromptOutcome) -> Void
    ) {
        precondition(Thread.isMainThread)
        let springboard = XCUIApplication(bundleIdentifier: IOSUseProtocol.springboardBundleId)
        var lastDiagnostic = "no system alert became visible"

        func poll() {
            if shouldStop() {
                completion(.notHandled)
                return
            }

            if let alert = inspectAlert(in: springboard) {
                switch classifyPhotosPermissionAlert(alert) {
                case .safe(let button):
                    let label = button.label
                    button.tap()
                    DriverLog.info("[alert] accepted Runner Photos add-only prompt with '\(label)'")
                    completion(.handled(text: alert.text, button: label))
                    return
                case .ownedButUnsafe(let diagnostic):
                    completion(.interactionRequired(diagnostic))
                    return
                case .unrelated(let diagnostic):
                    lastDiagnostic = diagnostic
                }
            }

            guard Date() < deadline else {
                completion(.interactionRequired(lastDiagnostic))
                return
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + IOSUseProtocol.mediaPermissionPromptPollIntervalSeconds,
                execute: poll
            )
        }

        poll()
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
        DriverLog.info("[alert] dismissed: tapped '\(tappedLabel)' (index \(index)) in \(appId)")

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

    private struct AlertInspection {
        let text: String
        let buttons: [XCUIElement]
    }

    private enum PhotosAlertClassification {
        case safe(XCUIElement)
        case ownedButUnsafe(String)
        case unrelated(String)
    }

    private static func inspectAlert(in app: XCUIApplication) -> AlertInspection? {
        guard let alert = findAlertElement(in: app) else { return nil }
        return AlertInspection(
            text: collectAlertText(alert),
            buttons: alert.descendants(matching: .button).allElementsBoundByIndex
        )
    }

    private static func classifyPhotosPermissionAlert(_ alert: AlertInspection) -> PhotosAlertClassification {
        let normalizedText = alert.text.lowercased()
        let identifiesRunner = normalizedText.contains("iosusedriver")
            || normalizedText.contains("ios-use")
        let identifiesPhotos = normalizedText.contains("photo")
            || normalizedText.contains("照片")
            || normalizedText.contains("相片")
        let buttonSummary = alert.buttons.map {
            let identifier = $0.identifier.isEmpty ? "<none>" : $0.identifier
            return "\($0.label)[id=\(identifier),hittable=\($0.isHittable)]"
        }.joined(separator: ", ")
        let diagnostic = clippedDiagnostic(
            "alertText=\(alert.text.replacingOccurrences(of: "\n", with: " | ")); buttons=\(buttonSummary)"
        )

        guard identifiesRunner && identifiesPhotos else {
            return .unrelated("a non-Photos or non-Runner alert is blocking prompt discovery; \(diagnostic)")
        }
        guard alert.buttons.count == 2 else {
            return .ownedButUnsafe("Runner Photos prompt has \(alert.buttons.count) buttons instead of 2; \(diagnostic)")
        }

        let positiveLabels: Set<String> = ["allow", "允许", "允許"]
        let positive = alert.buttons.filter {
            positiveLabels.contains($0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        guard positive.count == 1, positive[0].isHittable else {
            return .ownedButUnsafe("Runner Photos prompt has no unique hittable allow action; \(diagnostic)")
        }
        return .safe(positive[0])
    }

    private static func clippedDiagnostic(_ value: String) -> String {
        let limit = 600
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}
