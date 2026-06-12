import Darwin
import Foundation
import XCTest
@testable import IOSUseCLI

final class AppLogCaptureServiceTests: XCTestCase {
    override func tearDown() {
        AppLogCaptureService.executablePathOverrideForTesting = nil
        AppLogCaptureService.helperLauncherForTesting = nil
        AppLogCaptureService.processAliveOverrideForTesting = nil
        AppLogCaptureService.processCommandOverrideForTesting = nil
        AppLogCaptureService.signalSenderForTesting = nil
        AppLogCaptureService.processExitWaiterForTesting = nil
        AppLogCaptureService.terminateObservationTimeoutForTesting = nil
        Shell.runResultOverrideForTesting = nil
        super.tearDown()
    }

    func testStartLaunchesHiddenHelperAndWaitsForRunningState() throws {
        let root = tempRoot("ios-use-app-log-start")
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        AppLogCaptureService.executablePathOverrideForTesting = "/usr/local/bin/ios-use"
        var launchedRequest: AppLogCaptureService.HelperLaunchRequest?
        AppLogCaptureService.helperLauncherForTesting = { request in
            launchedRequest = request
            let logFile = try XCTUnwrap(argumentValue(after: "--log-file", in: request.arguments))
            try AppLogCaptureService.writeState(AppLogState(
                lastLogFile: logFile,
                lastCapture: AppLogCaptureTarget(
                    bundleID: "com.example.LogEmitter",
                    udid: "SIM-1",
                    deviceType: "simulator",
                    logFile: logFile,
                    startedAt: 1,
                    stoppedAt: nil,
                    status: "running",
                    helperPID: 4321,
                    lastError: nil
                )
            ), paths: paths)
            return 4321
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        let result = try AppLogCaptureService.start(bundleID: "com.example.LogEmitter", udid: "SIM-1", deviceType: "simulator", paths: paths)

        XCTAssertEqual(result.message.components(separatedBy: "\n").first, "App log capture started.")
        XCTAssertTrue(result.message.contains("PID: 4321"))
        XCTAssertTrue(result.message.contains("Read with: ios-use log-read"))
        let request = try XCTUnwrap(launchedRequest)
        XCTAssertEqual(request.executablePath, "/usr/local/bin/ios-use")
        XCTAssertEqual(argumentValue(after: "--device-type", in: request.arguments), "simulator")
        XCTAssertEqual(argumentValue(after: "--udid", in: request.arguments), "SIM-1")
        XCTAssertEqual(argumentValue(after: "--bundle-id", in: request.arguments), "com.example.LogEmitter")
        XCTAssertEqual(argumentValue(after: "--home", in: request.arguments), root)
        XCTAssertEqual(request.environment["IOS_USE_HOME"], root)
        XCTAssertTrue(try XCTUnwrap(AppLogCaptureService.readState(paths: paths)?.lastLogFile).contains("com.example.LogEmitter-"))
    }

    func testLogReadUsesPatternLastAndClearAfterRead() throws {
        let root = tempRoot("ios-use-app-log-read")
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        let logFile = "\(paths.logs)/com.example-1.log"
        try "alpha 1\nbeta\nALPHA 2\n".write(toFile: logFile, atomically: true, encoding: .utf8)
        try AppLogCaptureService.writeState(AppLogState(
            lastLogFile: logFile,
            lastCapture: AppLogCaptureTarget(
                bundleID: "com.example",
                udid: "REAL-1",
                deviceType: "real",
                logFile: logFile,
                startedAt: 1,
                stoppedAt: 2,
                status: "stopped",
                helperPID: nil,
                lastError: nil
            )
        ), paths: paths)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root])
            .run(arguments: ["log-read", "--pattern", "alpha", "--flags", "i", "--last", "1", "--clearAfterRead"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "ALPHA 2\n")
        XCTAssertEqual(try String(contentsOfFile: logFile, encoding: .utf8), "")
    }

    func testObserveStopAfterTerminateReturnsStoppedWhenHelperUpdatesState() throws {
        let root = tempRoot("ios-use-app-log-observe-stopped")
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let logFile = "\(root)/logs/app.log"
        try AppLogCaptureService.writeState(AppLogState(
            lastLogFile: logFile,
            lastCapture: AppLogCaptureTarget(
                bundleID: "com.example",
                udid: "REAL-1",
                deviceType: "real",
                logFile: logFile,
                startedAt: 1,
                stoppedAt: nil,
                status: "running",
                helperPID: 111,
                lastError: nil
            )
        ), paths: paths)
        AppLogCaptureService.processAliveOverrideForTesting = { _ in true }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            try? AppLogCaptureService.writeState(AppLogState(
                lastLogFile: logFile,
                lastCapture: AppLogCaptureTarget(
                    bundleID: "com.example",
                    udid: "REAL-1",
                    deviceType: "real",
                    logFile: logFile,
                    startedAt: 1,
                    stoppedAt: 2,
                    status: "stopped",
                    helperPID: nil,
                    lastError: nil
                )
            ), paths: paths)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        let message = try AppLogCaptureService.observeStopAfterTerminate(bundleID: "com.example", udid: "REAL-1", paths: paths)

        XCTAssertEqual(message, "App log capture stopped.")
    }

    func testObserveStopAfterTerminateWarnsWhenHelperStillRunning() throws {
        let root = tempRoot("ios-use-app-log-observe-running")
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let logFile = "\(root)/logs/app.log"
        try AppLogCaptureService.writeState(AppLogState(
            lastLogFile: logFile,
            lastCapture: AppLogCaptureTarget(
                bundleID: "com.example",
                udid: "REAL-1",
                deviceType: "real",
                logFile: logFile,
                startedAt: 1,
                stoppedAt: nil,
                status: "running",
                helperPID: 222,
                lastError: nil
            )
        ), paths: paths)
        AppLogCaptureService.processAliveOverrideForTesting = { _ in true }
        AppLogCaptureService.terminateObservationTimeoutForTesting = 0.01
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        let message = try AppLogCaptureService.observeStopAfterTerminate(bundleID: "com.example", udid: "REAL-1", paths: paths)

        XCTAssertEqual(message, "warning: app log capture helper still running after terminateApp. Check \(paths.appLogState).")
    }

    func testSimulatorActivateAppUsesTerminateRunningProcessFlag() throws {
        var received: [String] = []
        Shell.runResultOverrideForTesting = { executable, arguments, cwd in
            XCTAssertEqual(executable, "xcrun")
            XCTAssertNil(cwd)
            received = arguments
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        try SimulatorService.activateApp(bundleID: "com.example", udid: "SIM-1", terminateExisting: true)

        XCTAssertEqual(received, ["simctl", "launch", "--terminate-running-process", "SIM-1", "com.example"])
    }

    private func tempRoot(_ prefix: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .path
    }
}

private func argumentValue(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option),
          arguments.indices.contains(arguments.index(after: index)) else {
        return nil
    }
    return arguments[arguments.index(after: index)]
}
