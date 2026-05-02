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

    func testProjectVectorToPrimaryAxis_ZeroesMinorAxis() {
        let projectedVertical = projectVectorToPrimaryAxis(CGVector(dx: 87.5, dy: 6), axis: .vertical)
        XCTAssertEqual(projectedVertical.dx, 0)
        XCTAssertEqual(projectedVertical.dy, 6)

        let projectedHorizontal = projectVectorToPrimaryAxis(CGVector(dx: 87.5, dy: 6), axis: .horizontal)
        XCTAssertEqual(projectedHorizontal.dx, 87.5)
        XCTAssertEqual(projectedHorizontal.dy, 0)
    }
}
