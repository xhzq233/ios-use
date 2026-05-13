import XCTest

enum RawPointerEvent {
    case tap(CGPoint)
    case longPress(CGPoint, duration: Double)
    case drag(start: XCUICoordinate, end: XCUICoordinate, pressDuration: Double, velocity: Double, holdDuration: Double)
}

enum RawPointer {
    private static let applicationImplSelector = NSSelectorFromString("applicationImpl")
    private static let currentProcessSelector = NSSelectorFromString("currentProcess")
    private static let waitForQuiescenceSelector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
    private static let waitForQuiescencePreEventSelector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")

    private typealias WaitForQuiescenceFn = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias WaitForQuiescencePreEventFn = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void

    static func perform(app: XCUIApplication, event: RawPointerEvent) -> NSError? {
        waitForQuiescence(app: app)

        switch event {
        case .tap(let point):
            var error: NSError?
            guard XCSynthesizeTapAtPoint(point, &error) else { return error }

        case .longPress(let point, let duration):
            var error: NSError?
            guard XCSynthesizeLongPressAtPoint(point, duration, &error) else { return error }

        case .drag(let start, let end, let pressDuration, let velocity, let holdDuration):
            start.press(
                forDuration: pressDuration,
                thenDragTo: end,
                withVelocity: XCUIGestureVelocity(rawValue: CGFloat(velocity)),
                thenHoldForDuration: holdDuration
            )
        }
        return nil
    }

    private static func waitForQuiescence(app: XCUIApplication) {
        guard let appImpl = performObjectSelector(on: app, selector: applicationImplSelector),
              let currentProcess = performObjectSelector(on: appImpl, selector: currentProcessSelector) else {
            return
        }

        // Match WebDriverAgent's XCUIApplicationProcess+FBQuiescence wrapper:
        // prefer the legacy selector when present; on newer XCTest builds that only expose
        // the pre-event variant, pass isPreEvent=false for an explicit command-side wait.
        if currentProcess.responds(to: waitForQuiescenceSelector) {
            let imp = currentProcess.method(for: waitForQuiescenceSelector)
            let fn = unsafeBitCast(imp, to: WaitForQuiescenceFn.self)
            fn(currentProcess, waitForQuiescenceSelector, true)
            return
        }

        if currentProcess.responds(to: waitForQuiescencePreEventSelector) {
            let imp = currentProcess.method(for: waitForQuiescencePreEventSelector)
            let fn = unsafeBitCast(imp, to: WaitForQuiescencePreEventFn.self)
            fn(currentProcess, waitForQuiescencePreEventSelector, true, false)
        }
    }

    private static func performObjectSelector(on target: AnyObject, selector: Selector) -> AnyObject? {
        guard target.responds(to: selector),
              let unmanaged = target.perform(selector) else {
            return nil
        }
        return unmanaged.takeUnretainedValue() as AnyObject
    }
}
