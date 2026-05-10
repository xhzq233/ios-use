import XCTest

// MARK: - Dom command (doc 2)

enum DomCommands {
    /// doc 2.2 — nested tree with rule 1-6 applied (or raw if --raw).
    /// Both containers and leaves may carry `l` when the source node has a label.
    static func dom(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = decodeArgsOptional(rawArgs, as: DomArgs.self)
        let app = try Session.shared.ensureActive()
        let bundleId = Session.shared.bundleId ?? app.value(forKey: "bundleID") as? String ?? ""

        // --raw mode: format the pre-clean snapshot as an indented string.
        if args?.raw == true {
            invalidateSnapshot()
            guard let root = SafeSnapshot(ofApp: app) else {
                return Codec.makeError("failed to take snapshot")
            }
            let lines = formatRawTree(root, parentDisabled: false, indent: "")
            return Codec.makeOK([
                "app": bundleId,
                "window": [Double(Int(root.frame.size.width.rounded())), Double(Int(root.frame.size.height.rounded()))],
                "raw": lines,
            ])
        }

        // --fresh mode: invalidate cache before taking snapshot.
        if args?.fresh == true {
            invalidateSnapshot()
        }

        guard let cs = getCleanedSnapshot() else {
            return Codec.makeError("failed to take snapshot")
        }
        let flatElements = serializeDomFlat(from: cs.elements)
        return Codec.makeOK([
            "app": bundleId,
            "window": [Double(Int(cs.appFrame.size.width.rounded())), Double(Int(cs.appFrame.size.height.rounded()))],
            "elements": flatElements,
        ])
    }
}

// MARK: - flat cleaned snapshot -> flat preorder DOM

func serializeDomFlat(from elements: [SnapshotElement]) -> [[String: Any]] {
    elements.map { element in
        var out: [String: Any] = ["tr": element.traits, "cc": element.childCount]
        let node = element.node
        if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
        if let value = displayValue(for: node) { out["v"] = value }
        if element.childCount == 0 {
            out["r"] = nodeRect(node)
        }
        return out
    }
}

private func nodeRect(_ node: SafeSnapshot) -> [Double] {
    rectArray(node.frame)
}

// MARK: - walkRaw — raw tree as indented string (--raw mode)

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
        let r = nodeRect(node)
        return "\(indent)- \(title) [\(traitStr)] (\(r.map { String(Int($0)) }.joined(separator: ",")))"
    }

    var lines: [String] = ["\(indent)\(title) [\(traitStr)]:"]
    for child in kids {
        lines.append(formatRawTree(child, parentDisabled: disabled, indent: indent + "  "))
    }
    return lines.joined(separator: "\n")
}
