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

    public struct Row: Codable, Equatable {
        /// An offset in the resulting tree, not an action ID.
        public let offset: Int
        public let childIndex: Int
        public let line: String
    }

    public struct Removal: Codable, Equatable {
        /// An offset in the previous tree. Its old value is already in context.
        public let offset: Int
        public let childIndex: Int
        public let label: String
    }

    public struct ChangeGroup: Codable {
        public var context: [String]
        public var removed: [Removal] = []
        public var added: [Row] = []
        public var updated: [Row] = []
    }

    public struct Observation: Codable {
        public var mode: String
        public var revision: String
        public var reason: String
        public var lines: [String]
        public var changes: [ChangeGroup]
        public var layoutChanged: Bool

        public var removed: [Removal] { changes.flatMap(\.removed) }
        public var added: [Row] { changes.flatMap(\.added) }
        public var updated: [Row] { changes.flatMap(\.updated) }

        public var text: String {
            if mode == "full" {
                let layout = layoutChanged ? "\nLayout changed; use dom --nodiff --json for current coordinates." : ""
                return lines.joined(separator: "\n") + layout + "\n"
            }
            var result = ["DOM changes (- removed, + added, ~ updated):"]
            if changes.isEmpty { result = ["DOM semantics unchanged"] }
            var context: [String] = []
            for group in changes {
                let shared = zip(context, group.context).prefix { $0 == $1 }.count
                result += group.context.dropFirst(shared).map { "  " + $0 }
                for row in group.removed {
                    result.append("- " + atom(row.label) + " (child \(row.childIndex))")
                }
                for (sign, rows) in [("~", group.updated), ("+", group.added)] {
                    for row in rows {
                        result.append(sign + " " + row.line + " (child \(row.childIndex))")
                    }
                }
                context = group.context
            }
            if layoutChanged { result.append("Layout changed; use dom --nodiff --json for current coordinates.") }
            return result.joined(separator: "\n") + "\n"
        }

        /// Reconstruct exactly, including duplicate labels, reparenting and moves.
        /// Updates replace a row at the same old/new offset; all insertions still
        /// refer to final offsets, so other edits cannot shift their meaning.
        public func applying(to previous: [String]) -> [String]? {
            if mode == "full" { return lines }
            var delta: [CollectionDifference<String>.Change] = []
            let removals = removed.map(\.offset) + updated.map(\.offset)
            for offset in removals {
                guard previous.indices.contains(offset) else { return nil }
                delta.append(.remove(offset: offset, element: previous[offset], associatedWith: nil))
            }
            delta += (added + updated).map { .insert(offset: $0.offset, element: $0.line, associatedWith: nil) }
            guard let difference = CollectionDifference(delta) else { return nil }
            return previous.applying(difference)
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
    /// This history is only for diffing; lookups and actions capture their own trees.
    public final class Store {
        private let lock = NSLock()
        private let epoch = UUID().uuidString
        private var sequence = 0
        private var previous: (app: String, size: [Double], lines: [String], labels: [String], geometry: [[Double]], revision: String)?

        public init() {}

        public func reset() {
            lock.lock(); defer { lock.unlock() }
            previous = nil
        }

        public func observe(app: String, size: [Double], elements: [Element], diff: Bool,
                            since: String) -> Observation {
            observe(app: app, size: size, lines: SemanticDOM.lines(elements),
                    labels: elements.map(\.label), geometry: elements.map(\.rect), diff: diff, since: since)
        }

        // Also used by offline trajectory replay, without inventing native AX data
        // from already-rendered observations.
        func observe(app: String, size: [Double], lines: [String], labels: [String],
                     geometry: [[Double]], diff: Bool, since: String) -> Observation {
            lock.lock(); defer { lock.unlock() }
            sequence += 1
            let revision = "\(epoch):\(sequence)"
            let old = previous
            previous = (app, size, lines, labels, geometry, revision)
            var full = Observation(mode: "full", revision: revision, reason: "requested",
                                   lines: lines, changes: [], layoutChanged: false)
            guard diff else { return full }
            guard let old, old.revision == since else {
                full.reason = "observation reset"; return full
            }
            full.layoutChanged = old.size != size || old.geometry != geometry
            guard old.app == app, old.size == size else {
                full.reason = "app or window changed"; return full
            }
            var removed: Set<Int> = [], added: Set<Int> = []
            let beforeContext = Self.contexts(old.lines)
            let afterContext = Self.contexts(lines)
            for change in lines.difference(from: old.lines) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): added.insert(offset)
                }
            }
            let oldCounts = Dictionary(old.labels.map { ($0, 1) }, uniquingKeysWith: +)
            let newCounts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
            // Coalesce only unambiguous same-position, same-selector replacements.
            // This is a compact representation of exact edits, not native identity
            // tracking. Generated/duplicate/moved selectors need no special cache.
            let updated = removed.intersection(added).filter { offset in
                let label = labels[offset]
                return !label.isEmpty && old.labels[offset] == label
                    && oldCounts[label] == 1 && newCounts[label] == 1
                    && beforeContext[offset].parents == afterContext[offset].parents
            }
            removed.subtract(updated); added.subtract(updated)
            var groups: [ChangeGroup] = []
            var groupIndices: [[String]: Int] = [:]
            func groupIndex(_ context: [String]) -> Int {
                if let index = groupIndices[context] { return index }
                let index = groups.count
                groupIndices[context] = index
                groups.append(ChangeGroup(context: context))
                return index
            }
            for offset in removed.sorted() {
                let context = beforeContext[offset]
                let index = groupIndex(context.parents)
                groups[index].removed.append(Removal(offset: offset, childIndex: context.index, label: old.labels[offset]))
            }
            for offset in updated.sorted() {
                let context = afterContext[offset]
                let index = groupIndex(context.parents)
                groups[index].updated.append(Row(offset: offset, childIndex: context.index, line: lines[offset]))
            }
            for offset in added.sorted() {
                let context = afterContext[offset]
                let index = groupIndex(context.parents)
                groups[index].added.append(Row(offset: offset, childIndex: context.index, line: lines[offset]))
            }
            let delta = Observation(mode: "diff", revision: revision, reason: "",
                                    lines: [], changes: groups, layoutChanged: old.geometry != geometry)
            // Prefer the shorter model-facing representation. Transport is measured
            // separately; repeated JSON metadata must not veto a useful text diff.
            if delta.text.utf8.count >= full.text.utf8.count {
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
