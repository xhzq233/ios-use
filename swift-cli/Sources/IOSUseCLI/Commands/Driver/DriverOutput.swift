import Foundation
import IOSUseProtocol

public enum DriverOutput {
    public static func formatDom(_ payload: ForyDomPayload) -> String {
        if !payload.raw.isEmpty {
            return "\(payload.raw)\n"
        }
        let elements = presentationDomElements(payload.elements)

        var lines: [String] = []
        lines.append("App: \(payload.app)")
        lines.append("Elements:")

        var index = 0
        while index < elements.count {
            index = collectDomFlatSubtreeLines(elements, index: index, baseIndent: "  ", depth: 0, lines: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func presentationDomElements(_ elements: [ForyDomElement]) -> [ForyDomElement] {
        var index = 0
        var roots: [DomPresentationNode] = []
        while index < elements.count {
            let parsed = parseDomPresentationNode(elements, index: index)
            roots.append(parsed.node)
            index = max(parsed.nextIndex, index + 1)
        }

        var out: [ForyDomElement] = []
        for root in roots {
            appendPresentationDomNode(root, to: &out)
        }
        return out
    }

    private static func collectDomFlatSubtreeLines(_ elements: [ForyDomElement], index: Int, baseIndent: String, depth: Int, lines: inout [String]) -> Int {
        guard index < elements.count else { return index }
        let element = elements[index]
        let padding = baseIndent + String(repeating: "  ", count: depth)
        let line = formatDomLine(element)
        let childCount = max(0, Int(element.childCount))

        if childCount > 0 {
            lines.append("\(padding)\(line)\(formatDomRect(element)):")
            var childIndex = index + 1
            for _ in 0..<childCount {
                guard childIndex < elements.count else { break }
                childIndex = collectDomFlatSubtreeLines(elements, index: childIndex, baseIndent: baseIndent, depth: depth + 1, lines: &lines)
            }
            return childIndex
        }

        lines.append("\(padding)- \(line)\(formatDomRect(element))")
        return index + 1
    }

    private static func formatDomRect(_ element: ForyDomElement) -> String {
        element.rect.map { " (\($0.x),\($0.y),\($0.w),\($0.h))" } ?? ""
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

    private struct DomPresentationNode {
        var element: ForyDomElement
        var children: [DomPresentationNode]
    }

    private static func parseDomPresentationNode(_ elements: [ForyDomElement], index: Int) -> (node: DomPresentationNode, nextIndex: Int) {
        guard index < elements.count else {
            return (DomPresentationNode(element: ForyDomElement(), children: []), index)
        }
        var nextIndex = index + 1
        var children: [DomPresentationNode] = []
        let childCount = max(0, Int(elements[index].childCount))
        children.reserveCapacity(childCount)
        for _ in 0..<childCount {
            guard nextIndex < elements.count else { break }
            let parsed = parseDomPresentationNode(elements, index: nextIndex)
            children.append(parsed.node)
            nextIndex = max(parsed.nextIndex, nextIndex + 1)
        }
        return (DomPresentationNode(element: elements[index], children: children), nextIndex)
    }

    private static func appendPresentationDomNode(_ node: DomPresentationNode, to out: inout [ForyDomElement]) {
        var element = node.element
        if let direction = inferPresentationScrollDirection(for: element, children: node.children.map(\.element)),
           !element.traits.contains(direction) {
            element.traits.append(direction)
        }
        out.append(element)
        for child in node.children {
            appendPresentationDomNode(child, to: &out)
        }
    }

    private static func inferPresentationScrollDirection(for element: ForyDomElement, children: [ForyDomElement]) -> String? {
        guard element.traits.contains("Scroll")
            || element.traits.contains("Collection")
            || element.traits.contains("Table") else {
            return nil
        }

        let visibleChildRects = children.compactMap { child -> ForyRect? in
            guard !child.traits.contains("invisible") else { return nil }
            return child.rect
        }
        guard visibleChildRects.count >= 2 else {
            return fallbackPresentationScrollDirection(for: element)
        }

        let ys = visibleChildRects.map(\.y)
        let xs = visibleChildRects.map(\.x)
        let yRange = (ys.max() ?? 0) - (ys.min() ?? 0)
        let xRange = (xs.max() ?? 0) - (xs.min() ?? 0)

        if yRange > xRange { return "vertical" }
        if xRange > yRange { return "horizontal" }
        return "vertical"
    }

    private static func fallbackPresentationScrollDirection(for element: ForyDomElement) -> String {
        guard let rect = element.rect else { return "vertical" }
        return rect.h >= rect.w ? "vertical" : "horizontal"
    }

    public static func formatWaitFor(label: String, payload: ForyWaitForPayload) -> String {
        let element = payload.element
        let rect = element.rect.map { "(\($0.x),\($0.y),\($0.w),\($0.h))" } ?? "(0,0,0,0)"
        return "\(elementTypeName(element.elemType)) \"\(element.label)\" \(rect) waited=\(String(format: "%.2f", payload.waited))s\n"
    }

    public static func formatElement(_ payload: ForyElementPayload) -> String {
        let element = payload.element
        let rect = element.rect.map { "(\($0.x),\($0.y),\($0.w),\($0.h))" } ?? "(0,0,0,0)"
        let label = element.label.isEmpty ? "" : " \"\(element.label)\""
        return "\(elementTypeName(element.elemType))\(label) \(rect)\n"
    }

    public static func formatSwipe(_ payload: ForySwipePayload) -> String {
        let element = payload.element
        let label = element.label.isEmpty ? "" : " \"\(element.label)\""
        let direction = payload.scrollDirection.isEmpty ? "" : " direction=\(payload.scrollDirection)"
        return "\(elementTypeName(element.elemType))\(label) scrolls=\(payload.scrolls)\(direction)\n"
    }

    public static func formatAlert(_ payload: ForyAlertPayload) -> String {
        if payload.dismissed {
            return "Alert dismissed: tapped \"\(payload.button)\" (text: \(payload.text))\n"
        }
        return "No alert found: \(payload.reason)\n"
    }

    public static func elementTypeName(_ raw: Int32) -> String {
        IOSUseElementTypes.displayName(rawType: raw)
    }
}
