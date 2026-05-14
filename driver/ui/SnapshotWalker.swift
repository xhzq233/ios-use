import XCTest

// MARK: - Cleaned Snapshot (doc 4.3)

/// The cleaned snapshot: root survives unchanged, but `elements` is a flat
/// post-rule-1..6 view used by find/swipe/waitFor/etc.
struct CleanedSnapshot {
    let root: SafeSnapshot
    let appFrame: CGRect
    let rawRoot: SafeSnapshot
    let elements: [SnapshotElement]
    let searchEntries: [SearchEntry]
    let searchCandidates: [SearchCandidate]
}

struct SnapshotElement {
    let node: SafeSnapshot
    let traits: [String]           // [type, ...flags]
    let disabled: Bool
    let invisible: Bool
    let childCount: Int

    var isVisible: Bool { !invisible }
}

private struct CleanSubtree {
    let records: [SnapshotElement]
}

private enum CleanBuildResult {
    case skip
    case keep(CleanSubtree)
    case promote([CleanSubtree])
}

struct SearchEntry {
    let element: SnapshotElement
    let rawTexts: [String]
    let normalizedTexts: [String]
}

struct SearchCandidate {
    let displayText: String
    let normalizedText: String
}

private let scrollableElementTypes: Set<UInt> = [
    XCUIElement.ElementType.scrollView.rawValue,
    XCUIElement.ElementType.collectionView.rawValue,
    XCUIElement.ElementType.table.rawValue,
    XCUIElement.ElementType.webView.rawValue,
]

private let cellLikeElementTypes: Set<UInt> = [
    XCUIElement.ElementType.cell.rawValue,
    XCUIElement.ElementType.icon.rawValue,
]

func displayName(for node: SafeSnapshot) -> String? {
    if let identifier = node.identifier, !identifier.isEmpty {
        return identifier
    }
    if let label = node.label, !label.isEmpty {
        return label
    }
    return nil
}

func snapshotTraits(for node: SafeSnapshot, disabled: Bool, invisible: Bool) -> [String] {
    let typeName = elementTypeName(XCUIElement.ElementType(rawValue: UInt(node.elementType)) ?? .other)
    var traits: [String] = [typeName]
    if disabled { traits.append("disabled") }
    if invisible { traits.append("invisible") }
    if node.isSelected { traits.append("selected") }
    if node.hasFocus || node.hasKeyboardFocus { traits.append("focused") }
    return traits
}

func displayValue(for node: SafeSnapshot) -> String? {
    guard let value = node.value, !value.isEmpty else { return nil }
    if let name = displayName(for: node), name == value {
        return nil
    }
    return value
}

// MARK: - Cache (doc 4.3)

/// Global cached snapshot. Invalidated by tap/swipe/input/longPress.
private var _cachedSnapshot: CleanedSnapshot?
private var _cachedAt: TimeInterval = 0
private let _snapshotLock = NSLock()
private let _cacheTTL: TimeInterval = SnapshotConstants.cacheTTLSeconds

/// doc 4.3 — all commands share the same entry point.
/// Returns a cached snapshot if available; otherwise builds a fresh one.
/// Time complexity: O(1) on cache hit; O(n) on cache miss, where n is the
/// number of nodes in the snapshot tree.
func getCleanedSnapshot() -> CleanedSnapshot? {
    _snapshotLock.lock()
    if let cached = _cachedSnapshot, Date().timeIntervalSince1970 - _cachedAt < _cacheTTL {
        _snapshotLock.unlock()
        return cached
    }
    _snapshotLock.unlock()

    guard let fresh = rebuildCleanedSnapshot() else { return nil }

    _snapshotLock.lock()
    _cachedSnapshot = fresh
    _cachedAt = Date().timeIntervalSince1970
    _snapshotLock.unlock()
    return fresh
}

/// Force a fresh snapshot (no cache). Used by waitFor and mutation post-checks.
/// Time complexity: O(n), where n is the number of nodes traversed by
/// `cleanTree` while rebuilding the flat index.
func rebuildCleanedSnapshot() -> CleanedSnapshot? {
    guard let app = try? Session.shared.ensureActive() else { return nil }
    guard let raw = SafeSnapshot(ofApp: app) else { return nil }

    let elements = buildCleanElements(from: raw)

    let searchEntries = buildSearchEntries(from: elements)
    let searchCandidates = buildSearchCandidates(from: searchEntries)

    return CleanedSnapshot(
        root: raw,
        appFrame: app.frame,
        rawRoot: raw,
        elements: elements,
        searchEntries: searchEntries,
        searchCandidates: searchCandidates
    )
}

