import XCTest
@testable import IOSUseCLI

final class XCTestSessionHolderServiceTests: XCTestCase {
    func testHolderStopsAfterStartupFailure() {
        let message = XCTestSessionHolderService.holderStopMessage(
            startupFailure: HolderFailure(description: "startup EOF"),
            postConfigurationFailure: nil
        )

        XCTAssertEqual(message, "holder startup session failed after readiness: startup EOF")
    }

    func testHolderStopsAfterPostConfigurationFailure() {
        let message = XCTestSessionHolderService.holderStopMessage(
            startupFailure: nil,
            postConfigurationFailure: HolderFailure(description: "TLS EOF")
        )

        XCTAssertEqual(message, "XCTest session ended after configuration; stopping holder: TLS EOF")
    }

    func testHolderKeepsRunningWithoutListenerFailure() {
        let message = XCTestSessionHolderService.holderStopMessage(
            startupFailure: nil,
            postConfigurationFailure: nil
        )

        XCTAssertNil(message)
    }
}

private struct HolderFailure: Error, CustomStringConvertible {
    let description: String
}
