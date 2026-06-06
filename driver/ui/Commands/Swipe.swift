import XCTest
import Fory

// MARK: - Swipe command (doc 3 & 5)

enum SwipeCommands {

    /// doc 5 — unified swipe with to/from/distance/dir/traits.
    static func swipe(_ args: ForySwipeArgs) throws -> ForyResponseFrame {
        let app = try Session.shared.ensureActive()
        defer { invalidateSnapshot() }

        let toTarget = args.toTarget
        let fromTarget = args.fromTarget

        if toTarget.point != nil, (!toTarget.traits.isEmpty || toTarget.cindex != nil) {
            return Codec.foryError("swipe: traits/cindex require label to target")
        }
        if fromTarget.point != nil, (!fromTarget.traits.isEmpty || fromTarget.cindex != nil) {
            return Codec.foryError("swipe: traits/cindex require label from target")
        }
        if !fromTarget.traits.isEmpty || fromTarget.cindex != nil {
            return Codec.foryError("swipe: traits/cindex are only supported for to target")
        }

        // Path A0: from/to are both absolute points -> direct drag.
        if let from = fromTarget.point, let to = toTarget.point {
            return try handleAbsolutePointSwipe(from: from, to: to, app: app)
        }

        guard let cs = getCleanedSnapshot() else {
            return Codec.foryError("failed to take snapshot")
        }

        // Path B: `to` is a point → STEP_POINT
        if let point = toTarget.point {
            return try handlePointSwipe(point, cs: cs, app: app)
        }
        // Path C: no `to` label → STEP_DISTANCE
        if toTarget.label.isEmpty && toTarget.point == nil {
            return try handleDistanceSwipe(args: args, cs: cs, app: app)
        }
        // Path A: `to` is a label → STEP 2+
        let label = toTarget.label

        return try handleLabelSwipe(target: toTarget, args: args, fromTarget: fromTarget, cs: cs, app: app)
    }

    // MARK: - STEP 2-8 (label path)

    private static func handleLabelSwipe(target toTarget: ForyTarget,
                                         args: ForySwipeArgs,
                                         fromTarget: ForyTarget,
                                         cs: CleanedSnapshot,
                                         app: XCUIApplication) throws -> ForyResponseFrame {
        let label = toTarget.label
        let target: SnapshotElement
        switch rawFindInSnapshot(toTarget, cs: cs, visibility: .any) {
        case .found(let elem):
            target = elem
        case .ambiguous(let matches):
            return swipeAmbiguityResponse(label, matches: matches)
        case .fuzzy(let suggestions):
            if !fromTarget.label.isEmpty || fromTarget.point != nil {
                return try handleAnchorScroll(target: toTarget, args: args, fromTarget: fromTarget, cs: cs, app: app)
            }
            return swipeNotFoundResponse(label,
                                         suggestions: suggestions,
                                         hint: "Try passing --from (anchor) to scroll from a known element")
        case .notFound(let suggestions):
            if !fromTarget.label.isEmpty || fromTarget.point != nil {
                return try handleAnchorScroll(target: toTarget, args: args, fromTarget: fromTarget, cs: cs, app: app)
            }
            return swipeNotFoundResponse(label,
                                         suggestions: suggestions,
                                         hint: "Try passing --from (anchor) to scroll from a known element")
        }

        // STEP 3: find scrollable ancestor.
        guard let scrollView = findScrollableAncestor(target.node) else {
            if isVisibleWithEffectiveGeometry(target, in: app.frame) {
                return okScroll(target: target, scrolls: 0, scrollDirection: "")
            }
            return okScroll(target: target, scrolls: 0, scrollDirection: "")
        }

        // STEP 4: already visible in app frame. Still try centering the target
        // in its scrollable so edge / overlay-adjacent targets become easier to tap.
        if isVisibleWithEffectiveGeometry(target, in: app.frame) {
            let adjusted = centerTargetInScrollFrame(targetCell: findCellAncestor(target.node),
                                                     scrollFrame: scrollView.frame,
                                                     app: app)
            return okScroll(target: target, scrolls: adjusted.count, scrollDirection: adjusted.scrollDirection)
        }

        // STEP 5: direction inference from visible cells.
        let cellSnapshots = collectCellSnapshots(scrollView)
        let targetCell = findCellAncestor(target.node)
        let targetCellIdx = cellSnapshots.firstIndex { SnapshotMatchesElement($0.raw, targetCell.raw) }

        let visibleCells = cellSnapshots.filter { $0.isVisible }
        guard visibleCells.count >= 2 else {
            return Codec.foryError("less than 2 visible cells in scrollable")
        }
        let firstVisibleCell = visibleCells.first!
        let lastVisibleCell = visibleCells.last!
        let lastVisibleIdx = cellSnapshots.firstIndex { SnapshotMatchesElement($0.raw, lastVisibleCell.raw) } ?? 0

        let dx = firstVisibleCell.frame.minX - lastVisibleCell.frame.minX
        let dy = firstVisibleCell.frame.minY - lastVisibleCell.frame.minY
        let vertical = abs(dy) > abs(dx)

        let scrollUpwards: Bool
        if args.dir == IOSUseProtocol.XCConstants.swipeDirectionBack {
            scrollUpwards = true
        } else if args.dir == IOSUseProtocol.XCConstants.swipeDirectionForth {
            scrollUpwards = false
        } else if let tci = targetCellIdx {
            scrollUpwards = tci < lastVisibleIdx
        } else {
            scrollUpwards = false
        }

        // STEP 6: scroll loop.
        let scrolls = scrollUntilVisible(scrollView: scrollView,
                                            target: toTarget,
                                            vertical: vertical,
                                            scrollUpwards: scrollUpwards,
                                            app: app)

        switch scrolls {
        case .reachedMax:
            return Codec.foryError("max scroll count reached")
        case .hitBoundary:
            return try boundaryResponse(vertical: vertical, scrollUpwards: scrollUpwards)
        case .snapshotFailed:
            return Codec.foryError("scroll: failed to rebuild snapshot (app may have exited)")
        case .ambiguous(let lbl, let matches):
            return swipeAmbiguityResponse(lbl, matches: matches)
        case .found(let count, let finalTarget, _):
            return okScrollWithAncestors(node: finalTarget,
                                         scrolls: count,
                                         scrollDirection: scrollDirectionName(vertical: vertical, scrollUpwards: scrollUpwards))
        }
    }

