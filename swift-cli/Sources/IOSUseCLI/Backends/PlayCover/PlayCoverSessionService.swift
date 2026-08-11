import Foundation
import IOSUsePlayDevice
#if canImport(Darwin)
import Darwin
#endif
import PlayCoverUpstream

struct PlayCoverSessionCleanupError: Error, CustomStringConvertible {
    enum Operation { case launch, stop }

    let operation: Operation
    let cleanupError: Error
    let originalError: Error?
    let logPath: String?

    var description: String {
        let prefix = operation == .launch
            ? "Mac launch failed and cleanup did not finish"
            : "Mac App stopped, but session cleanup did not finish"
        return prefix + ": \(cleanupError)"
            + (originalError.map { ". Original error: \($0)" } ?? "")
            + (logPath.map { "\nMac log: \($0)" } ?? "")
    }
}

struct PlayCoverSessionLoggedLaunchError: Error, CustomStringConvertible {
    let logPath: String
    let underlying: Error

    var description: String {
        "\(underlying)\nMac log: \(logPath)"
    }
}

struct PlayCoverSessionUnterminatedLaunchError:
    Error,
    CustomStringConvertible
{
    let underlying: PlayCoverSlotUnterminatedLaunchError
    let logPath: String?

    var description: String {
        underlying.description
            + (logPath.map { "\nMac log: \($0)" } ?? "")
    }
}

struct PlayCoverSessionCommitRollbackError:
    Error,
    CustomStringConvertible
{
    let result: PlayCoverSessionService.LaunchResult
    let originalError: Error
    let cleanupError: Error

    var description: String {
        "Mac session commit failed and exact rollback could not be confirmed. "
            + "Original error: \(originalError). Cleanup error: \(cleanupError)"
            + (result.logPath.map { "\nMac log: \($0)" } ?? "")
    }
}

enum PlayCoverSessionService {
    static let deviceType = "mac"
    static let staleLaunchingMilliseconds: Int64 = 60_000

    struct LaunchResult: Equatable, Sendable {
        let sessionID: String
        let appPath: String
        let bundleIdentifier: String
        let executablePath: String
        let installRevision: String
        let productType: String
        let pid: Int32
        let runtimeSocketPath: String
        let logPath: String?
        let reused: Bool
        let recovered: Bool
    }

    enum ProcessState: Equatable {
        case running(executablePath: String)
        case missing
        case unverifiable(errno: Int32)
    }

    enum InterruptedLaunchStopResult: Equatable {
        case noRecord
        case cleared
        case stopped(Int32)
    }

    typealias LaunchOverride = (
        _ slot: PlayCoverInstalledSlot,
        _ sessionID: String,
        _ runtimeSocketPath: String,
        _ stdioLog: PlayCoverStdioLogIdentity?,
        _ timeout: Double
    ) throws -> LaunchResult

    static var launchOverrideForTesting: LaunchOverride?
    static var terminateOverrideForTesting:
        ((SessionService.Info) throws -> Int32)?
    static var processExecutablePathOverrideForTesting:
        ((Int32) -> String?)?
    static var signalOverrideForTesting: ((Int32, Int32) -> Int32)?
    static var processStateOverrideForTesting:
        ((Int32) -> ProcessState)?
    static var processStartTimeOverrideForTesting:
        ((Int32) -> UInt64?)?
    static var terminationIdentityProbeOverrideForTesting:
        ((SessionService.Info) throws -> Void)?
    static var nowMillisecondsOverrideForTesting: (() -> Int64)?
    static var resolveSlotOverrideForTesting: ((
        String?,
        PlayCoverSigningIdentityEvidence?,
        IOSUsePaths
    ) throws -> (slot: PlayCoverInstalledSlot, reused: Bool))?

