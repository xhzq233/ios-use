import XCTest

/// Opt-in integration regression: keep the fixture foreground on the Duo inner screen.
final class MultiDisplayTests: XCTestCase {
    func testDOMViewportMatchesInnerWindow() throws {
        guard ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] != nil else {
            throw XCTSkip("Requires a foreground multi-display fixture")
        }
        let app = try Session.shared.refreshActive()
        let snapshot = try XCTUnwrap(SafeSnapshot(ofApp: app))
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertEqual(snapshot.appFrame.width, windowFrame.width, accuracy: 0.001,
                       "DOM visibility must use the inner window's current orientation")
        XCTAssertEqual(snapshot.appFrame.height, windowFrame.height, accuracy: 0.001)
        XCTAssertEqual(snapshot.appFrame.minX, windowFrame.minX, accuracy: 0.001)
        XCTAssertEqual(snapshot.appFrame.minY, windowFrame.minY, accuracy: 0.001)
        XCTAssertEqual(snapshot.frame, snapshot.appFrame)
        XCTAssertEqual(try XCTUnwrap(captureCleanedSnapshot()).appFrame, snapshot.appFrame)
    }

    func testDOMScrollReachesForegroundInnerDisplay() throws {
        guard ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] != nil,
              let label = ProcessInfo.processInfo.environment["IOS_USE_TEST_SCROLL_LABEL"] else {
            throw XCTSkip("Requires the configured inner-display scrolling fixture")
        }
        let app = try Session.shared.refreshActive()
        // Make the live fixture repeatable after an earlier scroll run.
        for _ in 0..<3 {
            try scrollAncestorByVector(CGVector(dx: 0, dy: 300), scrollFrame: app.windows.firstMatch.frame, app: app)
        }
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).firstMatch
        XCTAssertTrue(element.exists)
        let before = element.frame.minY
        try scrollAncestorByVector(CGVector(dx: 0, dy: -300), scrollFrame: app.windows.firstMatch.frame, app: app)
        let after = element.exists ? element.frame.minY : nil
        try scrollAncestorByVector(CGVector(dx: 0, dy: 300), scrollFrame: app.windows.firstMatch.frame, app: app)
        XCTAssertTrue(after == nil || after! < before - 80, "A DOM scroll must move content on the inner display")
    }

    func testDOMTapReachesForegroundInnerDisplay() throws {
        guard let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"],
              let entry = ProcessInfo.processInfo.environment["IOS_USE_TEST_ENTRY_LABEL"],
              let destination = ProcessInfo.processInfo.environment["IOS_USE_TEST_DESTINATION_LABEL"] else {
            throw XCTSkip("Requires the configured inner-display navigation fixture")
        }
        let app = try Session.shared.refreshActive()
        XCTAssertEqual(app.value(forKey: "bundleID") as? String, bundle)
        let entryElement = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", entry, entry)).firstMatch
        XCTAssertTrue(entryElement.exists, "The entry must be present before the tap")
        let frame = entryElement.frame
        let error = try RawPointer.perform(app: app, event: .tap(CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertNil(error)
        let destinationElement = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", destination, destination)).firstMatch
        XCTAssertTrue(destinationElement.waitForExistence(timeout: 5), "A DOM tap must navigate on the inner display")
        guard let closeLabel = ProcessInfo.processInfo.environment["IOS_USE_TEST_CLOSE_LABEL"] else { return }
        let close = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", closeLabel)).firstMatch
        XCTAssertTrue(close.exists)
        let closeFrame = close.frame
        XCTAssertNil(try RawPointer.perform(app: app, event: .tap(CGPoint(x: closeFrame.midX, y: closeFrame.midY))))
        XCTAssertTrue(entryElement.waitForExistence(timeout: 5), "The inner-display return control must restore the entry page")
    }

    func testForegroundApplicationOnExpandedDisplay() throws {
        guard let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] else {
            throw XCTSkip("Requires a foreground multi-display fixture")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        XCTAssertEqual(app.state, .runningForeground, "The fixture must already be visible on the inner display")
        let detected = try XCTUnwrap(GetActiveApplication())
        XCTAssertEqual(detected.value(forKey: "bundleID") as? String, bundle,
                       "Foreground detection must select the app on the active inner display")
    }
}
