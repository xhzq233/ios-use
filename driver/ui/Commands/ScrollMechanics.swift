import XCTest

enum ScrollAxis {
    case vertical
    case horizontal
}

/// An offscreen target and its viewport share App coordinates. Prefer geometry
/// over accessibility traversal order, which need not match visual placement.
func scrollBackwardsToward(targetFrame: CGRect, scrollFrame: CGRect, axis: ScrollAxis) -> Bool? {
    guard !targetFrame.isEmpty, !targetFrame.isInfinite, !targetFrame.isNull,
          !scrollFrame.isEmpty, !scrollFrame.isInfinite, !scrollFrame.isNull else { return nil }
    let targetMin = axis == .vertical ? targetFrame.minY : targetFrame.minX
    let targetMax = axis == .vertical ? targetFrame.maxY : targetFrame.maxX
    let viewMin = axis == .vertical ? scrollFrame.minY : scrollFrame.minX
    let viewMax = axis == .vertical ? scrollFrame.maxY : scrollFrame.maxX
    if targetMin < viewMin && targetMax <= viewMax { return true }
    if targetMax > viewMax && targetMin >= viewMin { return false }
    return nil
}

// MARK: - Normalized direction helpers (doc 5.8)

/// Content scrolls up → finger moves down (+dy)
func scrollUpByNormalizedDistance(_ dist: Double, scrollFrame: CGRect, app: XCUIApplication,
                                  displayContext: XCDisplayContext? = nil) throws {
    let vector = CGVector(dx: 0, dy: scrollFrame.height * CGFloat(dist))
    try scrollByVector(vector, scrollFrame: scrollFrame, app: app, displayContext: displayContext)
}

/// Content scrolls down → finger moves up (-dy)
func scrollDownByNormalizedDistance(_ dist: Double, scrollFrame: CGRect, app: XCUIApplication,
                                    displayContext: XCDisplayContext? = nil) throws {
    let vector = CGVector(dx: 0, dy: -scrollFrame.height * CGFloat(dist))
    try scrollByVector(vector, scrollFrame: scrollFrame, app: app, displayContext: displayContext)
}

/// Content scrolls left → finger moves right (+dx)
func scrollLeftByNormalizedDistance(_ dist: Double, scrollFrame: CGRect, app: XCUIApplication,
                                    displayContext: XCDisplayContext? = nil) throws {
    let vector = CGVector(dx: scrollFrame.width * CGFloat(dist), dy: 0)
    try scrollByVector(vector, scrollFrame: scrollFrame, app: app, displayContext: displayContext)
}

/// Content scrolls right → finger moves left (-dx)
func scrollRightByNormalizedDistance(_ dist: Double, scrollFrame: CGRect, app: XCUIApplication,
                                     displayContext: XCDisplayContext? = nil) throws {
    let vector = CGVector(dx: -scrollFrame.width * CGFloat(dist), dy: 0)
    try scrollByVector(vector, scrollFrame: scrollFrame, app: app, displayContext: displayContext)
}

// MARK: - Vector scroll (segmented, doc 5.8)