    static func launch(
        explicitAppPath: String?,
        signingIdentity: PlayCoverSigningIdentityEvidence? = nil,
        captureStdio: Bool = false,
        timeout: Double,
        paths: IOSUsePaths
    ) throws -> LaunchResult {
        if let recovered = try recoverLaunching(
            timeout: timeout,
            paths: paths
        ) {
            return recovered
        }
        let bundleIdentifier = try preflightBundleIdentifier(
            explicitAppPath: explicitAppPath,
            paths: paths
        )
        let bundleLock = try PlayCoverBundleStartLock.acquire(
            bundleIdentifier: bundleIdentifier,
            paths: paths
        )
        defer { _ = bundleLock }
        try ensureRuntimeDirectories(paths: paths)

        let slot: PlayCoverInstalledSlot
        let reused: Bool
        if let resolveSlotOverrideForTesting {
            let resolved = try resolveSlotOverrideForTesting(
                explicitAppPath,
                signingIdentity,
                paths
            )
            slot = resolved.slot
            reused = resolved.reused
        } else if let explicitAppPath, !explicitAppPath.isEmpty {
            guard let signingIdentity else {
                throw PlayCoverBackendError.codeSigningFailed(
                    "explicit Mac App start has no signing identity"
                )
            }
            slot = try PlayCoverSlotService.install(
                sourceAppPath: explicitAppPath,
                paths: paths,
                signingIdentity: signingIdentity
            )
            guard slot.metadata.bundleIdentifier == bundleIdentifier else {
                throw PlayCoverBackendError.cacheTampered(
                    "source Bundle ID changed during prepare"
                )
            }
            reused = false
        } else {
            guard let selected = try PlayCoverHomeStore
                    .readCurrentBundle(paths: paths) else {
                throw PlayCoverBackendError.launchFailed(
                    "no current Mac App is selected; run `ios-use start "
                        + "--mac --app <source.app>`"
                )
            }
            slot = try PlayCoverSlotService.read(
                bundleIdentifier: selected,
                paths: paths,
                expectedInstallRevision:
                    PlayCoverSlotService.currentInstallRevision(paths: paths)
            )
            reused = true
        }
        try PlayCoverHomeStore.updateCurrentBundle(
            slot.metadata.bundleIdentifier,
            paths: paths
        )

        let sessionID = UUID().uuidString
        let runtimeSocketPath = try paths.macRuntimeSocketPath(
            sessionID: sessionID
        )
        let stdioLog = captureStdio
            ? try PlayCoverStdioLogService.create(
                sessionID: sessionID,
                paths: paths
            )
            : nil
        defer {
            #if canImport(Darwin)
            if let descriptor = stdioLog?.descriptor, descriptor >= 0 {
                Darwin.close(descriptor)
            }
            #endif
        }
        do {
            if let launchOverrideForTesting {
                return try launchOverrideForTesting(
                    slot,
                    sessionID,
                    runtimeSocketPath,
                    stdioLog,
                    timeout
                )
            }
            let identity = try PlayCoverSlotLauncher.launch(
                slot: slot,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath,
                paths: paths,
                stdioLog: stdioLog,
                timeout: timeout
            )
            return LaunchResult(
                sessionID: identity.sessionID,
                appPath: identity.appPath,
                bundleIdentifier: identity.bundleIdentifier,
                executablePath: identity.executablePath,
                installRevision: identity.installRevision,
                productType: String(cString: IOSUsePlayDeviceProductType()),
                pid: identity.pid,
                runtimeSocketPath: identity.runtimeSocketPath,
                logPath: stdioLog?.path,
                reused: reused,
                recovered: false
            )
        } catch let error as PlayCoverSlotUnterminatedLaunchError {
            throw PlayCoverSessionUnterminatedLaunchError(
                underlying: error,
                logPath: stdioLog?.path
            )
        } catch {
            if let stdioLog {
                throw PlayCoverSessionLoggedLaunchError(
                    logPath: stdioLog.path,
                    underlying: error
                )
            }
            throw error
        }
    }

    static func finishDriverLockCommit(
        result: LaunchResult,
        paths: IOSUsePaths
    ) throws {
        try PlayCoverLaunchingStore.remove(
            sessionID: result.sessionID,
            paths: paths
        )
    }

