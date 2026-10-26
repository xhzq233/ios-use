import XCTest
import Fory

final class ScrollMechanicsTests: XCTestCase {

    func testExplicitDirectionLocksAxisAndDoesNotProbeAfterNoProgress() {
        for (direction, axis, back) in [(IOSUseSwipeDirection.up, ScrollAxis.vertical, true),
                                       (.down, .vertical, false), (.left, .horizontal, true), (.right, .horizontal, false)] {
            XCTAssertEqual(explicitScrollAxis(direction.rawValue), axis)
            XCTAssertEqual(direction.backwards, back)
            var search = ScrollAxisSearch(hint: explicitScrollAxis(direction.rawValue))
            XCTAssertFalse(search.observe(changed: false))
            XCTAssertEqual(search.axis, axis)
        }
        XCTAssertNil(explicitScrollAxis(IOSUseSwipeDirection.forth.rawValue))
        XCTAssertNil(explicitScrollAxis(IOSUseSwipeDirection.back.rawValue))
    }

    func testUnknownWireDirectionFailsBeforeResolvingAnApp() throws {
        let result = try SwipeCommands.swipe(ForySwipeArgs(dir: 99))
        XCTAssertFalse(result.ok)
        let error = try createFory().deserialize(result.payload, as: ForyErrorPayload.self)
        XCTAssertEqual(error.code, IOSUseErrorCode.invalidArguments)
    }

    func testOffscreenTargetDirectionUsesViewportGeometryOnBothAxes() {
        let viewport = CGRect(x: 40, y: 120, width: 320, height: 640)
        XCTAssertEqual(scrollBackwardsToward(targetFrame: CGRect(x: 50, y: 1100, width: 60, height: 30), scrollFrame: viewport, axis: .vertical), false)
        XCTAssertEqual(scrollBackwardsToward(targetFrame: CGRect(x: 50, y: 30, width: 60, height: 30), scrollFrame: viewport, axis: .vertical), true)
        XCTAssertEqual(scrollBackwardsToward(targetFrame: CGRect(x: 600, y: 150, width: 60, height: 30), scrollFrame: viewport, axis: .horizontal), false)
        XCTAssertEqual(scrollBackwardsToward(targetFrame: CGRect(x: -100, y: 150, width: 60, height: 30), scrollFrame: viewport, axis: .horizontal), true)
        XCTAssertNil(scrollBackwardsToward(targetFrame: .zero, scrollFrame: viewport, axis: .vertical))
        XCTAssertNil(scrollBackwardsToward(targetFrame: CGRect(x: 50, y: 200, width: 60, height: 30), scrollFrame: viewport, axis: .vertical))
    }

