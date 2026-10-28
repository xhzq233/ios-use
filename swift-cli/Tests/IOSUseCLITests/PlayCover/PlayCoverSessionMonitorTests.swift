import Darwin
import Foundation
@testable import IOSUseCLI
import XCTest

final class PlayCoverSessionMonitorTests: XCTestCase {
    func testKernelObservationSeesTerminationAndForceQuit() throws {
        for signal in [SIGTERM, SIGKILL] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            let pid = process.processIdentifier
            let birth = try XCTUnwrap(PlayCoverService.processStartTimeMicroseconds(for: pid))
            let executable = try XCTUnwrap(PlayCoverRuntimeClient.executablePath(for: pid))
            var becameReady = false
            try PlayCoverSessionMonitor.observeExit(pid: pid, birth: birth,
                                                   executablePath: executable) {
                becameReady = true
                XCTAssertTrue(process.isRunning)
                XCTAssertEqual(kill(pid, signal), 0)
            }
            XCTAssertTrue(becameReady)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        }
    }

    func testObservationDoesNotWaitForAReusedPID() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let pid = process.processIdentifier
        let birth = try XCTUnwrap(PlayCoverService.processStartTimeMicroseconds(for: pid))
        try PlayCoverSessionMonitor.observeExit(
            pid: pid, birth: birth - 1,
            executablePath: PlayCoverRuntimeClient.executablePath(for: pid), ready: {}
        )
        XCTAssertTrue(process.isRunning)
    }

    func testProcessExitingBeforeRegistrationStillBecomesReady() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        var becameReady = false

        try PlayCoverSessionMonitor.observeExit(
            pid: process.processIdentifier, birth: 0,
            executablePath: "/usr/bin/true"
        ) {
            becameReady = true
        }

        XCTAssertTrue(becameReady)
    }
}
