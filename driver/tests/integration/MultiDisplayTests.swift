import UIKit
import XCTest
import Fory

/// Opt-in integration regression: keep the fixture foreground on the Duo inner screen.
final class MultiDisplayTests: XCTestCase {
    func testWindowResolutionMatchesLiveSnapshot() throws {
        guard let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] else {
            throw XCTSkip("Requires a foreground fixture")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.activate()
        let raw = try XCTUnwrap(SnapshotOfElement(app))
        let selected = try XCTUnwrap(XCDisplayWindowSnapshot(raw))
        var error: NSError?
        let window = try XCTUnwrap(XCAppWindow(app, &error))
        XCTAssertNil(error)
        XCTAssertTrue(SnapshotMatchesElement(selected, try XCTUnwrap(SnapshotOfElement(window))))
    }

    func testExplicitDisplayTapUsesSynthesizedEvents() throws {
        guard let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"],
              let entry = ProcessInfo.processInfo.environment["IOS_USE_TEST_ENTRY_LABEL"],
              let destination = ProcessInfo.processInfo.environment["IOS_USE_TEST_DESTINATION_LABEL"] else {
            throw XCTSkip("Requires the configured navigation fixture")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.activate()
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", entry, entry)).firstMatch
        XCTAssertTrue(element.exists)
        let result = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", destination, destination)).firstMatch
        XCTAssertFalse(result.exists, "Start on the fixture's entry page")
        let frame = element.frame
        let point = try RawPointer.coordinate(app: app, point: CGPoint(x: frame.midX, y: frame.midY)).screenPoint
        var error: NSError?
        let screen = try XCTUnwrap(XCAppScreen(app, &error))
        let displayID = try XCTUnwrap(screen.value(forKey: "displayID") as? NSNumber)
        XCTAssertTrue(XCSynthesizeTapAtPoint(point, app, displayID, &error))
        XCTAssertNil(error)
        XCTAssertTrue(result.waitForExistence(timeout: 5), "Explicit-display synthesis must reach the navigation target")
        try returnFromNavigation(app: app, entry: element)
    }

    func testScreenshotMatchesForegroundDisplay() throws {
        guard XCUIScreen.screens.count > 1,
              ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] != nil else {
            throw XCTSkip("Requires a foreground multi-display fixture")
        }
        let app = try Session.shared.refreshActive()
        var error: NSError?
        let screen = try XCTUnwrap(XCAppScreen(app, &error))
        XCTAssertNil(error)
        let window = try XCTUnwrap(XCDisplayWindowSnapshot(try XCTUnwrap(SnapshotOfElement(app))))
        XCTAssertEqual((window as? NSObject)?.value(forKey: "displayID") as? NSNumber,
                       screen.value(forKey: "displayID") as? NSNumber)
        let response = try ScreenCommands.screenshot()
        let payload = try createFory().deserialize(response.payload, as: ForyScreenshotPayload.self)
        let image = try XCTUnwrap(UIImage(data: payload.jpeg))
        let reference = screen.screenshot().image
        XCTAssertEqual(image.size.width, reference.size.width * reference.scale, accuracy: 1)
        XCTAssertEqual(image.size.height, reference.size.height * reference.scale, accuracy: 1)
        XCTAssertEqual(payload.scale, (screen.value(forKey: "scale") as? NSNumber)?.doubleValue)
    }

