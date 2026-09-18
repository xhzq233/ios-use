import Foundation
import IOSUseProtocol

/// The last DOM shown for a Device session, separate from the Driver's lookup cache.
/// Observation IDs describe this history; they are not native node IDs or tap targets.
struct DomObservation {
    private let paths: IOSUsePaths
    private let session: String

    init(paths: IOSUsePaths) throws {
        self.paths = paths
        session = try Self.sessionIdentity(paths: paths)
    }

    private static func sessionIdentity(paths: IOSUsePaths) throws -> String {
        let info = try DriverSessionStore.readInfo(paths: paths)
        return "\(info?.udid ?? "")|\(info?.sessionIdentifier ?? "")|\(info?.startedAt ?? 0)|\(info?.runnerPid ?? 0)"
    }

    private struct Saved: Codable {
        let session: String
        let dom: Data
        // Optional so an observation saved by an older CLI simply starts a full view.
        let ids: [Int]?
        let nextID: Int?
    }

    fileprivate struct MatchKey: Hashable {
        let role: String
        let identifier: String
        let label: String

        init(_ element: ForyDomElement) {
            role = element.traits.first ?? element.type
            identifier = element.identifier
            label = identifier.isEmpty ? element.label : ""
        }
    }

    struct Node: Equatable {
        let id: Int
        let parent: Int?
        let index: Int
        let depth: Int
        let element: MachineValue
        let text: String
        fileprivate let key: MatchKey

        var machineValue: MachineValue {
            .object(["id": .integer(id), "parent": parent.map(MachineValue.integer) ?? .null,
                     "index": .integer(index), "element": element])
        }
        var location: String { "parent=\(parent.map(String.init) ?? "root") index=\(index)" }
    }

    struct Snapshot {
        let session: String
        let app: String
        let width: Double
        let height: Double
        let nodes: [Node]
        let nextID: Int

        init(payload: ForyDomPayload, session: String, previous: Snapshot? = nil,
             ids: [Int]? = nil, nextID savedNextID: Int? = nil) {
            self.session = session
            app = payload.app
            width = payload.windowSize.x
            height = payload.windowSize.y
            let elements = DriverOutput.presentationDomElements(payload.elements)
            // Unique semantic anchors can survive a changed/moved container. Otherwise
            // match duplicate siblings in order within the same parent. Matching only
            // chooses an observation ID: all properties and hierarchy are still compared.
            let candidates = Dictionary(grouping: previous?.nodes ?? [], by: \.key)
            let counts = Dictionary(grouping: elements, by: MatchKey.init).mapValues(\.count)
            var used = Set<Int>()
            var nextID = savedNextID ?? previous?.nextID ?? 1
            var result: [Node] = []
            var parents: [(id: Int, remaining: Int, next: Int)] = []
            var root = 0
            for (offset, element) in elements.enumerated() {
                while parents.last?.remaining == 0 { parents.removeLast() }
                let parent = parents.last?.id
                let index: Int
                if let last = parents.last {
                    index = last.next
                    parents[parents.count - 1].remaining -= 1
                    parents[parents.count - 1].next += 1
                } else {
                    index = root
                    root += 1
                }
                let key = MatchKey(element)
                let options = candidates[key] ?? []
                let unique = options.count == 1 && counts[key] == 1
                    && (!key.identifier.isEmpty || !key.label.isEmpty)
                let matched = options.first { !used.contains($0.id) && (unique || $0.parent == parent) }
                let id: Int
                if let ids, offset < ids.count { id = ids[offset] }
                else if let matched { id = matched.id }
                else { id = nextID; nextID += 1 }
                used.insert(id)
                nextID = max(nextID, id + 1)
                var fields: [String: MachineValue] = [:]
                if case .object(let value) = machineDomElement(element) { fields = value }
                // Capture IDs/generation are volatile. Parent and sibling order below
                // carry hierarchy without making descendants change when a sibling moves.
                for key in ["nodeID", "snapshotGeneration", "hierarchy", "ancestors"] {
                    fields.removeValue(forKey: key)
                }
                result.append(Node(id: id, parent: parent, index: index, depth: parents.count,
                                   element: .object(fields),
                                   text: DriverOutput.formatDomLine(element) + DriverOutput.formatDomRect(element), key: key))
                if element.childCount > 0 { parents.append((id, Int(element.childCount), 0)) }
            }
            nodes = result
            self.nextID = nextID
        }

        var text: String {
            (["App: \(app)", "Elements (observation IDs, not tap targets):"] + nodes.map {
                String(repeating: "  ", count: $0.depth + 1) + "\($0.id) \($0.text)"
            }).joined(separator: "\n") + "\n"
        }
    }

    struct Change {
        let before: Node
        let after: Node

        var text: String {
            var parts: [String] = []
            if before.parent != after.parent { parts.append(after.location) }
            else if before.index != after.index { parts.append("index=\(after.index)") }
            if case .object(let old) = before.element, case .object(let new) = after.element {
                let keys = new.keys.filter { old[$0] != new[$0] }.sorted()
                for key in keys {
                    if key == "frame", case .array(let current) = new[key],
                       case .array(let previous) = old[key], current.count == 4, previous.count == 4 {
                        let axes = ["x", "y", "w", "h"]
                        parts += (0..<4).filter { current[$0] != previous[$0] }.map {
                            "frame.\(axes[$0])=\(Self.render(current[$0]))"
                        }
                    } else if case .object(let fields) = new[key], case .object(let previous) = old[key] {
                        parts += fields.keys.sorted().filter { fields[$0] != previous[$0] }.map {
                            "\(key).\($0)=\(Self.render(fields[$0]!))"
                        }
                    } else if let value = new[key] { parts.append("\(key)=\(Self.render(value))") }
                }
            }
            return "~ \(after.id) " + parts.joined(separator: " ")
        }

