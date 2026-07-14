import Darwin
import IOSUseProtocol
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

    func testHolderControlSocketReturnsDisplayInfoFromReadySession() throws {
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
        let expected = CoreDeviceDisplayInfo(
            displays: [
                CoreDeviceDisplayInfo.Display(
                    displayID: 1,
                    name: "LCD",
                    primary: true,
                    pointScale: 3,
                    bounds: [0, 0, 1206, 2622],
                    nativeSize: [1206, 2622],
                    currentOrientation: "rot0",
                    nativeOrientation: "rot0"
                ),
            ],
            currentDeviceOrientation: "portrait",
            currentDeviceNonFlatOrientation: "portrait",
            orientationLocked: false,
            backlightState: "on"
        )
        state.markReady(
            runnerPid: 456,
            sessionIdentifier: "SESSION-1",
            displayInfoProvider: { expected }
        )
        let server = XCTestSessionHolderControlServer(socketPath: socketPath, state: state)
        try server.start()
        defer { server.stop() }

        let response = try XCTestSessionHolderControlClient.request(
            socketPath: socketPath,
            command: "displayInfo",
            timeoutSeconds: 2
        )

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.displayInfo, expected)
        XCTAssertNotNil(response.displayInfoElapsedMs)
        XCTAssertNil(response.error)
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

    func testDriverReadinessPollsUntilTCPConnectSucceeds() throws {
        var attempts = 0
        var sleeps: [useconds_t] = []
        var logs: [String] = []
        var peerFD: Int32?
        XCTestSessionHolderService.driverReadinessConnectorForTesting = { _, port in
            XCTAssertEqual(port, Int(IOSUseProtocol.defaultDriverPort))
            attempts += 1
            if attempts < 3 {
                throw UsbmuxError.connectFailed(response: "not ready")
            }
            var fds = [Int32](repeating: 0, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                throw CLIParseError.invalidValue("socketpair failed: \(errno)")
            }
            peerFD = fds[1]
            return fds[0]
        }
        XCTestSessionHolderService.driverReadinessSleeperForTesting = { sleeps.append($0) }
        XCTestSessionHolderService.driverReadinessTimeoutSecondsForTesting = 1
        addTeardownBlock {
            XCTestSessionHolderService.driverReadinessConnectorForTesting = nil
            XCTestSessionHolderService.driverReadinessSleeperForTesting = nil
            XCTestSessionHolderService.driverReadinessTimeoutSecondsForTesting = nil
            if let peerFD {
                Darwin.close(peerFD)
            }
        }

        try XCTestSessionHolderService.waitForDriverReadiness(udid: "REAL-1") {
            logs.append($0)
        }

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, [
            IOSUseProtocol.realDeviceDriverReadinessInitialDelayMicroseconds,
            IOSUseProtocol.realDeviceDriverReadinessPollMicroseconds,
            IOSUseProtocol.realDeviceDriverReadinessPollMicroseconds,
            IOSUseProtocol.realDeviceDriverReadinessPostSuccessDelayMicroseconds,
        ].map(useconds_t.init))
        XCTAssertTrue(logs.contains { $0.contains("waiting for driver TCP readiness") })
        XCTAssertTrue(logs.contains { $0.contains("driver TCP readiness confirmed attempts=3") })
    }

    func testDriverReadinessFailsAfterSingleAttemptWhenTimeoutIsZero() {
        var attempts = 0
        var sleeps: [useconds_t] = []
        XCTestSessionHolderService.driverReadinessConnectorForTesting = { _, _ in
            attempts += 1
            throw UsbmuxError.connectFailed(response: "still not ready")
        }
        XCTestSessionHolderService.driverReadinessSleeperForTesting = { sleeps.append($0) }
        XCTestSessionHolderService.driverReadinessTimeoutSecondsForTesting = 0
        addTeardownBlock {
            XCTestSessionHolderService.driverReadinessConnectorForTesting = nil
            XCTestSessionHolderService.driverReadinessSleeperForTesting = nil
            XCTestSessionHolderService.driverReadinessTimeoutSecondsForTesting = nil
        }

        XCTAssertThrowsError(try XCTestSessionHolderService.waitForDriverReadiness(udid: "REAL-1") { _ in }) { error in
            XCTAssertTrue(String(describing: error).contains("Driver TCP readiness timed out"))
            XCTAssertTrue(String(describing: error).contains("still not ready"))
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sleeps, [
            IOSUseProtocol.realDeviceDriverReadinessInitialDelayMicroseconds,
        ].map(useconds_t.init))
    }
}

private struct HolderFailure: Error, CustomStringConvertible {
    let description: String
}
