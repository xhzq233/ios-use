import XCTest

enum RawPointerEvent {
    case tap(CGPoint)
    case longPress(CGPoint, duration: Double)
    case drag(start: XCUICoordinate, end: XCUICoordinate, pressDuration: Double, velocity: Double, holdDuration: Double)
}

enum RawPointer {
    static func perform(app: XCUIApplication, event: RawPointerEvent, waitForIdle: Bool = true) throws -> NSError? {
        if waitForIdle { try Quiescence.wait(app: app, command: "raw-pointer") }
        try CommandDeadline.check()

        switch event {
        case .tap(let point):
            var error: NSError?
            guard XCSynthesizeTapAtPoint(point, &error) else { return error }

        case .longPress(let point, let duration):
            var error: NSError?
            guard XCSynthesizeLongPressAtPoint(point, duration, &error) else { return error }

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