        private static func render(_ value: MachineValue) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
    }

    struct Delta {
        let added: [Node]
        let removed: [Node]
        let changed: [Change]
        var unchanged: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

        init(before: Snapshot, after: Snapshot) {
            let old = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
            let new = Set(after.nodes.map(\.id))
            added = after.nodes.filter { old[$0.id] == nil }
            removed = before.nodes.filter { !new.contains($0.id) }
            changed = after.nodes.compactMap { node in
                guard let previous = old[node.id], previous.element != node.element
                        || previous.parent != node.parent || previous.index != node.index else { return nil }
                return Change(before: previous, after: node)
            }
        }

        var removedIDs: String {
            let ids = removed.map(\.id).sorted()
            var ranges: [String] = []
            var index = 0
            while index < ids.count {
                let first = ids[index]
                var last = first
                index += 1
                while index < ids.count && ids[index] == last + 1 { last = ids[index]; index += 1 }
                ranges.append(first == last ? String(first) : "\(first)-\(last)")
            }
            return ranges.joined(separator: ",")
        }
    }

    struct Output {
        let text: String
        let value: MachineValue
    }

    /// Called under DeviceCommandLock, together with the action and its observation.
    func observe(_ payload: ForyDomPayload, diff: Bool) throws -> Output {
        let file = URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent()
            .appendingPathComponent("dom-observation.plist")
        if !payload.raw.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return Output(text: DriverOutput.formatDom(payload), value: machineDom(payload))
        }
        let sameSession = (try Self.sessionIdentity(paths: paths)) == session
        let fory = ForyRegistry.create()
        var previous: Snapshot?
        if sameSession,
           let data = try? Data(contentsOf: file),
           let saved = try? PropertyListDecoder().decode(Saved.self, from: data),
           let ids = saved.ids,
           let dom = try? fory.deserialize(saved.dom, as: ForyDomPayload.self) {
            previous = Snapshot(payload: dom, session: saved.session, ids: ids, nextID: saved.nextID)
        }
        let reason: String?
        if !sameSession { reason = "session changed during observation" }
        else if let previous {
            if previous.session != session { reason = "session changed" }
            else if previous.app != payload.app { reason = "app changed" }
            else if previous.width != payload.windowSize.x || previous.height != payload.windowSize.y { reason = "window size changed" }
            else { reason = nil }
        } else { reason = "no previous observation" }
        let current = Snapshot(payload: payload, session: session, previous: reason == nil ? previous : nil)
        func full(_ reason: String) -> Output {
            Output(text: "DOM full (\(reason))\n" + current.text, value: .object([
                "mode": .string("full"), "reason": .string(reason), "app": .string(payload.app),
                "windowSize": .array([.double(current.width), .double(current.height)]),
                "snapshotGeneration": .integer(Int(payload.snapshotGeneration)),
                "nodes": .array(current.nodes.map(\.machineValue)),
            ]))
        }
        var output: Output
        if !diff {
            // Keep full DOM fields and expose the observation ID for mixed JSON/text use.
            var value = machineDom(payload)
            if case .object(var fields) = value, case .array(let elements) = fields["elements"] {
                fields["elements"] = .array(zip(elements, current.nodes).map { element, node in
                    guard case .object(var fields) = element else { return element }
                    fields["observationID"] = .integer(node.id)
                    return .object(fields)
                })
                value = .object(fields)
            }
            output = Output(text: current.text, value: value)
        } else if let previous, reason == nil {
            let delta = Delta(before: previous, after: current)
            var lines = ["App: \(payload.app)", delta.unchanged ? "DOM unchanged" : "DOM changes (+ added, ~ updated; other IDs unchanged):"]
            if !delta.removed.isEmpty { lines.append("Removed IDs: " + delta.removedIDs) }
            lines += delta.added.map { "+ \($0.id) \($0.location) \($0.text)" }
            lines += delta.changed.map(\.text)
            output = Output(text: lines.joined(separator: "\n") + "\n", value: .object([
                "mode": .string("diff"), "app": .string(payload.app),
                "windowSize": .array([.double(current.width), .double(current.height)]),
                "snapshotGeneration": .integer(Int(payload.snapshotGeneration)),
                "unchanged": .boolean(delta.unchanged),
                "added": .array(delta.added.map(\.machineValue)),
                "removed": .array(delta.removed.map { .integer($0.id) }),
                "changed": .array(delta.changed.map { $0.after.machineValue }),
            ]))
            if !delta.unchanged {
                let complete = full("broad changes")
                if output.text.count >= complete.text.count { output = complete }
            }
        } else { output = full(reason ?? "reset") }
        if !sameSession {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return output
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let saved = Saved(session: session, dom: try fory.serialize(payload), ids: current.nodes.map(\.id), nextID: current.nextID)
        try encoder.encode(saved).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return output
    }
}
