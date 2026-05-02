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

        guard let cs = getCleanedSnapshot() else {
            return Codec.makeError("failed to take snapshot")
        }
        if isSpringBoardApp(app) {
            let springboardElements = buildSpringBoardVisibleDom(from: cs.rawRoot)
            return Codec.makeOK([
                "app": bundleId,
                "window": [Double(Int(cs.appFrame.size.width.rounded())), Double(Int(cs.appFrame.size.height.rounded()))],
                "elements": springboardElements,
            ])
        }
        // Re-walk the raw root but apply rules 1-6 while producing nested output.
        let rootNested = walkClean(cs.rawRoot, parentDisabled: false)
        let cleanElements = (rootNested["__promote"] as? [[String: Any]])
            ?? (rootNested["c"] as? [[String: Any]])
            ?? []
        return Codec.makeOK([
            "app": bundleId,
            "window": [Double(Int(cs.appFrame.size.width.rounded())), Double(Int(cs.appFrame.size.height.rounded()))],
            "elements": cleanElements,
        ])
    }
}

private func buildSpringBoardVisibleDom(from root: SafeSnapshot) -> [[String: Any]] {
    var elements: [[String: Any]] = []
    let dock = findFirstVisibleNode(in: root, where: {
        displayName(for: $0) == "程序坞"
    })
    let dockMinY = dock.map { springBoardVisibleRect($0).minY } ?? root.frame.maxY

    let pageIcons = collectVisibleSpringBoardPageIcons(root, dockMinY: dockMinY)
    if !pageIcons.isEmpty {
        elements.append([
            "tr": ["Group"],
            "l": "Home screen icons",
            "c": pageIcons.map { serializeSpringBoardLeaf($0) },
        ])
    }

    if let spotlight = findFirstVisibleNode(in: root, where: {
        let type = XCUIElement.ElementType(rawValue: UInt($0.elementType)) ?? .other
        return type == .other && displayName(for: $0) == "spotlight-pill"
    }) {
        let node = serializeSpringBoardVisibleSubtree(spotlight, parentDisabled: false)
        if !(node["__skip"] as? Bool ?? false) {
            elements.append(node)
        }
    }

    if let dock {
        let dockIcons = collectVisibleSpringBoardIcons(dock, includeDock: true)
        if !dockIcons.isEmpty {
            elements.append([
                "tr": ["Other"],
                "l": displayName(for: dock) ?? "程序坞",
                "c": dockIcons.map { serializeSpringBoardLeaf($0) },
            ])
        }
    }

    elements.append(contentsOf: collectVisibleStatusBarLeaves(root))
    return elements
}

private func collectVisibleSpringBoardPageIcons(_ root: SafeSnapshot, dockMinY: CGFloat) -> [SafeSnapshot] {
    guard let home = findFirstVisibleNode(in: root, where: {
        displayName(for: $0) == "Home screen icons"
    }) else {
        return []
    }
    let pageRoot = findCurrentSpringBoardIconPage(in: home, dockMinY: dockMinY) ?? home
    return collectSpringBoardLeafIcons(pageRoot, includeDock: false, dockMinY: dockMinY)
}

private func findCurrentSpringBoardIconPage(in root: SafeSnapshot, dockMinY: CGFloat) -> SafeSnapshot? {
    var best: SafeSnapshot?
    var bestCount = 0
    var stack: [SafeSnapshot] = [root]
    while let node = stack.popLast() {
        let type = XCUIElement.ElementType(rawValue: UInt(node.elementType)) ?? .other
        if type == .icon,
           node.isVisible,
           node.frame.width == 0,
           node.frame.height == 0 {
            let count = collectSpringBoardLeafIcons(node, includeDock: false, dockMinY: dockMinY).count
            if count > bestCount {
                best = node
                bestCount = count
            }
        }
        stack.append(contentsOf: node.children.reversed())
    }
    return best
}

private func collectVisibleSpringBoardIcons(_ root: SafeSnapshot, includeDock: Bool) -> [SafeSnapshot] {
    collectSpringBoardLeafIcons(root, includeDock: includeDock, dockMinY: .greatestFiniteMagnitude)
}

private func collectSpringBoardLeafIcons(_ root: SafeSnapshot, includeDock: Bool, dockMinY: CGFloat) -> [SafeSnapshot] {
    var icons: [SafeSnapshot] = []
    var stack: [SafeSnapshot] = [root]
    while let node = stack.popLast() {
        if isVisibleSpringBoardLeafIcon(node, includeDock: includeDock, dockMinY: dockMinY) {
            icons.append(node)
            continue
        }
        stack.append(contentsOf: node.children.reversed())
    }
    return icons
}

