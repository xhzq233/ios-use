import XCTest

enum Quiescence {
    // Normal animations finish early; missing idle notifications cannot consume
    // the 10s command watchdog. This also bounds native gesture-internal waits.
    static let timeoutSeconds = 2.0

    static func bounded<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        var error: NSError?
        guard XCWithApplicationStateTimeout(timeoutSeconds, { result = Result { try body() } }, &error) else {
            throw DriverError.serverError(error?.localizedDescription ?? "Could not bound XCTest idle waiting")
        }
        return try result!.get()
    }
    private static let applicationImplSelector = NSSelectorFromString("applicationImpl")
    private static let currentProcessSelector = NSSelectorFromString("currentProcess")
    private static let waitForQuiescenceSelector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
    private static let waitForQuiescencePreEventSelector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")

    private typealias WaitForQuiescenceFn = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias WaitForQuiescencePreEventFn = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void

    static func wait(app: XCUIApplication, command: String) throws {
        try CommandDeadline.check()
        try bounded { waitForIdle(app: app, command: command) }
        try CommandDeadline.check()
    }

    private static func waitForIdle(app: XCUIApplication, command: String) {
        guard let appImpl = performObjectSelector(on: app, selector: applicationImplSelector),
              let currentProcess = performObjectSelector(on: appImpl, selector: currentProcessSelector) else {
            log("wait skipped command=\(command) reason=no-current-process")
            return
        }

        if currentProcess.responds(to: waitForQuiescenceSelector) {
            runWait(command: command, selectorName: "waitForQuiescenceIncludingAnimationsIdle:") {
                let imp = currentProcess.method(for: waitForQuiescenceSelector)
                let fn = unsafeBitCast(imp, to: WaitForQuiescenceFn.self)
                fn(currentProcess, waitForQuiescenceSelector, true)
            }
            return
        }

        if currentProcess.responds(to: waitForQuiescencePreEventSelector) {
            runWait(command: command, selectorName: "waitForQuiescenceIncludingAnimationsIdle:isPreEvent:") {
                let imp = currentProcess.method(for: waitForQuiescencePreEventSelector)
                let fn = unsafeBitCast(imp, to: WaitForQuiescencePreEventFn.self)
                fn(currentProcess, waitForQuiescencePreEventSelector, true, false)
            }
            return
        }

        log("wait skipped command=\(command) reason=no-selector")
    }

    private static func runWait(command: String, selectorName: String, _ wait: () -> Void) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        log("wait start command=\(command) limit=\(timeoutSeconds)s selector=\(selectorName)")
        wait()
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        log("wait finish command=\(command) elapsed=\(elapsedMs)ms selector=\(selectorName)")
    }

    private static func log(_ message: String) {
        DriverLog.info("[quiescence] \(message)")
    }

    private static func performObjectSelector(on target: AnyObject, selector: Selector) -> AnyObject? {
        guard target.responds(to: selector),
              let unmanaged = target.perform(selector) else {
            return nil
        }
        return unmanaged.takeUnretainedValue() as AnyObject
    }
}