// Build the single flat preorder stream consumed by find/search/indexing and
// later re-parsed by `dom`. `cleanTree` keeps promote boundaries in
// `CleanBuildResult`; this step only linearizes those already-built subtrees.
func buildCleanElements(from root: SafeSnapshot) -> [SnapshotElement] {
    flattenCleanBuildResult(cleanTree(root, parentDisabled: false))
}

private func buildSearchEntries(from elements: [SnapshotElement]) -> [SearchEntry] {
    var entries: [SearchEntry] = []
    entries.reserveCapacity(elements.count)
    for element in elements {
        let rawTexts = searchableTexts(for: element.node)
        guard !rawTexts.isEmpty else { continue }
        let normalizedTexts = normalizedSearchableTexts(from: rawTexts)
        guard !normalizedTexts.isEmpty else { continue }
        entries.append(SearchEntry(
            element: element,
            rawTexts: rawTexts,
            normalizedTexts: normalizedTexts
        ))
    }
    return entries
}

private func buildSearchCandidates(from entries: [SearchEntry]) -> [SearchCandidate] {
    var seen: Set<String> = []
    seen.reserveCapacity(entries.count * 2)
    var candidates: [SearchCandidate] = []
    candidates.reserveCapacity(entries.count * 2)
    for entry in entries {
        for text in entry.rawTexts {
            let normalized = normalizeSearchText(text)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            candidates.append(SearchCandidate(displayText: text, normalizedText: normalized))
        }
    }
    return candidates
}

func isSpringBoardApp(_ app: XCUIApplication) -> Bool {
    (app.value(forKey: "bundleID") as? String) == DriverBundleConstants.springboardBundleId
}

/// doc 4.3 — mutations (tap/swipe/input/longPress) must invalidate the cache.
func invalidateSnapshot() {
    _snapshotLock.lock()
    _cachedSnapshot = nil
    _cachedAt = 0
    _snapshotLock.unlock()
}

// MARK: - cleanTree (doc 2.4: rules 1-6)