/// WDA's fb_scrollByVector: segment vector into chunks no larger than 75% of
/// scrollFrame, then dispatch each chunk via coordinate press+drag.
/// Time complexity: O(k), where k is the emitted segment count capped by
/// `preciseScrollMaxSegments`.
func scrollSegments(for vector: CGVector, scrollFrame: CGRect) -> [CGVector] {
    guard scrollFrame.width > 0, scrollFrame.height > 0 else { return [] }

    var boundingVector = CGVector(
        dx: scrollFrame.width * CGFloat(IOSUseProtocol.scrollTouchProportion),
        dy: scrollFrame.height * CGFloat(IOSUseProtocol.scrollTouchProportion)
    )
    boundingVector.dx = floor(copysign(boundingVector.dx, vector.dx))
    boundingVector.dy = floor(copysign(boundingVector.dy, vector.dy))

    // If both axes are zero, nothing to do.
    if boundingVector.dx == 0 && boundingVector.dy == 0 { return [] }

    var remaining = vector
    var attempts = IOSUseProtocol.preciseScrollMaxSegments
    var segments: [CGVector] = []

    while true {
        let segment = CGVector(
            dx: abs(remaining.dx) > abs(boundingVector.dx) ? boundingVector.dx : remaining.dx,
            dy: abs(remaining.dy) > abs(boundingVector.dy) ? boundingVector.dy : remaining.dy
        )
        remaining = CGVector(dx: remaining.dx - segment.dx, dy: remaining.dy - segment.dy)

        // Tiny residual segments do not form a meaningful scroll. Drop them at
        // the planning stage so callers can distinguish "no effective drag"
        // from "real drag dispatched but content hit boundary".
        if abs(segment.dx) >= CGFloat(IOSUseProtocol.fuzzyPointThreshold)
            || abs(segment.dy) >= CGFloat(IOSUseProtocol.fuzzyPointThreshold) {
            segments.append(segment)
        }

        let shouldFinish = fuzzyEqualVector(remaining, .zero, threshold: 1) || attempts <= 1
        if shouldFinish { break }
        attempts -= 1
    }
    return segments
}

/// Content geometry is evidence, not a property of the viewport's aspect
/// ratio. Ambiguous grids and sparse trees remain unknown. Use centers so
/// differently aligned text inside full-width rows does not bias the axis.
func primaryScrollAxis(visibleCellFrames: [CGRect], scrollFrame: CGRect) -> ScrollAxis? {
    let frames = visibleCellFrames.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
    guard frames.count >= 2, let first = frames.first else { return nil }
    var minX = first.midX, maxX = first.midX
    var minY = first.midY, maxY = first.midY
    for frame in frames.dropFirst() {
        minX = min(minX, frame.midX); maxX = max(maxX, frame.midX)
        minY = min(minY, frame.midY); maxY = max(maxY, frame.midY)
    }
    let dx = maxX - minX, dy = maxY - minY
    guard max(dx, dy) > 1 else { return nil }
    if dy > dx * 1.5 { return .vertical }
    if dx > dy * 1.5 { return .horizontal }
    return nil
}

/// An offscreen target can disambiguate the axis without any extra observation.
func scrollAxisToward(targetFrame: CGRect, scrollFrame: CGRect) -> ScrollAxis? {
    let x = scrollBackwardsToward(targetFrame: targetFrame, scrollFrame: scrollFrame, axis: .horizontal)
    let y = scrollBackwardsToward(targetFrame: targetFrame, scrollFrame: scrollFrame, axis: .vertical)
    if x != nil && y == nil { return .horizontal }
    if y != nil && x == nil { return .vertical }
    return nil
}

/// A search may try the other axis once, only before any content progress and
/// only when the initial axis was unknown. Direct/distance drags never use it.
struct ScrollAxisSearch {
    private(set) var axis: ScrollAxis
    private var mayTryAlternate: Bool

    init(hint: ScrollAxis?) {
        axis = hint ?? .vertical
        mayTryAlternate = hint == nil
    }

    mutating func observe(changed: Bool?) -> Bool {
        if changed == true { mayTryAlternate = false; return false }
        guard changed == false, mayTryAlternate else { return false }
        axis = axis == .vertical ? .horizontal : .vertical
        mayTryAlternate = false
        return true
    }
}

/// Keeps only the component aligned with the scrollable's dominant axis so a
/// point-swipe on a vertical list cannot degrade into a horizontal tap-drag.
/// Time complexity: O(1).
func projectVectorToPrimaryAxis(_ vector: CGVector, axis: ScrollAxis) -> CGVector {
    switch axis {
    case .vertical:
        return CGVector(dx: 0, dy: vector.dy)
    case .horizontal:
        return CGVector(dx: vector.dx, dy: 0)
    }
}

