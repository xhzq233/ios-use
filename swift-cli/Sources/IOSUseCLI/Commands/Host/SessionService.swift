import Foundation

public enum SessionService {
    public struct Info: Equatable, Sendable {
        public let udid: String
        public let deviceName: String
        public let deviceVersion: String
        public let deviceType: String
        public let startedAt: Int
        public let holderPid: Int?
        public let runnerPid: Int?
        public let startMode: String?
        public let sessionIdentifier: String?
        public let bundleId: String?

        public init(
            udid: String,
            deviceName: String,
            deviceVersion: String,
            deviceType: String,
            startedAt: Int = Int(Date().timeIntervalSince1970 * 1000),
            holderPid: Int? = nil,
            runnerPid: Int? = nil,
            startMode: String? = nil,
            sessionIdentifier: String? = nil,
            bundleId: String? = nil
        ) {
            self.udid = udid
            self.deviceName = deviceName
            self.deviceVersion = deviceVersion
            self.deviceType = deviceType
            self.startedAt = startedAt
            self.holderPid = holderPid
            self.runnerPid = runnerPid
            self.startMode = startMode
            self.sessionIdentifier = sessionIdentifier
            self.bundleId = bundleId
        }

        func applying(_ metadata: DriverLifecycleService.LaunchMetadata) -> Info {
            Info(
                udid: udid,
                deviceName: deviceName,
                deviceVersion: deviceVersion,
                deviceType: deviceType,
                startedAt: startedAt,
                holderPid: metadata.holderPid,
                runnerPid: metadata.runnerPid,
                startMode: startMode,
                sessionIdentifier: metadata.sessionIdentifier,
                bundleId: metadata.bundleId ?? bundleId
            )
        }
    }

    static var simulatorDriverReachableForTesting: (() -> Bool)?
    static var simulatorDriverLauncherForTesting: ((String) throws -> Void)?
    static var simulatorDriverTerminatorForTesting: ((String) throws -> Bool)?
    static var realDriverTerminatorForTesting: ((String) throws -> Bool)?

    public static func clear(paths: IOSUsePaths) {
        DriverSessionStore.clear(paths: paths)
    }

    public static func readDriverLock(paths: IOSUsePaths) -> String? {
        DriverSessionStore.readDriverLock(paths: paths)
    }

    public static func readDriverLockInfo(paths: IOSUsePaths) throws -> Info? {
        try DriverSessionStore.readInfo(paths: paths)
    }

    public static func requireDriverLock(paths: IOSUsePaths) throws -> Info {
        try DriverSessionStore.requireInfo(paths: paths)
    }

    public static func resolveTargetUdid(
        explicitUdid: String?,
        paths: IOSUsePaths,
        missingMessage: String,
        fallbackUdid: (() throws -> String?)? = nil
    ) throws -> String {
        if let explicitUdid, !explicitUdid.isEmpty {
            return explicitUdid
        }
        if let current = read(paths: paths) {
            return current.udid
        }
        if let fallback = try fallbackUdid?(), !fallback.isEmpty {
            return fallback
        }
        throw CLIParseError.invalidValue(missingMessage)
    }

    public static func writeDriverLock(info: Info, paths: IOSUsePaths) throws {
        try DriverSessionStore.write(info: info, paths: paths)
    }

    public static func clearDriverLock(paths: IOSUsePaths) {
        DriverSessionStore.clearDriverLock(paths: paths)
    }

    public static func start(udid requestedUdid: String?, paths: IOSUsePaths, verbose: Bool) throws -> String {
        if let current = try readDriverLockInfo(paths: paths) {
            throw CLIParseError.invalidValue("Driver already started for \(current.udid). Run `ios-use stop` before starting another driver.")
        }
        let udid = try resolveStartUdid(requestedUdid, paths: paths)
        let info = try resolveDriverInfo(udid: udid, paths: paths)
        try writeDriverLock(info: info, paths: paths)
        var launchedInfo: Info?
        do {
            if let metadata = try launchDriver(for: info, paths: paths, verbose: verbose) {
                let updated = info.applying(metadata)
                launchedInfo = updated
                try writeDriverLock(info: updated, paths: paths)
            }
        } catch {
            if let launchedInfo {
                _ = try? DriverLifecycleService.terminateDriver(
                    for: launchedInfo,
                    paths: paths,
                    simulatorTerminator: simulatorDriverTerminatorForTesting,
                    realTerminator: realDriverTerminatorForTesting
                )
            }
            clearDriverLock(paths: paths)
            throw error
        }
        return "Driver started for \(udid)\n"
    }

    public static func stop(paths: IOSUsePaths) throws -> String {
        let current = try requireDriverLock(paths: paths)
        var output = try DriverLifecycleService.terminateDriver(
            for: current,
            paths: paths,
            simulatorTerminator: simulatorDriverTerminatorForTesting,
            realTerminator: realDriverTerminatorForTesting
        )
        do {
            try DriverSessionStore.removeDriverLock(paths: paths)
        } catch {
            throw CLIParseError.invalidValue("Driver stopped, but failed to remove \(paths.driverLock): \(error)")
        }
        output += "Driver stopped\n"
        return output
    }

    public static func read(paths: IOSUsePaths) -> Info? {
        try? readDriverLockInfo(paths: paths)
    }

    public static func resolveDriverInfo(udid: String, paths: IOSUsePaths) throws -> Info {
        try DriverLifecycleService.resolveDriverInfo(udid: udid, paths: paths)
    }

    private static func resolveStartUdid(_ requestedUdid: String?, paths: IOSUsePaths) throws -> String {
        if let requestedUdid, !requestedUdid.isEmpty {
            return requestedUdid
        }
        guard let device = try DeviceService.listDevices(simulatorOnly: false, paths: paths).first(where: { $0.kind == .real }) else {
            throw CLIParseError.invalidValue("No --udid and no USB real devices detected.")
        }
        return device.udid
    }

    static func launchDriver(for info: Info, paths: IOSUsePaths, verbose: Bool) throws -> DriverLifecycleService.LaunchMetadata? {
        try DriverLifecycleService.launchDriver(
            for: info,
            paths: paths,
            verbose: verbose,
            simulatorReachable: simulatorDriverReachableForTesting,
            simulatorLauncher: simulatorDriverLauncherForTesting
        )
    }
}