/// Apply clean-tree rules during a recursive DFS. Children are processed
/// first so we can observe (and merge) sibling equivalents.
///
/// Rules (doc 2.5):
///   1. SKIP_TYPES promote (Window, empty Other)
///   2. disabled propagation via parentDisabled
///   3. empty-leaf trim (no label, no children)
///   4. single-child same-type merge (same type + rect + label)
///   5. content-less container promote (no label, has children) — folded into rule 1
/// Time complexity: O(n) over the whole tree, where n is the number of
/// visited nodes.
private func cleanTree(
    _ node: SafeSnapshot,
    parentDisabled: Bool
) -> CleanBuildResult {
    let rawType = UInt(node.elementType)
    let type = XCUIElement.ElementType(rawValue: rawType) ?? .other
    let disabled = parentDisabled || !node.isEnabled
    let invisible = !node.isVisible

    // Rule 1: SKIP_TYPES — Window OR (Other with no label, regardless of
    // child count). Rule 5 is a subset of Rule 1 (content-less container).
    //  M7 fix: don't hide Other with <=1 child — always promote when label nil.
    if type == .window || (type == .other && displayName(for: node) == nil) {
        var promoted: [CleanSubtree] = []
        promoted.reserveCapacity(node.children.count)
        for child in node.children {
            switch cleanTree(child, parentDisabled: disabled) {
            case .skip:
                continue
            case .keep(let subtree):
                promoted.append(subtree)
            case .promote(let subtrees):
                promoted.append(contentsOf: subtrees)
            }
        }
        return promoted.isEmpty ? .skip : .promote(promoted)
    }

    // Collect this node's kept descendants separately so we can apply
    // single-child merge (rule 4) locally.
    var childSubtrees: [CleanSubtree] = []
    childSubtrees.reserveCapacity(node.children.count)

    for child in node.children {
        switch cleanTree(child, parentDisabled: disabled) {
        case .skip:
            continue
        case .keep(let subtree):
            childSubtrees.append(subtree)
        case .promote(let subtrees):
            childSubtrees.append(contentsOf: subtrees)
        }
    }

    // Rule 3: empty leaf trim. Keep leaves that have a display value even
    // when label/identifier is nil (e.g. Switch with value "0" or "1").
    if displayName(for: node) == nil && displayValue(for: node) == nil && childSubtrees.isEmpty {
        return .skip
    }

    // SpringBoard / desktop icons already carry the semantic node we want.
    // Keep them as leaves so we don't walk decorative descendants and we
    // retain their original snapshot frame instead of rebuilding via fallback.
    if type == .icon {
        let frame = node.frame
        if frame.width > 0, frame.height > 0 {
            childSubtrees = []
        }
    }

    // Build traits: [typeName, disabled?, invisible?, selected?, focused?]
    let traits = snapshotTraits(for: node, disabled: disabled, invisible: invisible)
    var subtree: [SnapshotElement] = []
    subtree.reserveCapacity(1 + childSubtrees.reduce(0) { $0 + $1.records.count })
    subtree.append(SnapshotElement(
        node: node,
        traits: traits,
        disabled: disabled,
        invisible: invisible,
        childCount: 0
    ))

    // Rule 4: single-child same-type merge — if this node has exactly one kept
    // child and that child is same type + same rect + same label, keep only
    // the parent and adopt the child's descendants.
    var effectiveSubtrees = childSubtrees
    if effectiveSubtrees.count == 1, let childRoot = effectiveSubtrees[0].records.first {
        if sameElementType(childRoot.node, node)
            && rectApproxEqual(childRoot.node.frame, node.frame)
            && displayName(for: childRoot.node) == displayName(for: node) {
            let childRecords = effectiveSubtrees[0].records
            let mergedRoot = SnapshotElement(
                node: node,
                traits: traits,
                disabled: disabled,
                invisible: invisible,
                childCount: childRoot.childCount
            )
            var mergedRecords: [SnapshotElement] = []
            mergedRecords.reserveCapacity(childRecords.count)
            mergedRecords.append(mergedRoot)
            if childRecords.count > 1 {
                mergedRecords.append(contentsOf: childRecords.dropFirst())
            }
            return .keep(CleanSubtree(records: mergedRecords))
        }
    }

    // Rule 6: parent-child same-label merge — if this node has exactly one kept
    // child and both share the same display name, merge traits (including type)
    // and keep the child's descendants. The parent node survives as the merged
    // root so its frame/value are retained.
    if effectiveSubtrees.count == 1,
       let childRecords = effectiveSubtrees.first?.records,
       !childRecords.isEmpty,
       let parentName = displayName(for: node),
       parentName == displayName(for: childRecords[0].node) {
        var mergedTraits = traits
        for t in childRecords[0].traits where !mergedTraits.contains(t) {
            mergedTraits.append(t)
        }
        let mergedRoot = SnapshotElement(
            node: node,
            traits: mergedTraits,
            disabled: disabled,
            invisible: invisible,
            childCount: childRecords[0].childCount
        )
        var mergedRecords: [SnapshotElement] = []
        mergedRecords.reserveCapacity(childRecords.count)
        mergedRecords.append(mergedRoot)
        if childRecords.count > 1 {
            mergedRecords.append(contentsOf: childRecords.dropFirst())
        }
        return .keep(CleanSubtree(records: mergedRecords))
    }

    subtree[0] = SnapshotElement(
        node: node,
        traits: traits,
        disabled: disabled,
        invisible: invisible,
        childCount: effectiveSubtrees.count
    )
    for childSubtree in effectiveSubtrees {
        subtree.append(contentsOf: childSubtree.records)
    }

    return .keep(CleanSubtree(records: subtree))
}

// MARK: - helpers

private func flattenCleanBuildResult(_ result: CleanBuildResult) -> [SnapshotElement] {
    switch result {
    case .skip:
        return []
    case .keep(let subtree):
        return subtree.records
    case .promote(let subtrees):
        // `records` already contains each subtree's full preorder encoding.
        // `flatMap(\.records)` only concatenates sibling subtrees into one
        // flat stream; it does not recurse or rebuild tree structure here.
        var records: [SnapshotElement] = []
        records.reserveCapacity(subtrees.reduce(0) { $0 + $1.records.count })
        for subtree in subtrees {
            records.append(contentsOf: subtree.records)
        }
        return records
    }
}

private func sameElementType(_ a: SafeSnapshot, _ b: SafeSnapshot) -> Bool {
    a.elementType == b.elementType
}

private func rectApproxEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat = SnapshotConstants.rectApproxEqualEpsilon) -> Bool {
    abs(a.origin.x - b.origin.x) <= epsilon
        && abs(a.origin.y - b.origin.y) <= epsilon
        && abs(a.size.width - b.size.width) <= epsilon
        && abs(a.size.height - b.size.height) <= epsilon
}

