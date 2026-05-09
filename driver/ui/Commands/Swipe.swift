import XCTest

// MARK: - Swipe command (doc 3 & 5)

enum SwipeCommands {

    /// doc 5 — unified swipe with to/from/distance/dir/context.
    static func swipe(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = decodeArgsOptional(rawArgs, as: SwipeArgs.self) ?? SwipeArgs(
            to: nil, from: nil, distance: nil, dir: nil, traits: nil)
        let app = try Session.shared.ensureActive()

        defer { invalidateSnapshot() }  // mutation — drop cache

        // STEP 1: take cleaned snapshot (doc 5.1)
        guard let cs = getCleanedSnapshot() else {
            return Codec.makeError("failed to take snapshot")
        }

        // Path A0: from/to are both absolute points -> direct drag.
        if let from = args.from?.asPoint, let to = args.to?.asPoint {
            return handleAbsolutePointSwipe(from: from, to: to, app: app)
        }

        // Path B: `to` is a point [x, y] → STEP_POINT
        if let to = args.to, let point = to.asPoint {
            return handlePointSwipe(point, cs: cs, app: app)
        }
        // Path C: no `to` at all → STEP_DISTANCE
        if args.to == nil {
            return handleDistanceSwipe(args: args, cs: cs, app: app)
        }
        // Path A: `to` is a label → STEP 2+
        guard let label = args.to?.asLabel else {
            return Codec.makeError("swipe: invalid 'to' argument")
        }

        return handleLabelSwipe(label: label, args: args, cs: cs, app: app)
    }

    // MARK: - STEP 2-8 (label path)

    private static func handleLabelSwipe(label: String,
                                         args: SwipeArgs,
                                         cs: CleanedSnapshot,
                                         app: XCUIApplication) -> ResponseFrame {
        // STEP 2: all label commands share rawFind semantics so future changes
        // to exact/fuzzy/context behavior stay aligned automatically.
        let target: SnapshotElement
        switch rawFind(label, traits: args.traits) {
        case .found(let elem):
            target = elem
        case .ambiguous(let matches):
            return ambiguityResponse(label, matches: matches)
        case .fuzzy(let suggestions):
            if args.from != nil {
                return handleAnchorScroll(label: label, args: args, cs: cs, app: app)
            }
            return notFoundResponse(label,
                                    suggestions: suggestions,
                                    hint: "Try passing --from (anchor) to scroll from a known element")
        case .notFound(let suggestions):
            if args.from != nil {
                return handleAnchorScroll(label: label, args: args, cs: cs, app: app)
            }
            return notFoundResponse(label,
                                    suggestions: suggestions,
                                    hint: "Try passing --from (anchor) to scroll from a known element")
        }

        // STEP 3: already visible? return ok with 0 scrolls.
        if target.isVisible {
            return okScroll(target: target, scrolls: 0)
        }

        // STEP 4: find scrollable ancestor.
        guard let scrollView = findScrollableAncestor(target.node) else {
            return okScroll(target: target, scrolls: 0)
        }

        // STEP 5: direction inference from visible cells.
        let cellSnapshots = collectCellSnapshots(scrollView)
        let targetCell = findCellAncestor(target.node)
        let targetCellIdx = cellSnapshots.firstIndex { SnapshotMatchesElement($0.raw, targetCell.raw) }

        let visibleCells = cellSnapshots.filter { $0.isVisible }
        guard visibleCells.count >= 2 else {
            return Codec.makeError("less than 2 visible cells in scrollable")
        }
        let firstVisibleCell = visibleCells.first!
        let lastVisibleCell = visibleCells.last!
        let lastVisibleIdx = cellSnapshots.firstIndex { SnapshotMatchesElement($0.raw, lastVisibleCell.raw) } ?? 0

        let dx = firstVisibleCell.frame.minX - lastVisibleCell.frame.minX
        let dy = firstVisibleCell.frame.minY - lastVisibleCell.frame.minY
        let vertical = abs(dy) > abs(dx)

        // scrollUpwards: true = finger moves down/right (back/negative direction).
        let scrollUpwards: Bool
        if let d = args.dir {
            scrollUpwards = (d == .back)
        } else if let tci = targetCellIdx {
            scrollUpwards = tci < lastVisibleIdx
        } else {
            scrollUpwards = false  // default forth
        }

        // STEP 6: scroll loop.
        let scrolls = scrollLoop(scrollView: scrollView,
                                 label: label,
                                 traits: args.traits,
                                 vertical: vertical,
                                 scrollUpwards: scrollUpwards,
                                 app: app)

        switch scrolls {
        case .reachedMax:
            return Codec.makeError("max scroll count reached")
        case .hitBoundary:
            return boundaryResponse(vertical: vertical, scrollUpwards: scrollUpwards)
        case .snapshotFailed:
            return Codec.makeError("scroll: failed to rebuild snapshot (app may have exited)")
        case .found(let count, let finalTarget):
            // STEP 7: precise adjust via visibleFrame.
            preciseAdjust(targetCell: findCellAncestor(finalTarget),
                          scrollFrame: scrollView.frame,
                          app: app)
            return okScrollWithAncestors(node: finalTarget, scrolls: count)
        }
    }

