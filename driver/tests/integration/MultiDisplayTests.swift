import UIKit
import XCTest
import Fory

/// Opt-in integration regression: keep the fixture foreground on the Duo inner screen.
final class MultiDisplayTests: XCTestCase {
    func testSystemPermissionAlertDismissal() throws {
        guard let label = ProcessInfo.processInfo.environment["IOS_USE_TEST_ALERT_BUTTON"] else {
            throw XCTSkip("Requires an already visible system permission alert and its explicit button label")
        }
        let springboard = XCUIApplication(bundleIdentifier: IOSUseProtocol.springboardBundleId)
        XCTAssertTrue(springboard.buttons[label].exists)
        let response = try AlertCommands.dismissAlert(ForyDismissAlertArgs(
            selection: IOSUseAlertSelectionMode.label.rawValue,
            label: label,
            scope: IOSUseAlertScope.springboard.rawValue
        ))
        XCTAssertTrue(response.ok)
        let payload = try createFory().deserialize(response.payload, as: ForyAlertPayload.self)
        XCTAssertTrue(payload.dismissed)
        XCTAssertEqual(payload.button, label)
        XCTAssertFalse(springboard.buttons[label].waitForExistence(timeout: 1))
    }

    func testWindowResolutionMatchesLiveSnapshot() throws {
        guard let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] else {
            throw XCTSkip("Requires a foreground fixture")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.activate()
        let raw = try XCTUnwrap(SnapshotOfElement(app))
        let selected = try XCTUnwrap(XCDisplayWindowSnapshot(raw))
        var error: NSError?
        let context = try XCTUnwrap(XCResolveDisplayContext(app, raw, &error))
        let window = try XCTUnwrap(XCDisplayWindow(context, &error))
        XCTAssertNil(error)
        XCTAssertTrue(SnapshotMatchesElement(selected, try XCTUnwrap(SnapshotOfElement(window))))
        XCTAssertTrue(try XCTUnwrap(XCDisplayWindow(context, &error)) === window)
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
        let context = try XCTUnwrap(XCResolveDisplayContext(app, nil, nil))
        var error: NSError?
        let screen = try XCTUnwrap(XCDisplayScreen(context, &error))
        let displayID = try XCTUnwrap(screen.value(forKey: "displayID") as? NSNumber)
        XCTAssertEqual(displayID, context.displayID)
        XCTAssertNil(try RawPointer.perform(app: app, event: .tap(CGPoint(x: frame.midX, y: frame.midY)),
                                             displayContext: context, waitForIdle: false))
        XCTAssertNil(error)
        XCTAssertTrue(result.waitForExistence(timeout: 5), "Explicit-display synthesis must reach the navigation target")
        try returnFromNavigation(app: app, entry: element)
    }

    func testScreenshotMatchesForegroundDisplay() throws {
        guard XCHasMultipleDisplays(),
              ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] != nil else {
            throw XCTSkip("Requires a foreground multi-display fixture")
        }
        let app = try Session.shared.refreshActive()
        var error: NSError?
        let context = try XCTUnwrap(XCResolveDisplayContext(app, nil, &error))
        let screen = try XCTUnwrap(XCDisplayScreen(context, &error))
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

    func testWindowOnlyObservationRestoresFullSnapshotDepth() throws {
        guard let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] else {
            throw XCTSkip("Requires a foreground fixture")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.activate()
        let context = try XCTUnwrap(XCResolveDisplayContext(app, nil, nil))
        let window = try XCTUnwrap(context.windowSnapshot as? NSObject)
        let raw = try XCTUnwrap(SnapshotOfElement(app) as? NSObject)
        let full = try XCTUnwrap(XCResolveDisplayContext(app, raw, nil))
        let fullWindow = try XCTUnwrap(full.windowSnapshot as? NSObject)
        XCTAssertFalse(try XCTUnwrap(fullWindow.value(forKey: "children") as? [Any]).isEmpty,
                       "A window-only request must not limit the next DOM snapshot")
        let windows = try XCTUnwrap(raw.value(forKey: "children") as? [NSObject]).filter {
            ($0.value(forKey: "elementType") as? NSNumber)?.uintValue == XCUIElement.ElementType.window.rawValue
        }
        if windows.count == 1 {
            XCTAssertTrue(try XCTUnwrap(window.value(forKey: "children") as? [Any]).isEmpty,
                          "A single window should not require its content subtree")
        }
        XCTAssertEqual(context.displayID, full.displayID)
        XCTAssertEqual(context.windowFrame, full.windowFrame)
    }

    func testSnapshotCoordinateConversionMatchesNativeAcrossOrientations() throws {
        guard let bundle = ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] else {
            throw XCTSkip("Requires a foreground fixture")
        }
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original }
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.activate()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            device.orientation = orientation
            let context = try XCTUnwrap(XCResolveDisplayContext(app, SnapshotOfElement(app), nil))
            let window = try XCTUnwrap(XCDisplayWindow(context, nil))
            let frame = context.windowFrame
            let actualOrientation = try XCTUnwrap(app.value(forKey: "interfaceOrientation") as? NSNumber)
            for point in [CGPoint(x: frame.minX + 10, y: frame.minY + 10),
                          CGPoint(x: frame.midX, y: frame.midY),
                          CGPoint(x: frame.maxX - 10, y: frame.maxY - 10)] {
                let native = window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY)).screenPoint
                var converted = CGPoint.zero
                XCTAssertTrue(XCDisplayScreenPoint(context, point, actualOrientation.intValue, &converted, nil))
                XCTAssertEqual(converted.x, native.x, accuracy: 0.001)
                XCTAssertEqual(converted.y, native.y, accuracy: 0.001)
            }
        }
    }

    func testDOMViewportMatchesInnerWindow() throws {
        guard XCHasMultipleDisplays(),
              ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] != nil else {
            throw XCTSkip("Requires a foreground multi-display fixture")
        }
        let app = try Session.shared.refreshActive()
        let snapshot = try XCTUnwrap(SafeSnapshot(ofApp: app))
        var error: NSError?
        let windowFrame = try XCTUnwrap(XCResolveDisplayContext(app, SnapshotOfElement(app), &error)).windowFrame
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
        guard ProcessInfo.processInfo.environment["IOS_USE_TEST_FOREGROUND_BUNDLE"] != nil,
              let label = ProcessInfo.processInfo.environment["IOS_USE_TEST_SCROLL_LABEL"] else {
            throw XCTSkip("Requires the configured scrolling fixture")
        }
        let app = try Session.shared.refreshActive()
        func drag(_ dy: CGFloat) throws {
            let context = try XCTUnwrap(XCResolveDisplayContext(app, nil, nil))
            let origin = try RawPointer.origin(app: app, displayContext: context)
            try scrollAncestorByVector(CGVector(dx: 0, dy: dy), scrollFrame: context.windowFrame,
                                        app: app, origin: origin)
        }
        // Make the live fixture repeatable after an earlier scroll run.
        for _ in 0..<3 { try drag(300) }
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).firstMatch
        XCTAssertTrue(element.exists)
        let before = element.frame.minY
        try drag(-300)
        let after = element.exists ? element.frame.minY : nil
        try drag(300)
        XCTAssertTrue(after == nil || after! < before - 80, "A DOM scroll must move content on the inner display")
    }

    func testDOMTapReachesForegroundInnerDisplay() throws {
        guard XCHasMultipleDisplays(),
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
        guard XCHasMultipleDisplays(),
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
