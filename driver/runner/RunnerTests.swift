import XCTest

final class IOSUseDriver: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        // #region debug-point xctest-entry-setup
        NSLog("[debug][xctest-entry-setup] IOSUseDriver setUp invoked")
        // #endregion
    }

    func testRun() throws {
        // #region debug-point xctest-entry-testRun
        NSLog("[debug][xctest-entry-testRun] IOSUseDriver testRun invoked")
        // #endregion
        let server = DriverServer.shared

        do {
            try server.start()
        } catch {
            XCTFail("Failed to start server: \(error)")
        }

        // Block forever, keeping the server alive
        let runLoop = RunLoop.current
        while server.isRunning {
            runLoop.run(mode: .default, before: .distantFuture)
        }
    }
}
