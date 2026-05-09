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
            if args.offset != nil {
                return Codec.makeError("tap: offset requires element label, not absolute point")
            }
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
        switch rawFind(label, traits: args.traits) {
        case .found(let elem):
            let f = elem.node.frame
            guard f.width > 0, f.height > 0 else {
                return Codec.makeError("tap: element '\(label)' has zero-area frame")
            }
            let point: CGPoint
            do {
                point = try resolveTapPoint(frame: f, offset: args.offset)
            } catch let error as DriverError {
                return Codec.makeError("tap: \(error.description)")
            }
            try tapAtPoint(point, app: app)
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
                                    hint: "Try adding --traits, or verify the active app")
        case .notFound(let s):
            return notFoundResponse(label,
                                    suggestions: s,
                                    hint: "Try adding --traits, or verify the active app")
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
        switch rawFind(label, traits: args.traits) {
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
                                    hint: "Try adding --traits, or verify the active app")
        case .notFound(let s):
            return notFoundResponse(label,
                                    suggestions: s,
                                    hint: "Try adding --traits, or verify the active app")
        }
    }

    // MARK: - Internals

    private static func tapAtPoint(_ p: CGPoint, app: XCUIApplication) throws {
        if let error = RawPointer.perform(app: app, event: .tap(p)) {
            throw DriverError.serverError("tap synthesis failed: \(error.localizedDescription)")
        }
    }

    private static func pressAtPoint(_ p: CGPoint, duration: Double, app: XCUIApplication) throws {
        if let error = RawPointer.perform(app: app, event: .longPress(p, duration: duration)) {
            throw DriverError.serverError("longPress synthesis failed: \(error.localizedDescription)")
        }
    }
}

func resolveTapPoint(frame: CGRect, offset: TapOffset?) throws -> CGPoint {
    guard let offset else {
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    let hasX = offset.x != nil
    let hasY = offset.y != nil
    let hasXRatio = offset.xRatio != nil
    let hasYRatio = offset.yRatio != nil

    if hasX && hasXRatio {
        throw DriverError.invalidArgs("offset.x and offset.xRatio are mutually exclusive")
    }
    if hasY && hasYRatio {
        throw DriverError.invalidArgs("offset.y and offset.yRatio are mutually exclusive")
    }

    let localX = offset.x ?? frame.width * (offset.xRatio ?? 0.5)
    let localY = offset.y ?? frame.height * (offset.yRatio ?? 0.5)

    return CGPoint(x: frame.minX + localX, y: frame.minY + localY)
}