    // MARK: - Anchor scroll (doc 5.3)

    private static func handleAnchorScroll(target toTarget: ForyTarget,
                                           args: ForySwipeArgs,
                                           fromTarget: ForyTarget,
                                           cs: CleanedSnapshot,
                                           app: XCUIApplication) throws -> ForyResponseFrame {
        let label = toTarget.label
        let anchorScrollView: SafeSnapshot
        if let pt = fromTarget.point {
            guard let scrollView = findScrollableAtPoint(CGPoint(x: pt.x, y: pt.y), cs.root) else {
                return Codec.foryError("no scrollable found at from point")
            }
            anchorScrollView = scrollView
        } else if !fromTarget.label.isEmpty {
            let anchor: SnapshotElement
            switch rawFindInSnapshot(ForyTarget(label: fromTarget.label), cs: cs, visibility: .only) {
            case .found(let elem):
                anchor = elem
            case .ambiguous(let matches):
                return swipeAmbiguityResponse(fromTarget.label, matches: matches)
            case .fuzzy(let suggestions):
                return swipeNotFoundResponse(fromTarget.label,
                                             suggestions: suggestions,
                                             hint: "Try a more specific --from label or a coordinate anchor")
            case .notFound(let suggestions):
                return swipeNotFoundResponse(fromTarget.label,
                                             suggestions: suggestions,
                                             hint: "Try a more specific --from label or a coordinate anchor")
            }
            guard let scrollView = findScrollableAncestor(anchor.node) else {
                return Codec.foryError("anchor not inside a scrollable")
            }
            anchorScrollView = scrollView
        } else {
            return Codec.foryError("anchor scroll requires 'from'")
        }
        let cells = collectCellSnapshots(anchorScrollView)
        let visibleCells = cells.filter { $0.isVisible }
        guard visibleCells.count >= 2 else {
            return Codec.foryError("less than 2 visible cells in anchor's scrollable")
        }
        let dx = visibleCells.first!.frame.minX - visibleCells.last!.frame.minX
        let dy = visibleCells.first!.frame.minY - visibleCells.last!.frame.minY
        let vertical = abs(dy) > abs(dx)
        let scrollUpwards = args.dir == IOSUseProtocol.XCConstants.swipeDirectionBack

        let result = scrollUntilVisible(scrollView: anchorScrollView,
                                        target: toTarget,
                                        vertical: vertical,
                                        scrollUpwards: scrollUpwards,
                                        app: app)
        switch result {
        case .found(let count, let target, _):
            return okScrollWithAncestors(node: target,
                                         scrolls: count,
                                         scrollDirection: scrollDirectionName(vertical: vertical, scrollUpwards: scrollUpwards))
        case .hitBoundary:
            return try boundaryResponse(vertical: vertical, scrollUpwards: scrollUpwards)
        case .reachedMax:
            return Codec.foryError("anchor scroll: max scroll count reached")
        case .snapshotFailed:
            return Codec.foryError("anchor scroll: failed to rebuild snapshot (app may have exited)")
        case .ambiguous(let lbl, let matches):
            return swipeAmbiguityResponse(lbl, matches: matches)
        }
    }