    func testScrollSegments_SplitsLargeVerticalDistance() {
        let frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        let segments = scrollSegments(for: CGVector(dx: 0, dy: -900), scrollFrame: frame)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].dx, 0)
        XCTAssertEqual(segments[0].dy, -609)
        XCTAssertEqual(segments[1].dx, 0)
        XCTAssertEqual(segments[1].dy, -291)
    }

    func testScrollSegments_DoesNotSplitWithinTouchLimit() {
        let frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        let segments = scrollSegments(for: CGVector(dx: 0, dy: -600), scrollFrame: frame)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].dy, -600)
    }

    func testScrollSegments_EmptyForZeroSizedFrame() {
        let segments = scrollSegments(for: CGVector(dx: 0, dy: -900),
                                      scrollFrame: .zero)
        XCTAssertTrue(segments.isEmpty)
    }

    func testScrollSegments_DropsTinyVectorBelowThreshold() {
        let frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        let segments = scrollSegments(for: CGVector(dx: 0, dy: 6), scrollFrame: frame)
        XCTAssertTrue(segments.isEmpty)
    }

    func testPrimaryScrollAxis_PrefersVisibleCellDirection() {
        let axis = primaryScrollAxis(
            visibleCellFrames: [
                CGRect(x: 16, y: 780, width: 343, height: 44),
                CGRect(x: 16, y: 200, width: 343, height: 82),
            ],
            scrollFrame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        XCTAssertEqual(axis, .vertical)
    }

    func testAxisDoesNotUseViewportAspectRatioOrForceAmbiguousGrid() {
        let wide = CGRect(x: 0, y: 0, width: 867, height: 669)
        XCTAssertNil(primaryScrollAxis(visibleCellFrames: [], scrollFrame: wide))
        XCTAssertNil(primaryScrollAxis(visibleCellFrames: [CGRect(x: 0, y: 0, width: 800, height: 500)], scrollFrame: wide))
        let grid = [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 200, y: 200, width: 50, height: 50)]
        XCTAssertNil(primaryScrollAxis(visibleCellFrames: grid, scrollFrame: wide))
        XCTAssertEqual(primaryScrollAxis(visibleCellFrames: [CGRect(x: 0, y: 0, width: 800, height: 40), CGRect(x: 350, y: 200, width: 100, height: 40)], scrollFrame: wide), .vertical)
        XCTAssertEqual(primaryScrollAxis(visibleCellFrames: [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 200, y: 0, width: 50, height: 50)], scrollFrame: wide), .horizontal)
    }

    func testOffscreenAxisRequiresAnUnambiguousTarget() {
        let viewport = CGRect(x: 0, y: 0, width: 867, height: 669)
        XCTAssertEqual(scrollAxisToward(targetFrame: CGRect(x: 20, y: 900, width: 100, height: 40), scrollFrame: viewport), .vertical)
        XCTAssertEqual(scrollAxisToward(targetFrame: CGRect(x: 1000, y: 20, width: 100, height: 40), scrollFrame: viewport), .horizontal)
        XCTAssertNil(scrollAxisToward(targetFrame: CGRect(x: 1000, y: 900, width: 100, height: 40), scrollFrame: viewport))
        XCTAssertNil(scrollAxisToward(targetFrame: .zero, scrollFrame: viewport))
    }

    func testUnknownSearchSwitchesAxisOnceAndProgressLocksIt() {
        var unknown = ScrollAxisSearch(hint: nil)
        XCTAssertEqual(unknown.axis, .vertical)
        XCTAssertTrue(unknown.observe(changed: false))
        XCTAssertEqual(unknown.axis, .horizontal)
        XCTAssertFalse(unknown.observe(changed: false))
        var progressed = ScrollAxisSearch(hint: nil)
        XCTAssertFalse(progressed.observe(changed: true))
        XCTAssertFalse(progressed.observe(changed: false))
        XCTAssertEqual(progressed.axis, .vertical)
        var known = ScrollAxisSearch(hint: .horizontal)
        XCTAssertFalse(known.observe(changed: false))
        var noEvidence = ScrollAxisSearch(hint: nil)
        XCTAssertFalse(noEvidence.observe(changed: nil))
        XCTAssertEqual(noEvidence.axis, .vertical)
    }

    func testHitPointOffset_UsesClippedHorizontalCollectionFrame() {
        let frame = CGRect(x: 0, y: 696, width: 402, height: 90)

        let point = hitPointOffset(for: CGVector(dx: -300, dy: 0), scrollFrame: frame)

        XCTAssertEqual(point.dx, 301)
        XCTAssertEqual(point.dy, 718)
    }

    func testCenterScrollAdjustment_MovesBottomCellToScrollCenter() {
        let scrollFrame = CGRect(x: 0, y: 116, width: 402, height: 696)
        let targetFrame = CGRect(x: 0, y: 790, width: 402, height: 53)

        let adjust = centerScrollAdjustment(targetFrame: targetFrame, scrollFrame: scrollFrame)

        XCTAssertEqual(adjust.dx, 0)
        XCTAssertEqual(adjust.dy, -352.5)
    }

    func testCenterScrollAdjustment_MovesCellInsideAppButBelowScrollableFrameToCenter() {
        let collectionScrollFrame = CGRect(x: 0, y: 116, width: 402, height: 672)
        let generalCellFrame = CGRect(x: 0, y: 842, width: 402, height: 53)

        let adjust = centerScrollAdjustment(targetFrame: generalCellFrame,
                                            scrollFrame: collectionScrollFrame)

        XCTAssertEqual(adjust.dx, 0)
        XCTAssertEqual(adjust.dy, -416.5)
    }

    func testCenterScrollAdjustment_MovesSafeAreaClippedCellToCenter() {
        let scrollFrame = CGRect(x: 0, y: 116, width: 402, height: 696)
        let targetFrame = CGRect(x: 0, y: 750, width: 402, height: 53)

        let adjust = centerScrollAdjustment(targetFrame: targetFrame, scrollFrame: scrollFrame)

        XCTAssertEqual(adjust.dx, 0)
        XCTAssertEqual(adjust.dy, -312.5)
    }

    func testCenterScrollAdjustment_MovesTopCellToScrollCenter() {
        let scrollFrame = CGRect(x: 0, y: 116, width: 402, height: 696)
        let targetFrame = CGRect(x: 0, y: 90, width: 402, height: 53)

        let adjust = centerScrollAdjustment(targetFrame: targetFrame, scrollFrame: scrollFrame)

        XCTAssertEqual(adjust.dx, 0)
        XCTAssertEqual(adjust.dy, 347.5)
    }

}