    // MARK: - Anchor scroll (doc 5.3)

    private static func handleAnchorScroll(label: String,
                                           args: SwipeArgs,
                                           cs: CleanedSnapshot,
                                           app: XCUIApplication) -> ResponseFrame {
        let anchorScrollView: SafeSnapshot
        if let from = args.from, let pt = from.asPoint, pt.count == 2 {
            guard let scrollView = findScrollableAtPoint(CGPoint(x: pt[0], y: pt[1]), cs.root) else {
                return Codec.makeError("no scrollable found at from point")
            }
            anchorScrollView = scrollView
        } else if let from = args.from, let flabel = from.asLabel {
            let anchor: SnapshotElement
            switch rawFindInSnapshot(flabel, traits: nil, cs: cs) {
            case .found(let elem):
                anchor = elem
            case .ambiguous(let matches):
                return ambiguityResponse(flabel, matches: matches)
            case .fuzzy(let suggestions):
                return notFoundResponse(flabel,
                                        suggestions: suggestions,
                                        hint: "Try a more specific --from label or a coordinate anchor")
            case .notFound(let suggestions):
                return notFoundResponse(flabel,
                                        suggestions: suggestions,
                                        hint: "Try a more specific --from label or a coordinate anchor")
            }
            guard let scrollView = findScrollableAncestor(anchor.node) else {
                return Codec.makeError("anchor not inside a scrollable")
            }
            anchorScrollView = scrollView
        } else {
            return Codec.makeError("anchor scroll requires 'from'")
        }
        let scrollView = anchorScrollView
        let cells = collectCellSnapshots(scrollView)
        let visibleCells = cells.filter { $0.isVisible }
        guard visibleCells.count >= 2 else {
            return Codec.makeError("less than 2 visible cells in anchor's scrollable")
        }
        let dx = visibleCells.first!.frame.minX - visibleCells.last!.frame.minX
        let dy = visibleCells.first!.frame.minY - visibleCells.last!.frame.minY
        let vertical = abs(dy) > abs(dx)
        let scrollUpwards = (args.dir == .back)

        var prevFrames = visibleCells.map { $0.frame }
        let scrollFrame = scrollView.frame

        for i in 0..<ScrollConstants.maxScrollCount {
            if vertical {
                scrollUpwards
                    ? scrollUpByNormalizedDistance(0.75, scrollFrame: scrollFrame, app: app)
                    : scrollDownByNormalizedDistance(0.75, scrollFrame: scrollFrame, app: app)
            } else {
                scrollUpwards
                    ? scrollLeftByNormalizedDistance(0.75, scrollFrame: scrollFrame, app: app)
                    : scrollRightByNormalizedDistance(0.75, scrollFrame: scrollFrame, app: app)
            }
            Thread.sleep(forTimeInterval: ScrollConstants.settleInterval)
            invalidateSnapshot()

            guard let freshCS = rebuildCleanedSnapshot() else { break }
            switch rawFindInSnapshot(label, traits: args.traits, cs: freshCS) {
            case .found(let elem):
                if elem.isVisible {
                    return okScrollWithAncestors(node: elem.node, scrolls: i + 1)
                }
            case .ambiguous(let matches):
                return ambiguityResponse(label, matches: matches)
            case .fuzzy, .notFound:
                break
            }

            // Boundary detection: new visible frames identical to previous.
            guard let freshScrollView = reResolveScrollable(in: freshCS.rawRoot,
                                                            against: scrollView) else {
                return Codec.makeError("anchor scroll: failed to re-resolve scrollable")
            }
            let freshCells = collectCellSnapshots(freshScrollView).filter { $0.isVisible }.map { $0.frame }
            if freshCells == prevFrames {
                return boundaryResponse(vertical: vertical, scrollUpwards: scrollUpwards)
            }
            prevFrames = freshCells
        }
        return Codec.makeError("anchor scroll: max scroll count reached")
    }