    private static func handleAbsolutePointSwipe(from: ForyPoint,
                                                 to: ForyPoint,
                                                 app: XCUIApplication) throws -> ForyResponseFrame {
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = origin.withOffset(CGVector(dx: from.x, dy: from.y))
        let end = origin.withOffset(CGVector(dx: to.x, dy: to.y))
        _ = RawPointer.perform(
            app: app,
            event: .drag(
                start: start,
                end: end,
                pressDuration: IOSUseProtocol.touchPressDuration,
                velocity: IOSUseProtocol.touchVelocity,
                holdDuration: IOSUseProtocol.touchHoldDuration
            )
        )
        let payload = ForySwipePayload(
            ancestors: [],
            elemType: IOSUseProtocol.XCConstants.coordinateElementTypeRawValue,
            label: "",
            rect: ForyRect(
                x: Int32(from.x.sanitized),
                y: Int32(from.y.sanitized),
                w: Int32(to.x.sanitized),
                h: Int32(to.y.sanitized)
            ),
            scrolls: 1,
            scrollDirection: scrollDirectionName(vector: CGVector(dx: to.x - from.x, dy: to.y - from.y))
        )
        return try Codec.foryOK(payload)
    }

    // MARK: - Point swipe (doc 5.2)

    private static func handlePointSwipe(_ point: ForyPoint,
                                         cs: CleanedSnapshot,
                                         app: XCUIApplication) throws -> ForyResponseFrame {
        let p = CGPoint(x: point.x, y: point.y)
        guard let scrollView = findScrollableAtPoint(p, cs.root) else {
            return Codec.foryError("no scrollable at point")
        }
        let frame = scrollView.frame
        let axis = primaryScrollAxis(visibleCellFrames: collectVisibleCellFrames(scrollView), scrollFrame: frame)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let rawVector = CGVector(dx: center.x - p.x, dy: center.y - p.y)
        let vector = projectVectorToPrimaryAxis(rawVector, axis: axis)
        let vertical = axis == .vertical
        let scrollUpwards = vertical ? vector.dy > 0 : vector.dx > 0
        let axisName = vertical ? "vertical" : "horizontal"
        DriverLog.info(String(
            format: "[point-swipe] to=(%.1f,%.1f) axis=%@ rawVector=(%.1f,%.1f) vector=(%.1f,%.1f)",
            p.x,
            p.y,
            axisName,
            rawVector.dx,
            rawVector.dy,
            vector.dx,
            vector.dy
        ))
        return try performDirectScroll(scrollView: scrollView,
                                   responseNode: scrollView,
                                   vector: vector,
                                   vertical: vertical,
                                   scrollUpwards: scrollUpwards,
                                   app: app)
    }

    // MARK: - Distance-only swipe (doc 5.3)

    private static func handleDistanceSwipe(args: ForySwipeArgs,
                                            cs: CleanedSnapshot,
                                            app: XCUIApplication) throws -> ForyResponseFrame {
        let scrollNode = findLargestScrollable(cs.root)
        let scrollFrame = scrollNode?.frame ?? app.frame
        let isBack = args.dir == IOSUseProtocol.XCConstants.swipeDirectionBack
        let axis = primaryScrollAxis(visibleCellFrames: collectVisibleCellFrames(scrollNode ?? cs.root), scrollFrame: scrollFrame)
        let axisSize = axis == .vertical ? scrollFrame.height : scrollFrame.width
        let distance = args.distance > 0 ? args.distance : (IOSUseProtocol.scrollTouchProportion * Double(axisSize))

        let vector: CGVector
        let vertical = axis == .vertical
        if vertical {
            vector = isBack
                ? CGVector(dx: 0, dy: CGFloat(distance))
                : CGVector(dx: 0, dy: -CGFloat(distance))
        } else {
            vector = isBack
                ? CGVector(dx: CGFloat(distance), dy: 0)
                : CGVector(dx: -CGFloat(distance), dy: 0)
        }
        let node = scrollNode ?? cs.root
        return try performDirectScroll(scrollView: node,
                                   responseNode: node,
                                   vector: vector,
                                   vertical: vertical,
                                   scrollUpwards: isBack,
                                   app: app)
    }

