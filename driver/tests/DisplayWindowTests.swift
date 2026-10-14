import XCTest

private final class DisplayWindowSnapshot: NSObject {
    @objc let elementType: NSNumber
    @objc let displayID: NSNumber?
    @objc let frame: NSValue
    @objc let isVisible: Bool
    @objc let children: [DisplayWindowSnapshot]

    init(type: XCUIElement.ElementType, displayID: UInt64? = nil, frame: CGRect = .zero,
         visible: Bool = true, children: [DisplayWindowSnapshot] = []) {
        self.elementType = NSNumber(value: type.rawValue)
        self.displayID = displayID.map(NSNumber.init(value:))
        self.frame = NSValue(cgRect: frame)
        self.isVisible = visible
        self.children = children
    }
}

final class DisplayWindowTests: XCTestCase {
    func testSelectsVisibleWindowWhenRootRetainsOuterDisplayGeometry() throws {
        let outerFrame = CGRect(x: 0, y: 0, width: 466, height: 678)
        let innerFrame = CGRect(x: 0, y: 0, width: 951, height: 669)
        let empty = DisplayWindowSnapshot(type: .window, displayID: 3)
        let hidden = DisplayWindowSnapshot(type: .window, displayID: 1, frame: outerFrame, visible: false)
        let inner = DisplayWindowSnapshot(type: .window, displayID: 3, frame: innerFrame)
        let root = DisplayWindowSnapshot(type: .application, frame: outerFrame, children: [empty, hidden, inner])
        let selected = try XCTUnwrap(XCDisplayWindowSnapshot(root) as? DisplayWindowSnapshot)
        XCTAssertTrue(selected === inner)
        XCTAssertEqual(selected.frame.cgRectValue, innerFrame)
        XCTAssertTrue(XCDisplayWindowSnapshot(inner) as? DisplayWindowSnapshot === inner)
    }

    func testZeroIsAValidDisplayIDButMissingIDIsNot() {
        let frame = CGRect(x: 0, y: 0, width: 466, height: 678)
        let missingID = DisplayWindowSnapshot(type: .window, frame: frame)
        let mainWindow = DisplayWindowSnapshot(type: .window, displayID: 0, frame: frame)
        let root = DisplayWindowSnapshot(type: .application, children: [missingID, mainWindow])
        XCTAssertTrue(XCDisplayWindowSnapshot(root) as? DisplayWindowSnapshot === mainWindow)
        XCTAssertNil(XCDisplayWindowSnapshot(missingID))
    }

    func testSystemAlertWindowTakesPriorityOverOuterSpringBoardWindow() {
        let frame = CGRect(x: 0, y: 0, width: 951, height: 669)
        let outer = DisplayWindowSnapshot(type: .window, displayID: 1, frame: frame)
        let hiddenAlert = DisplayWindowSnapshot(type: .alert, visible: false)
        let hiddenWindow = DisplayWindowSnapshot(type: .window, displayID: 1, frame: frame, children: [hiddenAlert])
        let alert = DisplayWindowSnapshot(type: .sheet, frame: frame)
        let inner = DisplayWindowSnapshot(type: .window, displayID: 3, frame: frame, children: [alert])
        let root = DisplayWindowSnapshot(type: .application, children: [outer, hiddenWindow, inner])
        XCTAssertTrue(XCDisplayWindowSnapshot(root) as? DisplayWindowSnapshot === inner)
    }
}
