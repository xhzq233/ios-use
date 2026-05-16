import XCTest
import Fory

// MARK: - WaitFor (doc 6.5)

enum WaitForCommands {
    /// doc 6.5 — poll rawFind until target label is visible or timeout.
    static func waitFor(_ args: ForyWaitForArgs) throws -> ForyResponseFrame {
        _ = try Session.shared.ensureActive()

        let timeout = args.timeout > 0 ? args.timeout : IOSUseProtocol.waitForDefaultTimeoutSeconds
        guard timeout > 0 else {
            return Codec.foryError("waitFor: timeout must be > 0")
        }
        let traits = args.traits.isEmpty ? nil : args.traits
        let t0 = CFAbsoluteTimeGetCurrent()

        var shouldUseFreshSnapshot = false
        while true {
            if shouldUseFreshSnapshot {
                invalidateSnapshot()
            }
            guard let cs = getCleanedSnapshot() else {
                return Codec.foryError("waitFor: failed to take snapshot")
            }
            let result = rawFindInSnapshot(args.label, traits: traits, cs: cs, enableFuzzy: false, visibility: .only)

            switch result {
            case .found(let elem):
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                let payload = ForyWaitForPayload(
                    elemType: Int32(truncatingIfNeeded: elem.node.elementType),
                    label: elem.node.label ?? "",
                    rect: makeForyRect(elem.node.frame),
                    waited: Double(elapsed).sanitized
                )
                return try Codec.foryOK(payload)
            case .ambiguous(let matches):
                return try ambiguityResponse(args.label, matches: matches)
            case .fuzzy, .notFound:
                break
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            if elapsed >= timeout {
                return Codec.foryError("waitFor '\(args.label)' timed out after \(timeout)s")
            }
            shouldUseFreshSnapshot = true
            usleep(UInt32(IOSUseProtocol.waitForPollIntervalMilliseconds * IOSUseProtocol.microsecondsPerMillisecond))
        }
    }
}
