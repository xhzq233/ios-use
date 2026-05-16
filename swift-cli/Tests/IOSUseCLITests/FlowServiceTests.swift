import XCTest
import IOSUseCLI

final class FlowServiceTests: XCTestCase {
    func testMissingFlowFileFailsBeforeDriverWork() {
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": "/tmp/ios-use-swift-flow"]).run(arguments: ["flow", "/tmp/no-such-flow.yaml"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Flow file not found"))
    }
}
