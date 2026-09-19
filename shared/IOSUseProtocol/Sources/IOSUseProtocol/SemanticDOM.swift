import Foundation

/// Shared by XCTest and the injected Mac Runtime. This is a presentation of the
/// current lookup tree, never a replacement for that tree or its selectors.
public enum SemanticDOM {
    public struct Element {
        public var label: String
        public var accessibilityLabel: String
        public var value: String
        public var hint: String
        public var traits: [String]
        public var children: Int
        public var rect: [Double]

        public init(label: String, accessibilityLabel: String = "", value: String = "",
                    hint: String = "", traits: [String], children: Int, rect: [Double] = []) {
            self.label = label; self.accessibilityLabel = accessibilityLabel
            self.value = value; self.hint = hint; self.traits = traits
            self.children = children; self.rect = rect
        }
    }

    public struct Edit: Codable, Equatable {
        /// Removal offsets refer to the previous tree; insertion offsets to the new tree.
        public let offset: Int
        public let childIndex: Int
        public let line: String
        public let context: [String]
    }

    public struct Observation: Codable {
        public var mode: String
        public var revision: String
        public var reason: String
        public var lines: [String]
        public var removed: [Edit]
        public var added: [Edit]
        public var layoutChanged: Bool

        public var text: String {
            if mode == "full" {
                let layout = layoutChanged ? "\nLayout changed; use dom --json for current coordinates." : ""
                return lines.joined(separator: "\n") + layout + "\n"
            }
            var result = ["DOM changes (- removed, + added):"]
            if removed.isEmpty && added.isEmpty { result = ["DOM semantics unchanged"] }
            var context: [String] = []
            for (sign, edits) in [("-", removed), ("+", added)] {
                for edit in edits.sorted(by: { $0.offset < $1.offset }) {
                    let shared = zip(context, edit.context).prefix { $0 == $1 }.count
                    result += edit.context.dropFirst(shared).map { "  " + $0 }
                    result.append(sign + " " + edit.line + " (child \(edit.childIndex))")
                    context = edit.context
                }
            }
            if layoutChanged { result.append("Layout changed; use dom --json for current coordinates.") }
            return result.joined(separator: "\n") + "\n"
        }

        /// Exact ordered reconstruction, including repeated identical rows and moves.
        public func applying(to previous: [String]) -> [String]? {
            if mode == "full" { return lines }
            var changes: [CollectionDifference<String>.Change] = []
            changes += removed.map { .remove(offset: $0.offset, element: $0.line, associatedWith: nil) }
            changes += added.map { .insert(offset: $0.offset, element: $0.line, associatedWith: nil) }
            guard let delta = CollectionDifference(changes) else { return nil }
            return previous.applying(delta)
        }
    }

    public static func lines(_ elements: [Element]) -> [String] {
        var parents: [Int] = []
        var result: [String] = []
        var directChildren = Array(repeating: [Int](), count: elements.count)
        var traversal: [(index: Int, remaining: Int)] = []
        for (index, element) in elements.enumerated() {
            while traversal.last?.remaining == 0 { traversal.removeLast() }
            if let parent = traversal.last {
                directChildren[parent.index].append(index)
                traversal[traversal.count - 1].remaining -= 1
            }
            if element.children > 0 { traversal.append((index, element.children)) }
        }
        for (index, element) in elements.enumerated() {
            while parents.last == 0 { parents.removeLast() }
            let depth = parents.count
            if !parents.isEmpty { parents[parents.count - 1] -= 1 }
            var title = atom(element.label)
            if !element.value.isEmpty && element.value != element.label {
                title += "=" + atom(element.value)
            }
            if title.isEmpty { title = element.traits.first ?? "Element" }
            var traits = element.traits
            if !traits.contains("vertical") && !traits.contains("horizontal"),
               traits.contains(where: { ["Scroll", "Collection", "Table"].contains($0) }) {
                let rects = directChildren[index].map { elements[$0] }
                    .filter { !$0.traits.contains("invisible") && $0.rect.count == 4 }.map(\.rect)
                let direction: String
                if rects.count >= 2 {
                    let xs = rects.map { $0[0] }, ys = rects.map { $0[1] }
                    direction = (xs.max()! - xs.min()!) > (ys.max()! - ys.min()!) ? "horizontal" : "vertical"
                } else {
                    direction = element.rect.count == 4 && element.rect[2] > element.rect[3] ? "horizontal" : "vertical"
                }
                traits.append(direction)
            }
            var line = String(repeating: "  ", count: depth) + title
                + " [" + traits.joined(separator: ",") + "]"
            if !element.accessibilityLabel.isEmpty && element.accessibilityLabel != element.label
                && element.accessibilityLabel != element.value {
                line += " text=" + quoted(element.accessibilityLabel)
            }
            if !element.hint.isEmpty { line += " hint=" + quoted(element.hint) }
            if element.children > 0 { line += ":"; parents.append(element.children) }
            result.append(line)
        }
        return result
    }

