import XCTest

enum TextInputCommands {
    static func execute(_ args: ForyTextInputArgs) throws -> ForyResponseFrame {
        guard ["replace", "select", "key", "type"].contains(args.operation),
              ["text", "cursor_before", "cursor_after"].contains(args.selectionType),
              args.operation != "select" || !args.text.isEmpty else {
            return try failure("Invalid text input operation or selection", validation: true)
        }
        // Parse keys before touching focus or UI state.
        let chord: KeyboardChord?
        do { chord = args.operation == "key" ? try KeyboardChord.parse(args.text) : nil }
        catch { return try failure(String(describing: error), validation: true) }
        let app = try Session.shared.ensureActive()
        defer { invalidateSnapshot() }
        if args.operation == "type" {
            var error: NSError?
            guard XCFBTypeText(args.text, XCDefaultTypingFrequency(), &error) else {
                return try failure(error?.localizedDescription ?? "Text input failed")
            }
            return try Codec.foryOK(ForyElementPayload())
        }
        if let chord {
            Quiescence.wait(app: app, command: "pressKey")
            var error: NSError?
            guard XCSynthesizeKey(chord.key, chord.modifiers, &error) else {
                return try failure(error?.localizedDescription ?? "Key synthesis failed")
            }
            return try Codec.foryOK(ForyElementPayload())
        }

        var element: SnapshotElement
        switch editableTarget(args.target) {
        case .found(let found): element = found
        case .ambiguous(let matches): return try ambiguityResponse(args.target, matches: matches)
        case .fuzzy(let suggestions): return try notFoundResponse(args.target, suggestions: suggestions)
        case .notFound(let suggestions, let rejected): return try notFoundResponse(args.target, suggestions: suggestions, rejected: rejected)
        }
        guard editableTypes.contains(element.node.elementType) else {
            return try failure("Target is not an editable text element", validation: true)
        }
        guard element.node.elementType != XCUIElement.ElementType.secureTextField.rawValue else {
            return try failure("Secure inputs do not expose verifiable text; focus and use typeText instead", validation: true)
        }
        if !element.node.hasKeyboardFocus {
            guard let frame = interactionFrame(element.node) else {
                return try failure("Editable target has no visible interaction frame", validation: true)
            }
            if let error = RawPointer.perform(app: app, event: .tap(CGPoint(x: frame.midX, y: frame.midY))) {
                return try failure(error.localizedDescription)
            }
            Quiescence.wait(app: app, command: "text-focus")
            invalidateSnapshot()
            guard let focused = getCleanedSnapshot()?.elements.first(where: {
                $0.node.hasKeyboardFocus && SnapshotMatchesElement($0.node.raw, element.node.raw)
            }) else {
                return try failure("Target did not acquire keyboard focus; no text was changed")
            }
            element = focused
        }
        var error: NSError?
        guard let value = args.operation == "replace" ? XCSelectAllText(element.node.raw, &error) : XCTextValue(element.node.raw, &error), error == nil else {
            return try failure(error?.localizedDescription ?? "Cannot read target text")
        }

        if args.operation == "select" {
            let range: NSRange
            do { range = try textSelectionRange(in: value, text: args.text, prefix: args.prefix, suffix: args.suffix, selectionType: args.selectionType) }
            catch { return try failure(String(describing: error), validation: true) }
            guard XCSelectTextRange(element.node.raw, value, range, &error) else {
                return try failure(error?.localizedDescription ?? "This target does not support text selection")
            }
        } else if !value.isEmpty || !args.text.isEmpty {
            let text = args.text.isEmpty ? "\u{7f}" : args.text
            error = nil
            guard XCFBTypeText(text, XCDefaultTypingFrequency(), &error) else {
                return try failure(error?.localizedDescription ?? "Text replacement failed")
            }
            error = nil
            guard XCTextValueMatches(element.node.raw, args.text, &error), error == nil else {
                return try failure("Replacement text was not confirmed; observe before retrying")
            }
        }
        return try Codec.foryOK(ForyElementPayload(element: makeForyElementSummary(element.node)))
    }

    private static let editableTypes: Set<UInt> = [
        XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.secureTextField.rawValue,
        XCUIElement.ElementType.searchField.rawValue, XCUIElement.ElementType.textView.rawValue,
    ]

