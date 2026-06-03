import XCTest

final class DriverLogTests: XCTestCase {
    func testDriverLogRoutesStartupMessagesThroughConfiguredSink() {
        var messages: [String] = []

        DriverLog.withSinkForTesting({ message in
            messages.append(message)
        }) {
            DriverLog.info("[debug][xctest-entry-testRun] IOSUseDriver testRun invoked")
            DriverLog.error("[driver] constructor start failed: unit")
        }

        XCTAssertEqual(messages, [
            "[debug][xctest-entry-testRun] IOSUseDriver testRun invoked",
            "[driver] constructor start failed: unit"
        ])
    }
}
