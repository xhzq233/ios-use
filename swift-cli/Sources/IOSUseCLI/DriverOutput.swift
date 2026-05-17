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

        var index = 0
        while index < payload.elements.count {
            index = collectDomFlatSubtreeLines(payload.elements, index: index, baseIndent: "  ", depth: 0, lines: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func collectDomFlatSubtreeLines(_ elements: [ForyDomElement], index: Int, baseIndent: String, depth: Int, lines: inout [String]) -> Int {
        guard index < elements.count else { return index }
        let element = elements[index]
        let padding = baseIndent + String(repeating: "  ", count: depth)
        let line = formatDomLine(element)
        let childCount = max(0, Int(element.childCount))

        if childCount > 0 {
            lines.append("\(padding)\(line):")
            var childIndex = index + 1
            for _ in 0..<childCount {
                guard childIndex < elements.count else { break }
                childIndex = collectDomFlatSubtreeLines(elements, index: childIndex, baseIndent: baseIndent, depth: depth + 1, lines: &lines)
            }
            return childIndex
        }

        let rect = element.rect.map { " (\($0.x),\($0.y),\($0.w),\($0.h))" } ?? ""
        lines.append("\(padding)- \(line)\(rect)")
        return index + 1
    }

    private static func formatDomLine(_ element: ForyDomElement) -> String {
        let type = element.traits.first ?? "?"
        let flags = element.traits.dropFirst().joined(separator: ",")
        let allTraits = flags.isEmpty ? type : "\(type),\(flags)"
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if !label.isEmpty {
            title = value.isEmpty ? label : "\(label)=\(value)"
        } else if !value.isEmpty {
            title = "=\(value)"
        } else {
            title = type
        }
        return "\(title) [\(allTraits)]"
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
