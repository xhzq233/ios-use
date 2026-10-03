import XCTest
import Fory

enum SemanticTouchResolution {
    case found(snapshot: CleanedSnapshot, element: SnapshotElement, frame: CGRect)
    case failure(ForyResponseFrame)
}

/// Quiescence can finish before restored list positions reach accessibility.
/// Re-resolve the selector until its interaction geometry is steady, then keep
/// that latest snapshot alive through touch delivery. No second idle wait follows.
func resolveSemanticTouchTarget(
    _ target: ForyTarget,
    command: String,
    capture: () -> CleanedSnapshot? = captureCleanedSnapshot,
    clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    poll: () -> Void = {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
) throws -> SemanticTouchResolution {
    let startedAt = clock()
    let deadline = startedAt + 1.0
    var stableSince = startedAt
    var previous: TouchGeometry?
    var captures = 0

    while true {
        try CommandDeadline.check()
        guard let snapshot = capture() else {
            return .failure(try Codec.foryError("failed to take snapshot",
                category: IOSUseErrorCategory.lookup, code: IOSUseErrorCode.snapshotFailed,
                phase: IOSUseErrorPhase.snapshot, retryable: true, target: target))
        }
        let element: SnapshotElement
        switch rawFindInSnapshot(target, cs: snapshot, visibility: .only) {
        case .found(let found): element = found
        case .ambiguous(let matches): return .failure(try ambiguityResponse(target, matches: matches))
        case .fuzzy(let suggestions): return .failure(try notFoundResponse(target, suggestions: suggestions))
        case .notFound(let suggestions, let rejected):
            return .failure(try notFoundResponse(target, suggestions: suggestions, rejected: rejected))
        }
        guard let frame = interactionFrame(element.node) else {
            return .failure(try Codec.foryError(
                "\(command): element '\(target.label)' has no interaction frame",
                category: IOSUseErrorCategory.lookup, code: IOSUseErrorCode.elementNotActionable,
                phase: IOSUseErrorPhase.lookup, retryable: true, target: target,
                candidates: [makeErrorCandidate(element, rejectedBy: [
                    interactionFrameRejectionReason(element.node, in: snapshot.appFrame)
                        ?? IOSUseCandidateRejection.zeroAreaFrame
                ])], candidateCount: 1))
        }

        captures += 1
        let now = clock()
        let geometry = TouchGeometry(snapshot: snapshot, element: element, frame: frame)
        if let previous, geometry.matches(previous) {
            if now - stableSince >= 0.1 {
                DriverPerf.append("[perf] \(command).geometry captures=\(captures) elapsed=\(Int((now - startedAt) * 1000))ms")
                return .found(snapshot: snapshot, element: element, frame: frame)
            }
        } else {
            stableSince = now
            previous = geometry
        }
        guard now < deadline else {
            return .failure(try Codec.foryError(
                "\(command): element '\(target.label)' is still moving; no touch was dispatched",
                category: IOSUseErrorCategory.lookup, code: IOSUseErrorCode.elementNotActionable,
                phase: IOSUseErrorPhase.interaction, retryable: true, target: target,
                candidates: [makeErrorCandidate(element)], candidateCount: 1))
        }
        poll()
    }
}

private struct TouchGeometry {
    let bundleId: String
    let appFrame: CGRect
    let frame: CGRect
    let elementType: UInt
    let identifier: String?
    let label: String?

    init(snapshot: CleanedSnapshot, element: SnapshotElement, frame: CGRect) {
        bundleId = snapshot.bundleId
        appFrame = snapshot.appFrame
        self.frame = frame
        elementType = element.node.elementType
        identifier = element.node.identifier
        label = element.node.label
    }

    func matches(_ other: TouchGeometry) -> Bool {
        bundleId == other.bundleId && appFrame == other.appFrame
            && elementType == other.elementType && identifier == other.identifier && label == other.label
            && abs(frame.minX - other.frame.minX) <= 1
            && abs(frame.minY - other.frame.minY) <= 1
            && abs(frame.width - other.frame.width) <= 1
            && abs(frame.height - other.frame.height) <= 1
    }
}