// MARK: - ancestor chain helpers (doc 4.2)

func hasAncestor(_ node: SafeSnapshot, ofType typeName: String) -> Bool {
    var cur = node.parent
    while let p = cur {
        if elementTypeName(XCUIElement.ElementType(rawValue: UInt(p.elementType)) ?? .other) == typeName {
            return true
        }
        cur = p.parent
    }
    return false
}

func hasAncestor(_ node: SafeSnapshot, withLabel label: String) -> Bool {
    var cur = node.parent
    while let p = cur {
        if p.label == label || displayName(for: p) == label { return true }
        cur = p.parent
    }
    return false
}

// MARK: - findLargestScrollable (doc 5.3)

/// Single DFS that picks the largest scrollable container by area.
/// Time complexity: O(n), where n is the number of nodes in the subtree.
func findLargestScrollable(_ root: SafeSnapshot) -> SafeSnapshot? {
    var best: SafeSnapshot?
    var bestArea: CGFloat = 0
    var stack: [SafeSnapshot] = [root]
    while let node = stack.popLast() {
        if scrollableElementTypes.contains(UInt(node.elementType)) {
            let a = node.frame.width * node.frame.height
            if a > bestArea { best = node; bestArea = a }
        }
        for c in node.children { stack.append(c) }
    }
    return best
}

// MARK: - findScrollableAncestor (doc 5.1 STEP 4)

/// Walks the parent chain and validates candidate containers by visible cells.
/// Time complexity: O(h * n_sub) in the worst case, where h is ancestor depth
/// and n_sub is the size of each checked ancestor subtree.
func findScrollableAncestor(_ node: SafeSnapshot) -> SafeSnapshot? {
    var cur: SafeSnapshot? = node.parent
    while let p = cur {
        if scrollableElementTypes.contains(UInt(p.elementType))
            && p.isVisible
            && p.frame.width > 0 && p.frame.height > 0 {
            let frames = collectVisibleCellFrames(p, limit: 2)
            if frames.count > 1 { return p }
        }
        cur = p.parent
    }
    return nil
}

// MARK: - findScrollableAtPoint (doc 5.2)

/// Chooses the smallest scrollable whose frame contains the target point.
/// Time complexity: O(n), where n is the number of nodes in the subtree.
func findScrollableAtPoint(_ point: CGPoint, _ root: SafeSnapshot) -> SafeSnapshot? {
    var best: SafeSnapshot?
    var bestArea: CGFloat = .greatestFiniteMagnitude
    var stack: [SafeSnapshot] = [root]
    while let node = stack.popLast() {
        if scrollableElementTypes.contains(UInt(node.elementType))
            && node.isVisible
            && node.frame.width > 0 && node.frame.height > 0
            && node.frame.contains(point) {
            let a = node.frame.width * node.frame.height
            if a < bestArea { best = node; bestArea = a }
        }
        for c in node.children { stack.append(c) }
    }
    return best
}

// MARK: - collectCellSnapshots (doc 5.5 — three-tier fallback)

/// Searches a scrollable subtree with a three-tier fallback: Cell -> Icon ->
/// allDescendants.
/// Time complexity: O(n), where n is the number of descendants in the
/// scrollable subtree.
func collectCellSnapshots(_ scrollView: SafeSnapshot) -> [SafeSnapshot] {
    // 1) Cell
    let cells = descendantsOfType(scrollView, elementType: UInt(XCUIElement.ElementType.cell.rawValue))
    if !cells.isEmpty { return cells }
    // 2) Icon (SpringBoard springboard home screen)
    let icons = descendantsOfType(scrollView, elementType: UInt(XCUIElement.ElementType.icon.rawValue))
    if !icons.isEmpty { return icons }
    // 3) All descendants (bottom-of-barrel fallback)
    return scrollView.allDescendants
}

/// Early-terminating variant: collects up to `limit` visible cell/icon frames.
/// Used by boundary detection in scroll loops — only needs a few anchor frames
/// to detect movement, not the full cell list.
func collectVisibleCellFrames(_ scrollView: SafeSnapshot, limit: Int = 3) -> [CGRect] {
    var frames: [CGRect] = []
    frames.reserveCapacity(limit)
    var stack: [SafeSnapshot] = [scrollView]
    while let n = stack.popLast() {
        if cellLikeElementTypes.contains(UInt(n.elementType)) && n.isVisible {
            frames.append(n.frame)
            if frames.count >= limit { return frames }
        }
        for c in n.children.reversed() { stack.append(c) }
    }
    // Fallback: if no Cell/Icon found, use any visible descendant
    if frames.isEmpty {
        var fallback: [SafeSnapshot] = [scrollView]
        while let n = fallback.popLast() {
            if n.isVisible && n !== scrollView {
                frames.append(n.frame)
                if frames.count >= limit { return frames }
            }
            for c in n.children.reversed() { fallback.append(c) }
        }
    }
    return frames
}

