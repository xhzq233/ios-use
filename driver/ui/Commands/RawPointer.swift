import XCTest

enum RawPointerEvent {
    case tap(CGPoint)
    case longPress(CGPoint, duration: Double)
    case drag(start: XCUICoordinate, end: XCUICoordinate, pressDuration: Double, velocity: Double, holdDuration: Double)
}

enum RawPointer {
    static func origin(app: XCUIApplication, displayContext: XCDisplayContext? = nil) throws -> XCUICoordinate {
        if let context = try resolveDisplay(app: app, existing: displayContext) {
            var error: NSError?
            guard let window = XCDisplayWindow(context, &error) else {
                throw DriverError.gestureFailed(error?.localizedDescription ?? "Active display window is unavailable")
            }
            let frame = context.windowFrame
            return window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: -frame.minX, dy: -frame.minY))
        }
        return app.coordinate(withNormalizedOffset: .zero)
    }

    private static func resolveDisplay(app: XCUIApplication, existing: XCDisplayContext?) throws -> XCDisplayContext? {
        if let existing { return existing }
        guard XCHasMultipleDisplays() else { return nil }
        var error: NSError?
        guard let context = XCResolveDisplayContext(app, nil, &error) else {
            throw DriverError.gestureFailed(error?.localizedDescription ?? "Active display is unavailable")
        }
        return context
    }

    private static func touchPoint(_ point: CGPoint, app: XCUIApplication,
                                   displayContext: XCDisplayContext?) throws -> (CGPoint, NSNumber?) {
        guard let context = try resolveDisplay(app: app, existing: displayContext) else {
            return (app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y)).screenPoint, nil)
        }
        var error: NSError?
        var screenPoint = CGPoint.zero
        guard let orientation = app.value(forKey: "interfaceOrientation") as? NSNumber,
              XCDisplayScreenPoint(context, point, orientation.intValue, &screenPoint, &error) else {
            throw DriverError.gestureFailed(error?.localizedDescription ?? "Touch coordinate conversion failed")
        }
        return (screenPoint, context.displayID)
    }

    static func perform(app: XCUIApplication, event: RawPointerEvent,
                        displayContext: XCDisplayContext? = nil, waitForIdle: Bool = true) throws -> NSError? {
        if waitForIdle { try Quiescence.wait(app: app, command: "raw-pointer") }
        try CommandDeadline.check()

        switch event {
        case .tap(let point):
            var error: NSError?
            let (screenPoint, display) = try touchPoint(point, app: app, displayContext: displayContext)
            try CommandDeadline.check()
            guard XCSynthesizeTapAtPoint(screenPoint, app, display, &error) else { return error }

        case .longPress(let point, let duration):
            var error: NSError?
            let (screenPoint, display) = try touchPoint(point, app: app, displayContext: displayContext)
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
