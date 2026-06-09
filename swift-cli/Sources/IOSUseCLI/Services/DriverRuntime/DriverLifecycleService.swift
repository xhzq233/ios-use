import Darwin
import Foundation
import IOSUseProtocol

enum DriverLifecycleService {
    struct LaunchMetadata: Equatable {
        let holderPid: Int?
        let runnerPid: Int?
        let sessionIdentifier: String?
        let bundleId: String?
        var controlSocketPath: String? = nil
    }

    enum HolderTerminationResult: Equatable {
        case notApplicable
        case terminated
        case alreadyStopped
        case refused
        case failed

    }

    static var holderLauncherForTesting: ((String, String, IOSUsePaths, Bool) throws -> LaunchMetadata)?
    static var holderTerminatorForTesting: ((SessionService.Info, IOSUsePaths) -> HolderTerminationResult)?
    static var processAliveForTesting: ((Int32) -> Bool)?
    static var holderProcessValidatorForTesting: ((Int32, String) -> Bool)?
    static var signalSenderForTesting: ((Int32, Int32) -> Int32)?
    static var processExitWaiterForTesting: ((Int32, Double) -> Bool)?

    static func resolveDriverInfo(udid: String, paths: IOSUsePaths) throws -> SessionService.Info {
        guard let configEntry = ConfigService.listEntries(paths: paths).first(where: { $0.udid == udid }) else {
            throw CLIParseError.invalidValue("No signing config found for device \(udid). Run `ios-use config --udid \(udid)` first.")
        }
        try ConfigService.assertDriverInstallCurrent(udid: udid, paths: paths)
        if configEntry.bundleId == ConfigService.simulatorBundleId {
            guard let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).first(where: { $0.udid == udid }) else {
                throw CLIParseError.invalidValue("Device \(udid) not found.")
            }
            return SessionService.Info(
                udid: udid,
                deviceName: simulator.name,
                deviceVersion: simulator.version,
                deviceType: "simulator"
            )
        }
        if try DeviceService.isUsbDeviceConnected(udid: udid) {
            let device = try DeviceService.listDevices(simulatorOnly: false, paths: paths).first { $0.udid == udid }
            return SessionService.Info(
                udid: udid,
                deviceName: device?.name ?? "Unknown",
                deviceVersion: device?.version ?? "",
                deviceType: "real"
            )
        }
        if let device = try DeviceService.listDevices(simulatorOnly: false, paths: paths).first(where: { $0.udid == udid }) {
            return SessionService.Info(
                udid: udid,
                deviceName: device.name,
                deviceVersion: device.version,
                deviceType: "real"
            )
        }
        throw CLIParseError.invalidValue("Device \(udid) not found.")
    }

    static func launchDriver(
        for info: SessionService.Info,
        paths: IOSUsePaths,
        verbose: Bool,
        simulatorReachable: (() -> Bool)?,
        simulatorLauncher: ((String) throws -> Void)?
    ) throws -> LaunchMetadata? {
        try ConfigService.assertDriverInstallCurrent(udid: info.udid, paths: paths)
        switch info.deviceType {
        case "simulator":
            if simulatorLauncher == nil {
                return try SimulatorService.launchDriverWithXcodebuild(
                    udid: info.udid,
                    paths: paths,
                    verbose: verbose,
                    isReachable: simulatorReachable
                )
            }
            try SimulatorService.ensureDriverRunning(
                udid: info.udid,
                allowExistingDriver: false,
                isReachable: simulatorReachable,
                launcher: simulatorLauncher
            )
            return nil
        case "real":
            return try ensureRealDriverRunning(
                udid: info.udid,
                paths: paths,
                verbose: verbose
            )
        default:
            throw CLIParseError.invalidValue("Invalid driver.lock: unknown deviceType \(info.deviceType).")
        }
    }

    static func terminateDriver(
        for info: SessionService.Info,
        paths: IOSUsePaths,
        simulatorTerminator: ((String) throws -> Bool)?,
        realTerminator: ((String) throws -> Bool)?
    ) throws -> String {
        if info.deviceType == "simulator" {
            let holderResult = terminateHolderProcessIfNeeded(info: info, paths: paths, allowedDeviceTypes: ["simulator"])
            let terminated = try SimulatorService.terminateDriver(udid: info.udid, terminator: simulatorTerminator)
            SimulatorService.cleanupXcodebuildLaunchArtifacts(udid: info.udid, paths: paths)
            if let failure = holderTerminationFailureMessage(result: holderResult, info: info) {
                throw CLIParseError.invalidValue(failure)
            }
            return (terminated || holderResult == .terminated) ? "Driver app terminated on simulator\n" : "Driver app was not running on simulator\n"
        }

        if let realTerminator {
            let terminated = try realTerminator(info.udid)
            let holderResult = terminateHolderProcessIfNeeded(info: info, paths: paths)
            if let failure = holderTerminationFailureMessage(result: holderResult, info: info) {
                throw CLIParseError.invalidValue(failure)
            }
            return (terminated || holderResult == .terminated) ? "Driver app terminated on device\n" : "Driver app was not running on device\n"
        }

        let holderResult = terminateHolderProcessIfNeeded(info: info, paths: paths)
        switch holderResult {
        case .terminated:
            return "Driver app terminated on device\n"
        case .alreadyStopped:
            return "Driver app was not running on device\n"
        case .notApplicable:
            appendLifecycleLog(paths: paths, "No XCTest holder pid recorded; skipping device-side terminate")
            return "Driver app was not running on device\n"
        case .refused:
            throw CLIParseError.invalidValue(holderTerminationFailureMessage(result: holderResult, info: info) ?? "Refused to stop XCTest holder.")
        case .failed:
            throw CLIParseError.invalidValue(holderTerminationFailureMessage(result: holderResult, info: info) ?? "Failed to stop XCTest holder.")
        }
    }

    private static func ensureRealDriverRunning(
        udid: String,
        paths: IOSUsePaths,
        verbose: Bool
    ) throws -> LaunchMetadata? {
        guard let bundleId = ConfigService.listEntries(paths: paths).first(where: { $0.udid == udid })?.bundleId,
              !bundleId.isEmpty,
              bundleId != "(missing)" else {
            throw CLIParseError.invalidValue("No driver bundle ID found for device \(udid). Run `ios-use config --udid \(udid)` first.")
        }

        return try launchRealDriverDetached(
            udid: udid,
            bundleId: bundleId,
            paths: paths,
            verbose: verbose
        )
    }

    private static func launchRealDriverDetached(
        udid: String,
        bundleId: String,
        paths: IOSUsePaths,
        verbose: Bool
    ) throws -> LaunchMetadata? {
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true, attributes: nil)

        if verbose {
            FileHandle.standardError.write(Data("CLI log: \(CLILogService.logPath(paths: paths))\n".utf8))
        }
        do {
            if let holderLauncherForTesting {
                return try holderLauncherForTesting(udid, bundleId, paths, verbose)
            }
            appendLifecycleLog(paths: paths, "Launching driver through native XCTest lifecycle")
            let metadata = try launchRealDriverHolder(udid: udid, bundleId: bundleId, paths: paths, verbose: verbose)
            appendLifecycleLog(paths: paths, "Native XCTest holder launch completed holderPid=\(metadata.holderPid ?? -1) runnerPid=\(metadata.runnerPid ?? -1)")
            return metadata
        } catch {
            appendLifecycleLog(paths: paths, "Native XCTest launch failed: \(error)")
            throw CLIParseError.invalidValue("Native real-device launch failed. XCTest: \(error)")
        }
    }

    private static func launchRealDriverHolder(
        udid: String,
        bundleId: String,
        paths: IOSUsePaths,
        verbose: Bool
    ) throws -> LaunchMetadata {
        let stateDir = URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true, attributes: nil)
        let controlSocket = "\(stateDir)/xctest-holder-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: controlSocket)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try currentExecutablePath())
        var arguments = [
            XCTestSessionHolderService.commandName,
            "--udid", udid,
            "--bundle-id", bundleId,
            "--control-socket", controlSocket,
        ]
        if verbose {
            arguments.append("--verbose")
        }
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["IOS_USE_HOME": paths.root]) { _, new in new }
        let holderLogPath = CLILogService.holderLogPath(paths: paths)
        if !FileManager.default.fileExists(atPath: holderLogPath) {
            FileManager.default.createFile(atPath: holderLogPath, contents: nil)
        }
        let holderLogHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: holderLogPath))
        _ = try? holderLogHandle.seekToEnd()
        defer { try? holderLogHandle.close() }
        process.standardOutput = holderLogHandle
        process.standardError = holderLogHandle
        appendLifecycleLog(paths: paths, "Starting XCTest holder process")
        try process.run()

        do {
            return try waitForHolderStartResult(
                process: process,
                controlSocket: controlSocket,
                udid: udid,
                bundleId: bundleId,
                paths: paths
            )
        } catch {
            if !terminateProcess(pid: process.processIdentifier, force: true) {
                appendLifecycleLog(paths: paths, "XCTest holder pid=\(process.processIdentifier) did not exit after failed launch cleanup")
            }
            throw error
        }
    }

    private static func waitForHolderStartResult(
        process: Process,
        controlSocket: String,
        udid: String,
        bundleId: String,
        paths: IOSUsePaths
    ) throws -> LaunchMetadata {
        let timeout = IOSUseProtocol.XCConstants.xctestHolderStartResultTimeoutSeconds
        let deadline = Date().addingTimeInterval(timeout)
        var lastSocketError: Error?
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: controlSocket) {
                do {
                    let response = try XCTestSessionHolderControlClient.request(
                        socketPath: controlSocket,
                        command: "startStatus",
                        timeoutSeconds: max(1, deadline.timeIntervalSinceNow)
                    )
                    if response.status == "ready" {
                        return LaunchMetadata(
                            holderPid: response.holderPid ?? Int(process.processIdentifier),
                            runnerPid: response.runnerPid,
                            sessionIdentifier: response.sessionIdentifier,
                            bundleId: bundleId,
                            controlSocketPath: response.controlSocketPath ?? controlSocket
                        )
                    }
                    let message = response.error ?? "holder reported \(response.status)"
                    throw CLIParseError.invalidValue(message)
                } catch {
                    lastSocketError = error
                    if !process.isRunning {
                        let status = process.terminationStatus
                        throw CLIParseError.invalidValue("XCTest holder exited before start result with status \(status). Check \(CLILogService.holderLogPath(paths: paths)). Last socket error: \(error)")
                    }
                }
            }
            if !process.isRunning {
                let status = process.terminationStatus
                if let lastSocketError {
                    throw CLIParseError.invalidValue("XCTest holder exited before start result with status \(status). Check \(CLILogService.holderLogPath(paths: paths)). Last socket error: \(lastSocketError)")
                }
                throw CLIParseError.invalidValue("XCTest holder exited before start result with status \(status). Check \(CLILogService.holderLogPath(paths: paths))")
            }
            usleep(useconds_t(IOSUseProtocol.XCConstants.xctestHolderStartPollMicroseconds))
        }
        if let lastSocketError {
            throw CLIParseError.invalidValue("Timed out waiting for XCTest holder start result. Check \(CLILogService.holderLogPath(paths: paths)). Last socket error: \(lastSocketError)")
        }
        throw CLIParseError.invalidValue("Timed out waiting for XCTest holder start result. Check \(CLILogService.holderLogPath(paths: paths))")
    }

    private static func stopHolderThroughControlSocketIfPossible(info: SessionService.Info, paths: IOSUsePaths) -> HolderTerminationResult? {
        guard let socketPath = info.controlSocketPath, !socketPath.isEmpty else {
            return nil
        }
        do {
            let response = try XCTestSessionHolderControlClient.request(
                socketPath: socketPath,
                command: "stop",
                timeoutSeconds: IOSUseProtocol.XCConstants.xctestHolderStopRequestTimeoutSeconds
            )
            appendLifecycleLog(paths: paths, "Requested XCTest holder stop through control socket status=\(response.status)")
            if let holderPid = info.holderPid {
                return waitForProcessExit(pid: Int32(holderPid), timeoutSeconds: IOSUseProtocol.XCConstants.xctestHolderStopWaitTimeoutSeconds) ? .terminated : .failed
            }
            return .terminated
        } catch {
            appendLifecycleLog(paths: paths, "XCTest holder control socket stop failed; falling back to signal: \(error)")
            return nil
        }
    }

    static func terminateFullXCTestHolderIfNeeded(info: SessionService.Info, paths: IOSUsePaths) -> HolderTerminationResult {
        terminateHolderProcessIfNeeded(info: info, paths: paths, allowedDeviceTypes: ["real"])
    }

    private static func terminateHolderProcessIfNeeded(
        info: SessionService.Info,
        paths: IOSUsePaths,
        allowedDeviceTypes: Set<String> = ["real"]
    ) -> HolderTerminationResult {
        guard allowedDeviceTypes.contains(info.deviceType) else {
            return .notApplicable
        }
        if let holderTerminatorForTesting {
            return holderTerminatorForTesting(info, paths)
        }
        guard let holderPid = info.holderPid, holderPid > 0 else {
            if let socketPath = info.controlSocketPath, !socketPath.isEmpty {
                return stopHolderThroughControlSocketIfPossible(info: info, paths: paths) ?? .failed
            }
            return .notApplicable
        }
        let pid = Int32(holderPid)
        guard processAlive(pid: pid) else {
            appendLifecycleLog(paths: paths, "XCTest holder pid=\(holderPid) was not running")
            return .alreadyStopped
        }
        if let socketResult = stopHolderThroughControlSocketIfPossible(info: info, paths: paths) {
            return socketResult
        }
        guard isExpectedHolderProcess(pid: pid, udid: info.udid, deviceType: info.deviceType) else {
            appendLifecycleLog(paths: paths, "Refusing to terminate pid=\(holderPid); command does not match XCTest holder for \(info.udid)")
            return .refused
        }
        appendLifecycleLog(paths: paths, "Terminating XCTest holder pid=\(holderPid)")
        guard terminateProcess(pid: pid, force: true) else {
            appendLifecycleLog(paths: paths, "XCTest holder pid=\(holderPid) did not exit after SIGTERM/SIGKILL")
            return .failed
        }
        return .terminated
    }

    static func holderTerminationFailureMessage(result: HolderTerminationResult, info: SessionService.Info) -> String? {
        switch result {
        case .refused:
            return "Refused to stop XCTest holder because driver.lock points at an unexpected host process."
        case .failed:
            let pid = info.holderPid.map(String.init) ?? "(missing)"
            return "Failed to stop XCTest holder pid=\(pid); driver.lock was left in place for manual cleanup."
        case .notApplicable, .terminated, .alreadyStopped:
            return nil
        }
    }

    private static func appendLifecycleLog(paths: IOSUsePaths, _ message: String) {
        CLILogService.append(paths: paths, ["[cli-lifecycle] \(message)"])
    }

    private static func currentExecutablePath() throws -> String {
        if let path = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let arg0 = ProcessInfo.processInfo.arguments.first, !arg0.isEmpty else {
            throw CLIParseError.invalidValue("Unable to resolve current ios-use executable path")
        }
        if arg0.hasPrefix("/") {
            return arg0
        }
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(arg0)
            .standardized
            .path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIParseError.invalidValue("Unable to resolve current ios-use executable path from \(arg0)")
        }
        return path
    }

    static func processAlive(pid: Int32) -> Bool {
        if let processAliveForTesting {
            return processAliveForTesting(pid)
        }
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0
    }

    @discardableResult
    private static func terminateProcess(pid: Int32, force: Bool) -> Bool {
        guard pid > 0 else { return true }
        _ = sendSignal(pid: pid, signal: SIGTERM)
        if waitForProcessExit(pid: pid, timeoutSeconds: IOSUseProtocol.XCConstants.xctestProcessTerminateWaitSeconds) {
            return true
        }
        guard force else {
            return false
        }
        _ = sendSignal(pid: pid, signal: SIGKILL)
        return waitForProcessExit(pid: pid, timeoutSeconds: IOSUseProtocol.XCConstants.xctestProcessKillWaitSeconds)
    }

    private static func waitForProcessExit(pid: Int32, timeoutSeconds: Double) -> Bool {
        if let processExitWaiterForTesting {
            return processExitWaiterForTesting(pid, timeoutSeconds)
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !processAlive(pid: pid) {
                return true
            }
            usleep(useconds_t(IOSUseProtocol.XCConstants.xctestProcessExitPollMicroseconds))
        }
        return !processAlive(pid: pid)
    }

    private static func sendSignal(pid: Int32, signal: Int32) -> Int32 {
        if let signalSenderForTesting {
            return signalSenderForTesting(pid, signal)
        }
        return Darwin.kill(pid, signal)
    }

    static func isExpectedHolderProcess(pid: Int32, udid: String) -> Bool {
        isExpectedHolderProcess(pid: pid, udid: udid, deviceType: "real")
    }

    private static func isExpectedHolderProcess(pid: Int32, udid: String, deviceType: String) -> Bool {
        if let holderProcessValidatorForTesting {
            return holderProcessValidatorForTesting(pid, udid)
        }
        guard let command = processCommand(pid: pid) else {
            return false
        }
        switch deviceType {
        case "real":
            return command.contains(XCTestSessionHolderService.commandName)
                && command.contains("--udid")
                && command.contains(udid)
        case "simulator":
            return command.contains("xcodebuild")
                && command.contains("test-without-building")
                && command.contains("platform=iOS Simulator,id=\(udid)")
        default:
            return false
        }
    }

    private static func processCommand(pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ps", "-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
