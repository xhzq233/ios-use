import XCTest

enum RawPointerEvent {
    case tap(CGPoint)
    case longPress(CGPoint, duration: Double)
    case drag(start: XCUICoordinate, end: XCUICoordinate, pressDuration: Double, velocity: Double, holdDuration: Double)
}

enum RawPointer {
    static func coordinate(app: XCUIApplication, point: CGPoint) -> XCUICoordinate {
        if XCUIScreen.screens.count > 1 {
            let window = app.windows.firstMatch
            let frame = window.frame
            return window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY))
        }
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    static func perform(app: XCUIApplication, event: RawPointerEvent, waitForIdle: Bool = true) throws -> NSError? {
        if waitForIdle { try Quiescence.wait(app: app, command: "raw-pointer") }
        try CommandDeadline.check()

        // App-relative XCTest coordinates resolve the display from the app's
        // snapshot. Raw synthesized records otherwise default to the outer screen.
        if XCUIScreen.screens.count > 1 {
            switch event {
            case .tap(let point):
                try Quiescence.bounded {
                    coordinate(app: app, point: point).tap()
                }
                return nil
            case .longPress(let point, let duration):
                try Quiescence.bounded {
                    coordinate(app: app, point: point).press(forDuration: duration)
                }
                return nil
            case .drag:
                break
            }
        }

        switch event {
        case .tap(let point):
            var error: NSError?
            let screenPoint = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y)).screenPoint
            guard XCSynthesizeTapAtPoint(screenPoint, app, &error) else { return error }

        case .longPress(let point, let duration):
            var error: NSError?
            let screenPoint = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y)).screenPoint
            guard XCSynthesizeLongPressAtPoint(screenPoint, duration, app, &error) else { return error }

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