    // MARK: - STEP 6 helper

    private enum ScrollOutcome {
        case found(count: Int, target: SafeSnapshot, freshScrollView: SafeSnapshot)
        case hitBoundary
        case reachedMax
        case snapshotFailed
        case ambiguous(label: String, matches: [SnapshotElement])
    }

    private static func scrollUntilVisible(scrollView: SafeSnapshot,
                                   target: ForyTarget,
                                   vertical: Bool,
                                   scrollUpwards: Bool,
                                   app: XCUIApplication) -> ScrollOutcome {
        var prevFrames = collectVisibleCellFrames(scrollView)
        let scrollFrame = scrollView.frame

        for i in 0..<IOSUseProtocol.maxScrollCount {
            autoreleasepool {
                if vertical {
                    scrollUpwards
                        ? scrollUpByNormalizedDistance(CGFloat(IOSUseProtocol.scrollTouchProportion), scrollFrame: scrollFrame, app: app)
                        : scrollDownByNormalizedDistance(CGFloat(IOSUseProtocol.scrollTouchProportion), scrollFrame: scrollFrame, app: app)
                } else {
                    scrollUpwards
                        ? scrollLeftByNormalizedDistance(CGFloat(IOSUseProtocol.scrollTouchProportion), scrollFrame: scrollFrame, app: app)
                        : scrollRightByNormalizedDistance(CGFloat(IOSUseProtocol.scrollTouchProportion), scrollFrame: scrollFrame, app: app)
                }
            }
            Thread.sleep(forTimeInterval: IOSUseProtocol.scrollSettleInterval)

            invalidateSnapshot()
            guard let freshCS = rebuildCleanedSnapshot() else { return .snapshotFailed }

            guard let freshScrollView = findMatching(in: freshCS.rawRoot, against: scrollView) else {
                return .hitBoundary
            }

            switch rawFindInSnapshot(target, cs: freshCS, enableFuzzy: false, visibility: .only) {
            case .found(let elem):
                return .found(count: i + 1, target: elem.node, freshScrollView: freshScrollView)
            case .ambiguous(let matches):
                return .ambiguous(label: target.label, matches: matches)
            default:
                break
            }

            let nowFrames = collectVisibleCellFrames(freshScrollView)
            if nowFrames == prevFrames {
                return .hitBoundary
            }
            prevFrames = nowFrames
        }
        return .reachedMax
    }

    private static func performDirectScroll(scrollView: SafeSnapshot,
                                            responseNode: SafeSnapshot,
                                            vector: CGVector,
                                            vertical: Bool,
                                            scrollUpwards: Bool,
                                            app: XCUIApplication) throws -> ForyResponseFrame {
        let segments = scrollSegments(for: vector, scrollFrame: scrollView.frame)
        guard !segments.isEmpty else {
            DriverLog.info(String(format: "[point-swipe] too small to scroll vector=(%.1f,%.1f)", vector.dx, vector.dy))
            return try tooSmallToScrollResponse(vertical: vertical, scrollUpwards: scrollUpwards)
        }

        let prevFrames = collectVisibleCellFrames(scrollView)
        let segmentCount = dispatchScrollSegments(segments, scrollFrame: scrollView.frame, app: app)

        Thread.sleep(forTimeInterval: IOSUseProtocol.scrollSettleInterval)

        if !prevFrames.isEmpty,
           let freshCS = rebuildCleanedSnapshot(),
           let freshScrollView = findMatching(in: freshCS.rawRoot, against: scrollView) {
            let nowFrames = collectVisibleCellFrames(freshScrollView)
            if nowFrames == prevFrames {
                DriverLog.info("[point-swipe] hit boundary after \(segmentCount) segment(s)")
                return try boundaryResponse(vertical: vertical, scrollUpwards: scrollUpwards)
            }

            let freshResponseNode = SnapshotMatchesElement(responseNode.raw, scrollView.raw)
                ? freshScrollView
                : (findMatching(in: freshCS.rawRoot, against: responseNode) ?? freshScrollView)
            return okNodeScroll(node: freshResponseNode,
                                scrolls: segmentCount,
                                scrollDirection: scrollDirectionName(vertical: vertical, scrollUpwards: scrollUpwards))
        }

        return okNodeScroll(node: responseNode,
                            scrolls: segmentCount,
                            scrollDirection: scrollDirectionName(vertical: vertical, scrollUpwards: scrollUpwards))
    }

    private static func findMatching(in root: SafeSnapshot, against target: SafeSnapshot) -> SafeSnapshot? {
        var stack: [SafeSnapshot] = [root]
        while let n = stack.popLast() {
            if SnapshotMatchesElement(n.raw, target.raw) { return n }
            for c in n.children { stack.append(c) }
        }
        return nil
    }

