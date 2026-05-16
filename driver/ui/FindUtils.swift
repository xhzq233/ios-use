import XCTest
import Fory

// MARK: - FindResult (doc 6.1)

enum FindResult {
    case found(SnapshotElement)
    case ambiguous(matches: [SnapshotElement])
    case fuzzy(suggestions: [String])
    case notFound(suggestions: [String])
}

enum RawFindVisibility {
    case any
    case only
}

// MARK: - rawFind (doc 6.1)

/// Unified label search against an explicit cleaned snapshot.
/// This is the single source of truth for all label-based command semantics.
/// Time complexity: O(n * s + m * r + c * q * t) in the worst case, where n is
/// the indexed element count, s is the number of precomputed searchable texts
/// per element, m is the number of contains matches, r is the number of
/// requested traits, c is candidate string count, q is query length, and t is
/// candidate length used by fuzzy fallback. Effective-visible filtering adds
/// O(n) before contains/fuzzy when `visibility == .only`.
func rawFindInSnapshot(_ label: String,
                       traits: String? = nil,
                       cs: CleanedSnapshot,
                       enableFuzzy: Bool = true,
                       visibility: RawFindVisibility = .only) -> FindResult {
    let query = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
        return .notFound(suggestions: [])
    }
    let normalizedQuery = normalizeSearchText(query)
    guard !normalizedQuery.isEmpty else {
        return .notFound(suggestions: [])
    }

    let searchEntries = visibility == .only
        ? cs.searchEntries.filter { isVisibleWithEffectiveGeometry($0.element, in: cs.appFrame) }
        : cs.searchEntries

    // 1. Unified normalized contains match across label + value.
    var matches = matchingElements(in: searchEntries) { entry in
        entry.normalizedTexts.contains { normalizedTextContainsQuery($0, normalizedQuery: normalizedQuery) }
    }

    // 2. Fuzzy fallback when contains-match is empty.
    if matches.isEmpty {
        guard enableFuzzy else { return .notFound(suggestions: []) }
        let candidates = visibility == .only ? searchCandidates(from: searchEntries) : cs.searchCandidates
        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizedQuery, from: candidates)
        if !suggestions.isEmpty { return .fuzzy(suggestions: suggestions) }
        return .notFound(suggestions: [])
    }

    // 3. Trait filter (AND semantics — element must contain all specified traits).
    if let traitsStr = traits, !traitsStr.isEmpty {
        let required = traitsStr.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if !required.isEmpty {
            matches = matches.filter { element in
                required.allSatisfy { req in
                    element.traits.contains(where: { $0.lowercased() == req })
                }
            }
        }
    }

    if matches.isEmpty { return .notFound(suggestions: []) }
    if matches.count > 1 { return .ambiguous(matches: matches) }
    return .found(matches[0])
}

/// Unified label search: contains(label/value) → fuzzy → trait filter.
/// Used by all label-based commands (find, tap, longPress, input, swipe, waitFor).
func rawFind(_ label: String, traits: String? = nil, visibility: RawFindVisibility = .only) -> FindResult {
    guard let cs = getCleanedSnapshot() else {
        return .notFound(suggestions: [])
    }
    return rawFindInSnapshot(label, traits: traits, cs: cs, visibility: visibility)
}

private func searchCandidates(from entries: [SearchEntry]) -> [SearchCandidate] {
    entries.flatMap { entry in
        entry.rawTexts.compactMap { text -> SearchCandidate? in
            let normalized = normalizeSearchText(text)
            guard !normalized.isEmpty else { return nil }
            return SearchCandidate(displayText: text, normalizedText: normalized)
        }
    }
}

func searchableTexts(label: String?, value: String?) -> [String] {
    var out: [String] = []
    for text in [label, value] {
        guard let text else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || out.contains(trimmed) { continue }
        out.append(trimmed)
    }
    return out
}

private let ignoredSearchScalars = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: "-_:/()[]{}.,'\""))

func normalizeSearchText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let filtered = trimmed.unicodeScalars.filter { !ignoredSearchScalars.contains($0) }
    return String(filtered).lowercased()
}

func normalizedSearchableTexts(from texts: [String]) -> [String] {
    var out: [String] = []
    for text in texts {
        let normalized = normalizeSearchText(text)
        if normalized.isEmpty || out.contains(normalized) { continue }
        out.append(normalized)
    }
    return out
}

func normalizedTextContainsQuery(_ text: String, normalizedQuery: String) -> Bool {
    text.contains(normalizedQuery)
}

func searchableTexts(for node: SafeSnapshot) -> [String] {
    searchableTexts(label: displayName(for: node), value: displayValue(for: node))
}

private func matchingElements(
    in entries: [SearchEntry],
    where predicate: (SearchEntry) -> Bool
) -> [SnapshotElement] {
    entries.compactMap { predicate($0) ? $0.element : nil }
}

