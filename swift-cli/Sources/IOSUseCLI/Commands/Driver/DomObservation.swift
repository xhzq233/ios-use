import Foundation
import IOSUseProtocol

/// The last DOM shown to one CLI client, separate from the Driver's lookup cache.
/// Paths identify positions in an observation, not persistent node identities or tap IDs.
struct DomObservation {
    private let paths: IOSUsePaths
    private let id: String
    private let session: String

    init(paths: IOSUsePaths) throws {
        self.paths = paths
        id = try Self.clientID()
        session = try Self.sessionIdentity(paths: paths)
    }

    private static func sessionIdentity(paths: IOSUsePaths) throws -> String {
        let info = try DriverSessionStore.readInfo(paths: paths)
        return "\(info?.udid ?? "")|\(info?.sessionIdentifier ?? "")|\(info?.startedAt ?? 0)|\(info?.runnerPid ?? 0)"
    }

    private struct Saved: Codable {
        let session: String
        let dom: Data
    }

    struct Node: Equatable {
        let path: String
        let element: MachineValue
        let text: String

        var parentPath: String? {
            guard let slash = path.lastIndex(of: "/") else { return nil }
            return String(path[..<slash])
        }
        var machineValue: MachineValue {
            .object(["path": .string(path), "element": element])
        }
    }

    struct Snapshot {
        let session: String
        let app: String
        let width: Double
        let height: Double
        let nodes: [Node]

        init(payload: ForyDomPayload, session: String) {
            self.session = session
            app = payload.app
            width = payload.windowSize.x
            height = payload.windowSize.y
            let elements = DriverOutput.presentationDomElements(payload.elements)
            var result: [Node] = []
            var parents: [(path: String, remaining: Int, next: Int)] = []
            var root = 0
            for element in elements {
                while parents.last?.remaining == 0 { parents.removeLast() }
                let path: String
                if let parent = parents.last {
                    path = "\(parent.path)/\(parent.next)"
                    parents[parents.count - 1].remaining -= 1
                    parents[parents.count - 1].next += 1
                } else {
                    path = String(root)
                    root += 1
                }
                var fields: [String: MachineValue] = [:]
                if case .object(let value) = machineDomElement(element) { fields = value }
                // Generation and native IDs can change on every capture. Hierarchy is
                // represented by path, including sibling order, on both backends.
                for key in ["nodeID", "snapshotGeneration", "hierarchy", "ancestors"] {
                    fields.removeValue(forKey: key)
                }
                result.append(Node(path: path, element: .object(fields),
                                   text: DriverOutput.formatDomLine(element) + DriverOutput.formatDomRect(element)))
                if element.childCount > 0 {
                    parents.append((path, Int(element.childCount), 0))
                }
            }
            nodes = result
        }
    }

    struct Change {
        let before: Node
        let after: Node

        var text: String {
            var details = ""
            if case .object(let old) = before.element, case .object(let new) = after.element {
                let keys = new.keys.filter { old[$0] != new[$0] && !["label", "value", "traits", "frame"].contains($0) }.sorted()
                let fields = keys.compactMap { key -> String? in
                    guard let data = try? JSONEncoder().encode(new[key]), let value = String(data: data, encoding: .utf8) else { return nil }
                    return "\(key)=\(value)"
                }
                if !fields.isEmpty { details = " {" + fields.joined(separator: ", ") + "}" }
            }
            return "~ [\(after.path)] \(before.text) -> \(after.text)\(details)"
        }
    }

    struct Delta {
        let added: [Node]
        let removed: [Node]
        let changed: [Change]
        let context: [Node]
        var unchanged: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

