import XCTest

// MARK: - Input command (doc 1.2, 6.3 — find label → prepare → type)

enum InputCommands {

    /// doc 6.3 — two-step typing:
    ///   1) prepare: tap the target to grab keyboard focus when missing.
    ///   2) type:    synthesize text via WDA-style FBTypeText event path.
    static func input(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: InputArgs.self)
        let app = try Session.shared.ensureActive()
        defer { invalidateSnapshot() }

        // Locate the target via rawFind.
        let elem: SnapshotElement
        switch rawFind(args.label, traits: args.traits) {
        case .found(let e): elem = e
        case .ambiguous(let matches): return ambiguityResponse(args.label, matches: matches)
        case .fuzzy(let s):
            return notFoundResponse(args.label,
                                    suggestions: s,
                                    hint: "Try adding --traits, or verify the active app before typing")
        case .notFound(let s):
            return notFoundResponse(args.label,
                                    suggestions: s,
                                    hint: "Try adding --traits, or verify the active app before typing")
        }

        let editableSnapshot = preferredInputSnapshot(around: elem.node)
        let frame = elem.node.frame

        // STEP 1 — prepare: prefer an editable ancestor, but allow keyboard-visible
        // cases where XCTest doesn't expose hasKeyboardFocus reliably.
        guard prepareForInput(editableSnapshot, fallback: elem.node, app: app) else {
            return Codec.makeError("input: failed to focus '\(args.label)' for typing")
        }

        // STEP 2 — when the keyboard is already up, type globally so web inputs
        // and placeholder labels can reuse the active responder. This mirrors
        // WDA's fb_typeText -> FBTypeText synthesized event path.
        guard typeText(args.content) else {
            return Codec.makeError("input: failed to type text into '\(args.label)'")
        }
        return Codec.makeOK([
            "type": elementTypeName(XCUIElement.ElementType(rawValue: UInt(elem.node.elementType)) ?? .other),
            "label": elem.node.label ?? "",
            "rect": rectArray(frame),
        ])
    }
}

enum InputPreparationPhase {
    case initialLookup
    case afterTapAttempt
}

private func hasKeyboardFocus(_ snapshot: SafeSnapshot) -> Bool {
    if snapshot.hasKeyboardFocus { return true }
    return snapshot.allDescendants.contains { $0.hasKeyboardFocus }
}

private func keyboardVisible(in app: XCUIApplication) -> Bool {
    !app.keyboards.allElementsBoundByIndex.isEmpty
}

private func isEditableElementType(_ type: UInt) -> Bool {
    switch XCUIElement.ElementType(rawValue: type) ?? .other {
    case .textField, .secureTextField, .searchField, .textView:
        return true
    default:
        return false
    }
}

private func preferredInputSnapshot(around node: SafeSnapshot) -> SafeSnapshot {
    var current: SafeSnapshot? = node
    while let snapshot = current {
        if isEditableElementType(UInt(snapshot.elementType)) {
            return snapshot
        }
        current = snapshot.parent
    }
    return node
}

func canProceedWithTyping(targetHasKeyboardFocus: Bool, keyboardVisible: Bool, phase: InputPreparationPhase) -> Bool {
    if targetHasKeyboardFocus { return true }
    return phase == .afterTapAttempt && keyboardVisible
}

private func canProceedWithTyping(_ snapshot: SafeSnapshot, app: XCUIApplication, phase: InputPreparationPhase) -> Bool {
    canProceedWithTyping(
        targetHasKeyboardFocus: hasKeyboardFocus(snapshot),
        keyboardVisible: keyboardVisible(in: app),
        phase: phase
    )
}

private func prepareForInput(_ target: SafeSnapshot, fallback: SafeSnapshot, app: XCUIApplication) -> Bool {
    if canProceedWithTyping(target, app: app, phase: .initialLookup) {
        return true
    }

    let candidates = SnapshotMatchesElement(target.raw, fallback.raw) ? [target] : [target, fallback]
    for candidate in candidates {
        guard tapSnapshotCenter(candidate) else { continue }
        Thread.sleep(forTimeInterval: 0.2)
        invalidateSnapshot()
        if let refreshed = refreshedInputSnapshot(matching: target),
           canProceedWithTyping(refreshed, app: app, phase: .afterTapAttempt) {
            return true
        }
        if !SnapshotMatchesElement(candidate.raw, target.raw),
           let refreshedFallback = refreshedInputSnapshot(matching: candidate),
           canProceedWithTyping(refreshedFallback, app: app, phase: .afterTapAttempt) {
            return true
        }
        if canProceedWithTyping(targetHasKeyboardFocus: false,
                                keyboardVisible: keyboardVisible(in: app),
                                phase: .afterTapAttempt) {
            return true
        }
    }
    invalidateSnapshot()
    return false
}

private func tapSnapshotCenter(_ snapshot: SafeSnapshot) -> Bool {
    let frame = snapshot.frame.integral
    guard !frame.isEmpty else { return false }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    var error: NSError?
    return XCSynthesizeTapAtPoint(point, &error)
}

private func refreshedInputSnapshot(matching target: SafeSnapshot) -> SafeSnapshot? {
    guard let cleaned = rebuildCleanedSnapshot() else { return nil }
    if SnapshotMatchesElement(cleaned.root.raw, target.raw) {
        return cleaned.root
    }
    for node in cleaned.root.allDescendants {
        if SnapshotMatchesElement(node.raw, target.raw) {
            return node
        }
    }
    return nil
}

private func typeText(_ text: String) -> Bool {
    var error: NSError?
    return XCFBTypeText(text, XCDefaultTypingFrequency(), &error)
}