/// Iterative DFS over the subtree rooted at `root`.
/// Time complexity: O(n), where n is the number of nodes in the subtree.
private func descendantsOfType(_ root: SafeSnapshot, elementType: UInt) -> [SafeSnapshot] {
    var out: [SafeSnapshot] = []
    var stack: [SafeSnapshot] = [root]
    while let n = stack.popLast() {
        if UInt(n.elementType) == elementType { out.append(n) }
        // Reverse children so DFS visits them in original order (top-to-bottom).
        for c in n.children.reversed() { stack.append(c) }
    }
    return out
}

// MARK: - findCellAncestor (doc 5.1 STEP 5)

/// Walks upward until the nearest Cell/Icon ancestor is found.
/// Time complexity: O(h), where h is the parent-chain depth.
func findCellAncestor(_ node: SafeSnapshot) -> SafeSnapshot {
    let t = UInt(node.elementType)
    if t == XCUIElement.ElementType.cell.rawValue || t == XCUIElement.ElementType.icon.rawValue {
        return node
    }
    var cur: SafeSnapshot? = node.parent
    while let p = cur {
        let pt = UInt(p.elementType)
        if pt == XCUIElement.ElementType.cell.rawValue || pt == XCUIElement.ElementType.icon.rawValue {
            return p
        }
        cur = p.parent
    }
    return node  // fallback: use node itself if no cell ancestor
}

/// Time complexity: O(1).
private func effectiveVisibleFrame(_ node: SafeSnapshot) -> CGRect {
    node.visibleFrame
}

/// Time complexity: O(1).
func hasEffectiveVisibleGeometry(_ node: SafeSnapshot, in bounds: CGRect) -> Bool {
    let frame = effectiveVisibleFrame(node)
    guard frame.width > 0, frame.height > 0, bounds.width > 0, bounds.height > 0 else {
        return false
    }
    let clipped = frame.intersection(bounds)
    return clipped.width > 0 && clipped.height > 0
}

/// Time complexity: O(1).
func isVisibleWithEffectiveGeometry(_ element: SnapshotElement, in bounds: CGRect) -> Bool {
    element.isVisible && hasEffectiveVisibleGeometry(element.node, in: bounds)
}

// MARK: - Element type name

func elementTypeName(_ type: XCUIElement.ElementType) -> String {
    switch type {
    case .any: return "Any"
    case .other: return "-"
    case .application: return "Application"
    case .group: return "Group"
    case .window: return "Window"
    case .sheet: return "Sheet"
    case .alert: return "Alert"
    case .button: return "Button"
    case .cell: return "Cell"
    case .staticText: return "StaticText"
    case .textField: return "TextField"
    case .secureTextField: return "SecureTextField"
    case .textView: return "TextView"
    case .searchField: return "SearchField"
    case .image: return "Image"
    case .icon: return "Icon"
    case .link: return "Link"
    case .switch: return "Switch"
    case .slider: return "Slider"
    case .tabBar: return "TabBar"
    case .tab: return "Tab"
    case .toolbar: return "Toolbar"
    case .navigationBar: return "NavigationBar"
    case .table: return "Table"
    case .tableRow: return "TableRow"
    case .tableColumn: return "TableColumn"
    case .collectionView: return "CollectionView"
    case .scrollView: return "ScrollView"
    case .webView: return "WebView"
    case .picker: return "Picker"
    case .pickerWheel: return "PickerWheel"
    case .segmentedControl: return "SegmentedControl"
    case .datePicker: return "DatePicker"
    case .pageIndicator: return "PageIndicator"
    case .progressIndicator: return "ProgressIndicator"
    case .activityIndicator: return "ActivityIndicator"
    case .stepper: return "Stepper"
    case .menu: return "Menu"
    case .menuItem: return "MenuItem"
    case .menuBar: return "MenuBar"
    case .keyboard: return "Keyboard"
    case .key: return "Key"
    case .statusBar: return "StatusBar"
    case .map: return "Map"
    case .browser: return "Browser"
    default: return "Other"
    }
}