    static func recoverLaunching(
        timeout: Double,
        paths: IOSUsePaths
    ) throws -> LaunchResult? {
        guard let record = try PlayCoverLaunchingStore.load(
            paths: paths
        ) else {
            return nil
        }
        let acquisition = try PlayCoverBundleStartLock.acquireForRecovery(
            bundleIdentifier: record.bundleIdentifier,
            paths: paths
        )
        defer { _ = acquisition.lock }
        let slot = try PlayCoverSlotService.read(
            bundleIdentifier: record.bundleIdentifier,
            paths: paths,
            expectedInstallRevision:
                PlayCoverSlotService.currentInstallRevision(paths: paths)
        )
        guard slot.metadata.executableRelativePath
                == record.executableRelativePath else {
            try PlayCoverLaunchingStore.remove(
                sessionID: record.sessionID,
                paths: paths
            )
            throw PlayCoverBackendError.launchRecoveryUnresolved(
                "launching record no longer matches the current Bundle slot",
                retryable: true
            )
        }
        let age = max(0, nowMilliseconds() - record.submittedAt)
        let staleAfter = max(
            staleLaunchingMilliseconds,
            Int64(timeout * 1_000)
        )
        switch acquisition.runningPIDs.count {
        case 0:
            if age >= staleAfter {
                try PlayCoverLaunchingStore.remove(
                    sessionID: record.sessionID,
                    paths: paths
                )
                try? PlayCoverHeadlessKeyCover.lock(
                    bundleIdentifier: record.bundleIdentifier,
                    playChainDirectory: URL(
                        fileURLWithPath: paths.playcoverPlayChain,
                        isDirectory: true
                    )
                )
                return nil
            }
            throw PlayCoverBackendError.launchRecoveryUnresolved(
                "a recent Mac launch is still within its submit timeout",
                retryable: true
            )
        case 1:
            let pid = acquisition.runningPIDs[0]
            do {
                let stdioLog = try stdioIdentity(
                    record.logPath,
                    sessionID: record.sessionID,
                    paths: paths
                )
                _ = try PlayCoverSlotLauncher.authenticate(
                    pid: pid,
                    slot: slot,
                    record: record,
                    stdioLog: stdioLog
                )
                return LaunchResult(
                    sessionID: record.sessionID,
                    appPath: slot.appPath,
                    bundleIdentifier: record.bundleIdentifier,
                    executablePath: slot.executablePath,
                    installRevision: slot.metadata.installRevision,
                    productType: String(
                        cString: IOSUsePlayDeviceProductType()
                    ),
                    pid: pid,
                    runtimeSocketPath: record.runtimeSocketPath,
                    logPath: record.logPath,
                    reused: true,
                    recovered: true
                )
            } catch {
                if !PlayCoverService.runtimeHelloFailureIsTerminal(error),
                   age < staleAfter {
                    throw PlayCoverBackendError.launchRecoveryUnresolved(
                        "the interrupted \(record.bundleIdentifier) launch "
                            + "has not authenticated yet; retry start or run "
                            + "`ios-use stop` to resolve it",
                        retryable: true
                    )
                }
                try PlayCoverLaunchingStore.remove(
                    sessionID: record.sessionID,
                    paths: paths
                )
                throw PlayCoverBackendError.launchRecoveryUnresolved(
                    "a \(record.bundleIdentifier) process is running but "
                        + "does not authenticate the interrupted ios-use "
                        + "launch; close it and retry",
                    retryable: false
                )
            }
        default:
            throw PlayCoverBackendError.launchRecoveryUnresolved(
                "multiple \(record.bundleIdentifier) processes are running; "
                    + "close them and retry",
                retryable: false
            )
        }
    }

    static func stopLaunchingWithoutDriverLock(
        paths: IOSUsePaths
    ) throws -> InterruptedLaunchStopResult {
        guard let record = try PlayCoverLaunchingStore.load(
            paths: paths
        ) else {
            return .noRecord
        }
        let acquisition = try PlayCoverBundleStartLock.acquireForRecovery(
            bundleIdentifier: record.bundleIdentifier,
            paths: paths
        )
        defer { _ = acquisition.lock }
        guard acquisition.runningPIDs.count <= 1 else {
            throw PlayCoverBackendError.terminateFailed(
                "multiple same-Bundle processes exist; refusing to guess"
            )
        }
        guard let pid = acquisition.runningPIDs.first else {
            let age = max(0, nowMilliseconds() - record.submittedAt)
            guard age >= staleLaunchingMilliseconds else {
                throw PlayCoverBackendError.launchRecoveryUnresolved(
                    "the interrupted \(record.bundleIdentifier) launch is "
                        + "still within its asynchronous submit window; "
                        + "retry `ios-use stop`",
                    retryable: true
                )
            }
            try PlayCoverLaunchingStore.remove(
                sessionID: record.sessionID,
                paths: paths
            )
            try PlayCoverHeadlessKeyCover.lock(
                bundleIdentifier: record.bundleIdentifier,
                playChainDirectory: URL(
                    fileURLWithPath: paths.playcoverPlayChain,
                    isDirectory: true
                )
            )
            return .cleared
        }
        let slot = try PlayCoverSlotService.read(
            bundleIdentifier: record.bundleIdentifier,
            paths: paths
        )
        let stdioLog = try stdioIdentity(
            record.logPath,
            sessionID: record.sessionID,
            paths: paths
        )
        do {
            _ = try PlayCoverSlotLauncher.authenticate(
                pid: pid,
                slot: slot,
                record: record,
                stdioLog: stdioLog
            )
        } catch {
            try PlayCoverLaunchingStore.remove(
                sessionID: record.sessionID,
                paths: paths
            )
            throw PlayCoverBackendError.terminateFailed(
                "running App did not authenticate the interrupted launch; "
                    + "refusing to terminate it"
            )
        }
        let candidate = PlayCoverSlotLaunchIdentityCandidate(
            pid: pid,
            bundleIdentifier: record.bundleIdentifier,
            bundleURLPath: slot.appPath,
            executablePath: slot.executablePath,
            processStartTimeMicroseconds:
                processStartTimeMicroseconds(pid),
            source: .authenticatedRuntime
        )
        try PlayCoverSlotLauncher.terminateExact(candidate, slot: slot)
        try PlayCoverLaunchingStore.remove(
            sessionID: record.sessionID,
            paths: paths
        )
        try PlayCoverHeadlessKeyCover.lock(
            bundleIdentifier: record.bundleIdentifier,
            playChainDirectory: URL(
                fileURLWithPath: paths.playcoverPlayChain,
                isDirectory: true
            )
        )
        return .stopped(pid)
    }

