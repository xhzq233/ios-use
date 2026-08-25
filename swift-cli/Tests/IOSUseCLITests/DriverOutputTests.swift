import XCTest
@testable import IOSUseCLI
import IOSUseProtocol

final class DriverOutputTests: XCTestCase {
    func testFormatDomRebuildsFlatPreorderTree() {
        let payload = ForyDomPayload(
            app: "com.apple.Preferences",
            windowSize: ForyPoint(x: 402, y: 874),
            elements: [
                ForyDomElement(traits: ["NavigationBar"], childCount: 2, rect: ForyRect(x: 0, y: 44, w: 402, h: 60)),
                ForyDomElement(traits: ["Button"], label: "Back", rect: ForyRect(x: 16, y: 54, w: 44, h: 44)),
                ForyDomElement(traits: ["Text"], label: "Settings", rect: ForyRect(x: 156, y: 54, w: 132, h: 44)),
                ForyDomElement(traits: ["Table"], childCount: 1, rect: ForyRect(x: 0, y: 100, w: 402, h: 774)),
                ForyDomElement(traits: ["Cell"], childCount: 1, label: "Wi-Fi", rect: ForyRect(x: 0, y: 100, w: 402, h: 44)),
                ForyDomElement(traits: ["Switch"], value: "1", rect: ForyRect(x: 340, y: 10, w: 50, h: 30)),
            ]
        )

        let output = DriverOutput.formatDom(payload)

        XCTAssertTrue(output.contains("App: com.apple.Preferences"))
        XCTAssertTrue(output.contains("Wi-Fi [Cell]"))
        XCTAssertTrue(output.contains("=1 [Switch]"))
    }

    func testPresentationDomElementsInfersHorizontalFromDirectChildren() {
        let elements = [
            ForyDomElement(traits: ["Collection"], childCount: 2),
            ForyDomElement(traits: ["Cell"], label: "A", rect: ForyRect(x: 10, y: 20, w: 80, h: 80)),
            ForyDomElement(traits: ["Cell"], label: "B", rect: ForyRect(x: 140, y: 20, w: 80, h: 80)),
        ]

        let presentation = DriverOutput.presentationDomElements(elements)

        XCTAssertEqual(presentation[0].traits, ["Collection", "horizontal"])
        XCTAssertEqual(elements[0].traits, ["Collection"])
    }

    func testPresentationDomElementsLeavesWebViewUntouched() {
        let elements = [
            ForyDomElement(traits: ["Web"], childCount: 1),
            ForyDomElement(traits: ["Text"], label: "Content", rect: ForyRect(x: 0, y: 100, w: 300, h: 40)),
        ]

        XCTAssertEqual(
            DriverOutput.presentationDomElements(elements)[0].traits,
            ["Web"]
        )
    }
}
