import XCTest
@testable import IOSUseCLI
import IOSUseProtocol

final class DriverOutputTests: XCTestCase {
    func testSharedElementTypesUseShortDisplayNames() {
        XCTAssertEqual(IOSUseElementTypes.displayName(rawType: 2), "App")
        XCTAssertEqual(IOSUseElementTypes.displayName(rawType: 48), "Text")
        XCTAssertEqual(IOSUseElementTypes.displayName(rawType: 49), "Input")
        XCTAssertEqual(IOSUseElementTypes.displayName(rawType: 45), "Input")
        XCTAssertEqual(IOSUseElementTypes.displayName(rawType: 46), "Scroll")
        XCTAssertEqual(IOSUseElementTypes.displayName(rawType: 32), "Collection")
        XCTAssertEqual(IOSUseElementTypes.displayName(rawType: 58), "Web")
        XCTAssertEqual(IOSUseElementTypes.displayName(rawType: 999), "-")
    }

    func testFormatFindIncludesValueText() {
        let payload = ForyFindPayload(matches: [
            ForyFindMatch(
                elemType: 49,
                label: "First name",
                rect: ForyRect(x: 1, y: 2, w: 3, h: 4),
                traits: ["Input"],
                value: "Alpha",
                ancestors: ["App", "Table", "Cell[Name]"]
            )
        ])

        let output = DriverOutput.formatFind(label: "Alpha", payload: payload)

        XCTAssertTrue(output.contains("Find \"Alpha\""))
        XCTAssertTrue(output.contains("[App > Table > Cell[Name]] Input \"First name=Alpha\" (1,2,3,4)"))
        XCTAssertFalse(output.contains("matches=1"))
    }

    func testDriverErrorUsesDriverProvidedString() {
        let error = DriverClientError.driverError("""
        label '关闭' is ambiguous (2 matches)
        matches:
          [Application > Table > Cell[蓝牙]] Button [disabled] "关闭" (10,20,30,40)
        suggestions: 关闭
        hint: Try adding --traits to disambiguate
        """)

        let output = String(describing: error)

        XCTAssertTrue(output.contains("label '关闭' is ambiguous"))
        XCTAssertTrue(output.contains("matches:"))
        XCTAssertTrue(output.contains("[Application > Table > Cell[蓝牙]] Button [disabled] \"关闭\" (10,20,30,40)"))
        XCTAssertTrue(output.contains("suggestions: 关闭"))
        XCTAssertTrue(output.contains("hint: Try adding --traits to disambiguate"))
    }

