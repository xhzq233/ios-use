import XCTest

// MARK: - Touch commands (doc 1.2 — tap, longPress)

enum TouchCommands {
    private static let defaultLongPressDuration = 0.5

    /// doc 1.2 — tap. `label` is either a String (look up via rawFind) or a
    /// 2-element [x, y] absolute point. Mutation → invalidates snapshot cache.
    static func tap(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: TapArgs.self)
        let app = try Session.shared.ensureActive()
        defer { invalidateSnapshot() }

        // Path A: absolute coordinate.
        if let pt = args.label.asPoint {
            guard pt.count == 2 else {
                return Codec.makeError("tap: point must be [x, y]")
            }
            let point = CGPoint(x: pt[0], y: pt[1])
            try tapAtPoint(point, app: app)
            return Codec.makeOK([
                "type": "Coordinate",
                "label": "",
                "rect": rectArray(CGRect(x: point.x, y: point.y, width: 0, height: 0)),
            ])
        }

        // Path B: label lookup via rawFind (exact + fuzzy + context filter).
        guard let label = args.label.asLabel else {
            return Codec.makeError("tap: invalid label/point")
        }
        switch rawFind(label, context: args.context) {
        case .found(let elem):
            let f = elem.node.frame
            guard f.width > 0, f.height > 0 else {
                return Codec.makeError("tap: element '\(label)' has zero-area frame")
            }
            try tapAtPoint(CGPoint(x: f.midX, y: f.midY), app: app)
            return Codec.makeOK([
                "type": elementTypeName(XCUIElement.ElementType(rawValue: UInt(elem.node.elementType)) ?? .other),
                "label": elem.node.label ?? "",
                "rect": rectArray(f),
            ])
        case .ambiguous(let matches):
            return ambiguityResponse(label, matches: matches)
        case .fuzzy(let s):
            return notFoundResponse(label,
                                    suggestions: s,
                                    hint: "Try refining --context.ancestor-type / --context.ancestor-label, or verify the active app")
        case .notFound(let s):
            return notFoundResponse(label,
                                    suggestions: s,
                                    hint: "Try refining --context.ancestor-type / --context.ancestor-label, or verify the active app")
        }
    }

    /// doc 1.2 — longPress. Same label/point semantics as `tap`, plus an
    /// optional duration (default 500ms).
    static func longPress(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: LongPressArgs.self)
        let app = try Session.shared.ensureActive()
        let duration = args.duration ?? defaultLongPressDuration
        defer { invalidateSnapshot() }

        if let pt = args.label.asPoint {
            guard pt.count == 2 else {
                return Codec.makeError("longPress: point must be [x, y]")
            }
            let point = CGPoint(x: pt[0], y: pt[1])
            try pressAtPoint(point, duration: duration, app: app)
            return Codec.makeOK([
                "type": "Coordinate",
                "label": "",
                "rect": rectArray(CGRect(x: point.x, y: point.y, width: 0, height: 0)),
            ])
        }

        guard let label = args.label.asLabel else {
            return Codec.makeError("longPress: invalid label/point")
        }
        switch rawFind(label, context: args.context) {
        case .found(let elem):
            let f = elem.node.frame
            guard f.width > 0, f.height > 0 else {
                return Codec.makeError("longPress: element '\(label)' has zero-area frame")
            }
            try pressAtPoint(CGPoint(x: f.midX, y: f.midY), duration: duration, app: app)
            return Codec.makeOK([
                "type": elementTypeName(XCUIElement.ElementType(rawValue: UInt(elem.node.elementType)) ?? .other),
                "label": elem.node.label ?? "",
                "rect": rectArray(f),
            ])
        case .ambiguous(let matches):
            return ambiguityResponse(label, matches: matches)
        case .fuzzy(let s):
            return notFoundResponse(label,
                                    suggestions: s,
                                    hint: "Try refining --context.ancestor-type / --context.ancestor-label, or verify the active app")
        case .notFound(let s):
            return notFoundResponse(label,
                                    suggestions: s,
                                    hint: "Try refining --context.ancestor-type / --context.ancestor-label, or verify the active app")
        }
    }

    // MARK: - Internals

    private static func tapAtPoint(_ p: CGPoint, app: XCUIApplication) throws {
        let _ = app
        var error: NSError?
        guard XCSynthesizeTapAtPoint(p, &error) else {
            throw DriverError.serverError("tap synthesis failed: \(error?.localizedDescription ?? "unknown error")")
        }
    }

    private static func pressAtPoint(_ p: CGPoint, duration: Double, app: XCUIApplication) throws {
        let _ = app
        var error: NSError?
        guard XCSynthesizeLongPressAtPoint(p, duration, &error) else {
            throw DriverError.serverError("longPress synthesis failed: \(error?.localizedDescription ?? "unknown error")")
        }
    }
}
