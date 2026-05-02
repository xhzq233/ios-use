import XCTest

// MARK: - FindResult (doc 6.1)

enum FindResult {
    case found(SnapshotElement)
    case ambiguous(matches: [SnapshotElement])
    case fuzzy(suggestions: [String])
    case notFound(suggestions: [String])
}

// MARK: - rawFind (doc 6.1)

/// Unified label search against an explicit cleaned snapshot.
/// This is the single source of truth for all label-based command semantics.
/// Time complexity: O(m * h + c * q * t) in the worst case, where m is the
/// number of exact-label matches, h is ancestor depth for context filtering,
/// c is candidate label count, q is query length, and t is candidate length
/// used by fuzzy fallback.
func rawFindInSnapshot(_ label: String, context: LabelContext?, cs: CleanedSnapshot) -> FindResult {
    // 1. Exact match
    var matches = cs.byLabel[label] ?? []

    // 2. Fuzzy fallback when exact empty
    if matches.isEmpty {
        let suggestions = fuzzySuggestions(for: label, from: Array(cs.byLabel.keys))
        if !suggestions.isEmpty { return .fuzzy(suggestions: suggestions) }
        return .notFound(suggestions: [])
    }

    // 3. Context filter (ancestorType / ancestorLabel) — sweep parent chain
    if let at = context?.ancestorType {
        matches = matches.filter { hasAncestor($0.node, ofType: at) }
    }
    if let al = context?.ancestorLabel {
        matches = matches.filter { hasAncestor($0.node, withLabel: al) }
    }

    matches = finalizeFindMatches(matches, query: label)

    if matches.isEmpty { return .notFound(suggestions: []) }
    if matches.count > 1 { return .ambiguous(matches: matches) }
    return .found(matches[0])
}

/// Unified label search: exact → fuzzy → context filter.
/// Used by all label-based commands (find, tap, longPress, input, swipe, waitFor).
func rawFind(_ label: String, context: LabelContext?) -> FindResult {
    guard let cs = getCleanedSnapshot() else {
        return .notFound(suggestions: [])
    }
    return rawFindInSnapshot(label, context: context, cs: cs)
}

func finalizeFindMatches(_ matches: [SnapshotElement], query: String) -> [SnapshotElement] {
    preferVisibleMatches(dedupeNestedExactMatches(matches, query: query))
}

private func preferVisibleMatches(_ matches: [SnapshotElement]) -> [SnapshotElement] {
    let visible = matches.filter { $0.isVisible }
    return visible.isEmpty ? matches : visible
}

private func dedupeNestedExactMatches(_ matches: [SnapshotElement], query: String) -> [SnapshotElement] {
    guard matches.count > 1 else { return matches }
    var keep = Array(repeating: true, count: matches.count)
    for i in 0..<matches.count {
        guard keep[i] else { continue }
        for j in 0..<matches.count where i != j && keep[j] {
            let lhs = matches[i]
            let rhs = matches[j]
            guard nestedDuplicatePair(lhs, rhs, query: query) else { continue }
            if shouldPreferAncestor(lhs.node, over: rhs.node) {
                keep[j] = false
            } else if shouldPreferAncestor(rhs.node, over: lhs.node) {
                keep[i] = false
                break
            }
        }
    }
    let deduped = zip(matches, keep).compactMap { $1 ? $0 : nil }
    return deduped.isEmpty ? matches : deduped
}

private func nestedDuplicatePair(_ lhs: SnapshotElement, _ rhs: SnapshotElement, query: String) -> Bool {
    guard matchesQueryLabel(lhs.node, query: query), matchesQueryLabel(rhs.node, query: query) else {
        return false
    }
    return isAncestor(lhs.node, of: rhs.node) || isAncestor(rhs.node, of: lhs.node)
}

private func matchesQueryLabel(_ node: SafeSnapshot, query: String) -> Bool {
    node.label == query || displayName(for: node) == query
}

private func isAncestor(_ ancestor: SafeSnapshot, of node: SafeSnapshot) -> Bool {
    var current = node.parent
    while let p = current {
        if SnapshotMatchesElement(p.raw, ancestor.raw) { return true }
        current = p.parent
    }
    return false
}

private func shouldPreferAncestor(_ ancestor: SafeSnapshot, over descendant: SafeSnapshot) -> Bool {
    guard isAncestor(ancestor, of: descendant) else { return false }
    let ancestorType = XCUIElement.ElementType(rawValue: UInt(ancestor.elementType)) ?? .other
    let descendantType = XCUIElement.ElementType(rawValue: UInt(descendant.elementType)) ?? .other
    if isInteractiveFindTarget(ancestorType) && !isInteractiveFindTarget(descendantType) {
        return true
    }
    if ancestorType == .button && descendantType == .staticText {
        return true
    }
    return false
}