    @discardableResult
    static func terminate(
        result: LaunchResult,
        paths: IOSUsePaths
    ) throws -> Int32 {
        try terminate(session: makeSessionInfo(from: result), paths: paths)
    }

    static func terminate(
        session: SessionService.Info,
        paths: IOSUsePaths
    ) throws -> Int32 {
        let slot = try validateSlot(session: session, paths: paths)
        let pid = try terminateConfirmedProcess(
            session: session,
            slot: slot,
            paths: paths
        )
        do {
            try PlayCoverHeadlessKeyCover.lock(
                bundleIdentifier: slot.metadata.bundleIdentifier,
                playChainDirectory: URL(
                    fileURLWithPath: paths.playcoverPlayChain,
                    isDirectory: true
                )
            )
            if let sessionID = session.sessionIdentifier,
               let record = try PlayCoverLaunchingStore.load(paths: paths),
               record.sessionID == sessionID {
                try PlayCoverLaunchingStore.remove(
                    sessionID: sessionID,
                    paths: paths
                )
            }
        } catch {
            throw PlayCoverSessionCleanupError(
                operation: .stop,
                cleanupError: error,
                originalError: nil,
                logPath: session.macLogPath
            )
        }
        return pid
    }

    private static func terminateConfirmedProcess(
        session: SessionService.Info,
        slot: PlayCoverInstalledSlot,
        paths: IOSUsePaths
    ) throws -> Int32 {
        if let terminateOverrideForTesting {
            return try terminateOverrideForTesting(session)
        }
        guard let pidValue = session.runnerPid,
              pidValue > 0,
              pidValue <= Int(Int32.max) else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: Mac PID is missing."
            )
        }
        let pid = Int32(pidValue)
        let initialState = processState(pid)
        switch initialState {
        case .missing:
            return pid
        case .unverifiable(let errorNumber):
            throw PlayCoverBackendError.terminateFailed(
                "cannot verify Mac App PID \(pid): errno \(errorNumber)"
            )
        case .running(let executablePath):
            guard PlayCoverRuntimeClient.canonicalPath(executablePath)
                    == PlayCoverRuntimeClient.canonicalPath(
                        slot.executablePath
                    ) else {
                throw PlayCoverBackendError.terminateFailed(
                    "refusing to terminate PID \(pid): executable changed"
                )
            }
        }
        let initialBirth = processStartTimeMicroseconds(pid)
        var runtimeUnavailable = false
        do {
            if let terminationIdentityProbeOverrideForTesting {
                try terminationIdentityProbeOverrideForTesting(session)
            } else {
                _ = try PlayCoverDriverClient.runtimeClient(
                    for: session,
                    timeoutSeconds: 0.75
                ).hello()
            }
        } catch {
            guard PlayCoverService.permitsUnresponsiveRuntimeTermination(
                after: error
            ) else {
                throw PlayCoverBackendError.terminateFailed(
                    "Runtime did not prove the recorded session identity: "
                        + "\(error)"
                )
            }
            runtimeUnavailable = true
        }
        _ = try validateSlot(session: session, paths: paths)
        guard case .running(let currentExecutable) = processState(pid),
              PlayCoverRuntimeClient.canonicalPath(currentExecutable)
                == PlayCoverRuntimeClient.canonicalPath(
                    slot.executablePath
                ) else {
            if case .missing = processState(pid) { return pid }
            throw PlayCoverBackendError.terminateFailed(
                "Mac process identity changed before SIGTERM"
            )
        }
        let currentBirth = processStartTimeMicroseconds(pid)
        if let initialBirth, let currentBirth,
           initialBirth != currentBirth {
            throw PlayCoverBackendError.terminateFailed(
                "refusing to terminate a reused PID"
            )
        }
        if runtimeUnavailable {
            let upperBound = UInt64(max(0, session.startedAt)) * 1_000
            guard let initialBirth,
                  currentBirth == initialBirth,
                  initialBirth <= upperBound else {
                throw PlayCoverBackendError.terminateFailed(
                    "unresponsive Runtime fallback lacks stable birth proof"
                )
            }
        }
        #if canImport(Darwin)
        let result = sendSignal(pid, SIGTERM)
        let signalError = errno
        if result != 0, signalError == ESRCH { return pid }
        guard result == 0 else {
            throw PlayCoverBackendError.terminateFailed(
                "SIGTERM failed for PID \(pid): errno \(signalError)"
            )
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            switch processState(pid) {
            case .missing:
                return pid
            case .running(let executablePath):
                if PlayCoverRuntimeClient.canonicalPath(executablePath)
                    != PlayCoverRuntimeClient.canonicalPath(
                        slot.executablePath
                    ) {
                    return pid
                }
            case .unverifiable(let errorNumber):
                if errorNumber == ESRCH { return pid }
                throw PlayCoverBackendError.terminateFailed(
                    "cannot verify PID after SIGTERM: errno \(errorNumber)"
                )
            }
            usleep(50_000)
        }
        throw PlayCoverBackendError.terminateFailed(
            "Mac App PID \(pid) did not exit after SIGTERM"
        )
        #else
        return pid
        #endif
    }

    static func validateSlot(
        session: SessionService.Info,
        paths: IOSUsePaths
    ) throws -> PlayCoverInstalledSlot {
        guard session.deviceType == deviceType,
              session.startMode == deviceType,
              session.udid == deviceType,
              let bundleIdentifier = session.bundleId,
              let appPath = session.macAppPath,
              let executablePath = session.macExecutablePath,
              let installRevision = session.macInstallRevision,
              let sessionID = session.sessionIdentifier,
              UUID(uuidString: sessionID) != nil,
              let socketPath = session.macRuntimeSocketPath,
              session.startedAt > 0,
              let runnerPID = session.runnerPid,
              runnerPID > 0 else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: Mac slot identity is incomplete."
            )
        }
        let slot = try PlayCoverSlotService.read(
            bundleIdentifier: bundleIdentifier,
            paths: paths,
            expectedInstallRevision: installRevision
        )
        guard PlayCoverRuntimeClient.canonicalPath(slot.appPath)
                == PlayCoverRuntimeClient.canonicalPath(appPath),
              PlayCoverRuntimeClient.canonicalPath(slot.executablePath)
                == PlayCoverRuntimeClient.canonicalPath(executablePath),
              PlayCoverRuntimeClient.canonicalPath(socketPath)
                == PlayCoverRuntimeClient.canonicalPath(
                    try paths.macRuntimeSocketPath(sessionID: sessionID)
                ) else {
            throw PlayCoverBackendError.terminateFailed(
                "active session no longer matches the current Bundle slot"
            )
        }
        return slot
    }

    static func makeSessionInfo(
        from result: LaunchResult
    ) -> SessionService.Info {
        SessionService.Info(
            udid: deviceType,
            deviceName: result.productType,
            deviceVersion: "Mac Catalyst",
            deviceType: deviceType,
            runnerPid: Int(result.pid),
            startMode: deviceType,
            sessionIdentifier: result.sessionID,
            bundleId: result.bundleIdentifier,
            macAppPath: result.appPath,
            macExecutablePath: result.executablePath,
            macInstallRevision: result.installRevision,
            macRuntimeSocketPath: result.runtimeSocketPath,
            macLogPath: result.logPath
        )
    }

    static func preflightBundleIdentifier(
        explicitAppPath: String?,
        paths: IOSUsePaths
    ) throws -> String {
        if let explicitAppPath, !explicitAppPath.isEmpty {
            let plistURL = URL(
                fileURLWithPath: explicitAppPath,
                isDirectory: true
            ).appendingPathComponent("Info.plist")
            let data: Data
            do {
                data = try Data(contentsOf: plistURL, options: .mappedIfSafe)
            } catch {
                throw PlayCoverBackendError.prepareFailed(
                    "explicit Mac App is missing a readable Info.plist"
                )
            }
            guard let plist = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  let bundleIdentifier = plist[
                    "CFBundleIdentifier"
                  ] as? String else {
                throw PlayCoverBackendError.prepareFailed(
                    "explicit Mac App has no valid CFBundleIdentifier"
                )
            }
            try PlayCoverSlotService.validateBundleIdentifier(
                bundleIdentifier
            )
            return bundleIdentifier
        }
        guard let bundleIdentifier = try PlayCoverHomeStore
                .readCurrentBundle(paths: paths) else {
            throw PlayCoverBackendError.launchFailed(
                "no current Mac App is selected; run `ios-use start --mac "
                    + "--app <source.app>`"
            )
        }
        return bundleIdentifier
    }

    static func expectedRuntimeSocketPath(
        sessionID: String,
        paths: IOSUsePaths
    ) throws -> String {
        try paths.macRuntimeSocketPath(sessionID: sessionID)
    }

    static func expectedRuntimeSocketPath(
        sessionID: String,
        homeID: String,
        socketRootPath: String
    ) throws -> String {
        try IOSUsePaths.macRuntimeSocketPath(
            sessionID: sessionID,
            homeID: homeID,
            socketRoot: socketRootPath
        )
    }

    static func processState(_ pid: Int32) -> ProcessState {
        if let processStateOverrideForTesting {
            return processStateOverrideForTesting(pid)
        }
        if let executable = processExecutablePath(pid) {
            return .running(executablePath: executable)
        }
        #if canImport(Darwin)
        let result = Darwin.kill(pid, 0)
        let errorNumber = errno
        return result != 0 && errorNumber == ESRCH
            ? .missing
            : .unverifiable(errno: errorNumber)
        #else
        return .missing
        #endif
    }

    private static func ensureRuntimeDirectories(
        paths: IOSUsePaths
    ) throws {
        for path in [
            paths.playcoverRun,
            paths.playcoverSocketRoot,
            paths.playcoverPlayChain,
        ] {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            #if canImport(Darwin)
            var status = stat()
            guard lstat(path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(),
                  chmod(path, 0o700) == 0 else {
                throw PlayCoverBackendError.launchFailed(
                    "Mac Runtime directory must be owner-only: \(path)"
                )
            }
            #endif
        }
    }

    private static func stdioIdentity(
        _ path: String?,
        sessionID: String,
        paths: IOSUsePaths
    ) throws -> PlayCoverStdioLogIdentity? {
        guard let path else { return nil }
        try PlayCoverStdioLogService.validateSessionPath(
            path,
            sessionID: sessionID,
            paths: paths
        )
        #if canImport(Darwin)
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw PlayCoverBackendError.stdioLogFailed(
                "Mac stdio log identity is unavailable during recovery"
            )
        }
        return PlayCoverStdioLogIdentity(
            path: path,
            device: UInt64(truncatingIfNeeded: status.st_dev),
            inode: UInt64(status.st_ino)
        )
        #else
        return nil
        #endif
    }

    private static func processExecutablePath(_ pid: Int32) -> String? {
        if let processExecutablePathOverrideForTesting {
            return processExecutablePathOverrideForTesting(pid)
        }
        return PlayCoverRuntimeClient.executablePath(for: pid)
    }

    private static func processStartTimeMicroseconds(
        _ pid: Int32
    ) -> UInt64? {
        if let processStartTimeOverrideForTesting {
            return processStartTimeOverrideForTesting(pid)
        }
        return PlayCoverService.processStartTimeMicroseconds(for: pid)
    }

    private static func sendSignal(
        _ pid: Int32,
        _ signal: Int32
    ) -> Int32 {
        if let signalOverrideForTesting {
            return signalOverrideForTesting(pid, signal)
        }
        #if canImport(Darwin)
        return Darwin.kill(pid, signal)
        #else
        return -1
        #endif
    }

    private static func nowMilliseconds() -> Int64 {
        if let nowMillisecondsOverrideForTesting {
            return nowMillisecondsOverrideForTesting()
        }
        return Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
