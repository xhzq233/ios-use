import XCTest

// MARK: - Find command (doc 1.2, 6.1 — label-only lookup)

enum FindCommands {

    /// doc 6.1 — unified label search. Always goes through `rawFind` which
    /// performs exact + fuzzy + context filtering and returns one of four
    /// outcomes. Unlike tap/longPress/swipe, `find` only accepts a label
    /// (doc 1.2: "find except takes label only").
    static func find(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: FindArgs.self)
        _ = try Session.shared.ensureActive()

        switch rawFind(args.label, context: args.context) {
        case .found(let elem):
            return Codec.makeOK(elementInfo(elem, includeAncestors: true))

        case .ambiguous(let matches):
            return ambiguityResponse(args.label, matches: matches)

        case .fuzzy(let s):
            return notFoundResponse(args.label,
                                    suggestions: s,
                                    hint: "Try refining --context.ancestor-type / --context.ancestor-label, or verify the active app")

        case .notFound(let s):
            return notFoundResponse(args.label,
                                    suggestions: s,
                                    hint: "Try refining --context.ancestor-type / --context.ancestor-label, or verify the active app")
        }
    }
}
