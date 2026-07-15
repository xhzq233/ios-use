import XCTest
import Fory

// MARK: - WaitFor (doc 6.5)

enum WaitForCommands {
    /// Poll rawFind until target label is visible, or (with --gone) until no exact visible match remains.
    static func waitFor(_ args: ForyWaitForArgs) throws -> ForyResponseFrame {
        _ = try Session.shared.ensureActive()

        let timeout = args.timeout > 0 ? args.timeout : IOSUseProtocol.waitForDefaultTimeoutSeconds
        guard timeout > 0 else {
            return try Codec.foryError(
                "waitFor: timeout must be > 0",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation,
                target: args.target
            )
        }
        let t0 = CFAbsoluteTimeGetCurrent()

        var shouldUseFreshSnapshot = false
        var remainingExactMatches = 0
        while true {
            if shouldUseFreshSnapshot {
                invalidateSnapshot()
            }
            guard let cs = getCleanedSnapshot() else {
                return try Codec.foryError(
                    "waitFor: failed to take snapshot",
                    category: IOSUseErrorCategory.lookup,
                    code: IOSUseErrorCode.snapshotFailed,
                    phase: IOSUseErrorPhase.snapshot,
                    retryable: true,
                    target: args.target
                )
            }
            let result = rawFindInSnapshot(args.target, cs: cs, enableFuzzy: false, visibility: .only)

            switch result {
            case .found(let elem):
                if args.gone {
                    // A gone wait only succeeds after an observation with no exact visible match.
                    // Keep polling through ambiguous snapshots as well; a duplicate is still visible.
                    remainingExactMatches = 1
                    break
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                let payload = ForyWaitForPayload(
                    element: makeForyElementSummary(elem.node),
                    waited: Double(elapsed).sanitized
                )
                return try Codec.foryOK(payload)
            case .ambiguous(let matches):
                if args.gone {
                    remainingExactMatches = matches.count
                    break
                }
                return try ambiguityResponse(args.target, matches: matches)
            case .fuzzy:
                remainingExactMatches = 0
                break
            case .notFound:
                remainingExactMatches = 0
                if args.gone {
                    let elapsed = CFAbsoluteTimeGetCurrent() - t0
                    let payload = ForyWaitForPayload(waited: Double(elapsed).sanitized)
                    return try Codec.foryOK(payload)
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            if elapsed >= timeout {
                let suffix: String
                if args.gone {
                    let noun = remainingExactMatches == 1 ? "match" : "matches"
                    suffix = "; \(remainingExactMatches) visible exact \(noun) remained"
                } else {
                    suffix = ""
                }
                return try Codec.foryError(
                    "waitFor '\(args.target.label)' timed out after \(timeout)s\(suffix)",
                    category: IOSUseErrorCategory.timeout,
                    code: IOSUseErrorCode.waitTimedOut,
                    phase: IOSUseErrorPhase.wait,
                    retryable: true,
                    target: args.target
                )
            }
            shouldUseFreshSnapshot = true
            usleep(UInt32(IOSUseProtocol.waitForPollIntervalMilliseconds * IOSUseProtocol.microsecondsPerMillisecond))
        }
    }
}
