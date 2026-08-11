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
        public let macAppPath: String?
        public let macExecutablePath: String?
        public let macInstallRevision: String?
        public let macRuntimeSocketPath: String?
        public let macLogPath: String?

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
            macAppPath: String? = nil,
            macExecutablePath: String? = nil,
            macInstallRevision: String? = nil,
            macRuntimeSocketPath: String? = nil,
            macLogPath: String? = nil
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
            self.macAppPath = macAppPath
            self.macExecutablePath = macExecutablePath
            self.macInstallRevision = macInstallRevision
            self.macRuntimeSocketPath = macRuntimeSocketPath
            self.macLogPath = macLogPath
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
                macAppPath: macAppPath,
                macExecutablePath: macExecutablePath,
                macInstallRevision: macInstallRevision,
                macRuntimeSocketPath: macRuntimeSocketPath,
                macLogPath: macLogPath
            )
        }
    }

    static var simulatorDriverReachableForTesting: (() -> Bool)?
    static var simulatorDriverLauncherForTesting: ((String) throws -> Void)?
    static var simulatorDriverTerminatorForTesting: ((String) throws -> Bool)?
    static var realDriverTerminatorForTesting: ((String) throws -> Bool)?
    static var readDriverLockObserverForTesting: (() -> Void)?

    public static func clear(paths: IOSUsePaths) {
        DriverSessionStore.clear(paths: paths)
    }

    public static func readDriverLock(paths: IOSUsePaths) -> String? {
        DriverSessionStore.readDriverLock(paths: paths)
    }

    public static func readDriverLockInfo(paths: IOSUsePaths) throws -> Info? {
        readDriverLockObserverForTesting?()
        return try DriverSessionStore.readInfo(paths: paths)
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
        try SessionOperationLock.withExclusiveLock(paths: paths) {
            try startLocked(
                udid: requestedUdid,
                paths: paths,
                verbose: verbose
            )
        }
    }

    private static func startLocked(
        udid requestedUdid: String?,
        paths: IOSUsePaths,
        verbose: Bool
    ) throws -> String {
        try prepareForDriverStart(paths: paths)
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
        captureStdio: Bool = false,
        timeout: Double,
        paths: IOSUsePaths
    ) throws -> String {
        // Explicit-App start must fail on an unavailable signing identity
        // before acquiring the per-Home operation lock. Lock acquisition may
        // create IOS_USE_HOME, so this preflight is intentionally read-only
        // and outside every session/cache mutation boundary.
        let signingIdentity: PlayCoverSigningIdentityEvidence?
        if let appPath, !appPath.isEmpty {
            signingIdentity = try PlayCoverService
                .requireHealthySigningIdentityForStart()
        } else {
            signingIdentity = nil
        }
        return try startPlayCoverAfterPreflight(
            appPath: appPath,
            signingIdentity: signingIdentity,
            captureStdio: captureStdio,
            timeout: timeout,
            paths: paths
        )
    }

    /// Module-internal handoff from the CLI's earlier routing preflight.
    /// Public callers cannot inject signer evidence and therefore cannot
    /// bypass the read-only configuration check above.
    static func startPlayCoverAfterPreflight(
        appPath: String?,
        signingIdentity: PlayCoverSigningIdentityEvidence?,
        captureStdio: Bool = false,
        timeout: Double,
        paths: IOSUsePaths
    ) throws -> String {
        guard (appPath?.isEmpty == false)
                == (signingIdentity != nil) else {
            throw PlayCoverBackendError.codeSigningFailed(
                "explicit Mac App start is missing preflight signer evidence"
            )
        }
        return try SessionOperationLock.withExclusiveLock(paths: paths) {
            try startPlayCoverLocked(
                appPath: appPath,
                signingIdentity: signingIdentity,
                captureStdio: captureStdio,
                timeout: timeout,
                paths: paths
            )
        }
    }

    private static func startPlayCoverLocked(
        appPath: String?,
        signingIdentity: PlayCoverSigningIdentityEvidence?,
        captureStdio: Bool,
        timeout: Double,
        paths: IOSUsePaths
    ) throws -> String {
        try prepareForDriverStart(paths: paths)
        var launch: PlayCoverSessionService.LaunchResult?
        do {
            let result = try PlayCoverSessionService.launch(
                explicitAppPath: appPath,
                signingIdentity: signingIdentity,
                captureStdio: captureStdio,
                timeout: timeout,
                paths: paths
            )
            launch = result
            try writeDriverLock(
                info: PlayCoverSessionService.makeSessionInfo(from: result),
                paths: paths
            )
            #if DEBUG && canImport(Darwin)
            PlayCoverLaunchCrashCut.hit(.afterDriverLockDurable)
            #endif
            try PlayCoverSessionService.finishDriverLockCommit(
                result: result,
                paths: paths
            )
            let slotDisposition = result.recovered
                ? "recovered"
                : (result.reused ? "reused" : "installed")
            var output = """
            Mac session started for \(result.bundleIdentifier) (pid \(result.pid))
            Mac App slot \(slotDisposition): \(result.appPath)
            IOS_USE_HOME: \(paths.root)

            """
            if let logPath = result.logPath {
                output += "Mac log: \(logPath)\n"
            }
            return output
        } catch {
            if let launch {
                let reportedError: Error
                if let logPath = launch.logPath {
                    reportedError =
                        PlayCoverSessionLoggedLaunchError(
                            logPath: logPath,
                            underlying: error
                        )
                } else {
                    reportedError = error
                }
                do {
                    _ = try PlayCoverSessionService.terminate(
                        result: launch,
                        paths: paths
                    )
                    try DriverSessionStore.removeDriverLock(
                        paths: paths
                    )
                } catch let cleanupError {
                    throw PlayCoverSessionCommitRollbackError(
                        result: launch,
                        originalError: reportedError,
                        cleanupError: cleanupError
                    )
                }
                throw reportedError
            }
            clearDriverLock(paths: paths)
            throw error
        }
    }

    private static func prepareForDriverStart(
        paths: IOSUsePaths
    ) throws {
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
        try SessionOperationLock.withExclusiveLock(paths: paths) {
            try stopLocked(paths: paths)
        }
    }

    private static func stopLocked(paths: IOSUsePaths) throws -> String {
        guard let current = try readDriverLockInfo(paths: paths) else {
            switch try PlayCoverSessionService
                .stopLaunchingWithoutDriverLock(paths: paths) {
            case .stopped(let pid):
                return "Mac interrupted launch stopped (pid \(pid))\n"
                    + "Mac session stopped\n"
            case .cleared:
                return "Mac interrupted launch state cleared "
                    + "(no running App)\nMac session stopped\n"
            case .noRecord:
                break
            }
            _ = try requireDriverLock(paths: paths)
            preconditionFailure(
                "requireDriverLock must throw when driver.lock is absent"
            )
        }
        if current.deviceType == PlayCoverSessionService.deviceType {
            let pid = try PlayCoverSessionService.terminate(
                session: current,
                paths: paths
            )
            do {
                try DriverSessionStore.removeDriverLock(paths: paths)
            } catch {
                throw CLIParseError.invalidValue(
                    "Mac App stopped, but failed to remove "
                        + "\(paths.driverLock): \(error)"
                )
            }
            return "Mac App stopped (pid \(pid))\n"
                + "Mac session stopped\n"
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