private func isVisibleSpringBoardLeafIcon(_ node: SafeSnapshot, includeDock: Bool, dockMinY: CGFloat) -> Bool {
    let type = XCUIElement.ElementType(rawValue: UInt(node.elementType)) ?? .other
    guard type == .icon,
          node.isVisible,
          let name = displayName(for: node),
          !name.isEmpty else {
        return false
    }

    let rect = springBoardVisibleRect(node)
    guard rect.width > 0, rect.height > 0 else {
        return false
    }

    let inDock = hasAncestor(node, withLabel: "程序坞")
    guard inDock == includeDock else {
        return false
    }

    if !includeDock, dockMinY.isFinite, rect.maxY > dockMinY {
        return false
    }
    return true
}

private func springBoardVisibleRect(_ node: SafeSnapshot) -> CGRect {
    let visible = node.visibleFrame
    if visible.width > 0, visible.height > 0 {
        return visible
    }
    return node.frame
}

private func findFirstVisibleNode(in root: SafeSnapshot, where predicate: (SafeSnapshot) -> Bool) -> SafeSnapshot? {
    var stack: [SafeSnapshot] = [root]
    while let node = stack.popLast() {
        if node.isVisible && predicate(node) {
            return node
        }
        stack.append(contentsOf: node.children.reversed())
    }
    return nil
}

private func collectVisibleStatusBarLeaves(_ root: SafeSnapshot) -> [[String: Any]] {
    var leaves: [[String: Any]] = []
    var stack: [SafeSnapshot] = [root]
    while let node = stack.popLast() {
        let type = XCUIElement.ElementType(rawValue: UInt(node.elementType)) ?? .other
        if hasAncestor(node, ofType: "StatusBar"),
           node.isVisible,
           node.children.isEmpty,
           let name = displayName(for: node),
           !name.isEmpty {
            var leaf: [String: Any] = [
                "tr": snapshotTraits(for: node, disabled: !node.isEnabled, invisible: false),
                "l": name,
                "r": nodeRect(node),
            ]
            if let value = displayValue(for: node) {
                leaf["v"] = value
            }
            leaves.append(leaf)
            continue
        }
        if type == .statusBar || hasAncestor(node, ofType: "StatusBar") || type == .window || type == .other {
            stack.append(contentsOf: node.children.reversed())
        }
    }
    return mergeSiblingsNested(leaves)
}

private func serializeSpringBoardLeaf(_ node: SafeSnapshot) -> [String: Any] {
    var out: [String: Any] = [
        "tr": snapshotTraits(for: node, disabled: !node.isEnabled, invisible: !node.isVisible),
        "l": displayName(for: node) ?? elementTypeName(XCUIElement.ElementType(rawValue: UInt(node.elementType)) ?? .other),
        "r": rectArray(springBoardVisibleRect(node)),
    ]
    if let value = displayValue(for: node) {
        out["v"] = value
    }
    return out
}

private func serializeSpringBoardVisibleSubtree(_ node: SafeSnapshot, parentDisabled: Bool) -> [String: Any] {
    if !node.isVisible {
        return ["__skip": true]
    }

    let type = XCUIElement.ElementType(rawValue: UInt(node.elementType)) ?? .other
    let disabled = parentDisabled || !node.isEnabled

    if type == .icon, node.frame.width > 0, node.frame.height > 0 {
        return serializeSpringBoardLeaf(node)
    }

    if type == .window || (type == .other && displayName(for: node) == nil) {
        var kids: [[String: Any]] = []
        for child in node.children {
            let r = serializeSpringBoardVisibleSubtree(child, parentDisabled: disabled)
            if let promoted = r["__promote"] as? [[String: Any]] {
                kids.append(contentsOf: promoted)
            } else if !(r["__skip"] as? Bool ?? false) {
                kids.append(r)
            }
        }
        return ["__promote": mergeSiblingsNested(kids)]
    }

    var kids: [[String: Any]] = []
    for child in node.children {
        let r = serializeSpringBoardVisibleSubtree(child, parentDisabled: disabled)
        if let promoted = r["__promote"] as? [[String: Any]] {
            kids.append(contentsOf: promoted)
        } else if !(r["__skip"] as? Bool ?? false) {
            kids.append(r)
        }
    }
    kids = mergeSiblingsNested(kids)

    if displayName(for: node) == nil && kids.isEmpty {
        return ["__skip": true]
    }

    let tr = snapshotTraits(for: node, disabled: disabled, invisible: false)
    if displayName(for: node) == nil && !kids.isEmpty {
        return ["__promote": kids]
    }

    if !kids.isEmpty {
        var out: [String: Any] = ["tr": tr, "c": kids]
        if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
        if let value = displayValue(for: node) { out["v"] = value }
        return out
    }

    var out: [String: Any] = ["tr": tr, "r": nodeRect(node)]
    if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
    if let value = displayValue(for: node) { out["v"] = value }
    return out
}

// MARK: - walkClean — produces nested tree applying rules 1-6 (doc 2.2)

