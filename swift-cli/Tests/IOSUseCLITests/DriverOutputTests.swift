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
        XCTAssertTrue(output.contains("matches=1"))
        XCTAssertTrue(output.contains("TextField \"First name=Alpha\""))
    }

    func testFormatDomIncludesInputValues() {
        let payload = ForyDomPayload(
            app: "com.apple.MobileAddressBook",
            windowSize: ForyPoint(x: 393, y: 852),
            elements: [
                ForyDomElement(traits: ["TextField"], label: "First name", value: "Alpha", rect: ForyRect(x: 1, y: 2, w: 3, h: 4)),
                ForyDomElement(traits: ["TextField"], label: "Last name", value: "Beta", rect: ForyRect(x: 5, y: 6, w: 7, h: 8))
            ]
        )

        let output = DriverOutput.formatDom(payload)

        XCTAssertTrue(output.contains("First name=Alpha"))
        XCTAssertTrue(output.contains("Last name=Beta"))
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
