import XCTest

final class ServerTests: XCTestCase {
    func testStop_DoesNotDeadlockWhenServerIsIdle() {
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            DriverServer.shared.stop()
            sem.signal()
        }

        XCTAssertEqual(sem.wait(timeout: .now() + .seconds(1)), .success)
    }
}
