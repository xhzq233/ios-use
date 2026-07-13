import Darwin
import Foundation
import IOSUseProtocol

struct AppLogCaptureTarget: Codable, Equatable, Sendable {
    var bundleID: String
    var udid: String
    var deviceType: String
    var logFile: String
    var startedAt: Int
    var stoppedAt: Int?
    var status: String
    var helperPID: Int32?
    var lastError: String?
}

struct AppLogState: Codable, Equatable, Sendable {
    var lastLogFile: String?
    var lastCapture: AppLogCaptureTarget?
}

enum AppLogCaptureService {
    static let helperCommandName = "__ios-use-app-log-capture"

    struct HelperLaunchRequest: Equatable {
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
        var stderrPath: String
    }

    static var executablePathOverrideForTesting: String?
    static var helperLauncherForTesting: ((HelperLaunchRequest) throws -> Int32)?
    static var processAliveOverrideForTesting: ((Int32) -> Bool)?
    static var processCommandOverrideForTesting: ((Int32) -> String?)?
    static var signalSenderForTesting: ((Int32, Int32) -> Int32)?
    static var processExitWaiterForTesting: ((Int32, Double) -> Bool)?
    static var terminateObservationTimeoutForTesting: Double?

    static func start(bundleID: String, udid: String, deviceType: String, paths: IOSUsePaths) throws -> AppLifecycleService.Result {
        try stopExistingCaptureIfNeeded(paths: paths)
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        let logFile = "\(paths.logs)/\(safeLogFileStem(bundleID))-\(nowSeconds()).log"
        FileManager.default.createFile(atPath: logFile, contents: nil)

        let request = HelperLaunchRequest(
            executablePath: try executablePath(),
            arguments: [
                helperCommandName,
                "--device-type", deviceType,
                "--udid", udid,
                "--bundle-id", bundleID,
                "--log-file", logFile,
                "--home", paths.root,
            ],
            environment: ProcessInfo.processInfo.environment.merging(["IOS_USE_HOME": paths.root]) { _, new in new },
            stderrPath: CLILogService.logPath(paths: paths)
        )
        let pid = try launchHelper(request)
        let capture = try waitForCaptureStart(pid: pid, logFile: logFile, paths: paths)
        let status = capture.status == "running" ? "App log capture started." : "App log capture finished."
        return AppLifecycleService.Result(message: "\(status)\nPID: \(pid)\nLog: \(logFile)")
    }

    static func runHelper(arguments: [String], paths: IOSUsePaths) throws -> String {
        let options = try parseHelperOptions(arguments)
        if let home = options.home, standardizedPath(home) != standardizedPath(paths.root) {
            throw CLIParseError.invalidValue("app log helper home mismatch: \(home) != \(paths.root)")
        }
        let monitor = InterruptMonitor(onInterrupt: nil)
        monitor.start()
        defer { monitor.stop() }

        var started = false
        do {
            switch options.deviceType {
            case "real":
                try runRealDeviceHelper(options: options, paths: paths, interruptMonitor: monitor) {
                    started = true
                }
            case "simulator":
                try runSimulatorHelper(options: options, paths: paths, interruptMonitor: monitor) {
                    started = true
                }
            default:
                throw CLIParseError.invalidValue("Unsupported app log device type: \(options.deviceType)")
            }
            if started {
                try markStopped(bundleID: options.bundleID, udid: options.udid, logFile: options.logFile, paths: paths)
            }
            return ""
        } catch let signal as CLIExitSignal {
            if started {
                try? markStopped(bundleID: options.bundleID, udid: options.udid, logFile: options.logFile, paths: paths)
            } else {
                try? markFailed(options: options, error: signal.message, paths: paths)
            }
            throw signal
        } catch {
            if started {
                try? markStopped(bundleID: options.bundleID, udid: options.udid, logFile: options.logFile, paths: paths)
            } else {
                try? markFailed(options: options, error: "\(error)", paths: paths)
            }
            throw error
        }
    }

    static func stopCaptureForInstall(bundleID: String, udid: String, paths: IOSUsePaths) throws {
        try stopExistingCaptureIfNeeded(paths: paths, matchingBundleID: bundleID, matchingUDID: udid)
    }