        init(before: Snapshot, after: Snapshot) {
            let old = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.path, $0) })
            let new = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.path, $0) })
            added = after.nodes.filter { old[$0.path] == nil }
            removed = before.nodes.filter { new[$0.path] == nil }
            changed = after.nodes.compactMap { node in
                guard let previous = old[node.path], previous.element != node.element else { return nil }
                return Change(before: previous, after: node)
            }
            let changes = Set(added.map(\.path) + changed.map { $0.after.path })
            let parents = Set((added + removed + changed.map(\.after)).compactMap(\.parentPath))
            context = after.nodes.filter { parents.contains($0.path) && !changes.contains($0.path) }
        }
    }

    struct Output {
        let text: String
        let value: MachineValue
    }

    static func clientID(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let id = environment["IOS_USE_DOM_CLIENT"] ?? "default"
        guard !id.isEmpty, id.utf8.count <= 80,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw CLIParseError.invalidValue("IOS_USE_DOM_CLIENT must be 1–80 letters, digits, '-' or '_'")
        }
        return id.lowercased()
    }

    /// Called under DeviceCommandLock, together with the action and its observation.
    func observe(_ payload: ForyDomPayload, diff: Bool) throws -> Output {
        let file = URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent()
            .appendingPathComponent("dom-observations").appendingPathComponent(id + ".plist")
        if !payload.raw.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return Output(text: DriverOutput.formatDom(payload), value: machineDom(payload))
        }
        let current = Snapshot(payload: payload, session: session)
        let sameSession = (try Self.sessionIdentity(paths: paths)) == session
        let fory = ForyRegistry.create()
        var previous: Snapshot?
        if diff, sameSession,
           let data = try? Data(contentsOf: file),
           let saved = try? PropertyListDecoder().decode(Saved.self, from: data),
           let dom = try? fory.deserialize(saved.dom, as: ForyDomPayload.self) {
            previous = Snapshot(payload: dom, session: saved.session)
        }
        let reason: String?
        if !sameSession { reason = "session changed during observation" }
        else if let previous {
            if previous.session != current.session { reason = "session changed" }
            else if previous.app != current.app { reason = "app changed" }
            else if previous.width != current.width || previous.height != current.height { reason = "window size changed" }
            else { reason = nil }
        } else { reason = "no previous observation" }

        func full(_ reason: String) -> Output {
            Output(text: "DOM full (\(reason))\n" + DriverOutput.formatDom(payload), value: .object([
                "mode": .string("full"), "reason": .string(reason),
                "app": .string(payload.app),
                "windowSize": .array([.double(current.width), .double(current.height)]),
                "snapshotGeneration": .integer(Int(payload.snapshotGeneration)),
                "nodes": .array(current.nodes.map(\.machineValue)),
            ]))
        }
        var output: Output
        if !diff {
            output = Output(text: DriverOutput.formatDom(payload), value: machineDom(payload))
        } else if let previous, reason == nil {
            let delta = Delta(before: previous, after: current)
            var lines = ["App: \(payload.app)", delta.unchanged ? "DOM unchanged" : "DOM changes (+ added, - removed, ~ changed; paths are positions):"]
            lines += delta.context.map { "  [\($0.path)] \($0.text)" }
            lines += delta.removed.map { "- [\($0.path)] \($0.text)" }
            lines += delta.added.map { "+ [\($0.path)] \($0.text)" }
            lines += delta.changed.map(\.text)
            output = Output(text: lines.joined(separator: "\n") + "\n", value: .object([
                "mode": .string("diff"), "app": .string(payload.app),
                "windowSize": .array([.double(current.width), .double(current.height)]),
                "snapshotGeneration": .integer(Int(payload.snapshotGeneration)),
                "unchanged": .boolean(delta.unchanged),
                "added": .array(delta.added.map(\.machineValue)),
                "removed": .array(delta.removed.map(\.machineValue)),
                "changed": .array(delta.changed.map { .object([
                    "path": .string($0.after.path), "before": $0.before.element, "after": $0.after.element
                ]) }),
                "context": .array(delta.context.map(\.machineValue)),
            ]))
            // Large replacements/reordered lists are clearer and cheaper as a full tree.
            if !delta.unchanged {
                let complete = full("broad changes")
                if output.text.utf8.count >= complete.text.utf8.count { output = complete }
            }
        } else {
            output = full(reason ?? "reset")
        }
        if !sameSession {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return output
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let saved = Saved(session: session, dom: try fory.serialize(payload))
        try encoder.encode(saved).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return output
    }
}
