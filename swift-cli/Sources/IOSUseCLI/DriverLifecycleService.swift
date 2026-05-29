import Darwin
import Foundation
import IOSUseProtocol

enum DriverLifecycleService {
    typealias CoreDeviceLifecycleFactory = (((String) -> Void)?) -> CoreDeviceDriverLifecycleManaging

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
        simulatorLauncher: ((String) throws -> Void)?,
        realReachable: ((String) -> Bool)?,
        realLauncher: ((String, String) throws -> Void)?,
        coreDeviceFactory: CoreDeviceLifecycleFactory?
    ) throws {
        try ConfigService.assertDriverInstallCurrent(udid: info.udid, paths: paths)
        switch info.deviceType {
        case "simulator":
            try SimulatorService.ensureDriverRunning(
                udid: info.udid,
                allowExistingDriver: false,
                isReachable: simulatorReachable,
                launcher: simulatorLauncher
            )
        case "real":
            try ensureRealDriverRunning(
                udid: info.udid,
                paths: paths,
                verbose: verbose,
                isReachableOverride: realReachable,
                launcherOverride: realLauncher,
                coreDeviceFactory: coreDeviceFactory
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
            terminated = try terminateRealDriverProcesses(udid: info.udid, paths: paths, coreDeviceFactory: coreDeviceFactory)
        }
        return terminated ? "Driver app terminated on device\n" : "Driver app was not running on device\n"
    }

    private static func ensureRealDriverRunning(
        udid: String,
        paths: IOSUsePaths,
        verbose: Bool,
        isReachableOverride: ((String) -> Bool)?,
        launcherOverride: ((String, String) throws -> Void)?,
        coreDeviceFactory: CoreDeviceLifecycleFactory?
    ) throws {
        let isReachable = isReachableOverride ?? { targetUdid in
            isDriverPortReachable(udid: targetUdid)
        }
        guard let bundleId = ConfigService.listEntries(paths: paths).first(where: { $0.udid == udid })?.bundleId,
              !bundleId.isEmpty,
              bundleId != "(missing)" else {
            throw CLIParseError.invalidValue("No driver bundle ID found for device \(udid). Run `ios-use config --udid \(udid)` first.")
        }

        if let launcherOverride {
            try launcherOverride(udid, bundleId)
            let deadline = Date().addingTimeInterval(IOSUseProtocol.driverStartReadinessTimeoutSeconds)
            while Date() < deadline {
                if isReachable(udid) {
                    return
                }
                usleep(useconds_t(IOSUseProtocol.driverStartReadinessPollIntervalMicroseconds))
            }
            throw CLIParseError.invalidValue("Driver launched but port \(IOSUseProtocol.defaultDriverPort) did not become reachable on device \(udid). Check \(driverLogPath(paths: paths))")
        }

        try launchRealDriverDetached(
            udid: udid,
            bundleId: bundleId,
            paths: paths,
            verbose: verbose,
            coreDeviceFactory: coreDeviceFactory
        )
    }

    private static func launchRealDriverDetached(
        udid: String,
        bundleId: String,
        paths: IOSUsePaths,
        verbose: Bool,
        coreDeviceFactory: CoreDeviceLifecycleFactory?
    ) throws {
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true, attributes: nil)
        let logPath = driverLogPath(paths: paths)
        rotateDriverLogIfNeeded(logPath)
        let separator = "\n--- session start \(ISO8601DateFormatter().string(from: Date())) ---\n"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            _ = try? handle.seekToEnd()
            if let data = separator.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            try? handle.close()
        }

        if verbose {
            FileHandle.standardError.write(Data("Driver console log: \(logPath)\n".utf8))
        }
        do {
            appendDriverLog(paths: paths, "Launching driver through CoreDevice appservice\n")
            try makeCoreDeviceDriverLifecycle(factory: coreDeviceFactory, eventSink: { event in
                appendDriverLog(paths: paths, "[CoreDevice] \(event)\n")
            }).launchDriver(udid: udid, bundleID: bundleId, timeoutSeconds: IOSUseProtocol.driverStartReadinessTimeoutSeconds)
            appendDriverLog(paths: paths, "CoreDevice appservice launch completed\n")
        } catch {
            appendDriverLog(paths: paths, "CoreDevice appservice launch failed: \(error)\n")
            throw CLIParseError.invalidValue("Native real-device launch failed. CoreDevice: \(error)")
        }
    }

    private static func terminateRealDriverProcesses(
        udid: String,
        paths: IOSUsePaths,
        coreDeviceFactory: CoreDeviceLifecycleFactory?
    ) throws -> Bool {
        do {
            let bundleID = ConfigService.listEntries(paths: paths).first(where: { $0.udid == udid })?.bundleId
            appendDriverLog(paths: paths, "Terminating driver through CoreDevice appservice\n")
            let terminated = try makeCoreDeviceDriverLifecycle(factory: coreDeviceFactory, eventSink: { event in
                appendDriverLog(paths: paths, "[CoreDevice] \(event)\n")
            }).terminateDriver(udid: udid, bundleID: bundleID)
            appendDriverLog(paths: paths, "CoreDevice appservice terminate completed terminated=\(terminated)\n")
            return terminated
        } catch {
            appendDriverLog(paths: paths, "CoreDevice appservice terminate failed: \(error)\n")
            throw CLIParseError.invalidValue("Native real-device terminate failed. CoreDevice: \(error)")
        }
    }

    private static func isDriverPortReachable(udid: String) -> Bool {
        guard let fd = try? Usbmux.connect(udid: udid, port: Int(IOSUseProtocol.defaultDriverPort)) else {
            return false
        }
        usleep(useconds_t(IOSUseProtocol.driverStartReadinessProbeHoldMicroseconds))
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        return true
    }

    private static func driverLogPath(paths: IOSUsePaths) -> String {
        "\(paths.logs)/driver.log"
    }

    private static func rotateDriverLogIfNeeded(_ logPath: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 2 * 1024 * 1024 else {
            return
        }
        try? FileManager.default.removeItem(atPath: "\(logPath).1")
        try? FileManager.default.moveItem(atPath: logPath, toPath: "\(logPath).1")
    }

    private static func appendDriverLog(paths: IOSUsePaths, _ message: String) {
        let logPath = driverLogPath(paths: paths)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(message.utf8))
            try? handle.close()
        }
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