    private static func handleAbsolutePointSwipe(from: [Double],
                                                 to: [Double],
                                                 app: XCUIApplication) -> ResponseFrame {
        guard from.count == 2, to.count == 2 else {
            return Codec.makeError("swipe: point arguments must be [x, y]")
        }
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = origin.withOffset(CGVector(dx: from[0], dy: from[1]))
        let end = origin.withOffset(CGVector(dx: to[0], dy: to[1]))
        XCPressAndDrag(start, end,
                       ScrollConstants.touchPressDuration,
                       ScrollConstants.touchVelocity,
                       ScrollConstants.touchHoldDuration)
        return Codec.makeOK([
            "ancestors": [String](),
            "type": "Coordinate",
            "label": "",
            "rect": [from[0].sanitized, from[1].sanitized, to[0].sanitized, to[1].sanitized],
            "scrolls": 1,
        ])
    }

    // MARK: - Point swipe (doc 5.2)

    private static func handlePointSwipe(_ point: [Double],
                                         cs: CleanedSnapshot,
                                         app: XCUIApplication) -> ResponseFrame {
        guard point.count == 2 else {
            return Codec.makeError("swipe: 'to' point must be [x, y]")
        }
        let p = CGPoint(x: point[0], y: point[1])
        guard let scrollView = findScrollableAtPoint(p, cs.root) else {
            return Codec.makeError("no scrollable at point")
        }
        let frame = scrollView.frame
        let axis = primaryScrollAxis(visibleCellFrames: visibleCellFrames(scrollView), scrollFrame: frame)
        // Point-swipe semantics: move the content point toward the viewport
        // center, so the finger drag vector is the inverse of point offset.
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let rawVector = CGVector(dx: center.x - p.x, dy: center.y - p.y)
        let vector = projectVectorToPrimaryAxis(rawVector, axis: axis)
        let vertical = axis == .vertical
        let scrollUpwards = vertical ? vector.dy > 0 : vector.dx > 0
        let axisName = vertical ? "vertical" : "horizontal"
        NSLog("[point-swipe] to=(%.1f,%.1f) axis=%@ rawVector=(%.1f,%.1f) vector=(%.1f,%.1f)",
              p.x, p.y,
              axisName,
              rawVector.dx, rawVector.dy,
              vector.dx, vector.dy)
        return performDirectScroll(scrollView: scrollView,
                                   responseNode: scrollView,
                                   vector: vector,
                                   vertical: vertical,
                                   scrollUpwards: scrollUpwards,
                                   app: app)
    }

    // MARK: - Distance-only swipe (doc 5.3)

    private static func handleDistanceSwipe(args: SwipeArgs,
                                            cs: CleanedSnapshot,
                                            app: XCUIApplication) -> ResponseFrame {
        let scrollNode = findLargestScrollable(cs.root)
        let scrollFrame = scrollNode?.frame ?? app.frame
        let dir = args.dir ?? .forth
        let axisSize = scrollFrame.height
        let distance = args.distance ?? (ScrollConstants.scrollTouchProportion * Double(axisSize))

        // Default to vertical direction — forth = content moves down (finger up = -dy).
        let vector: CGVector
        switch dir {
        case .forth:
            vector = CGVector(dx: 0, dy: -CGFloat(distance))
        case .back:
            vector = CGVector(dx: 0, dy: CGFloat(distance))
        }
        let node = scrollNode ?? cs.root
        return performDirectScroll(scrollView: node,
                                   responseNode: node,
                                   vector: vector,
                                   vertical: true,
                                   scrollUpwards: dir == .back,
                                   app: app)
    }