/// Executes each precomputed segment exactly once and returns the number of
/// segments that were dispatched.
/// Time complexity: O(k), where k is the segment count.
func dispatchScrollSegments(_ segments: [CGVector], scrollFrame: CGRect, app: XCUIApplication,
                            displayContext: XCDisplayContext? = nil) throws -> Int {
    guard !segments.isEmpty else { return 0 }
    let origin = try RawPointer.origin(app: app, displayContext: displayContext)
    for (index, segment) in segments.enumerated() {
        try autoreleasepool {
            try scrollAncestorByVector(segment, scrollFrame: scrollFrame, app: app, origin: origin)
        }

        if index < segments.count - 1 {
            // doc 5.8 — segment-level settle (multi-segment requires brief settle
            // for UIScrollView to flush; single-segment callers still get one sleep
            // before next outer iteration).
            Thread.sleep(forTimeInterval: IOSUseProtocol.scrollSettleInterval)
        }
    }
    return segments.count
}

/// Plans then dispatches scroll segments.
/// Time complexity: O(k), where k is the segment count.
func scrollByVector(_ vector: CGVector, scrollFrame: CGRect, app: XCUIApplication,
                    displayContext: XCDisplayContext? = nil) throws -> Int {
    let segments = scrollSegments(for: vector, scrollFrame: scrollFrame)
    return try dispatchScrollSegments(segments, scrollFrame: scrollFrame, app: app, displayContext: displayContext)
}

/// Computes the vector that drags the target's center to the scroll frame's
/// center. Positive values mean finger moves down/right.
/// Time complexity: O(1).
func centerScrollAdjustment(targetFrame: CGRect, scrollFrame: CGRect) -> CGVector {
    guard targetFrame.width > 0,
          targetFrame.height > 0,
          scrollFrame.width > 0,
          scrollFrame.height > 0 else {
        return .zero
    }

    return CGVector(dx: scrollFrame.midX - targetFrame.midX,
                    dy: scrollFrame.midY - targetFrame.midY)
}

// MARK: - hitPoint (doc 5.8)

/// WDA's fb_hitPointOffsetForScrollingVector:
///   scrolling with a positive drag vector (content moves up/left / finger moves down/right)
///   → starting point at (1 - scrollTouchProportion) edge, leaving 75% of frame for the drag
/// Time complexity: O(1).
func hitPointOffset(for vector: CGVector, scrollFrame: CGRect) -> CGVector {
    let prop = CGFloat(IOSUseProtocol.scrollTouchProportion)
    let x = scrollFrame.minX + scrollFrame.width * (vector.dx < 0 ? prop : (1 - prop))
    let y = scrollFrame.minY + scrollFrame.height * (vector.dy < 0 ? prop : (1 - prop))
    return CGVector(dx: floor(x), dy: floor(y))
}

// MARK: - Single-gesture dispatch (doc 5.8)

/// WDA's fb_scrollAncestorScrollViewByVectorWithinScrollViewFrame:
/// Compute absolute coordinates and perform press+drag at 350 px/s.
/// Time complexity: O(1).
func scrollAncestorByVector(_ vector: CGVector, scrollFrame: CGRect, app: XCUIApplication,
                            origin: XCUICoordinate? = nil) throws {
    let hitPoint = hitPointOffset(for: vector, scrollFrame: scrollFrame)

    let anchor = try origin ?? RawPointer.origin(app: app)
    let startCoord = anchor.withOffset(hitPoint)
    let endCoord = startCoord.withOffset(CGVector(dx: vector.dx, dy: vector.dy))

    _ = try RawPointer.perform(
        app: app,
        event: .drag(
            start: startCoord,
            end: endCoord,
            pressDuration: IOSUseProtocol.touchPressDuration,
            velocity: IOSUseProtocol.touchVelocity,
            holdDuration: IOSUseProtocol.touchHoldDuration
        ),
        // SwipeCommands waits before resolving the initial container and takes
        // fresh trees between scroll attempts. Do not add a stale-frame wait here.
        waitForIdle: false
    )
}

// MARK: - Math utils

/// Constant-time fuzzy comparison used by the segment splitter.
/// Time complexity: O(1).
func fuzzyEqualVector(_ a: CGVector, _ b: CGVector, threshold: CGFloat) -> Bool {
    abs(a.dx - b.dx) <= threshold && abs(a.dy - b.dy) <= threshold
}
