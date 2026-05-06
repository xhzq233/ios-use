import XCTest

// MARK: - Dom command (doc 2)

enum DomCommands {
    /// doc 2.2 — nested tree with rule 1-6 applied (or raw if --raw).
    /// Both containers and leaves may carry `l` when the source node has a label.
    static func dom(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = decodeArgsOptional(rawArgs, as: DomArgs.self)
        let app = try Session.shared.ensureActive()
        let bundleId = Session.shared.bundleId ?? app.value(forKey: "bundleID") as? String ?? ""

        // --raw mode: return the pre-clean snapshot as nested nodes for debugging.
        if args?.raw == true {
            guard let root = SafeSnapshot(ofApp: app) else {
                return Codec.makeError("failed to take snapshot")
            }
            let rootNode = walkRaw(root, parentDisabled: false)
            return Codec.makeOK([
                "app": bundleId,
                "window": [Double(Int(root.frame.size.width.rounded())), Double(Int(root.frame.size.height.rounded()))],
                "elements": rootNode["c"] as? [[String: Any]] ?? [],
            ])
        }

        // --fresh mode: invalidate cache before taking snapshot.
        if args?.fresh == true {
            invalidateSnapshot()
        }

        guard let cs = getCleanedSnapshot() else {
            return Codec.makeError("failed to take snapshot")
        }
        let cleanElements = serializeDomForest(from: cs.elements)
        return Codec.makeOK([
            "app": bundleId,
            "window": [Double(Int(cs.appFrame.size.width.rounded())), Double(Int(cs.appFrame.size.height.rounded()))],
            "elements": cleanElements,
        ])
    }
}

// MARK: - flat cleaned snapshot -> nested DOM

func serializeDomForest(from elements: [SnapshotElement]) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var index = 0
    while index < elements.count {
        let (node, nextIndex) = serializeDomNode(elements, at: index)
        out.append(node)
        index = nextIndex
    }
    return out
}

private func serializeDomNode(_ elements: [SnapshotElement], at index: Int) -> ([String: Any], Int) {
    let element = elements[index]
    let node = element.node

    if element.childCount == 0 {
        var out: [String: Any] = ["tr": element.traits, "r": nodeRect(node)]
        if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
        if let value = displayValue(for: node) { out["v"] = value }
        return (out, index + 1)
    }

    var children: [[String: Any]] = []
    var childIndex = index + 1
    for _ in 0..<element.childCount {
        guard childIndex < elements.count else { break }
        let (childNode, nextChildIndex) = serializeDomNode(elements, at: childIndex)
        children.append(childNode)
        childIndex = nextChildIndex
    }

    var out: [String: Any] = ["tr": element.traits, "c": children]
    if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
    if let value = displayValue(for: node) { out["v"] = value }
    return (out, childIndex)
}

/// Constant-time rect serialization helper for DOM leaves.
/// Time complexity: O(1).
private func nodeRect(_ node: SafeSnapshot) -> [Double] {
    rectArray(node.frame)
}

// MARK: - walkRaw — raw nested tree (--raw mode, doc 2.5)

/// Raw DFS serializer used for debugging output without clean-tree rules.
/// Time complexity: O(n), where n is the number of nodes in the subtree.
private func walkRaw(_ node: SafeSnapshot, parentDisabled: Bool) -> [String: Any] {
    let disabled = parentDisabled || !node.isEnabled
    let invisible = !node.isVisible

    let tr = snapshotTraits(for: node, disabled: disabled, invisible: invisible)

    var out: [String: Any] = ["tr": tr]
    if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
    if let value = displayValue(for: node) { out["v"] = value }

    let kids = node.children.map { walkRaw($0, parentDisabled: disabled) }
    if !kids.isEmpty {
        out["c"] = kids
    } else {
        out["r"] = nodeRect(node)
    }
    return out
}
