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
        public let controlSocketPath: String?
        public let playCoverAppPath: String?
        public let playCoverExecutablePath: String?
        public let playCoverGenerationKey: String?
        public let playCoverRuntimeSocketPath: String?

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
            bundleId: String? = nil,
            controlSocketPath: String? = nil,
            playCoverAppPath: String? = nil,
            playCoverExecutablePath: String? = nil,
            playCoverGenerationKey: String? = nil,
            playCoverRuntimeSocketPath: String? = nil
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
            self.controlSocketPath = controlSocketPath
            self.playCoverAppPath = playCoverAppPath
            self.playCoverExecutablePath = playCoverExecutablePath
            self.playCoverGenerationKey = playCoverGenerationKey
            self.playCoverRuntimeSocketPath = playCoverRuntimeSocketPath
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
                bundleId: metadata.bundleId ?? bundleId,
                controlSocketPath: metadata.controlSocketPath ?? controlSocketPath,
                playCoverAppPath: playCoverAppPath,
                playCoverExecutablePath: playCoverExecutablePath,
                playCoverGenerationKey: playCoverGenerationKey,
                playCoverRuntimeSocketPath: playCoverRuntimeSocketPath
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
        try prepareForStart(paths: paths)
        let udid = try resolveStartUdid(requestedUdid, paths: paths)
        let info = try resolveDriverInfo(udid: udid, paths: paths)
        let signingWarning = ConfigService.startSigningWarning(udid: udid, paths: paths)
        var launchedInfo: Info?
        do {
            let updated: Info
            if let metadata = try launchDriver(for: info, paths: paths, verbose: verbose) {
                updated = info.applying(metadata)
                launchedInfo = updated
                if info.deviceType == "real", isIncompleteRealDriverLock(updated) {
                    throw CLIParseError.invalidValue("Native real-device launch did not return complete XCTest holder metadata.")
                }
            } else {
                updated = info
                launchedInfo = updated
            }
            try writeDriverLock(info: updated, paths: paths)
        } catch {
            if let launchedInfo {
                do {
                    _ = try DriverLifecycleService.terminateDriver(
                        for: launchedInfo,
                        paths: paths,
                        simulatorTerminator: simulatorDriverTerminatorForTesting,
                        realTerminator: realDriverTerminatorForTesting
                    )
                    clearDriverLock(paths: paths)
                } catch let cleanupError {
                    try? writeDriverLock(info: launchedInfo, paths: paths)
                    throw CLIParseError.invalidValue("Driver start failed after holder launch, and cleanup failed: \(cleanupError). The active driver lock was preserved when possible. Original error: \(error)")
                }
            } else {
                clearDriverLock(paths: paths)
            }
            throw errorWithSigningWarning(signingWarning, error: error)
        }
        return (signingWarning ?? "") + "Driver started for \(udid)\n"
    }

    public static func startPlayCover(
        appPath: String?,
        timeout: Double,
        paths: IOSUsePaths
    ) throws -> String {
        try prepareForStart(paths: paths)
        var launch: PlayCoverSessionService.LaunchResult?
        do {
            let result = try PlayCoverSessionService.launch(
                explicitAppPath: appPath,
                timeout: timeout,
                paths: paths
            )
            launch = result
            try writeDriverLock(
                info: PlayCoverSessionService.makeSessionInfo(from: result),
                paths: paths
            )
            let cacheDisposition = result.reused ? "reused" : "prepared"
            return """
            PlayCover session started for \(result.bundleIdentifier) (pid \(result.pid))
            PlayCover generation \(cacheDisposition): \(result.generationKey)
            IOS_USE_HOME: \(paths.root)

            """
        } catch let error as
                PlayCoverSessionUnterminatedLaunchError {
            do {
                try writeDriverLock(
                    info: PlayCoverSessionService.makeSessionInfo(
                        from: error.result
                    ),
                    paths: paths
                )
            } catch let lockError {
                do {
                    _ = try PlayCoverSessionService.terminate(
                        result: error.result
                    )
                    clearDriverLock(paths: paths)
                } catch let finalCleanupError {
                    throw CLIParseError.invalidValue(
                        "\(error). Preserving the active session "
                            + "lock also failed: \(lockError). "
                            + "Final cleanup failed: "
                            + "\(finalCleanupError)"
                    )
                }
                throw CLIParseError.invalidValue(
                    "\(error). The App was stopped because its "
                        + "active session lock could not be written: "
                        + "\(lockError)"
                )
            }
            throw error
        } catch {
            if let launch {
                do {
                    _ = try PlayCoverSessionService.terminate(result: launch)
                } catch let cleanupError {
                    throw CLIParseError.invalidValue(
                        "PlayCover start failed after launch, and cleanup failed: \(cleanupError). Original error: \(error)"
                    )
                }
            }
            clearDriverLock(paths: paths)
            throw error
        }
    }

    private static func prepareForStart(paths: IOSUsePaths) throws {
        if let current = try readDriverLockInfo(paths: paths) {
            if isIncompleteRealDriverLock(current) {
                try cleanupIncompleteRealDriverLock(current, paths: paths)
            } else {
                throw CLIParseError.invalidValue("Driver already started for \(current.udid). Run `ios-use stop` before starting another driver.")
            }
        }
    }

    private static func errorWithSigningWarning(_ warning: String?, error: Error) -> Error {
        guard let warning, !warning.isEmpty else {
            return error
        }
        return CLIParseError.invalidValue("\(warning.trimmingCharacters(in: .whitespacesAndNewlines))\n\(error)")
    }

    static func isIncompleteRealDriverLock(_ info: Info) -> Bool {
        guard info.deviceType == "real" else { return false }
        return info.holderPid == nil
            || info.runnerPid == nil
            || info.sessionIdentifier == nil
            || info.bundleId == nil
            || info.controlSocketPath == nil
            || info.controlSocketPath?.isEmpty == true
    }

    private static func cleanupIncompleteRealDriverLock(_ info: Info, paths: IOSUsePaths) throws {
        do {
            _ = try DriverLifecycleService.terminateDriver(
                for: info,
                paths: paths,
                simulatorTerminator: simulatorDriverTerminatorForTesting,
                realTerminator: realDriverTerminatorForTesting
            )
            DriverSessionStore.clearDriverLock(paths: paths)
        } catch {
            throw CLIParseError.invalidValue("Existing driver.lock is incomplete, but cleanup failed: \(error). Run `ios-use stop` or remove the stale lock after verifying no holder process is running.")
        }
    }

    public static func stop(paths: IOSUsePaths) throws -> String {
        let current = try requireDriverLock(paths: paths)
        if current.deviceType == PlayCoverSessionService.deviceType {
            let pid = try PlayCoverSessionService.terminate(session: current)
            do {
                try DriverSessionStore.removeDriverLock(paths: paths)
            } catch {
                throw CLIParseError.invalidValue(
                    "PlayCover App stopped, but failed to remove \(paths.driverLock): \(error)"
                )
            }
            return "PlayCover App stopped (pid \(pid))\nPlayCover session stopped\n"
        }
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
