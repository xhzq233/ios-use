import Darwin
import Foundation
import IOSUseProtocol

enum DriverLifecycleService {
    typealias CoreDeviceLifecycleFactory = (((String) -> Void)?) -> CoreDeviceDriverLifecycleManaging
    struct LaunchMetadata: Equatable {
        let holderPid: Int?
        let runnerPid: Int?
        let sessionIdentifier: String?
        let bundleId: String?
    }

    enum HolderTerminationResult: Equatable {
        case notApplicable
        case terminated
        case alreadyStopped
        case refused

        var cleanedHostState: Bool {
            self == .terminated || self == .alreadyStopped
        }
    }

    static var holderLauncherForTesting: ((String, String, IOSUsePaths, Bool) throws -> LaunchMetadata)?
    static var holderTerminatorForTesting: ((SessionService.Info, IOSUsePaths) -> HolderTerminationResult)?
    static var processAliveForTesting: ((Int32) -> Bool)?
    static var holderProcessValidatorForTesting: ((Int32, String) -> Bool)?

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
        realTerminator: ((String) throws -> Bool)?,
        coreDeviceFactory: CoreDeviceLifecycleFactory?
    ) throws -> String {
        if info.deviceType == "simulator" {
            let terminated = try SimulatorService.terminateDriver(udid: info.udid, terminator: simulatorTerminator)
            return terminated ? "Driver app terminated on simulator\n" : "Driver app was not running on simulator\n"
        }

        let terminated: Bool
        if let realTerminator {
            terminated = try realTerminator(info.udid)
        } else {
            do {
                terminated = try terminateRealDriverProcesses(udid: info.udid, paths: paths, coreDeviceFactory: coreDeviceFactory)
            } catch {
                let holderResult = terminateHolderProcessIfNeeded(info: info, paths: paths)
                if holderResult.cleanedHostState {
                    appendLifecycleLog(paths: paths, "CoreDevice terminate failed after holder cleanup: \(error)")
                    return "Driver holder stopped on host\nDevice cleanup skipped: \(error)\n"
                }
                throw error
            }
        }
        let holderResult = terminateHolderProcessIfNeeded(info: info, paths: paths)
        return (terminated || holderResult == .terminated) ? "Driver app terminated on device\n" : "Driver app was not running on device\n"
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
        let readyFile = "\(stateDir)/xctest-holder-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: readyFile)

        let logPath = "\(paths.logs)/driver-holder.log"
        _ = FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        _ = try? logHandle.seekToEnd()
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try currentExecutablePath())
        var arguments = [
            XCTestSessionHolderService.commandName,
            "--udid", udid,
            "--bundle-id", bundleId,
            "--ready-file", readyFile,
        ]
        if verbose {
            arguments.append("--verbose")
        }
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["IOS_USE_HOME": paths.root]) { _, new in new }
        process.standardOutput = logHandle
        process.standardError = logHandle
        appendLifecycleLog(paths: paths, "Starting XCTest holder process")
        try process.run()

        do {
            return try waitForHolderReadiness(
                process: process,
                readyFile: readyFile,
                udid: udid,
                bundleId: bundleId,
                paths: paths
            )
        } catch {
            terminateProcess(pid: process.processIdentifier, force: true)
            throw error
        }
    }

    private static func waitForHolderReadiness(
        process: Process,
        readyFile: String,
        udid: String,
        bundleId: String,
        paths: IOSUsePaths
    ) throws -> LaunchMetadata {
        let timeout = IOSUseProtocol.driverStartReadinessTimeoutSeconds + 30
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let readiness = readHolderReadiness(path: readyFile) {
                try? FileManager.default.removeItem(atPath: readyFile)
                if readiness.status == "ready" {
                    return LaunchMetadata(
                        holderPid: readiness.holderPid ?? Int(process.processIdentifier),
                        runnerPid: readiness.runnerPid,
                        sessionIdentifier: readiness.sessionIdentifier,
                        bundleId: bundleId
                    )
                }
                let message = readiness.error ?? "holder reported \(readiness.status)"
                throw CLIParseError.invalidValue(message)
            }
            if !process.isRunning {
                let status = process.terminationStatus
                throw CLIParseError.invalidValue("XCTest holder exited before readiness with status \(status). Check \(paths.logs)/driver-holder.log")
            }
            usleep(100_000)
        }
        throw CLIParseError.invalidValue("Timed out waiting for XCTest holder readiness. Check \(paths.logs)/driver-holder.log")
    }

    private static func readHolderReadiness(path: String) -> XCTestSessionHolderReadiness? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(XCTestSessionHolderReadiness.self, from: data)
    }

    private static func terminateRealDriverProcesses(
        udid: String,
        paths: IOSUsePaths,
        coreDeviceFactory: CoreDeviceLifecycleFactory?
    ) throws -> Bool {
        do {
            let bundleID = ConfigService.listEntries(paths: paths).first(where: { $0.udid == udid })?.bundleId
            appendLifecycleLog(paths: paths, "Terminating driver through CoreDevice appservice")
            let terminated = try makeCoreDeviceDriverLifecycle(factory: coreDeviceFactory, eventSink: { event in
                appendCoreDeviceLog(paths: paths, event)
            }).terminateDriver(udid: udid, bundleID: bundleID)
            appendLifecycleLog(paths: paths, "CoreDevice appservice terminate completed terminated=\(terminated)")
            return terminated
        } catch {
            appendLifecycleLog(paths: paths, "CoreDevice appservice terminate failed: \(error)")
            throw CLIParseError.invalidValue("Native real-device terminate failed. CoreDevice: \(error)")
        }
    }

    static func terminateFullXCTestHolderIfNeeded(info: SessionService.Info, paths: IOSUsePaths) -> HolderTerminationResult {
        terminateHolderProcessIfNeeded(info: info, paths: paths)
    }

    private static func terminateHolderProcessIfNeeded(info: SessionService.Info, paths: IOSUsePaths) -> HolderTerminationResult {
        if let holderTerminatorForTesting {
            return holderTerminatorForTesting(info, paths)
        }
        guard info.deviceType == "real", let holderPid = info.holderPid, holderPid > 0 else {
            return .notApplicable
        }
        let pid = Int32(holderPid)
        guard processAlive(pid: pid) else {
            appendLifecycleLog(paths: paths, "XCTest holder pid=\(holderPid) was not running")
            return .alreadyStopped
        }
        guard isExpectedHolderProcess(pid: pid, udid: info.udid) else {
            appendLifecycleLog(paths: paths, "Refusing to terminate pid=\(holderPid); command does not match XCTest holder for \(info.udid)")
            return .refused
        }
        appendLifecycleLog(paths: paths, "Terminating XCTest holder pid=\(holderPid)")
        terminateProcess(pid: pid, force: true)
        return .terminated
    }

    private static func appendLifecycleLog(paths: IOSUsePaths, _ message: String) {
        CLILogService.append(paths: paths, ["[cli-lifecycle] \(message)"])
    }

    private static func appendCoreDeviceLog(paths: IOSUsePaths, _ event: String) {
        CLILogService.appendCoreDevice(paths: paths, ["[CoreDevice] \(event)"])
        guard shouldMirrorCoreDeviceEventToCLILog(event) else { return }
        appendLifecycleLog(paths: paths, "[CoreDevice] \(event)")
    }

    private static func shouldMirrorCoreDeviceEventToCLILog(_ event: String) -> Bool {
        if event.hasPrefix("TCP ") ||
            event.hasPrefix("RemoteXPC ") ||
            event.hasPrefix("RSD services:") {
            return false
        }
        return true
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

    private static func terminateProcess(pid: Int32, force: Bool) {
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !processAlive(pid: pid) {
                return
            }
            usleep(100_000)
        }
        if force, processAlive(pid: pid) {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    static func isExpectedHolderProcess(pid: Int32, udid: String) -> Bool {
        if let holderProcessValidatorForTesting {
            return holderProcessValidatorForTesting(pid, udid)
        }
        guard let command = processCommand(pid: pid) else {
            return false
        }
        return command.contains(XCTestSessionHolderService.commandName)
            && command.contains("--udid")
            && command.contains(udid)
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

    private static func makeCoreDeviceDriverLifecycle(
        factory: CoreDeviceLifecycleFactory?,
        eventSink: ((String) -> Void)?
    ) -> CoreDeviceDriverLifecycleManaging {
        if let factory {
            return factory(eventSink)
        }
        return CoreDeviceDriverLifecycle(eventSink: eventSink)
    }
}
