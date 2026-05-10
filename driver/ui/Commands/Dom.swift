import XCTest
import Fory

// MARK: - Dom command (doc 2)

enum DomCommands {
    /// doc 2.2 — nested tree with rule 1-6 applied (or raw if --raw).
    static func dom(_ args: ForyDomArgs, fory: Fory) throws -> ForyResponseFrame {
        let app = try Session.shared.ensureActive()
        let bundleId = Session.shared.bundleId ?? app.value(forKey: "bundleID") as? String ?? ""

        // --raw mode: format the pre-clean snapshot as an indented string.
        if args.raw {
            invalidateSnapshot()
            guard let root = SafeSnapshot(ofApp: app) else {
                return Codec.foryError("failed to take snapshot")
            }
            let lines = formatRawTree(root, parentDisabled: false, indent: "")
            let payload = ForyDomPayload(
                app: bundleId,
                windowSize: ForyPoint(
                    x: Double(Int(root.frame.size.width.rounded())),
                    y: Double(Int(root.frame.size.height.rounded()))
                ),
                raw: lines,
                elements: []
            )
            return try Codec.foryOK(payload, fory: fory)
        }

        // --fresh mode: invalidate cache before taking snapshot.
        if args.fresh {
            invalidateSnapshot()
        }

        guard let cs = getCleanedSnapshot() else {
            return Codec.foryError("failed to take snapshot")
        }
        let flatElements = serializeDomFlat(from: cs.elements)
        let payload = ForyDomPayload(
            app: bundleId,
            windowSize: ForyPoint(
                x: Double(Int(cs.appFrame.size.width.rounded())),
                y: Double(Int(cs.appFrame.size.height.rounded()))
            ),
            raw: "",
            elements: flatElements
        )
        return try Codec.foryOK(payload, fory: fory)
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
        if element.childCount == 0 {
            fEl.rect = makeForyRect(node.frame)
        }
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