    private static func editableTarget(_ target: ForyTarget) -> FindResult {
        guard let point = target.point else { return rawFind(target, visibility: .only) }
        let matches = (getCleanedSnapshot()?.elements ?? []).filter {
            editableTypes.contains($0.node.elementType) && $0.isVisible && !$0.disabled &&
                $0.node.frame.contains(CGPoint(x: point.x, y: point.y))
        }
        if matches.count == 1 { return .found(matches[0]) }
        if matches.count > 1 { return .ambiguous(matches: matches) }
        return .notFound(suggestions: [], rejected: [])
    }

    private static func failure(_ message: String, validation: Bool = false) throws -> ForyResponseFrame {
        try Codec.foryError(message, category: validation ? IOSUseErrorCategory.validation : IOSUseErrorCategory.action,
                           code: validation ? IOSUseErrorCode.invalidArguments : IOSUseErrorCode.inputFailed,
                           phase: validation ? IOSUseErrorPhase.validation : IOSUseErrorPhase.interaction, retryable: false)
    }
}

func textSelectionRange(in value: String, text: String, prefix: String, suffix: String, selectionType: String) throws -> NSRange {
    let source = value as NSString
    var offset = 0
    var match: NSRange?
    guard !text.isEmpty else { throw TextInputError.invalid("Selection text cannot be empty") }
    while offset < source.length {
        let range = source.range(of: text, options: .literal, range: NSRange(location: offset, length: source.length - offset))
        if range.location == NSNotFound { break }
        if source.substring(to: range.location).hasSuffix(prefix) && source.substring(from: NSMaxRange(range)).hasPrefix(suffix) {
            guard match == nil else { throw TextInputError.invalid("Selection is ambiguous; supply prefix or suffix") }
            match = range
        }
        offset = range.location + 1
    }
    guard let match else { throw TextInputError.invalid("Selection text is not present in this editable element") }
    switch selectionType {
    case "text": return match
    case "cursor_before": return NSRange(location: match.location, length: 0)
    case "cursor_after": return NSRange(location: NSMaxRange(match), length: 0)
    default: throw TextInputError.invalid("Unknown selectionType")
    }
}

private enum TextInputError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}

struct KeyboardChord {
    let key: String
    let modifiers: UInt

    static func parse(_ value: String) throws -> KeyboardChord {
        let parts = value == "+" ? [value] : value.components(separatedBy: "+")
        guard let name = parts.last, !name.isEmpty else { throw TextInputError.invalid("A key is required") }
        let modifierNames: [String: XCUIElement.KeyModifierFlags] = [
            "shift": .shift, "shift_l": .shift, "shift_r": .shift,
            "ctrl": .control, "control": .control, "control_l": .control, "control_r": .control,
            "alt": .option, "option": .option, "alt_l": .option, "alt_r": .option,
            "super": .command, "meta": .command, "cmd": .command, "command": .command, "super_l": .command, "super_r": .command,
            "fn": .function, "capslock": .capsLock,
        ]
        var modifiers: XCUIElement.KeyModifierFlags = []
        for part in parts.dropLast() {
            guard let flag = modifierNames[part.lowercased()] else { throw TextInputError.invalid("Unknown key modifier: \(part)") }
            modifiers.formUnion(flag)
        }
        let keys: [String: XCUIKeyboardKey] = [
            "return": .return, "enter": .enter, "kp_enter": .enter, "tab": .tab, "space": .space,
            "escape": .escape, "esc": .escape, "backspace": .delete, "delete": .forwardDelete,
            "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
            "home": .home, "end": .end, "page_up": .pageUp, "page_down": .pageDown, "prior": .pageUp, "next": .pageDown,
            "clear": .clear, "caps_lock": .capsLock, "shift_l": .shift, "shift_r": .rightShift,
            "control_l": .control, "control_r": .rightControl, "alt_l": .option, "alt_r": .rightOption,
            "super_l": .command, "super_r": .rightCommand, "plus": XCUIKeyboardKey(rawValue: "+"),
            "f1": .F1, "f2": .F2, "f3": .F3, "f4": .F4, "f5": .F5, "f6": .F6,
            "f7": .F7, "f8": .F8, "f9": .F9, "f10": .F10, "f11": .F11, "f12": .F12,
        ]
        let key = keys[name.lowercased()]?.rawValue ?? (name.unicodeScalars.count == 1 && name.utf16.count == 1 ? name : nil)
        guard let key else { throw TextInputError.invalid("Unknown or unsupported key: \(name)") }
        return KeyboardChord(key: key, modifiers: modifiers.rawValue)
    }
}