    /// Time complexity: O(k), where k is the emitted center-scroll segment count.
    private static func centerTargetInScrollFrame(targetCell: SafeSnapshot, scrollFrame: CGRect, app: XCUIApplication) -> (count: Int, scrollDirection: String) {
        let adjust = centerScrollAdjustment(targetFrame: targetCell.frame, scrollFrame: scrollFrame)
        if abs(adjust.dx) > 1 || abs(adjust.dy) > 1 {
            let count = scrollByVector(adjust, scrollFrame: scrollFrame, app: app)
            return (count, count > 0 ? scrollDirectionName(vector: adjust) : "")
        }
        return (0, "")
    }

    // MARK: - Responses

    private static func okScroll(target: SnapshotElement, scrolls: Int, scrollDirection: String) -> ForyResponseFrame {
        let payload = ForySwipePayload(
            element: makeForyElementSummary(target.node, includeAncestors: true),
            scrolls: Int32(scrolls),
            scrollDirection: scrollDirection
        )
        return (try? Codec.foryOK(payload)) ?? Codec.foryError("serialization failed")
    }

    private static func okNodeScroll(node: SafeSnapshot, scrolls: Int, scrollDirection: String) -> ForyResponseFrame {
        let payload = ForySwipePayload(
            element: makeForyElementSummary(node, includeAncestors: true),
            scrolls: Int32(scrolls),
            scrollDirection: scrollDirection
        )
        return (try? Codec.foryOK(payload)) ?? Codec.foryError("serialization failed")
    }

    private static func okScrollWithAncestors(node: SafeSnapshot, scrolls: Int, scrollDirection: String) -> ForyResponseFrame {
        okNodeScroll(node: node, scrolls: scrolls, scrollDirection: scrollDirection)
    }

    private static func boundaryResponse(vertical: Bool, scrollUpwards: Bool) throws -> ForyResponseFrame {
        Codec.foryError("hit scroll boundary: direction=\(scrollDirectionName(vertical: vertical, scrollUpwards: scrollUpwards))")
    }

    private static func tooSmallToScrollResponse(vertical: Bool, scrollUpwards: Bool) throws -> ForyResponseFrame {
        Codec.foryError("swipe displacement too small to scroll: direction=\(scrollDirectionName(vertical: vertical, scrollUpwards: scrollUpwards)), minDragDistance=\(IOSUseProtocol.fuzzyPointThreshold)")
    }

    private static func swipeAmbiguityResponse(_ label: String, matches: [SnapshotElement]) -> ForyResponseFrame {
        let rendered = matches.map { makeForyFindMatch($0, includeAncestors: true) }.map(renderSwipeMatch).joined(separator: "; ")
        let suffix = rendered.isEmpty ? "" : "; matches: \(rendered)"
        return Codec.foryError("label '\(label)' is ambiguous (\(matches.count) matches)\(suffix); hint: Try adding --traits to disambiguate")
    }

    private static func swipeNotFoundResponse(_ label: String, suggestions: [String], hint: String) -> ForyResponseFrame {
        var parts = ["label '\(label)' not found"]
        if !suggestions.isEmpty {
            parts.append("suggestions: \(suggestions.joined(separator: ", "))")
        }
        if !hint.isEmpty {
            parts.append("hint: \(hint)")
        }
        return Codec.foryError(parts.joined(separator: "; "))
    }

    private static func renderSwipeMatch(_ match: ForyFindMatch) -> String {
        let type = elementTypeName(XCUIElement.ElementType(rawValue: UInt(match.elemType)) ?? .other)
        let ancestors = match.ancestors.joined(separator: " > ")
        let rect = match.rect.map { "\($0.x),\($0.y),\($0.w),\($0.h)" } ?? ""
        let prefix = ancestors.isEmpty ? "" : "[\(ancestors)] "
        return "\(prefix)\(type) \"\(match.label)\" (\(rect))"
    }
}

func scrollDirectionName(vertical: Bool, scrollUpwards: Bool) -> String {
    if vertical {
        return scrollUpwards ? "up" : "down"
    }
    return scrollUpwards ? "left" : "right"
}

func scrollDirectionName(vector: CGVector) -> String {
    if abs(vector.dy) >= abs(vector.dx) {
        if vector.dy > 0 { return "up" }
        if vector.dy < 0 { return "down" }
    } else {
        if vector.dx > 0 { return "left" }
        if vector.dx < 0 { return "right" }
    }
    return ""
}
