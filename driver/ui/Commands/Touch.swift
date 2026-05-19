import XCTest
import Fory

// MARK: - Touch commands (doc 1.2 — tap, longPress)

enum TouchCommands {
    /// doc 1.2 — tap. `target` is decoded from ForyTapArgs.target (ForyTarget).
    static func tap(_ args: ForyTapArgs) throws -> ForyResponseFrame {
        let app = try Session.shared.ensureActive()
        defer { invalidateSnapshot() }

        let target = args.target

        // Path A: absolute coordinate.
        if let pt = target.point {
            guard target.traits.isEmpty, target.cindex == nil else {
                return Codec.foryError("tap: traits/cindex require label target")
            }
            let point = CGPoint(x: pt.x, y: pt.y)
            try tapAtPoint(point, app: app)
            let payload = ForyElementPayload(
                elemType: 1, // Other (coordinate)
                label: "",
                rect: makeForyRect(CGRect(x: point.x, y: point.y, width: 0, height: 0))
            )
            return try Codec.foryOK(payload)
        }

        // Path B: label lookup via rawFind.
        guard !target.label.isEmpty else {
            return Codec.foryError("tap: invalid label/point")
        }
        switch rawFind(target, visibility: .only) {
        case .found(let elem):
            let f = elem.node.frame
            guard f.width > 0, f.height > 0 else {
                return Codec.foryError("tap: element '\(target.label)' has zero-area frame")
            }
            let point = resolveTapPoint(frame: f, offset: args.offset, ratio: args.ratio)
            try tapAtPoint(point, app: app)
            let payload = ForyElementPayload(
                element: makeForyElementSummary(elem.node)
            )
            return try Codec.foryOK(payload)
        case .ambiguous(let matches):
            return try ambiguityResponse(target.label, matches: matches)
        case .fuzzy(let s):
            return try notFoundResponse(target.label, suggestions: s, hint: "Try adding --traits, or verify the active app")
        case .notFound(let s):
            return try notFoundResponse(target.label, suggestions: s, hint: "Try adding --traits, or verify the active app")
        }
    }

    /// doc 1.2 — longPress. Same label/point semantics as `tap`, plus an
    /// optional duration (default 500ms).
    static func longPress(_ args: ForyLongPressArgs) throws -> ForyResponseFrame {
        let app = try Session.shared.ensureActive()
        let duration = args.duration > 0 ? args.duration : IOSUseProtocol.defaultLongPressDurationSeconds
        defer { invalidateSnapshot() }

        let target = args.target

        if let pt = target.point {
            guard target.traits.isEmpty, target.cindex == nil else {
                return Codec.foryError("longPress: traits/cindex require label target")
            }
            let point = CGPoint(x: pt.x, y: pt.y)
            try pressAtPoint(point, duration: duration, app: app)
            let payload = ForyElementPayload(
                elemType: 1, // Other (coordinate)
                label: "",
                rect: makeForyRect(CGRect(x: point.x, y: point.y, width: 0, height: 0))
            )
            return try Codec.foryOK(payload)
        }

        guard !target.label.isEmpty else {
            return Codec.foryError("longPress: invalid label/point")
        }
        switch rawFind(target, visibility: .only) {
        case .found(let elem):
            let f = elem.node.frame
            guard f.width > 0, f.height > 0 else {
                return Codec.foryError("longPress: element '\(target.label)' has zero-area frame")
            }
            try pressAtPoint(CGPoint(x: f.midX, y: f.midY), duration: duration, app: app)
            let payload = ForyElementPayload(
                element: makeForyElementSummary(elem.node)
            )
            return try Codec.foryOK(payload)
        case .ambiguous(let matches):
            return try ambiguityResponse(target.label, matches: matches)
        case .fuzzy(let s):
            return try notFoundResponse(target.label, suggestions: s, hint: "Try adding --traits, or verify the active app")
        case .notFound(let s):
            return try notFoundResponse(target.label, suggestions: s, hint: "Try adding --traits, or verify the active app")
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

func resolveTapPoint(frame: CGRect, offset: ForyPoint?, ratio: ForyPoint) -> CGPoint {
    if let offset = offset {
        return CGPoint(x: frame.minX + offset.x, y: frame.minY + offset.y)
    }
    return CGPoint(
        x: frame.minX + frame.width * ratio.x,
        y: frame.minY + frame.height * ratio.y
    )
}
