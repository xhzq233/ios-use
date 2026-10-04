import XCTest
import Fory

// MARK: - Input command

enum InputCommands {

    /// Type into the current keyboard focus. When a tap target is provided,
    /// tap it first to focus an input and require the keyboard to become visible.
    static func input(_ args: ForyInputArgs) throws -> ForyResponseFrame {
        let app = try Session.shared.ensureActive()
        guard args.deleteCount >= 0,
              args.deleteCount <= 1_048_576 else {
            return try Codec.foryError(
                "input: deleteCount must be between 0 and 1048576",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation,
                retryable: false,
                target: hasTapTarget(args.target) ? args.target : nil
            )
        }

        let targetSummary: ForyElementSummary
        if hasTapTarget(args.target) {
            switch try tapInputTarget(args.target, app: app) {
            case .success(let summary):
                targetSummary = summary
            case .failure(let response):
                return response
            }
        } else {
            targetSummary = ForyElementSummary()
        }

        let effectiveContent =
            String(
                repeating: "\u{7F}",
                count: Int(args.deleteCount)
            )
            + args.content
            + (args.enter ? "\n" : "")
        try CommandDeadline.check()
        guard typeText(effectiveContent) else {
            return try Codec.foryError(
                "input: failed to type text",
                category: IOSUseErrorCategory.action,
                code: IOSUseErrorCode.inputFailed,
                phase: IOSUseErrorPhase.interaction,
                retryable: true,
                target: hasTapTarget(args.target) ? args.target : nil
            )
        }
        let payload = ForyElementPayload(element: targetSummary)
        return try Codec.foryOK(payload)
    }
}

private enum InputTapResult {
    case success(ForyElementSummary)
    case failure(ForyResponseFrame)
}

private func hasTapTarget(_ target: ForyTarget) -> Bool {
    target.point != nil || !target.label.isEmpty
}

private func tapInputTarget(_ target: ForyTarget, app: XCUIApplication) throws -> InputTapResult {
    let summary: ForyElementSummary
    if let point = target.point {
        guard try RawPointer.perform(app: app, event: .tap(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))) == nil else {
            return .failure(try Codec.foryError(
                "input: failed to tap point '\(point.x),\(point.y)'",
                category: IOSUseErrorCategory.action,
                code: IOSUseErrorCode.inputFailed,
                phase: IOSUseErrorPhase.interaction,
                retryable: true,
                target: target
            ))
        }
        summary = ForyElementSummary(rect: ForyRect(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), w: 0, h: 0))
    } else {
        try Quiescence.wait(app: app, command: "input-focus")
        let elem: SnapshotElement
        let snapshot: CleanedSnapshot
        switch try resolveSemanticTouchTarget(target, command: "input-focus") {
        case .found(let cs, let found, _):
            snapshot = cs
            elem = found
        case .failure(let response): return .failure(response)
        }
        defer { withExtendedLifetime(snapshot) {} }
        guard try tapSnapshotCenter(elem.node, app: app) else {
            return .failure(try Codec.foryError(
                "input: failed to tap '\(target.label)'",
                category: IOSUseErrorCategory.action,
                code: IOSUseErrorCode.inputFailed,
                phase: IOSUseErrorPhase.interaction,
                retryable: true,
                target: target,
                candidates: [makeErrorCandidate(elem)],
                candidateCount: 1
            ))
        }
        summary = makeForyElementSummary(elem.node)
    }

    Thread.sleep(forTimeInterval: IOSUseProtocol.inputPostTapFocusSettleSeconds)
    return .success(summary)
}

private func tapSnapshotCenter(_ snapshot: SafeSnapshot, app: XCUIApplication) throws -> Bool {
    guard let frame = interactionFrame(snapshot) else { return false }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    return try RawPointer.perform(app: app, event: .tap(point), waitForIdle: false) == nil
}

private func typeText(_ text: String) -> Bool {
    var error: NSError?
    return XCFBTypeText(text, XCDefaultTypingFrequency(), &error)
}
