import XCTest

// MARK: - Constants (doc 7)

enum ScrollConstants {
    static let scrollTouchProportion: CGFloat = 0.75
    static let touchPressDuration: Double = 0.03
    static let touchHoldDuration: Double = 0.07
    static let touchVelocity: Double = 350
    static let settleInterval: Double = 0.1
    static let fuzzyPointThreshold: CGFloat = 20
    static let preciseScrollMaxSegments = 20
    static let maxScrollCount = 25
}

enum ScrollAxis {
    case vertical
    case horizontal
}

// MARK: - Normalized direction helpers (doc 5.8)

/// Content scrolls up → finger moves down (+dy)
func scrollUpByNormalizedDistance(_ dist: Double, scrollFrame: CGRect, app: XCUIApplication) {
    let vector = CGVector(dx: 0, dy: scrollFrame.height * CGFloat(dist))
    scrollByVector(vector, scrollFrame: scrollFrame, app: app)
}

/// Content scrolls down → finger moves up (-dy)
func scrollDownByNormalizedDistance(_ dist: Double, scrollFrame: CGRect, app: XCUIApplication) {
    let vector = CGVector(dx: 0, dy: -scrollFrame.height * CGFloat(dist))
    scrollByVector(vector, scrollFrame: scrollFrame, app: app)
}

/// Content scrolls left → finger moves right (+dx)
func scrollLeftByNormalizedDistance(_ dist: Double, scrollFrame: CGRect, app: XCUIApplication) {
    let vector = CGVector(dx: scrollFrame.width * CGFloat(dist), dy: 0)
    scrollByVector(vector, scrollFrame: scrollFrame, app: app)
}

/// Content scrolls right → finger moves left (-dx)
func scrollRightByNormalizedDistance(_ dist: Double, scrollFrame: CGRect, app: XCUIApplication) {
    let vector = CGVector(dx: -scrollFrame.width * CGFloat(dist), dy: 0)
    scrollByVector(vector, scrollFrame: scrollFrame, app: app)
}

// MARK: - Vector scroll (segmented, doc 5.8)

/// WDA's fb_scrollByVector: segment vector into chunks no larger than 75% of
/// scrollFrame, then dispatch each chunk via coordinate press+drag.
/// Time complexity: O(k), where k is the emitted segment count capped by
/// `preciseScrollMaxSegments`.
func scrollSegments(for vector: CGVector, scrollFrame: CGRect) -> [CGVector] {
    guard scrollFrame.width > 0, scrollFrame.height > 0 else { return [] }

    var boundingVector = CGVector(
        dx: scrollFrame.width * ScrollConstants.scrollTouchProportion,
        dy: scrollFrame.height * ScrollConstants.scrollTouchProportion
    )
    boundingVector.dx = floor(copysign(boundingVector.dx, vector.dx))
    boundingVector.dy = floor(copysign(boundingVector.dy, vector.dy))

    // If both axes are zero, nothing to do.
    if boundingVector.dx == 0 && boundingVector.dy == 0 { return [] }

    var remaining = vector
    var attempts = ScrollConstants.preciseScrollMaxSegments
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
        if abs(segment.dx) >= ScrollConstants.fuzzyPointThreshold
            || abs(segment.dy) >= ScrollConstants.fuzzyPointThreshold {
            segments.append(segment)
        }

        let shouldFinish = fuzzyEqualVector(remaining, .zero, threshold: 1) || attempts <= 1
        if shouldFinish { break }
        attempts -= 1
    }
    return segments
}

/// Infers the dominant scroll axis from visible cells first, then falls back to
/// frame geometry when the subtree has too little structure to inspect.
/// Time complexity: O(1).
func primaryScrollAxis(visibleCellFrames: [CGRect], scrollFrame: CGRect) -> ScrollAxis {
    if visibleCellFrames.count >= 2,
       let first = visibleCellFrames.first,
       let last = visibleCellFrames.last {
        let dx = first.minX - last.minX
        let dy = first.minY - last.minY
        return abs(dy) >= abs(dx) ? .vertical : .horizontal
    }
    return scrollFrame.height >= scrollFrame.width ? .vertical : .horizontal
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
func dispatchScrollSegments(_ segments: [CGVector], scrollFrame: CGRect, app: XCUIApplication) -> Int {
    guard !segments.isEmpty else { return 0 }
    for (index, segment) in segments.enumerated() {
        autoreleasepool {
            scrollAncestorByVector(segment, scrollFrame: scrollFrame, app: app)
        }

        if index < segments.count - 1 {
            // doc 5.8 — segment-level settle (multi-segment requires brief settle
            // for UIScrollView to flush; single-segment callers still get one sleep
            // before next outer iteration).
            Thread.sleep(forTimeInterval: ScrollConstants.settleInterval)
        }
    }
    return segments.count
}

/// Plans then dispatches scroll segments.
/// Time complexity: O(k), where k is the segment count.
func scrollByVector(_ vector: CGVector, scrollFrame: CGRect, app: XCUIApplication) -> Int {
    let segments = scrollSegments(for: vector, scrollFrame: scrollFrame)
    return dispatchScrollSegments(segments, scrollFrame: scrollFrame, app: app)
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
    let prop = ScrollConstants.scrollTouchProportion
    let x = scrollFrame.minX + scrollFrame.width * (vector.dx < 0 ? prop : (1 - prop))
    let y = scrollFrame.minY + scrollFrame.height * (vector.dy < 0 ? prop : (1 - prop))
    return CGVector(dx: floor(x), dy: floor(y))
}

// MARK: - Single-gesture dispatch (doc 5.8)

/// WDA's fb_scrollAncestorScrollViewByVectorWithinScrollViewFrame:
/// Compute absolute coordinates and perform press+drag at 350 px/s.
/// Time complexity: O(1).
func scrollAncestorByVector(_ vector: CGVector, scrollFrame: CGRect, app: XCUIApplication) {
    let hitPoint = hitPointOffset(for: vector, scrollFrame: scrollFrame)

    let appCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let startCoord = appCoord.withOffset(CGVector(dx: hitPoint.dx, dy: hitPoint.dy))
    let endCoord = startCoord.withOffset(CGVector(dx: vector.dx, dy: vector.dy))

    _ = RawPointer.perform(
        app: app,
        event: .drag(
            start: startCoord,
            end: endCoord,
            pressDuration: ScrollConstants.touchPressDuration,
            velocity: ScrollConstants.touchVelocity,
            holdDuration: ScrollConstants.touchHoldDuration
        )
    )
}

// MARK: - Math utils

/// Constant-time fuzzy comparison used by the segment splitter.
/// Time complexity: O(1).
func fuzzyEqualVector(_ a: CGVector, _ b: CGVector, threshold: CGFloat) -> Bool {
    abs(a.dx - b.dx) <= threshold && abs(a.dy - b.dy) <= threshold
}
