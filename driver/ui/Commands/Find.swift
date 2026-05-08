import XCTest

// MARK: - Find command (doc 1.2, 6.1 — label-only lookup)

enum FindCommands {

    /// doc 6.1 — unified label search. Always goes through `rawFind` which
    /// performs exact + fuzzy + context filtering and returns one of four
    /// outcomes. Unlike tap/longPress/swipe, `find` only accepts a label
    /// (doc 1.2: "find except takes label only").
    ///
    /// Only returns `ok: false` when truly not found (no matches AND no suggestions).
    /// Ambiguous and fuzzy results return `ok: true` with all matches/suggestions.
    static func find(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: FindArgs.self)
        _ = try Session.shared.ensureActive()

        switch rawFind(args.label, traits: args.traits) {
        case .found(let elem):
            return Codec.makeOK([
                "matches": [elementInfo(elem, includeAncestors: true)],
            ])

        case .ambiguous(let matches):
            let infos = matches.map { elementInfo($0, includeAncestors: true) }
            return Codec.makeOK([
                "matches": infos,
                "hint": "Try adding --traits to disambiguate",
            ])

        case .fuzzy(let suggestions):
            return Codec.makeOK([
                "matches": [[String: Any]](),
                "suggestions": suggestions,
                "hint": "Try adding --traits, or verify the active app",
            ])

        case .notFound:
            return ResponseFrame(
                ok: false,
                error: "label '\(args.label)' not found",
                data: AnyCodable([
                    "hint": "Verify the active app or check the label spelling",
                ])
            )
        }
    }
}