    // MARK: - STEP 6 helper

    private enum ScrollOutcome {
        case found(count: Int, target: SafeSnapshot)
        case hitBoundary
        case reachedMax
        case snapshotFailed
    }

    /// Scrolls, rebuilds snapshots, and re-finds the target by label until it
    /// becomes visible or motion stops at the boundary.
    /// Time complexity: O(r * n), where r is `maxScrollCount` and n is the
    /// number of nodes visited across rebuilt snapshots.
    private static func scrollLoop(scrollView: SafeSnapshot,
                                   label: String,
                                   traits: String?,
                                   vertical: Bool,
                                   scrollUpwards: Bool,
                                   app: XCUIApplication) -> ScrollOutcome {
        var prevFrames = collectCellSnapshots(scrollView).filter { $0.isVisible }.map { $0.frame }
        let scrollFrame = scrollView.frame

        for i in 0..<ScrollConstants.maxScrollCount {
            autoreleasepool {
                if vertical {
                    scrollUpwards
                        ? scrollUpByNormalizedDistance(0.75, scrollFrame: scrollFrame, app: app)
                        : scrollDownByNormalizedDistance(0.75, scrollFrame: scrollFrame, app: app)
                } else {
                    scrollUpwards
                        ? scrollLeftByNormalizedDistance(0.75, scrollFrame: scrollFrame, app: app)
                        : scrollRightByNormalizedDistance(0.75, scrollFrame: scrollFrame, app: app)
                }
            }
            Thread.sleep(forTimeInterval: ScrollConstants.settleInterval)

            invalidateSnapshot()
            guard let freshCS = rebuildCleanedSnapshot() else { return .snapshotFailed }

            // Re-find target by label (not identity) — survives snapshot rebuilds.
            switch rawFindInSnapshot(label, traits: traits, cs: freshCS) {
            case .found(let elem) where elem.isVisible:
                return .found(count: i + 1, target: elem.node)
            default:
                break
            }

            // Boundary: cells didn't move → at edge.
            guard let freshScrollView = findMatching(in: freshCS.rawRoot, against: scrollView) else {
                return .hitBoundary
            }
            let nowFrames = collectCellSnapshots(freshScrollView).filter { $0.isVisible }.map { $0.frame }
            if nowFrames == prevFrames {
                return .hitBoundary
            }
            prevFrames = nowFrames
        }
        return .reachedMax
    }

    /// Executes a single direct scroll (point/distance) and re-checks whether
    /// the scrollable subtree actually moved. If no effective drag is emitted,
    /// report a dedicated "too small to scroll" error; if frames stay unchanged
    /// after a real drag, report boundary.
    private static func performDirectScroll(scrollView: SafeSnapshot,
                                            responseNode: SafeSnapshot,
                                            vector: CGVector,
                                            vertical: Bool,
                                            scrollUpwards: Bool,
                                            app: XCUIApplication) -> ResponseFrame {
        let segments = scrollSegments(for: vector, scrollFrame: scrollView.frame)
        guard !segments.isEmpty else {
            NSLog("[point-swipe] too small to scroll vector=(%.1f,%.1f)", vector.dx, vector.dy)
            return tooSmallToScrollResponse(vertical: vertical, scrollUpwards: scrollUpwards)
        }

        let prevFrames = visibleCellFrames(scrollView)
        let segmentCount = dispatchScrollSegments(segments, scrollFrame: scrollView.frame, app: app)

        Thread.sleep(forTimeInterval: ScrollConstants.settleInterval)

        if !prevFrames.isEmpty,
           let freshCS = rebuildCleanedSnapshot(),
           let freshScrollView = findMatching(in: freshCS.rawRoot, against: scrollView) {
            let nowFrames = visibleCellFrames(freshScrollView)
            if nowFrames == prevFrames {
                NSLog("[point-swipe] hit boundary after %d segment(s)", segmentCount)
                return boundaryResponse(vertical: vertical, scrollUpwards: scrollUpwards)
            }

            let freshResponseNode = findMatching(in: freshCS.rawRoot, against: responseNode) ?? freshScrollView
            return okNodeScroll(node: freshResponseNode, scrolls: segmentCount)
        }

        return okNodeScroll(node: responseNode, scrolls: segmentCount)
    }

