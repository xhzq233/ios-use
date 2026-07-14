import XCTest
@testable import IOSUseCLI

final class CaptureServiceTests: XCTestCase {
    func testNextScheduledSampleKeepsFutureSlotWhenFrameFinishesEarly() {
        XCTAssertEqual(
            CaptureService.nextScheduledSample(current: 10, completedAt: 10.05, interval: 0.1),
            10.1,
            accuracy: 0.000_001
        )
    }

    func testNextScheduledSampleSkipsOneOverrunSlot() {
        XCTAssertEqual(
            CaptureService.nextScheduledSample(current: 10, completedAt: 10.11, interval: 0.1),
            10.2,
            accuracy: 0.000_001
        )
    }

    func testNextScheduledSampleSkipsMultipleOverrunSlotsWithoutCatchUpBurst() {
        XCTAssertEqual(
            CaptureService.nextScheduledSample(current: 10, completedAt: 10.35, interval: 0.1),
            10.4,
            accuracy: 0.000_001
        )
    }
}
