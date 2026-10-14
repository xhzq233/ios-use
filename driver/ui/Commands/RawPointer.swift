import XCTest

enum RawPointerEvent {
    case tap(CGPoint)
    case longPress(CGPoint, duration: Double)
    case drag(start: XCUICoordinate, end: XCUICoordinate, pressDuration: Double, velocity: Double, holdDuration: Double)
}

enum RawPointer {
    static func coordinate(app: XCUIApplication, point: CGPoint) throws -> XCUICoordinate {
        if XCUIScreen.screens.count > 1 {
            var error: NSError?
            guard let window = XCAppWindow(app, &error) else {
                throw DriverError.gestureFailed(error?.localizedDescription ?? "Active display window is unavailable")
            }
            let frame = window.frame
            return window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY))
        }
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    private static func displayID(app: XCUIApplication) throws -> NSNumber? {
        guard XCUIScreen.screens.count > 1 else { return nil }
        var error: NSError?
        guard let screen = XCAppScreen(app, &error) else {
            throw DriverError.gestureFailed(error?.localizedDescription ?? "Active display is unavailable")
        }
        return screen.value(forKey: "displayID") as? NSNumber
    }

    static func perform(app: XCUIApplication, event: RawPointerEvent, waitForIdle: Bool = true) throws -> NSError? {
        if waitForIdle { try Quiescence.wait(app: app, command: "raw-pointer") }
        try CommandDeadline.check()

        switch event {
        case .tap(let point):
            var error: NSError?
            let screenPoint = try coordinate(app: app, point: point).screenPoint
            let display = try displayID(app: app)
            try CommandDeadline.check()
            guard XCSynthesizeTapAtPoint(screenPoint, app, display, &error) else { return error }

        case .longPress(let point, let duration):
            var error: NSError?
            let screenPoint = try coordinate(app: app, point: point).screenPoint
            let display = try displayID(app: app)
            try CommandDeadline.check()
            guard XCSynthesizeLongPressAtPoint(screenPoint, duration, app, display, &error) else { return error }

        case .drag(let start, let end, let pressDuration, let velocity, let holdDuration):
            try Quiescence.bounded {
                start.press(
                    forDuration: pressDuration,
                    thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: CGFloat(velocity)),
                    thenHoldForDuration: holdDuration
                )
            }
        }
        return nil
    }
}
