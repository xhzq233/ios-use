import XCTest

final class XCUIDriverRunner: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    func testRun() throws {
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