    static func observeStopAfterTerminate(bundleID: String, udid: String, paths: IOSUsePaths) throws -> String? {
        guard let capture = readState(paths: paths)?.lastCapture,
              capture.status == "running",
              capture.bundleID == bundleID,
              capture.udid == udid else {
            return nil
        }

        let deadline = Date().addingTimeInterval(terminateObservationTimeoutForTesting ?? 3.0)
        while Date() < deadline {
            if let refreshed = readState(paths: paths)?.lastCapture,
               refreshed.logFile == capture.logFile,
               refreshed.status != "running" {
                return "App log capture stopped."
            }
            usleep(100_000)
        }

        if let helperPID = capture.helperPID, !processAlive(helperPID) {
            return "warning: app log capture helper exited but state did not update to stopped. Check \(paths.appLogState)."
        }
        return "warning: app log capture helper still running after terminateApp. Check \(paths.appLogState)."
    }

    static func readState(paths: IOSUsePaths) -> AppLogState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.appLogState)) else { return nil }
        return try? JSONDecoder().decode(AppLogState.self, from: data)
    }

    static func writeState(_ state: AppLogState, paths: IOSUsePaths) throws {
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: paths.appLogState).deletingLastPathComponent().path, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: paths.appLogState), options: [.atomic])
    }

    private static func runRealDeviceHelper(
        options: HelperOptions,
        paths: IOSUsePaths,
        interruptMonitor: InterruptMonitor,
        didStart: () throws -> Void
    ) throws {
        let fileHandle = try openAppendHandle(path: options.logFile)
        defer { try? fileHandle.close() }

        let session = try CoreDeviceDirectTunnelRuntime(eventSink: nil).start(udid: options.udid)
        defer {
            session.close()
            _ = session.waitForClose(timeoutSeconds: 1)
        }
        guard let peerInfo = session.peerInfo else {
            throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
        }
        guard peerInfo.services[CoreDeviceAppService.serviceName] != nil else {
            throw CLIParseError.invalidValue("CoreDevice appservice not available on this device. Try re-plugging the device, clearing trust, and re-pairing.")
        }
        guard peerInfo.services[CoreDeviceOpenStdIOSocket.serviceName] != nil else {
            throw CLIParseError.invalidValue("CoreDevice openstdio service not available on this device.")
        }

        let stdioSocket = try CoreDeviceOpenStdIOSocket.connect(session: session)
        defer { stdioSocket.close() }

        let appService = try CoreDeviceAppService(client: session.connectRemoteXPCService(CoreDeviceAppService.serviceName))
        defer { appService.close() }
        _ = try appService.launchApplication(
            bundleID: options.bundleID,
            arguments: [],
            terminateExisting: true,
            startSuspended: false,
            environment: [:],
            payloadURL: nil,
            activates: true,
            standardIOIdentifier: stdioSocket.identifier
        )

        try markRunning(options: options, deviceType: "real", paths: paths)
        try didStart()
        try stdioSocket.drainToFile(fileHandle, interruptMonitor: interruptMonitor)
    }

    private static func runSimulatorHelper(
        options: HelperOptions,
        paths: IOSUsePaths,
        interruptMonitor: InterruptMonitor,
        didStart: () throws -> Void
    ) throws {
        let fileHandle = try openAppendHandle(path: options.logFile)
        defer { try? fileHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "xcrun", "simctl", "launch",
            "--console",
            "--terminate-running-process",
            options.udid,
            options.bundleID,
        ]
        process.standardOutput = fileHandle
        process.standardError = fileHandle
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                _ = waitForProcessExit(pid: process.processIdentifier, timeoutSeconds: 1.0)
            }
        }

        let quickFailureDeadline = Date().addingTimeInterval(0.5)
        while Date() < quickFailureDeadline, process.isRunning {
            try interruptMonitor.throwIfInterrupted("App log capture interrupted")
            usleep(50_000)
        }
        if !process.isRunning, process.terminationStatus != 0 {
            throw CLIParseError.invalidValue("simctl launch --console failed with exit \(process.terminationStatus). Check \(options.logFile).")
        }

        try markRunning(options: options, deviceType: "simulator", paths: paths)
        try didStart()
        while process.isRunning {
            try interruptMonitor.throwIfInterrupted("App log capture interrupted")
            usleep(100_000)
        }
    }

    private static func launchHelper(_ request: HelperLaunchRequest) throws -> Int32 {
        if let helperLauncherForTesting {
            return try helperLauncherForTesting(request)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.environment = request.environment

        let stderrHandle = try openAppendHandle(path: request.stderrPath)
        defer { try? stderrHandle.close() }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle
        try process.run()
        return process.processIdentifier
    }

    private static func waitForCaptureStart(pid: Int32, logFile: String, paths: IOSUsePaths) throws -> AppLogCaptureTarget {
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if let capture = readState(paths: paths)?.lastCapture,
               capture.logFile == logFile {
                switch capture.status {
                case "running", "stopped":
                    return capture
                case "failed":
                    throw CLIParseError.invalidValue(capture.lastError ?? "App log capture helper failed. Check \(CLILogService.logPath(paths: paths)).")
                default:
                    break
                }
            }
            if !processAlive(pid),
               let capture = readState(paths: paths)?.lastCapture,
               capture.logFile == logFile,
               capture.status == "failed" {
                throw CLIParseError.invalidValue(capture.lastError ?? "App log capture helper failed. Check \(CLILogService.logPath(paths: paths)).")
            }
            usleep(100_000)
        }
        throw CLIParseError.invalidValue("Timed out waiting for app log capture helper to start. Check \(CLILogService.logPath(paths: paths)).")
    }

    private static func stopExistingCaptureIfNeeded(paths: IOSUsePaths, matchingBundleID: String? = nil, matchingUDID: String? = nil) throws {
        guard var state = readState(paths: paths),
              var capture = state.lastCapture,
              capture.status == "running",
              let pid = capture.helperPID else {
            return
        }
        if let matchingBundleID, capture.bundleID != matchingBundleID {
            return
        }
        if let matchingUDID, capture.udid != matchingUDID {
            return
        }
        guard processAlive(pid) else {
            capture.status = "stopped"
            capture.stoppedAt = nowSeconds()
            capture.helperPID = nil
            state.lastCapture = capture
            try writeState(state, paths: paths)
            return
        }
        guard isExpectedHelperProcess(pid: pid, paths: paths) else {
            throw CLIParseError.invalidValue("app log state is owned by an unrelated live process (PID \(pid)); not terminating it. Remove stale state manually if needed: \(paths.appLogState)")
        }
        _ = terminateProcess(pid: pid, force: true)
        capture.status = "stopped"
        capture.stoppedAt = nowSeconds()
        capture.helperPID = nil
        state.lastCapture = capture
        try writeState(state, paths: paths)
    }

    private static func markRunning(options: HelperOptions, deviceType: String, paths: IOSUsePaths) throws {
        let capture = AppLogCaptureTarget(
            bundleID: options.bundleID,
            udid: options.udid,
            deviceType: deviceType,
            logFile: options.logFile,
            startedAt: nowSeconds(),
            stoppedAt: nil,
            status: "running",
            helperPID: getpid(),
            lastError: nil
        )
        try writeState(AppLogState(lastLogFile: options.logFile, lastCapture: capture), paths: paths)
    }

    private static func markStopped(bundleID: String, udid: String, logFile: String, paths: IOSUsePaths) throws {
        var state = readState(paths: paths) ?? AppLogState(lastLogFile: logFile, lastCapture: nil)
        var capture = state.lastCapture ?? AppLogCaptureTarget(
            bundleID: bundleID,
            udid: udid,
            deviceType: "",
            logFile: logFile,
            startedAt: nowSeconds(),
            stoppedAt: nil,
            status: "running",
            helperPID: getpid(),
            lastError: nil
        )
        guard capture.logFile == logFile else { return }
        capture.status = "stopped"
        capture.stoppedAt = nowSeconds()
        capture.helperPID = nil
        capture.lastError = nil
        state.lastLogFile = logFile
        state.lastCapture = capture
        try writeState(state, paths: paths)
    }

    private static func markFailed(options: HelperOptions, error: String, paths: IOSUsePaths) throws {
        let capture = AppLogCaptureTarget(
            bundleID: options.bundleID,
            udid: options.udid,
            deviceType: options.deviceType,
            logFile: options.logFile,
            startedAt: nowSeconds(),
            stoppedAt: nowSeconds(),
            status: "failed",
            helperPID: nil,
            lastError: error
        )
        try writeState(AppLogState(lastLogFile: options.logFile, lastCapture: capture), paths: paths)
    }

    private static func parseHelperOptions(_ arguments: [String]) throws -> HelperOptions {
        var parser = ArgumentParser(arguments)
        var deviceType: String?
        var udid: String?
        var bundleID: String?
        var logFile: String?
        var home: String?
        while let arg = parser.consume() {
            switch arg {
            case "--device-type": deviceType = try parser.value(for: arg)
            case "--udid": udid = try parser.value(for: arg)
            case "--bundle-id": bundleID = try parser.value(for: arg)
            case "--log-file": logFile = try parser.value(for: arg)
            case "--home": home = try parser.value(for: arg)
            default: throw CLIParseError.unknownOption(arg)
            }
        }
        return HelperOptions(
            deviceType: try require(deviceType, option: "--device-type"),
            udid: try require(udid, option: "--udid"),
            bundleID: try require(bundleID, option: "--bundle-id"),
            logFile: try require(logFile, option: "--log-file"),
            home: home
        )
    }

    private static func require(_ value: String?, option: String) throws -> String {
        guard let value, !value.isEmpty else { throw CLIParseError.missingRequiredOption(option) }
        return value
    }

    private static func openAppendHandle(path: String) throws -> FileHandle {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        _ = try? handle.seekToEnd()
        return handle
    }

    private static func executablePath() throws -> String {
        if let executablePathOverrideForTesting {
            return executablePathOverrideForTesting
        }
        if let path = Bundle.main.executableURL?.path, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return try NSLogService.executablePath()
    }

    private static func safeLogFileStem(_ bundleID: String) -> String {
        let safe = bundleID.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
        return safe.isEmpty ? "app" : safe
    }

    private static func nowSeconds() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    private static func isExpectedHelperProcess(pid: Int32, paths: IOSUsePaths) -> Bool {
        guard let command = processCommand(pid: pid) else { return false }
        return command.contains(helperCommandName)
            && command.contains("--home")
            && command.contains(paths.root)
    }

    private static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if let processAliveOverrideForTesting {
            return processAliveOverrideForTesting(pid)
        }
        return Darwin.kill(pid, 0) == 0
    }

    private static func processCommand(pid: Int32) -> String? {
        if let processCommandOverrideForTesting {
            return processCommandOverrideForTesting(pid)
        }
        return (try? Shell.run("ps", arguments: ["-p", String(pid), "-o", "command="]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func terminateProcess(pid: Int32, force: Bool) -> Bool {
        guard pid > 0 else { return true }
        _ = sendSignal(pid: pid, signal: SIGTERM)
        if waitForProcessExit(pid: pid, timeoutSeconds: 1.0) {
            return true
        }
        guard force else {
            return false
        }
        _ = sendSignal(pid: pid, signal: SIGKILL)
        return waitForProcessExit(pid: pid, timeoutSeconds: 1.0)
    }

    private static func waitForProcessExit(pid: Int32, timeoutSeconds: Double) -> Bool {
        if let processExitWaiterForTesting {
            return processExitWaiterForTesting(pid, timeoutSeconds)
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !processAlive(pid) {
                return true
            }
            usleep(100_000)
        }
        return !processAlive(pid)
    }

    private static func sendSignal(pid: Int32, signal: Int32) -> Int32 {
        if let signalSenderForTesting {
            return signalSenderForTesting(pid, signal)
        }
        return Darwin.kill(pid, signal)
    }
}

private struct HelperOptions {
    var deviceType: String
    var udid: String
    var bundleID: String
    var logFile: String
    var home: String?
}
