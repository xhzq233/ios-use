import XCTest

final class ScrollMechanicsTests: XCTestCase {

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