    private static func atom(_ value: String) -> String {
        if value.contains(where: { "=\"[]:\n\r\t".contains($0) }) || value.first == " " || value.last == " " {
            return quoted(value)
        }
        return escaped(value)
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func quoted(_ value: String) -> String {
        "\"" + escaped(value).replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// One last observation per Driver, independent of short-lived CLI sockets.
    /// Current snapshots still obey the backend's normal invalidation rules.
    public final class Store {
        private let lock = NSLock()
        private let epoch = UUID().uuidString
        private var sequence = 0
        private var previous: (app: String, size: [Double], lines: [String], geometry: [[Double]], revision: String)?

        public init() {}

        public func reset() {
            lock.lock(); defer { lock.unlock() }
            previous = nil
        }

        public func observe(app: String, size: [Double], elements: [Element], diff: Bool,
                            since: String) -> Observation {
            lock.lock(); defer { lock.unlock() }
            let lines = SemanticDOM.lines(elements)
            let geometry = elements.map(\.rect)
            sequence += 1
            let revision = "\(epoch):\(sequence)"
            let old = previous
            previous = (app, size, lines, geometry, revision)
            var full = Observation(mode: "full", revision: revision, reason: "requested",
                                   lines: lines, removed: [], added: [], layoutChanged: false)
            guard diff else { return full }
            guard let old, old.revision == since else {
                full.reason = "observation reset"; return full
            }
            guard old.app == app, old.size == size else {
                full.reason = "app or window changed"; return full
            }
            full.layoutChanged = old.geometry != geometry
            var removed: [Edit] = [], added: [Edit] = []
            let beforeContext = Self.contexts(old.lines)
            let afterContext = Self.contexts(lines)
            for change in lines.difference(from: old.lines) {
                switch change {
                case .remove(let offset, let line, _):
                    removed.append(Edit(offset: offset, childIndex: beforeContext[offset].index, line: line, context: beforeContext[offset].parents))
                case .insert(let offset, let line, _):
                    added.append(Edit(offset: offset, childIndex: afterContext[offset].index, line: line, context: afterContext[offset].parents))
                }
            }
            let delta = Observation(mode: "diff", revision: revision, reason: "",
                                    lines: [], removed: removed, added: added,
                                    layoutChanged: old.geometry != geometry)
            // Both model output and transport must benefit; otherwise send full.
            let encoder = JSONEncoder()
            if delta.text.utf8.count >= full.text.utf8.count ||
                (try? encoder.encode(delta).count) ?? Int.max >= (try? encoder.encode(full).count) ?? 0 {
                full.reason = "broad changes"; return full
            }
            return delta
        }

        private static func contexts(_ lines: [String]) -> [(index: Int, parents: [String])] {
            var parents: [(depth: Int, line: String, nextChild: Int)] = []
            var rootIndex = 0
            return lines.map { line in
                let depth = line.prefix { $0 == " " }.count / 2
                while let last = parents.last, last.depth >= depth { parents.removeLast() }
                let index: Int
                if let parent = parents.last {
                    index = parent.nextChild
                    parents[parents.count - 1].nextChild += 1
                } else { index = rootIndex; rootIndex += 1 }
                let result = (index, parents.map { $0.line })
                if line.hasSuffix(":") { parents.append((depth, line, 0)) }
                return result
            }
        }
    }
}
