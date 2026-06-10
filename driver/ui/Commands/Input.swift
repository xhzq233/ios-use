import XCTest
import Fory

// MARK: - Input command

enum InputCommands {

    /// Type into the current keyboard focus. When a tap target is provided,
    /// tap it first to focus an input and require the keyboard to become visible.
    static func input(_ args: ForyInputArgs) throws -> ForyResponseFrame {
        let app = try Session.shared.ensureActive()
        defer { invalidateSnapshot() }

        let targetSummary: ForyElementSummary
        if hasTapTarget(args.target) {
            switch tapInputTarget(args.target, app: app) {
            case .success(let summary):
                targetSummary = summary
            case .failure(let response):
                return response
            }
        } else {
            targetSummary = ForyElementSummary()
        }

        guard typeText(args.content) else {
            return Codec.foryError("input: failed to type text")
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

private func tapInputTarget(_ target: ForyTarget, app: XCUIApplication) -> InputTapResult {
    let summary: ForyElementSummary
    if let point = target.point {
        guard RawPointer.perform(app: app, event: .tap(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))) == nil else {
            return .failure(Codec.foryError("input: failed to tap point '\(point.x),\(point.y)'"))
        }
        summary = ForyElementSummary(rect: ForyRect(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), w: 0, h: 0))
    } else {
        let elem: SnapshotElement
        switch rawFind(target, visibility: .only) {
        case .found(let e): elem = e
        case .ambiguous(let matches): return .failure(ambiguityResponse(target.label, matches: matches))
        case .fuzzy(let s):
            return .failure(notFoundResponse(target.label,
                                             suggestions: s,
                                             hint: "Try adding --traits, or verify the active app before typing"))
        case .notFound(let s):
            return .failure(notFoundResponse(target.label,
                                             suggestions: s,
                                             hint: "Try adding --traits, or verify the active app before typing"))
        }
        guard tapSnapshotCenter(elem.node, app: app) else {
            return .failure(Codec.foryError("input: failed to tap '\(target.label)'"))
        }
        summary = makeForyElementSummary(elem.node)
    }

    Thread.sleep(forTimeInterval: IOSUseProtocol.inputPostTapFocusSettleSeconds)
    invalidateSnapshot()
    return .success(summary)
}

private func tapSnapshotCenter(_ snapshot: SafeSnapshot, app: XCUIApplication) -> Bool {
    let frame = snapshot.frame.integral
    guard !frame.isEmpty else { return false }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    return RawPointer.perform(app: app, event: .tap(point)) == nil
}

private func typeText(_ text: String) -> Bool {
    var error: NSError?
    return XCFBTypeText(text, XCDefaultTypingFrequency(), &error)
}
