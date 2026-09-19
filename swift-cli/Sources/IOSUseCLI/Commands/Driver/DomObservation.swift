import Foundation
import IOSUseProtocol

/// The Driver owns observation history. The CLI keeps only a continuation token,
/// so separate invocations can request deltas without copying the tree to disk.
struct DomObservation {
    private let file: URL
    private let detailed: Bool

    init(paths: IOSUsePaths, detailed: Bool = false) throws {
        self.detailed = detailed
        file = URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent()
            .appendingPathComponent("dom-observation-revision")
    }

    func arguments(raw: Bool = false, fresh: Bool, waitQuiescence: Bool, diff: Bool) -> ForyDomArgs {
        ForyDomArgs(raw: raw, fresh: fresh, waitQuiescence: waitQuiescence,
            semantic: !raw && (!detailed || diff), diff: diff,
            since: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    struct Output {
        let text: String
        let value: MachineValue
    }

    func observe(_ payload: ForyDomPayload, diff: Bool) throws -> Output {
        guard !payload.observation.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            if !payload.raw.isEmpty { return Output(text: DriverOutput.formatDom(payload), value: machineDom(payload)) }
            let nodes = DriverOutput.presentationDomElements(payload.elements).map {
                SemanticDOM.Element(label: $0.label, accessibilityLabel: $0.accessibilityLabel,
                    value: $0.value, hint: $0.hint, traits: $0.traits, children: Int($0.childCount))
            }
            let prefix = diff ? "DOM full (Driver did not return a delta)\n" : ""
            return Output(text: prefix + "App: \(payload.app)\n" + SemanticDOM.lines(nodes).joined(separator: "\n") + "\n",
                          value: machineDom(payload))
        }
        let observation = try JSONDecoder().decode(SemanticDOM.Observation.self, from: Data(payload.observation.utf8))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(observation.revision.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        func rows(_ values: [SemanticDOM.Row]) -> MachineValue {
            .array(values.map { .object(["offset": .integer($0.offset), "childIndex": .integer($0.childIndex), "line": .string($0.line)]) })
        }
        let changes: MachineValue = .array(observation.changes.map { group in
            .object([
                "context": .array(group.context.map(MachineValue.string)),
                "removed": .array(group.removed.map { .object([
                    "offset": .integer($0.offset), "childIndex": .integer($0.childIndex), "label": .string($0.label),
                ]) }),
                "added": rows(group.added), "updated": rows(group.updated),
            ])
        })
        return Output(text: "App: \(payload.app)\n" + observation.text, value: .object([
            "app": .string(payload.app), "mode": .string(observation.mode),
            "windowSize": .array([.double(payload.windowSize.x), .double(payload.windowSize.y)]), "revision": .string(observation.revision),
            "reason": .string(observation.reason), "layoutChanged": .boolean(observation.layoutChanged),
            "lines": .array(observation.lines.map(MachineValue.string)),
            "changes": changes,
        ]))
    }
}