private func matchesQueryContent(
    _ element: SnapshotElement,
    normalizedQuery: String,
    normalizedTextsByNode: [ObjectIdentifier: [String]]
) -> Bool {
    guard !normalizedQuery.isEmpty else { return false }
    guard let normalizedTexts = normalizedTextsByNode[nodeIdentity(element.node)] else { return false }
    return normalizedTexts.contains { normalizedTextContainsQuery($0, normalizedQuery: normalizedQuery) }
}

private func isAncestor(_ ancestor: SafeSnapshot, of node: SafeSnapshot) -> Bool {
    var current = node.parent
    while let p = current {
        if SnapshotMatchesElement(p.raw, ancestor.raw) { return true }
        current = p.parent
    }
    return false
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

/// Up to 3 closest suggestions within edit-distance threshold on normalized
/// search text. Returned values preserve original display text.
/// Time complexity: O(c * q * t), with length pruning and constant-size
/// top-3 ranking. c is candidate count, q is normalized query length, and t
/// is normalized candidate length.
func fuzzySuggestions(forNormalizedQuery normalizedQuery: String, from candidates: [SearchCandidate]) -> [String] {
    let queryLength = normalizedQuery.count
    let threshold = fuzzyThreshold(for: queryLength)
    if threshold <= 0 { return [] }

    var best: [(SearchCandidate, Int)] = []
    best.reserveCapacity(IOSUseProtocol.fuzzyMaxSuggestionCount)

    for candidate in candidates {
        guard !candidate.normalizedText.isEmpty else { continue }
        guard abs(candidate.normalizedText.count - queryLength) <= threshold else { continue }
        let distance = levenshtein(normalizedQuery, candidate.normalizedText)
        guard distance <= threshold else { continue }
        let item = (candidate, distance)
        if best.count < IOSUseProtocol.fuzzyMaxSuggestionCount {
            best.append(item)
            best.sort(by: fuzzyRankedBefore)
        } else if fuzzyRankedBefore(item, best[IOSUseProtocol.fuzzyMaxSuggestionCount - 1]) {
            best[IOSUseProtocol.fuzzyMaxSuggestionCount - 1] = item
            best.sort(by: fuzzyRankedBefore)
        }
    }

    return best.map { $0.0.displayText }
}

private func fuzzyRankedBefore(_ lhs: (SearchCandidate, Int), _ rhs: (SearchCandidate, Int)) -> Bool {
    if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
    return lhs.0.displayText < rhs.0.displayText
}

private func nodeIdentity(_ node: SafeSnapshot) -> ObjectIdentifier {
    ObjectIdentifier(node.raw as AnyObject)
}

private func fuzzyThreshold(for length: Int) -> Int {
    switch length {
    case ...IOSUseProtocol.fuzzyNoSuggestionMaxLength:
        return 0
    case ...IOSUseProtocol.fuzzyNearTypoMaxLength:
        return IOSUseProtocol.fuzzyNearTypoThreshold
    case ...IOSUseProtocol.fuzzyMediumTypoMaxLength:
        return IOSUseProtocol.fuzzyMediumTypoThreshold
    default:
        return IOSUseProtocol.fuzzyLongTypoThreshold
    }
}

// MARK: - Common formatting helpers (doc 3.3 / 6.1)

/// Build ForyRect from a CGRect. Returns non-optional (callers assign nil when needed).
func makeForyRect(_ r: CGRect) -> ForyRect {
    ForyRect(
        x: Int32(r.origin.x.rounded()),
        y: Int32(r.origin.y.rounded()),
        w: Int32(r.size.width.rounded()),
        h: Int32(r.size.height.rounded())
    )
}

/// Build a ForyFindMatch from a SnapshotElement.
func makeForyFindMatch(_ elem: SnapshotElement, includeAncestors: Bool = false) -> ForyFindMatch {
    var m = ForyFindMatch()
    m.elemType = Int32(truncatingIfNeeded: elem.node.elementType)
    m.label = displayName(for: elem.node) ?? ""
    m.rect = makeForyRect(elem.node.frame)
    m.traits = elem.traits
    if let v = displayValue(for: elem.node) { m.value = v }
    if includeAncestors { m.ancestors = ancestorChainNames(elem.node) }
    return m
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

/// Build the ambiguity response (doc 3.3).
func ambiguityResponse(_ label: String, matches: [SnapshotElement]) throws -> ForyResponseFrame {
    var payload = ForyErrorPayload()
    payload.matches = matches.map { makeForyFindMatch($0, includeAncestors: true) }
    payload.hint = "Try adding --traits to disambiguate"
    return try Codec.foryError("label '\(label)' is ambiguous (\(matches.count) matches)", payload: payload)
}

/// Build the fuzzy / notFound payload (doc 3.3).
func notFoundResponse(_ label: String, suggestions: [String], hint: String? = nil) throws -> ForyResponseFrame {
    var payload = ForyErrorPayload()
    payload.suggestions = suggestions
    if let hint, !hint.isEmpty { payload.hint = hint }
    return try Codec.foryError("label '\(label)' not found", payload: payload)
}
