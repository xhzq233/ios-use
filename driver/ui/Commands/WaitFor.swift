import Foundation
import XCTest
import Fory

// MARK: - WaitFor (doc 6.5)

enum WaitForCommands {
    /// Poll rawFind until target label is visible, or (with --gone) until no visible match remains.
    static func waitFor(_ args: ForyWaitForArgs) throws -> ForyResponseFrame {
        _ = try Session.shared.ensureActive()

        guard args.timeout.isFinite else {
            return try Codec.foryError(
                "waitFor: timeout must be finite",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation,
                target: args.target
            )
        }
        guard args.timeout >= 0 else {
            return try Codec.foryError(
                "waitFor: timeout must be > 0 when provided",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation,
                target: args.target
            )
        }
        let timeout = IOSUseProtocol.resolvedWaitForTimeoutSeconds(args.timeout)
        guard timeout > 0 else {
            return try Codec.foryError(
                "waitFor: timeout must be > 0",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation,
                target: args.target
            )
        }
        guard timeout <= IOSUseProtocol.waitForMaximumTimeoutSeconds else {
            return try Codec.foryError(
                "waitFor: timeout must be at most \(IOSUseProtocol.waitForMaximumTimeoutSeconds)s",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation,
                target: args.target
            )
        }
        let textMatch: RawFindTextMatch
        switch IOSUseWaitForMatchMode(rawValue: args.matchMode) {
        case .standard:
            textMatch = .standard
        case .exact:
            textMatch = .exact
        case .regex:
            do {
                textMatch = .regex(try NSRegularExpression(pattern: args.target.label))
            } catch {
                return try Codec.foryError(
                    "waitFor: invalid regular expression: \(error.localizedDescription)",
                    category: IOSUseErrorCategory.validation,
                    code: IOSUseErrorCode.invalidArguments,
                    phase: IOSUseErrorPhase.validation,
                    target: args.target
                )
            }
        case nil:
            return try Codec.foryError(
                "waitFor: unsupported match mode \(args.matchMode)",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation,
                target: args.target
            )
        }
        let t0 = CFAbsoluteTimeGetCurrent()

        var shouldUseFreshSnapshot = false
        var remainingMatches = 0
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
            // Polling only needs selector state. Skip rejected-candidate diagnostics
            // so every miss does not rescan the full DOM or build ancestor chains.
            let result = rawFindInSnapshot(
                args.target,
                cs: cs,
                enableFuzzy: false,
                visibility: .only,
                diagnostics: .none,
                textMatch: textMatch
            )

            switch result {
            case .found(let elem):
                if args.gone {
                    // A gone wait only succeeds after an observation with no visible selector match.
                    // Keep polling through ambiguous snapshots as well; a duplicate is still visible.
                    remainingMatches = 1
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
                    remainingMatches = matches.count
                    break
                }
                return try ambiguityResponse(args.target, matches: matches)
            case .fuzzy:
                remainingMatches = 0
                break
            case .notFound:
                remainingMatches = 0
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
                    let noun = remainingMatches == 1 ? "match" : "matches"
                    suffix = "; \(remainingMatches) visible selector \(noun) remained"
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
