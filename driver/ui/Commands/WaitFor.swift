import XCTest

// MARK: - WaitFor (doc 6.5)

enum WaitForCommands {
    /// doc 6.5 — poll rawFind until target label is visible or timeout.
    static func waitFor(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: WaitForArgs.self)
        _ = try Session.shared.ensureActive()

        let timeout = args.timeout ?? 10.0
        let intervalMs = args.interval ?? 500
        guard timeout > 0 else {
            return Codec.makeError("waitFor: timeout must be > 0")
        }
        guard intervalMs > 0 else {
            return Codec.makeError("waitFor: interval must be > 0")
        }
        let t0 = CFAbsoluteTimeGetCurrent()

        var shouldUseFreshSnapshot = false
        while true {
            if shouldUseFreshSnapshot {
                invalidateSnapshot()
            }
            let result = rawFind(args.label, context: args.context)

            switch result {
            case .found(let elem):
                if elem.isVisible {
                    let elapsed = CFAbsoluteTimeGetCurrent() - t0
                    let tn = elementTypeName(XCUIElement.ElementType(rawValue: UInt(elem.node.elementType)) ?? .other)
                    return Codec.makeOK([
                        "type": tn,
                        "label": elem.node.label ?? "",
                        "rect": rectArray(elem.node.frame),
                        "waited": Double(elapsed).sanitized,
                    ])
                }
                // exists but invisible → keep polling
            case .ambiguous(let matches):
                return ambiguityResponse(args.label, matches: matches)
            case .fuzzy, .notFound:
                break  // keep polling
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            if elapsed >= timeout {
                return Codec.makeError("waitFor '\(args.label)' timed out after \(timeout)s")
            }
            shouldUseFreshSnapshot = true
            usleep(UInt32(intervalMs * 1000))
        }
    }
}
