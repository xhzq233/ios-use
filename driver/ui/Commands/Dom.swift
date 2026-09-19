import XCTest
import Fory

// MARK: - Dom command (doc 2)

enum DomCommands {
    private static let observations = SemanticDOM.Store()
    /// doc 2.2 — nested tree with rule 1-6 applied (or raw if --raw).
    static func dom(_ args: ForyDomArgs) throws -> ForyResponseFrame {
        // External device services can switch Apps without a Driver mutation.
        // A fresh observation must refresh the active App as well as its tree.
        let app = try args.fresh ? Session.shared.refreshActive() : Session.shared.ensureActive()

        if args.waitQuiescence {
            Quiescence.wait(app: app, command: "dom")
        }

        // --raw mode: format the pre-clean snapshot as an indented string.
        if args.raw {
            observations.reset()
            invalidateSnapshot()
            guard let root = SafeSnapshot(ofApp: app) else {
                return try Codec.foryError(
                    "failed to take snapshot",
                    category: IOSUseErrorCategory.lookup,
                    code: IOSUseErrorCode.snapshotFailed,
                    phase: IOSUseErrorPhase.snapshot,
                    retryable: true
                )
            }
            let lines = formatRawTree(root, parentDisabled: false, indent: "")
            let payload = ForyDomPayload(
                app: app.value(forKey: "bundleID") as? String ?? "",
                windowSize: ForyPoint(
                    x: Double(Int(root.frame.size.width.rounded())),
                    y: Double(Int(root.frame.size.height.rounded()))
                ),
                raw: lines,
                elements: []
            )
            return try Codec.foryOK(payload)
        }

        // --fresh mode: invalidate cache before taking snapshot.
        if args.fresh || args.waitQuiescence {
            invalidateSnapshot()
        }

        guard let cs = getCleanedSnapshot() else {
            return try Codec.foryError(
                "failed to take snapshot",
                category: IOSUseErrorCategory.lookup,
                code: IOSUseErrorCode.snapshotFailed,
                phase: IOSUseErrorPhase.snapshot,
                retryable: true
            )
        }
        if args.semantic {
            let observation = observations.observe(
                app: cs.bundleId,
                size: [Double(cs.appFrame.width), Double(cs.appFrame.height)],
                elements: cs.elements.map { element in
                    let node = element.node
                    return SemanticDOM.Element(label: displayName(for: node) ?? "",
                        accessibilityLabel: node.label ?? "", value: displayValue(for: node) ?? "",
                        traits: element.traits, children: element.childCount,
                        rect: [Double(node.frame.minX), Double(node.frame.minY), Double(node.frame.width), Double(node.frame.height)])
                }, diff: args.diff, since: args.since)
            let json = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
            return try Codec.foryOK(ForyDomPayload(app: cs.bundleId, observation: json,
                windowSize: ForyPoint(x: Double(cs.appFrame.width), y: Double(cs.appFrame.height))))
        }
        let flatElements = serializeDomFlat(from: cs.elements)
        let payload = ForyDomPayload(
            app: cs.bundleId,
            windowSize: ForyPoint(
                x: Double(Int(cs.appFrame.size.width.rounded())),
                y: Double(Int(cs.appFrame.size.height.rounded()))
            ),
            raw: "",
            elements: flatElements
        )
        return try Codec.foryOK(payload)
    }
}

// MARK: - flat cleaned snapshot -> flat preorder DOM

func serializeDomFlat(from elements: [SnapshotElement]) -> [ForyDomElement] {
    elements.map { element in
        let node = element.node
        var fEl = ForyDomElement()
        fEl.traits = element.traits
        fEl.childCount = Int32(element.childCount)
        if let l = displayName(for: node), !l.isEmpty { fEl.label = l }
        if let value = displayValue(for: node) { fEl.value = value }
        fEl.identifier = node.identifier ?? ""
        fEl.accessibilityLabel = node.label ?? ""
        fEl.labelSource = node.identifier?.isEmpty == false ? "identifier" : node.label?.isEmpty == false ? "label" : "generated"
        if let base = node.identifier ?? node.label, base != fEl.label { fEl.labelSource += "+alias" }
        fEl.rect = makeForyRect(node.frame)
        return fEl
    }
}

// MARK: - walkRaw — raw tree as indented string (--raw mode)

private func nodeRect(_ node: SafeSnapshot) -> String {
    let r = node.frame
    return "\(Int(r.origin.x.rounded())),\(Int(r.origin.y.rounded())),\(Int(r.size.width.rounded())),\(Int(r.size.height.rounded()))"
}

private func formatRawTree(_ node: SafeSnapshot, parentDisabled: Bool, indent: String) -> String {
    let disabled = parentDisabled || !node.isEnabled
    let invisible = !node.isVisible
    let tr = snapshotTraits(for: node, disabled: disabled, invisible: invisible)
    let type = tr[0]
    let flags = tr.dropFirst().joined(separator: ",")
    let traitStr = flags.isEmpty ? type : "\(type),\(flags)"

    let label = displayName(for: node)?.trimmingCharacters(in: .whitespaces)
    let value = displayValue(for: node)?.trimmingCharacters(in: .whitespaces)

    var title: String
    if let l = label, !l.isEmpty {
        title = value.map { "\(l)=\($0)" } ?? l
    } else if let v = value {
        title = "=\(v)"
    } else {
        title = type
    }

    let kids = node.children
    if kids.isEmpty {
        return "\(indent)- \(title) [\(traitStr)] (\(nodeRect(node)))"
    }

    var lines: [String] = ["\(indent)\(title) [\(traitStr)]:"]
    for child in kids {
        lines.append(formatRawTree(child, parentDisabled: disabled, indent: indent + "  "))
    }
    return lines.joined(separator: "\n")
}
