import XCTest
@testable import IOSUseCLI

final class XCTestSessionHolderServiceTests: XCTestCase {
    func testDriverLockMatchesCurrentHolderOnlyForSameSession() {
        let info = SessionService.Info(
            udid: "REAL-1",
            deviceName: "iPhone",
            deviceVersion: "18.0",
            deviceType: "real",
            holderPid: 11,
            runnerPid: 22,
            sessionIdentifier: "SESSION",
            bundleId: "com.example.driver",
            controlSocketPath: "/tmp/holder.sock"
        )

        XCTAssertTrue(XCTestSessionHolderService.driverLockMatchesCurrentHolder(
            info: info,
            udid: "REAL-1",
            bundleId: "com.example.driver",
            holderPid: 11,
            runnerPid: 22,
            sessionIdentifier: "SESSION",
            controlSocketPath: "/tmp/holder.sock"
        ))
        XCTAssertFalse(XCTestSessionHolderService.driverLockMatchesCurrentHolder(
            info: info,
            udid: "REAL-1",
            bundleId: "com.example.driver",
            holderPid: 11,
            runnerPid: 22,
            sessionIdentifier: "OTHER",
            controlSocketPath: "/tmp/holder.sock"
        ))
        XCTAssertFalse(XCTestSessionHolderService.driverLockMatchesCurrentHolder(
            info: info,
            udid: "REAL-1",
            bundleId: "com.example.driver",
            holderPid: 11,
            runnerPid: 22,
            sessionIdentifier: "SESSION",
            controlSocketPath: "/tmp/other.sock"
        ))
    }

    func testHolderControlSocketReturnsStartResultAndStop() throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ius-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("holder.sock").path
        let state = XCTestSessionHolderControlState(
            holderPid: 123,
            bundleId: "com.example.driver",
            controlSocketPath: socketPath
        )
        let server = XCTestSessionHolderControlServer(socketPath: socketPath, state: state)
        try server.start()
        defer { server.stop() }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            state.markReady(runnerPid: 456, sessionIdentifier: "SESSION-1")
        }

        let start = try XCTestSessionHolderControlClient.request(
            socketPath: socketPath,
            command: "startStatus",
            timeoutSeconds: 2
        )

        XCTAssertEqual(start.status, "ready")
        XCTAssertEqual(start.holderPid, 123)
        XCTAssertEqual(start.runnerPid, 456)
        XCTAssertEqual(start.sessionIdentifier, "SESSION-1")
        XCTAssertEqual(start.bundleId, "com.example.driver")
        XCTAssertEqual(start.controlSocketPath, socketPath)

        let stop = try XCTestSessionHolderControlClient.request(
            socketPath: socketPath,
            command: "stop",
            timeoutSeconds: 2
        )
        XCTAssertEqual(stop.status, "stopping")
        XCTAssertTrue(state.shouldStop)
    }

    func testHolderStopsAfterStartupFailure() {
        let message = XCTestSessionHolderService.holderStopMessage(
            startupFailure: HolderFailure(description: "startup EOF"),
            postConfigurationFailure: nil
        )

        XCTAssertEqual(message, "holder startup session failed after start result: startup EOF")
    }

    func testHolderStopsAfterPostConfigurationFailure() {
        let message = XCTestSessionHolderService.holderStopMessage(
            startupFailure: nil,
            postConfigurationFailure: HolderFailure(description: "TLS EOF")
        )

        XCTAssertEqual(message, "XCTest session ended after configuration; stopping holder: TLS EOF")
    }

    func testHolderKeepsRunningWithoutListenerFailure() {
        let message = XCTestSessionHolderService.holderStopMessage(
            startupFailure: nil,
            postConfigurationFailure: nil
        )

        XCTAssertNil(message)
    }
}

private struct HolderFailure: Error, CustomStringConvertible {
    let description: String
}
