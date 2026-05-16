import XCTest
import IOSUseCLI

final class OSLogServiceTests: XCTestCase {
    func testClearKeepsUserVisibleContract() {
        XCTAssertEqual(OSLogService.clear(), "  → oslog: cleared=0\n")
    }

    func testOslogRejectsMissingUdidBeforeTouchingEnvironment() {
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": "/tmp/ios-use-swift-oslog"]).run(arguments: ["oslog", "--name", "logs"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("oslog requires --udid"))
    }
}