private func isInteractiveFindTarget(_ type: XCUIElement.ElementType) -> Bool {
    switch type {
    case .button, .cell, .link, .textField, .secureTextField, .searchField, .textView:
        return true
    default:
        return false
    }
}

// MARK: - Levenshtein (doc 8)

/// Swift Character = extended grapheme cluster; Chinese/emoji/ASCII each count 1.
/// Time complexity: O(m * n), where m and n are the two string lengths.
func levenshtein(_ a: String, _ b: String) -> Int {
    let m = a.count, n = b.count
    if m == 0 { return n }
    if n == 0 { return m }
    var dp = Array(0...n)
    for (i, c1) in a.enumerated() {
        var prev = dp[0]
        dp[0] = i + 1
        for (j, c2) in b.enumerated() {
            let cost = c1 == c2 ? 0 : 1
            let old = dp[j + 1]
            dp[j + 1] = min(prev + cost, dp[j] + 1, dp[j + 1] + 1)
            prev = old
        }
    }
    return dp[n]
}

/// Up to 3 closest label suggestions within edit-distance threshold.
/// Time complexity: O(c * q * t + c log c), where c is candidate count,
/// q is query length, and t is average candidate length.
func fuzzySuggestions(for query: String, from candidates: [String]) -> [String] {
    let normalized = Array(Set(candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
        .filter { !$0.isEmpty }
    let threshold = min(3, query.count / 2)
    if threshold <= 0 { return [] }
    return normalized
        .compactMap { candidate -> (String, Int)? in
            let d = levenshtein(query, candidate)
            return d <= threshold ? (candidate, d) : nil
        }
        .sorted { $0.1 < $1.1 }
        .prefix(3)
        .map { $0.0 }
}

// MARK: - Common formatting helpers (doc 3.3 / 6.1)

private func rectInt(_ value: CGFloat) -> Double {
    Double(Int(value.rounded()))
}

/// Build [x, y, w, h] integer-formatted rect from a CGRect.
func rectArray(_ r: CGRect) -> [Double] {
    [rectInt(r.origin.x),
     rectInt(r.origin.y),
     rectInt(r.size.width),
     rectInt(r.size.height)]
}

/// Serialize a snapshot element to the shape used in ambiguous/find responses.
func elementInfo(_ elem: SnapshotElement, includeAncestors: Bool = false) -> [String: Any] {
    let tn = elementTypeName(XCUIElement.ElementType(rawValue: UInt(elem.node.elementType)) ?? .other)
    var out: [String: Any] = [
        "type": tn,
        "label": displayName(for: elem.node) ?? "",
        "rect": rectArray(elem.node.frame),
        "traits": elem.traits,
    ]
    if let value = displayValue(for: elem.node) {
        out["value"] = value
    }
    if includeAncestors {
        out["ancestors"] = ancestorChainNames(elem.node)
    }
    return out
}

/// Build ["App", "Table", "Cell[Developer]"]-style ancestor chain (doc 3.3).
func ancestorChainNames(_ node: SafeSnapshot) -> [String] {
    var chain: [String] = []
    var cur: SafeSnapshot? = node.parent
    while let p = cur {
        if shouldSkipAncestorInCleanChain(p) {
            cur = p.parent
            continue
        }
        let tn = elementTypeName(XCUIElement.ElementType(rawValue: UInt(p.elementType)) ?? .other)
        if let l = displayName(for: p), !l.isEmpty {
            chain.append("\(tn)[\(l)]")
        } else {
            chain.append(tn)
        }
        cur = p.parent
    }
    return chain.reversed()
}

private func shouldSkipAncestorInCleanChain(_ node: SafeSnapshot) -> Bool {
    let type = XCUIElement.ElementType(rawValue: UInt(node.elementType)) ?? .other
    if type == .window {
        return true
    }
    if type == .other && displayName(for: node) == nil {
        return true
    }
    return false
}

/// Build the ambiguity response payload (doc 3.3).
func ambiguityResponse(_ label: String, matches: [SnapshotElement]) -> ResponseFrame {
    let infos = matches.map { elementInfo($0, includeAncestors: true) }
    let hint = "Try adding --context.ancestor-type / --context.ancestor-label, or use a coordinate/anchor to disambiguate"
    return ResponseFrame(
        ok: false,
        error: "label '\(label)' is ambiguous (\(matches.count) matches)",
        data: AnyCodable([
            "matches": infos,
            "hint": hint,
        ])
    )
}

/// Build the fuzzy / notFound payload (doc 3.3).
func notFoundResponse(_ label: String, suggestions: [String], hint: String? = nil) -> ResponseFrame {
    var data: [String: Any] = [:]
    if !suggestions.isEmpty { data["suggestions"] = suggestions }
    if let hint, !hint.isEmpty {
        data["hint"] = hint
    }
    return ResponseFrame(
        ok: false,
        error: "label '\(label)' not found",
        data: AnyCodable(data)
    )
}