    func testFormatDomIncludesInputValues() {
        let payload = ForyDomPayload(
            app: "com.apple.MobileAddressBook",
            windowSize: ForyPoint(x: 393, y: 852),
            elements: [
                ForyDomElement(traits: ["Input"], label: "First name", value: "Alpha", rect: ForyRect(x: 1, y: 2, w: 3, h: 4)),
                ForyDomElement(traits: ["Input"], label: "Last name", value: "Beta", rect: ForyRect(x: 5, y: 6, w: 7, h: 8))
            ]
        )

        let output = DriverOutput.formatDom(payload)

        XCTAssertTrue(output.contains("First name=Alpha"))
        XCTAssertTrue(output.contains("Last name=Beta"))
    }

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
                ForyDomElement(traits: ["Switch"], value: "1", rect: ForyRect(x: 340, y: 10, w: 50, h: 30))
            ]
        )

        let output = DriverOutput.formatDom(payload)

        XCTAssertFalse(output.hasPrefix("\n"))
        XCTAssertTrue(output.contains("App: com.apple.Preferences"))
        XCTAssertFalse(output.contains("Window:"))
        XCTAssertTrue(output.contains("""
Elements:
  NavigationBar [NavigationBar] (0,44,402,60):
    - Back [Button] (16,54,44,44)
    - Settings [Text] (156,54,132,44)
  Table [Table,vertical] (0,100,402,774):
    Wi-Fi [Cell] (0,100,402,44):
      - =1 [Switch] (340,10,50,30)
"""))
    }

    func testFormatDomAddsVerticalDirectionInPresentationOnly() {
        let payload = ForyDomPayload(
            app: "com.example",
            elements: [
                ForyDomElement(traits: ["Scroll"], childCount: 2),
                ForyDomElement(traits: ["Cell"], label: "First", rect: ForyRect(x: 0, y: 20, w: 320, h: 44)),
                ForyDomElement(traits: ["Cell"], label: "Second", rect: ForyRect(x: 0, y: 120, w: 320, h: 44)),
            ]
        )

        let output = DriverOutput.formatDom(payload)

        XCTAssertTrue(output.contains("Scroll [Scroll,vertical]:"))
        XCTAssertEqual(payload.elements[0].traits, ["Scroll"])
    }

    func testPresentationDomElementsAddsHorizontalDirectionFromDirectChildren() {
        let elements = [
            ForyDomElement(traits: ["Collection"], childCount: 2),
            ForyDomElement(traits: ["Cell"], childCount: 1, label: "A", rect: ForyRect(x: 10, y: 20, w: 80, h: 80)),
            ForyDomElement(traits: ["Text"], label: "Nested A", rect: ForyRect(x: 10, y: 20, w: 80, h: 20)),
            ForyDomElement(traits: ["Cell"], childCount: 1, label: "B", rect: ForyRect(x: 140, y: 20, w: 80, h: 80)),
            ForyDomElement(traits: ["Text"], label: "Nested B", rect: ForyRect(x: 140, y: 20, w: 80, h: 20)),
        ]

        let presentation = DriverOutput.presentationDomElements(elements)

        XCTAssertEqual(presentation[0].traits, ["Collection", "horizontal"])
        XCTAssertEqual(elements[0].traits, ["Collection"])
    }

    func testPresentationDomElementsDoesNotAddDirectionForWebView() {
        let elements = [
            ForyDomElement(traits: ["Web"], childCount: 1),
            ForyDomElement(traits: ["Text"], label: "Content", rect: ForyRect(x: 0, y: 100, w: 300, h: 40)),
        ]

        let presentation = DriverOutput.presentationDomElements(elements)

        XCTAssertEqual(presentation[0].traits, ["Web"])
    }

    func testPresentationDomElementsDefaultsSingleChildScrollableToVertical() {
        let elements = [
            ForyDomElement(traits: ["Table"], childCount: 1),
            ForyDomElement(traits: ["Cell"], label: "Only", rect: ForyRect(x: 0, y: 100, w: 390, h: 44)),
        ]

        let presentation = DriverOutput.presentationDomElements(elements)

        XCTAssertEqual(presentation[0].traits, ["Table", "vertical"])
    }

    func testPresentationDomElementsDefaultsOverlappingChildrenToVertical() {
        let elements = [
            ForyDomElement(traits: ["Scroll"], childCount: 2, rect: ForyRect(x: 0, y: 0, w: 320, h: 640)),
            ForyDomElement(traits: ["Cell"], label: "First", rect: ForyRect(x: 10, y: 20, w: 80, h: 80)),
            ForyDomElement(traits: ["Cell"], label: "Second", rect: ForyRect(x: 10, y: 20, w: 80, h: 80)),
        ]

        let presentation = DriverOutput.presentationDomElements(elements)

        XCTAssertEqual(presentation[0].traits, ["Scroll", "vertical"])
    }

    func testPresentationDomElementsFallsBackToHorizontalFromContainerAspectRatio() {
        let elements = [
            ForyDomElement(traits: ["Scroll"], childCount: 1, rect: ForyRect(x: 0, y: 0, w: 500, h: 120)),
            ForyDomElement(traits: ["Cell"], label: "Only", rect: ForyRect(x: 10, y: 20, w: 80, h: 80)),
        ]

        let presentation = DriverOutput.presentationDomElements(elements)

        XCTAssertEqual(presentation[0].traits, ["Scroll", "horizontal"])
    }

    func testPresentationDomElementsDefaultsMissingRectFallbackToVertical() {
        let elements = [
            ForyDomElement(traits: ["Scroll"], childCount: 0),
        ]

        let presentation = DriverOutput.presentationDomElements(elements)

        XCTAssertEqual(presentation[0].traits, ["Scroll", "vertical"])
    }

    func testFormatElementAndSwipe() {
        XCTAssertEqual(
            DriverOutput.formatElement(ForyElementPayload(elemType: 9, label: "Add", rect: ForyRect(x: 1, y: 2, w: 3, h: 4))),
            "Button \"Add\" (1,2,3,4)\n"
        )
        XCTAssertEqual(
            DriverOutput.formatSwipe(ForySwipePayload(elemType: 75, label: "General", scrolls: 2, scrollDirection: "down")),
            "Cell \"General\" scrolls=2 direction=down\n"
        )
    }
}