    func testDOMViewportMatchesInnerWindow() throws {
        guard XCUIScreen.screens.count > 1,
              ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] != nil else {
            throw XCTSkip("Requires a foreground multi-display fixture")
        }
        let app = try Session.shared.refreshActive()
        let snapshot = try XCTUnwrap(SafeSnapshot(ofApp: app))
        var error: NSError?
        let windowFrame = try XCTUnwrap(XCAppWindow(app, &error)).frame
        XCTAssertNil(error)
        XCTAssertEqual(snapshot.appFrame.width, windowFrame.width, accuracy: 0.001,
                       "DOM visibility must use the inner window's current orientation")
        XCTAssertEqual(snapshot.appFrame.height, windowFrame.height, accuracy: 0.001)
        XCTAssertEqual(snapshot.appFrame.minX, windowFrame.minX, accuracy: 0.001)
        XCTAssertEqual(snapshot.appFrame.minY, windowFrame.minY, accuracy: 0.001)
        XCTAssertEqual(snapshot.frame, snapshot.appFrame)
        XCTAssertEqual(try XCTUnwrap(captureCleanedSnapshot()).appFrame, snapshot.appFrame)
    }

    func testDOMScrollReachesForegroundInnerDisplay() throws {
        guard XCUIScreen.screens.count > 1,
              ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] != nil,
              let label = ProcessInfo.processInfo.environment["IOS_USE_TEST_SCROLL_LABEL"] else {
            throw XCTSkip("Requires the configured inner-display scrolling fixture")
        }
        let app = try Session.shared.refreshActive()
        var error: NSError?
        let windowFrame = try XCTUnwrap(XCAppWindow(app, &error)).frame
        XCTAssertNil(error)
        // Make the live fixture repeatable after an earlier scroll run.
        for _ in 0..<3 {
            try scrollAncestorByVector(CGVector(dx: 0, dy: 300), scrollFrame: windowFrame, app: app)
        }
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).firstMatch
        XCTAssertTrue(element.exists)
        let before = element.frame.minY
        try scrollAncestorByVector(CGVector(dx: 0, dy: -300), scrollFrame: windowFrame, app: app)
        let after = element.exists ? element.frame.minY : nil
        try scrollAncestorByVector(CGVector(dx: 0, dy: 300), scrollFrame: windowFrame, app: app)
        XCTAssertTrue(after == nil || after! < before - 80, "A DOM scroll must move content on the inner display")
    }

    func testDOMTapReachesForegroundInnerDisplay() throws {
        guard XCUIScreen.screens.count > 1,
              let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"],
              let entry = ProcessInfo.processInfo.environment["IOS_USE_TEST_ENTRY_LABEL"],
              let destination = ProcessInfo.processInfo.environment["IOS_USE_TEST_DESTINATION_LABEL"] else {
            throw XCTSkip("Requires the configured inner-display navigation fixture")
        }
        let app = try Session.shared.refreshActive()
        XCTAssertEqual(app.value(forKey: "bundleID") as? String, bundle)
        let entryElement = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", entry, entry)).firstMatch
        XCTAssertTrue(entryElement.exists, "The entry must be present before the tap")
        let destinationElement = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", destination, destination)).firstMatch
        XCTAssertFalse(destinationElement.exists, "Start on the fixture's entry page")
        let frame = entryElement.frame
        let error = try RawPointer.perform(app: app, event: .tap(CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertNil(error)
        XCTAssertTrue(destinationElement.waitForExistence(timeout: 5), "A DOM tap must navigate on the inner display")
        try returnFromNavigation(app: app, entry: entryElement)
    }

    private func returnFromNavigation(app: XCUIApplication, entry: XCUIElement) throws {
        guard let closeLabel = ProcessInfo.processInfo.environment["IOS_USE_TEST_CLOSE_LABEL"] else { return }
        let close = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", closeLabel)).firstMatch
        XCTAssertTrue(close.exists)
        let closeFrame = close.frame
        XCTAssertNil(try RawPointer.perform(app: app, event: .tap(CGPoint(x: closeFrame.midX, y: closeFrame.midY))))
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "The return control must restore the entry page")
    }

    func testForegroundApplicationOnExpandedDisplay() throws {
        guard XCUIScreen.screens.count > 1,
              let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] else {
            throw XCTSkip("Requires a foreground multi-display fixture")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        XCTAssertEqual(app.state, .runningForeground, "The fixture must already be visible on the inner display")
        let detected = try XCTUnwrap(GetActiveApplication())
        XCTAssertEqual(detected.value(forKey: "bundleID") as? String, bundle,
                       "Foreground detection must select the app on the active inner display")
    }
}
