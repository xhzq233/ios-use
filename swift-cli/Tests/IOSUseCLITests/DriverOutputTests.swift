import XCTest
import IOSUseCLI
import IOSUseProtocol

final class DriverOutputTests: XCTestCase {
    func testFormatFindIncludesValueText() {
        let payload = ForyFindPayload(matches: [
            ForyFindMatch(elemType: 10, label: "First name", rect: ForyRect(x: 1, y: 2, w: 3, h: 4), traits: ["TextField"], value: "Alpha")
        ])

        let output = DriverOutput.formatFind(label: "Alpha", payload: payload)

        XCTAssertTrue(output.contains("Find \"Alpha\""))
        XCTAssertTrue(output.contains("TextField \"First name=Alpha\""))
    }

    func testFormatElementAndSwipe() {
        XCTAssertEqual(
            DriverOutput.formatElement(ForyElementPayload(elemType: 7, label: "Add", rect: ForyRect(x: 1, y: 2, w: 3, h: 4))),
            "Button \"Add\" (1,2,3,4)\n"
        )
        XCTAssertEqual(
            DriverOutput.formatSwipe(ForySwipePayload(elemType: 8, label: "General", scrolls: 2)),
            "Cell \"General\" scrolls=2\n"
        )
    }
}