    // Find a node in the freshly built snapshot that matches (by identity, doc 5.4)
    // the original target pre-scroll.
    // Time complexity: O(n), where n is the number of nodes in the snapshot tree.
    private static func findMatching(in root: SafeSnapshot, against target: SafeSnapshot) -> SafeSnapshot? {
        var stack: [SafeSnapshot] = [root]
        while let n = stack.popLast() {
            if SnapshotMatchesElement(n.raw, target.raw) { return n }
            for c in n.children { stack.append(c) }
        }
        return nil
    }

    private static func reResolveScrollable(in root: SafeSnapshot,
                                            against target: SafeSnapshot) -> SafeSnapshot? {
        findMatching(in: root, against: target)
    }

    // STEP 7 precise adjust (doc 5.1)
    private static func preciseAdjust(targetCell: SafeSnapshot, scrollFrame: CGRect, app: XCUIApplication) {
        let frame = targetCell.frame
        var visible = targetCell.visibleFrame
        if visible.width <= 0 || visible.height <= 0 {
            visible = frame.intersection(scrollFrame)
        }
        guard visible.width > 0, visible.height > 0 else { return }
        let adjust = CGVector(dx: visible.width - frame.width,
                              dy: visible.height - frame.height)
        if abs(adjust.dx) > 1 || abs(adjust.dy) > 1 {
            scrollByVector(adjust, scrollFrame: scrollFrame, app: app)
        }
    }

    // MARK: - Responses

    private static func okScroll(target: SnapshotElement, scrolls: Int) -> ResponseFrame {
        let tn = elementTypeName(XCUIElement.ElementType(rawValue: UInt(target.node.elementType)) ?? .other)
        return Codec.makeOK([
            "ancestors": ancestorChainNames(target.node),
            "type": tn,
            "label": target.node.label ?? "",
            "rect": rectArray(target.node.frame),
            "scrolls": scrolls,
        ])
    }

    private static func okNodeScroll(node: SafeSnapshot, scrolls: Int) -> ResponseFrame {
        let tn = elementTypeName(XCUIElement.ElementType(rawValue: UInt(node.elementType)) ?? .other)
        return Codec.makeOK([
            "ancestors": ancestorChainNames(node),
            "type": tn,
            "label": node.label ?? "",
            "rect": rectArray(node.frame),
            "scrolls": scrolls,
        ])
    }

    private static func okScrollWithAncestors(node: SafeSnapshot, scrolls: Int) -> ResponseFrame {
        okNodeScroll(node: node, scrolls: scrolls)
    }

    private static func boundaryResponse(vertical: Bool, scrollUpwards: Bool) -> ResponseFrame {
        let axisName = vertical ? "vertical" : "horizontal"
        let dirStr = scrollUpwards ? "back" : "forth"
        return ResponseFrame(
            ok: false,
            error: "hit scroll boundary (\(axisName) \(dirStr))",
            data: AnyCodable([
                "atBoundary": true,
                "direction": dirStr,
            ] as [String: Any])
        )
    }

    private static func tooSmallToScrollResponse(vertical: Bool, scrollUpwards: Bool) -> ResponseFrame {
        let axisName = vertical ? "vertical" : "horizontal"
        let dirStr = scrollUpwards ? "back" : "forth"
        return ResponseFrame(
            ok: false,
            error: "swipe displacement too small to scroll (\(axisName) \(dirStr))",
            data: AnyCodable([
                "tooSmallToScroll": true,
                "direction": dirStr,
                "minDragDistance": Double(ScrollConstants.fuzzyPointThreshold),
            ] as [String: Any])
        )
    }
}

private func visibleCellFrames(_ scrollView: SafeSnapshot) -> [CGRect] {
    collectCellSnapshots(scrollView).filter { $0.isVisible }.map { $0.frame }
}

/// Uses the pre-indexed `byLabel` map first, then narrows by ancestor filters.
/// Time complexity: O(m + s), where m is the number of exact-label matches and
/// s is the number of fuzzy suggestions examined when no exact match exists.