/// Returns a dict which is either:
///   container: { "tr": [...], "c": [...] }
///   leaf:      { "tr": [...], "l"?: label, "r": [x,y,w,h] }
///   or a sentinel dict { "__promote": [...] } whose children should be promoted.
/// Time complexity: O(n + s) over the whole tree, where n is the number of
/// visited nodes and s is the total sibling comparisons performed by
/// `mergeSiblingsNested`.
private func walkClean(_ node: SafeSnapshot, parentDisabled: Bool) -> [String: Any] {
    let rawType = UInt(node.elementType)
    let type = XCUIElement.ElementType(rawValue: rawType) ?? .other
    let typeName = elementTypeName(type)
    let disabled = parentDisabled || !node.isEnabled
    let invisible = !node.isVisible

    if type == .icon {
        let frame = node.frame
        if frame.width > 0, frame.height > 0 {
            var out: [String: Any] = ["tr": snapshotTraits(for: node, disabled: disabled, invisible: invisible), "r": nodeRect(node)]
            if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
            if let value = displayValue(for: node) { out["v"] = value }
            return out
        }
    }

    // Rule 1: SKIP_TYPES — Window / (Other with no label). Promote children.
    if type == .window || (type == .other && displayName(for: node) == nil) {
        var kids: [[String: Any]] = []
        for child in node.children {
            let r = walkClean(child, parentDisabled: disabled)
            if let promoted = r["__promote"] as? [[String: Any]] {
                kids.append(contentsOf: promoted)
            } else if let stamp = r["__skip"] as? Bool, stamp {
                continue
            } else {
                kids.append(r)
            }
        }
        kids = mergeSiblingsNested(kids)
        return ["__promote": kids]
    }

    // Process children first.
    var kids: [[String: Any]] = []
    for child in node.children {
        let r = walkClean(child, parentDisabled: disabled)
        if let promoted = r["__promote"] as? [[String: Any]] {
            kids.append(contentsOf: promoted)
        } else if let stamp = r["__skip"] as? Bool, stamp {
            continue
        } else {
            kids.append(r)
        }
    }
    kids = mergeSiblingsNested(kids)

    // Rule 3: empty leaf trim — no label + no children.
    if displayName(for: node) == nil && kids.isEmpty {
        return ["__skip": true]
    }

    let tr = snapshotTraits(for: node, disabled: disabled, invisible: invisible)

    // Rule 5: content-less container promote.
    // Keep invisible containers, since doc 2.4 explicitly says invisible nodes
    // must stay in the tree and be marked via traits.
    if displayName(for: node) == nil && !kids.isEmpty && !invisible {
        return ["__promote": kids]
    }

    // Rule 4: single-child same-type merge.
    if kids.count == 1,
       let childTr = kids[0]["tr"] as? [String],
       childTr.first == typeName,
       (kids[0]["l"] as? String) == displayName(for: node),
       let childR = kids[0]["r"] as? [Double],
       rectApproxEqualArr(childR, nodeRect(node)) {
        // Merge: drop the redundant child layer.
        kids = []
    }

    // Compose container vs leaf.
    if !kids.isEmpty {
        var out: [String: Any] = ["tr": tr, "c": kids]
        if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
        if let value = displayValue(for: node) { out["v"] = value }
        return out
    }
    // Leaf
    var out: [String: Any] = ["tr": tr, "r": nodeRect(node)]
    if let l = displayName(for: node), !l.isEmpty { out["l"] = l }
    if let value = displayValue(for: node) { out["v"] = value }
    return out
}

/// Constant-time rect serialization helper for DOM leaves.
/// Time complexity: O(1).
private func nodeRect(_ node: SafeSnapshot) -> [Double] {
    rectArray(node.frame)
}

/// Compares two serialized rect arrays element-by-element.
/// Time complexity: O(1).
private func rectApproxEqualArr(_ a: [Double], _ b: [Double], epsilon: Double = 0.5) -> Bool {
    guard a.count == 4, b.count == 4 else { return false }
    for i in 0..<4 {
        if abs(a[i] - b[i]) > epsilon { return false }
    }
    return true
}

/// Rule 6: adjacent sibling same-type merge (same tr + l + ~rect).
/// Time complexity: O(k), where k is the number of sibling nodes at this level.
private func mergeSiblingsNested(_ nodes: [[String: Any]]) -> [[String: Any]] {
    if nodes.count <= 1 { return nodes }
    var out: [[String: Any]] = [nodes[0]]
    for i in 1..<nodes.count {
        let prev = out.last!
        let curr = nodes[i]
        let prevTr = prev["tr"] as? [String] ?? []
        let currTr = curr["tr"] as? [String] ?? []
        let prevL = prev["l"] as? String
        let currL = curr["l"] as? String
        let prevR = prev["r"] as? [Double]
        let currR = curr["r"] as? [Double]
        let prevC = prev["c"] as? [[String: Any]]
        let currC = curr["c"] as? [[String: Any]]

        let sameRect: Bool = {
            if let pr = prevR, let cr = currR { return rectApproxEqualArr(pr, cr) }
            return prevR == nil && currR == nil
        }()

        // Both must be either leaves or containers to consider merging.
        if prevTr == currTr && prevL == currL && sameRect && (prevC == nil) == (currC == nil) {
            continue
        }
        out.append(curr)
    }
    return out
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
