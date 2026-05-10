import XCTest
import Fory

// MARK: - Find command (doc 1.2, 6.1 — label-only lookup)

enum FindCommands {

    /// doc 6.1 — unified label search. Always goes through `rawFind` which
    /// performs exact + fuzzy + context filtering and returns one of four
    /// outcomes.
    static func find(_ args: ForyFindArgs, fory: Fory) throws -> ForyResponseFrame {
        _ = try Session.shared.ensureActive()

        switch rawFind(args.label, traits: args.traits.isEmpty ? nil : args.traits) {
        case .found(let elem):
            let match = makeForyFindMatch(elem, includeAncestors: true)
            var payload = ForyFindPayload()
            payload.matches = [match]
            return try Codec.foryOK(payload, fory: fory)

        case .ambiguous(let matches):
            var payload = ForyFindPayload()
            payload.matches = matches.map { makeForyFindMatch($0, includeAncestors: true) }
            payload.hint = "Try adding --traits to disambiguate"
            return try Codec.foryOK(payload, fory: fory)

        case .fuzzy(let suggestions):
            var payload = ForyFindPayload()
            payload.suggestions = suggestions
            payload.hint = "Try adding --traits, or verify the active app"
            return try Codec.foryOK(payload, fory: fory)

        case .notFound:
            var errPayload = ForyErrorPayload()
            errPayload.hint = "Verify the active app or check the label spelling"
            return try Codec.foryError("label '\(args.label)' not found", payload: errPayload, fory: fory)
        }
    }
}
