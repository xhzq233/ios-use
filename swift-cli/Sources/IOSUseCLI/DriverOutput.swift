import Foundation
import IOSUseProtocol

public enum DriverOutput {
    public static func formatDom(_ payload: ForyDomPayload) -> String {
        if !payload.raw.isEmpty {
            return "\(payload.raw)\n"
        }

        var lines: [String] = []
        lines.append("")
        lines.append("App: \(payload.app), Window: \(Int(payload.windowSize.x))x\(Int(payload.windowSize.y))")
        lines.append("Elements:")
        for element in payload.elements {
            let label: String
            if element.label.isEmpty {
                label = element.value.isEmpty ? "(no label)" : element.value
            } else if !element.value.isEmpty, element.value != element.label {
                label = "\(element.label)=\(element.value)"
            } else {
                label = element.label
            }
            let traits = element.traits.joined(separator: ",")
            let rect = element.rect.map { "(\($0.x),\($0.y),\($0.w),\($0.h))" } ?? "(0,0,0,0)"
            lines.append("  - \(label) [\(traits)] \(rect)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func formatFind(label: String, payload: ForyFindPayload) -> String {
        var lines: [String] = ["", "Find \"\(label)\":", "  matches=\(payload.matches.count)"]
        if payload.matches.isEmpty {
            if !payload.hint.isEmpty { lines.append("  hint: \(payload.hint)") }
            if !payload.suggestions.isEmpty { lines.append("  suggestions: \(payload.suggestions.joined(separator: ", "))") }
            return lines.joined(separator: "\n") + "\n"
        }

        for match in payload.matches {
            let rect = match.rect.map { "(\($0.x),\($0.y),\($0.w),\($0.h))" } ?? "(0,0,0,0)"
            let traits = match.traits.joined(separator: ",")
            let value = match.value.isEmpty ? "" : "=\(match.value)"
            lines.append("  \(elementTypeName(match.elemType)) \"\(match.label)\(value)\" [\(traits)] \(rect)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func formatWaitFor(label: String, payload: ForyWaitForPayload) -> String {
        let rect = payload.rect.map { "(\($0.x),\($0.y),\($0.w),\($0.h))" } ?? "(0,0,0,0)"
        return "\(elementTypeName(payload.elemType)) \"\(payload.label)\" \(rect) waited=\(String(format: "%.2f", payload.waited))s\n"
    }

    public static func formatElement(_ payload: ForyElementPayload) -> String {
        let rect = payload.rect.map { "(\($0.x),\($0.y),\($0.w),\($0.h))" } ?? "(0,0,0,0)"
        let label = payload.label.isEmpty ? "" : " \"\(payload.label)\""
        return "\(elementTypeName(payload.elemType))\(label) \(rect)\n"
    }

    public static func formatSwipe(_ payload: ForySwipePayload) -> String {
        let label = payload.label.isEmpty ? "" : " \"\(payload.label)\""
        return "\(elementTypeName(payload.elemType))\(label) scrolls=\(payload.scrolls)\n"
    }

    public static func formatAlert(_ payload: ForyAlertPayload) -> String {
        if payload.dismissed {
            return "Alert dismissed: tapped \"\(payload.button)\" (text: \(payload.text))\n"
        }
        return "No alert found: \(payload.reason)\n"
    }

    public static func elementTypeName(_ raw: Int32) -> String {
        switch raw {
        case 7: return "Button"
        case 8: return "Cell"
        case 9: return "StaticText"
        case 10: return "TextField"
        case 11: return "SecureTextField"
        case 12: return "TextView"
        case 13: return "SearchField"
        case 15: return "Icon"
        case 17: return "Switch"
        case 22: return "NavigationBar"
        case 23: return "Table"
        case 27: return "ScrollView"
        case 28: return "WebView"
        default: return "Other"
        }
    }
}
