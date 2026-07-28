import Foundation
import IOSUsePlayDevice
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverSessionCleanupError: Error,
    CustomStringConvertible
{
    enum Operation {
        case launch
        case stop
    }

    let operation: Operation
    let cleanupError: Error
    let originalError: Error?
    let logPath: String?

    var description: String {
        let prefix: String
        switch operation {
        case .launch:
            prefix =
                "PlayCover launch failed and its exact process is "
                + "stopped, but launch cleanup did not finish"
        case .stop:
            prefix =
                "PlayCover stop applied its lifecycle mutation, "
                + "but session cleanup did not finish"
        }
        return prefix
            + ": \(cleanupError)"
            + (originalError.map {
                ". Original error: \($0)"
            } ?? "")
            + ". Durable recovery authority was preserved; "
            + "retry `ios-use stop` after resolving the cleanup error."
            + (logPath.map {
                "\nPlayCover log: \($0)"
            } ?? "")
    }
}

struct PlayCoverSessionUnterminatedLaunchError: Error,
    CustomStringConvertible
{
    let result: PlayCoverSessionService.LaunchResult
    let underlying: PlayCoverUnterminatedLaunchError

    var description: String {
        underlying.description
            + (result.logPath.map {
                "\nPlayCover log: \($0)"
            } ?? "")
    }
}

struct PlayCoverSessionLoggedLaunchError: Error,
    CustomStringConvertible
{
    let logPath: String
    let underlying: Error

    var description: String {
        "\(underlying)\nPlayCover log: \(logPath)"
    }
}

struct PlayCoverSessionCommitRollbackError: Error,
    CustomStringConvertible
{
    let result: PlayCoverSessionService.LaunchResult
    let originalError: Error
    let cleanupError: Error

    var description: String {
        "PlayCover session commit failed and exact rollback could "
            + "not be confirmed. Original error: \(originalError). "
            + "Cleanup error: \(cleanupError)"
            + (result.logPath.map {
                "\nPlayCover log: \($0)"
            } ?? "")
    }
}

struct PlayCoverSessionJournalHandoffError: Error,
    CustomStringConvertible
{
    let result: PlayCoverSessionService.LaunchResult
    let underlying: Error

    var description: String {
        "PlayCover driver.lock is durable, but pending launch "
            + "handoff did not finish: \(underlying). The active "
            + "session and recovery evidence were preserved."
            + (result.logPath.map {
                "\nPlayCover log: \($0)"
            } ?? "")
    }
}

enum PlayCoverSessionService {
    static let deviceType = "playcover"

    struct PreparedReference: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let appPath: String
        let bundleIdentifier: String
        let executablePath: String
        let generationKey: String
    }

    struct LaunchResult: Equatable, Sendable {
        let sessionID: String
        let appPath: String
        let bundleIdentifier: String
        let executablePath: String
        let generationKey: String
        let productType: String
        let pid: Int32
        let runtimeSocketPath: String
        let logPath: String?
        let usesPendingLaunchJournal: Bool
        let reused: Bool
        let timing: PlayCoverStartTiming
        let currentGenerationToken:
            PlayCoverFastVerifiedGenerationToken?

        init(
            sessionID: String,
            appPath: String,
            bundleIdentifier: String,
            executablePath: String,
            generationKey: String,
            productType: String,
            pid: Int32,
            runtimeSocketPath: String,
            logPath: String? = nil,
            usesPendingLaunchJournal: Bool = false,
            reused: Bool,
            timing: PlayCoverStartTiming = .empty,
            currentGenerationToken:
                PlayCoverFastVerifiedGenerationToken? = nil
        ) {
            self.sessionID = sessionID
            self.appPath = appPath
            self.bundleIdentifier = bundleIdentifier
            self.executablePath = executablePath
            self.generationKey = generationKey
            self.productType = productType
            self.pid = pid
            self.runtimeSocketPath = runtimeSocketPath
            self.logPath = logPath
            self.usesPendingLaunchJournal =
                usesPendingLaunchJournal
            self.reused = reused
            self.timing = timing
            self.currentGenerationToken = currentGenerationToken
        }
    }

    typealias LaunchOverride = (
        _ appPath: String,
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
    static var signalOverrideForTesting:
        ((Int32, Int32) -> Int32)?
    enum ProcessState: Equatable {
        case running(executablePath: String)
        case missing
        case unverifiable(errno: Int32)
    }
    static var processStateOverrideForTesting:
        ((Int32) -> ProcessState)?
    static var processStartTimeOverrideForTesting:
        ((Int32) -> UInt64?)?
    static var terminationIdentityProbeOverrideForTesting:
        ((SessionService.Info) throws -> Void)?
    static var fastVerifyOverrideForTesting:
        ((String) throws -> PlayCoverPrepareManifest)?

    static func recordPrepared(
        _ manifest: PlayCoverPrepareManifest,
        paths: IOSUsePaths
    ) throws {
        try recordPrepared(
            appPath: manifest.preparedAppPath,
            bundleIdentifier: manifest.bundleIdentifier,
            executablePath: manifest.executablePath,
            generationKey: manifest.generationKey,
            paths: paths
        )
    }

    private static func recordPrepared(
        appPath: String,
        bundleIdentifier: String,
        executablePath: String,
        generationKey: String,
        paths: IOSUsePaths
    ) throws {
        try writeReference(
            PreparedReference(
                schemaVersion: 3,
                appPath: appPath,
                bundleIdentifier: bundleIdentifier,
                executablePath: executablePath,
                generationKey: generationKey
            ),
            paths: paths
        )
    }

    private struct ResolvedApp {
        let appPath: String
        let bundleIdentifier: String
        let executablePath: String
        let generationKey: String
        let generationIdentity: PlayCoverGenerationIdentity?
        let expectedManifest: PlayCoverPrepareManifest?
        let reused: Bool
        let timing: PlayCoverStartTiming
    }

    private static func resolveApp(
        explicitAppPath: String?,
        paths: IOSUsePaths
    ) throws -> ResolvedApp {
        if let explicitAppPath, !explicitAppPath.isEmpty {
            let resolution =
                try PlayCoverManagedAppService.resolveExplicitApp(
                    explicitAppPath,
                    paths: paths
            )
            return ResolvedApp(
                appPath: resolution.manifest.preparedAppPath,
                bundleIdentifier:
                    resolution.manifest.bundleIdentifier,
                executablePath:
                    resolution.manifest.executablePath,
                generationKey: resolution.manifest.generationKey,
                generationIdentity:
                    resolution.generationIdentity,
                expectedManifest: resolution.manifest,
                reused: resolution.reused,
                timing: resolution.timing
            )
        }
        let inspectStarted = PlayCoverMonotonicClock.now()
        guard let reference = try readPreparedReference(
            paths: paths
        ) else {
            throw PlayCoverBackendError.launchFailed(
                "no prepared App is selected; pass "
                    + "`--app <source-or-prepared.app>`"
            )
        }
        try validateManagedGenerationPath(
            appPath: reference.appPath,
            executablePath: reference.executablePath,
            generationKey: reference.generationKey,
            paths: paths
        )
        return ResolvedApp(
            appPath: reference.appPath,
            bundleIdentifier: reference.bundleIdentifier,
            executablePath: reference.executablePath,
            generationKey: reference.generationKey,
            generationIdentity: nil,
            expectedManifest: nil,
            reused: true,
            timing: PlayCoverStartTiming(
                inspectNanoseconds:
                    PlayCoverMonotonicClock.elapsed(
                        since: inspectStarted
                    ),
                cloneNanoseconds: nil,
                convertNanoseconds: nil,
                signNanoseconds: nil,
                verifyNanoseconds: 0,
                launchNanoseconds: 0,
                totalNanoseconds: 0
            )
        )
    }

    static func launch(
        explicitAppPath: String?,
        captureStdio: Bool = false,
        timeout: Double,
        paths: IOSUsePaths
    ) throws -> LaunchResult {
        let sessionID = UUID().uuidString
        try ensureOwnerOnlyRunDirectory(paths.playcoverRun)
        let socketPath = try paths.playCoverRuntimeSocketPath(
            sessionID: sessionID
        )
        // Validate the fixed-length Unix transport path before source
        // inspection or a cold prepare. A custom IOS_USE_HOME that cannot
        // host the Runtime socket must fail without doing expensive App work.
        let resolved = try resolveApp(
            explicitAppPath: explicitAppPath,
            paths: paths
        )
        var timing = resolved.timing
        let verificationStarted = PlayCoverMonotonicClock.now()
        let verifiedLaunch = try fastVerifiedLaunchCapability(
            appPath: resolved.appPath,
            expectedGenerationIdentity:
                resolved.generationIdentity
        )
        defer { verifiedLaunch.capability?.close() }
        let validatedManifest = verifiedLaunch.evidence
        let launchCapability = verifiedLaunch.capability
        let currentGenerationToken =
            verifiedLaunch.currentGenerationToken
        let verifiedManifest = validatedManifest.manifest
        timing.addVerify(
            PlayCoverMonotonicClock.elapsed(
                since: verificationStarted
            )
        )
        guard verifiedManifest.preparedAppPath == resolved.appPath,
              verifiedManifest.bundleIdentifier
                == resolved.bundleIdentifier,
              verifiedManifest.executablePath
                == resolved.executablePath,
              verifiedManifest.generationKey == resolved.generationKey,
              resolved.expectedManifest.map({
                $0 == verifiedManifest
              }) ?? true else {
            throw PlayCoverBackendError.cacheTampered(
                "selected generation identity changed before launch"
            )
        }
        // Bare start selects the most recent successfully prepared and
        // fast-verified generation. Runtime hello and session commit are a
        // separate transaction; a failed launch rolls back the App without
        // making this immutable generation undiscoverable for retry.
        try recordPrepared(verifiedManifest, paths: paths)
        let stdioLog = captureStdio
            ? try PlayCoverStdioLogService.create(
                sessionID: sessionID,
                paths: paths
            )
            : nil
        do {
            let launchStarted = PlayCoverMonotonicClock.now()
            var launchPhaseTiming = PlayCoverLaunchPhaseTiming.empty
            let rawResult: LaunchResult
            if let launchOverrideForTesting {
                rawResult = try launchOverrideForTesting(
                    verifiedManifest.preparedAppPath,
                    sessionID,
                    socketPath,
                    stdioLog,
                    timeout
                )
            } else {
                guard let launchCapability else {
                    throw PlayCoverBackendError.launchFailed(
                        "fast-verified launch capability is missing"
                    )
                }
                let identity: PlayCoverLaunchIdentity
                do {
                    identity = try PlayCoverService.launchVerified(
                        validatedManifest: validatedManifest,
                        launchCapability: launchCapability,
                        sessionID: sessionID,
                        runtimeSocketPath: socketPath,
                        stdioLog: stdioLog,
                        pendingLaunchPaths: paths,
                        launchPhaseTiming: &launchPhaseTiming,
                        timeout: timeout
                    )
                } catch let error as PlayCoverUnterminatedLaunchError {
                    timing.launchNanoseconds =
                        PlayCoverMonotonicClock.elapsed(
                            since: launchStarted
                        )
                    timing.launchPhaseTiming = launchPhaseTiming
                    throw PlayCoverSessionUnterminatedLaunchError(
                        result: LaunchResult(
                            sessionID: error.sessionID,
                            appPath: error.appPath,
                            bundleIdentifier:
                                error.bundleIdentifier,
                            executablePath: error.executablePath,
                            generationKey: error.generationKey,
                            productType: String(
                                cString:
                                    IOSUsePlayDeviceProductType()
                            ),
                            pid: error.pid,
                            runtimeSocketPath:
                                error.runtimeSocketPath,
                            logPath: stdioLog?.path,
                            usesPendingLaunchJournal: true,
                            reused: resolved.reused,
                            timing: timing
                        ),
                        underlying: error
                    )
                }
                rawResult = LaunchResult(
                    sessionID: identity.sessionID,
                    appPath: identity.appPath,
                    bundleIdentifier: identity.bundleIdentifier,
                    executablePath: identity.executablePath,
                    generationKey: identity.generationKey,
                    productType: String(
                        cString: IOSUsePlayDeviceProductType()
                    ),
                    pid: identity.pid,
                    runtimeSocketPath: identity.runtimeSocketPath,
                    logPath: stdioLog?.path,
                    usesPendingLaunchJournal: true,
                    reused: resolved.reused
                )
            }
            timing.launchNanoseconds =
                PlayCoverMonotonicClock.elapsed(since: launchStarted)
            timing.launchPhaseTiming = launchPhaseTiming
            let result = LaunchResult(
                sessionID: rawResult.sessionID,
                appPath: rawResult.appPath,
                bundleIdentifier: rawResult.bundleIdentifier,
                executablePath: rawResult.executablePath,
                generationKey: rawResult.generationKey,
                productType: rawResult.productType,
                pid: rawResult.pid,
                runtimeSocketPath: rawResult.runtimeSocketPath,
                logPath: stdioLog?.path,
                usesPendingLaunchJournal:
                    rawResult.usesPendingLaunchJournal,
                reused: resolved.reused,
                timing: timing,
                currentGenerationToken: currentGenerationToken
            )
            guard result.sessionID == sessionID,
                  result.appPath
                    == verifiedManifest.preparedAppPath,
                  result.pid > 0,
                  result.bundleIdentifier
                    == verifiedManifest.bundleIdentifier,
                  result.executablePath
                    == verifiedManifest.executablePath,
                  result.generationKey
                    == verifiedManifest.generationKey,
                  result.runtimeSocketPath == socketPath else {
                throw PlayCoverBackendError.launchFailed(
                    "Runtime hello returned incomplete or mismatched "
                        + "single-session identity"
                )
            }
            return result
        } catch let error as
                PlayCoverSessionUnterminatedLaunchError {
            throw error
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

    static func retirePendingLaunchJournalAfterDriverCommit(
        result: LaunchResult,
        paths: IOSUsePaths
    ) throws {
        guard result.usesPendingLaunchJournal else {
            return
        }
        try retirePendingLaunchJournalAfterDriverCommit(
            sessionID: result.sessionID,
            pid: result.pid,
            appPath: result.appPath,
            bundleIdentifier: result.bundleIdentifier,
            executablePath: result.executablePath,
            generationKey: result.generationKey,
            runtimeSocketPath: result.runtimeSocketPath,
            paths: paths,
            required: true
        )
    }

    static func retirePendingLaunchJournalAfterDriverCommit(
        session: SessionService.Info,
        paths: IOSUsePaths
    ) throws {
        guard session.deviceType == deviceType,
              let sessionID = session.sessionIdentifier,
              let pidValue = session.runnerPid,
              pidValue > 0,
              pidValue <= Int(Int32.max),
              let appPath = session.playCoverAppPath,
              let bundleIdentifier = session.bundleId,
              let executablePath =
                session.playCoverExecutablePath,
              let generationKey =
                session.playCoverGenerationKey,
              let runtimeSocketPath =
                session.playCoverRuntimeSocketPath else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: PlayCover handoff identity "
                    + "is incomplete."
            )
        }
        try retirePendingLaunchJournalAfterDriverCommit(
            sessionID: sessionID,
            pid: Int32(pidValue),
            appPath: appPath,
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            generationKey: generationKey,
            runtimeSocketPath: runtimeSocketPath,
            paths: paths,
            required: false
        )
    }

    private static func retirePendingLaunchJournalAfterDriverCommit(
        sessionID: String,
        pid: Int32,
        appPath: String,
        bundleIdentifier: String,
        executablePath: String,
        generationKey: String,
        runtimeSocketPath: String,
        paths: IOSUsePaths,
        required: Bool
    ) throws {
        guard var record = try PlayCoverPendingLaunchStore.load(
            paths: paths
        ) else {
            if required {
                throw PlayCoverPendingLaunchStoreError(
                    message:
                        "driver.lock commit has no matching "
                        + "pending launch"
                )
            }
            return
        }
        guard record.sessionID == sessionID,
              record.owner?.pid == pid,
              record.appPath == appPath,
              record.bundleIdentifier == bundleIdentifier,
              record.executablePath == executablePath,
              record.generationKey == generationKey,
              record.runtimeSocketPath == runtimeSocketPath else {
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "driver.lock does not match the pending "
                    + "launch authority"
            )
        }
        switch record.phase {
        case .owned:
            record = try PlayCoverPendingLaunchStore
                .markDriverLockCommitted(
                    sessionID: sessionID,
                    paths: paths
                )
            #if DEBUG && canImport(Darwin)
            PlayCoverLaunchCrashCut.hit(
                .afterPendingDriverLockCommitted
            )
            #endif
            fallthrough
        case .driverLockCommitted:
            record = try PlayCoverPendingLaunchStore
                .markConfirmedStopped(
                    sessionID: sessionID,
                    cleanupProof: .driverLockRetired,
                    paths: paths
                )
            #if DEBUG && canImport(Darwin)
            PlayCoverLaunchCrashCut.hit(
                .afterPendingDriverLockRetired
            )
            #endif
        case .confirmedStopped:
            guard record.cleanupProof == .driverLockRetired else {
                throw PlayCoverPendingLaunchStoreError(
                    message:
                        "driver.lock handoff conflicts with "
                        + "pending cleanup proof"
                )
            }
        case .intent, .aliasReady, .submissionArmed,
             .terminalCallback:
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "driver.lock was committed before durable "
                    + "process ownership"
            )
        }
        try PlayCoverPendingLaunchStore.removeConfirmed(
            sessionID: sessionID,
            paths: paths
        )
        #if DEBUG && canImport(Darwin)
        PlayCoverLaunchCrashCut.hit(.afterPendingJournalRemoved)
        #endif
    }

    @discardableResult
    static func terminate(result: LaunchResult) throws -> Int32 {
        try terminate(session: makeSessionInfo(from: result))
    }

    static func terminate(
        session: SessionService.Info
    ) throws -> Int32 {
        let manifest = try validateGeneration(session: session)
        let pid = try terminateConfirmedProcess(session: session)
        guard let sessionID = session.sessionIdentifier else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: PlayCover sessionID is missing."
            )
        }
        do {
            try PlayCoverService.lockKeyCover(for: manifest)
            try PlayCoverService.removeSessionLaunchAlias(
                sessionID: sessionID,
                manifest: manifest
            )
        } catch {
            throw PlayCoverSessionCleanupError(
                operation: .stop,
                cleanupError: error,
                originalError: nil,
                logPath: session.playCoverLogPath
            )
        }
        return pid
    }

    private static func terminateConfirmedProcess(
        session: SessionService.Info
    ) throws -> Int32 {
        if let terminateOverrideForTesting {
            return try terminateOverrideForTesting(session)
        }
        guard let pidValue = session.runnerPid,
              pidValue > 0,
              pidValue <= Int(Int32.max),
              let expectedExecutable =
                session.playCoverExecutablePath else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: PlayCover PID/executable "
                    + "identity is incomplete."
            )
        }
        let pid = Int32(pidValue)
        let initialState = processState(pid)
        guard case .running(let actualExecutable) =
                initialState else {
            switch initialState {
            case .missing:
                return pid
            case .unverifiable(let errorNumber):
                throw PlayCoverBackendError.terminateFailed(
                    "cannot verify whether PlayCover App PID "
                        + "\(pid) is still running: errno "
                        + "\(errorNumber)"
                )
            case .running:
                fatalError("unreachable")
            }
        }
        guard PlayCoverRuntimeClient.canonicalPath(
            actualExecutable
        ) == PlayCoverRuntimeClient.canonicalPath(
            expectedExecutable
        ) else {
            throw PlayCoverBackendError.terminateFailed(
                "refusing to terminate PID \(pid): it belongs "
                    + "to a different executable"
            )
        }
        let initialProcessStart =
            processStartTimeMicroseconds(pid)
        var usedUnresponsiveRuntimeFallback = false
        do {
            if let terminationIdentityProbeOverrideForTesting {
                try terminationIdentityProbeOverrideForTesting(
                    session
                )
            } else {
                _ = try PlayCoverDriverClient.runtimeClient(
                    for: session,
                    timeoutSeconds: 0.75
                ).hello()
            }
        } catch {
            guard PlayCoverService
                    .permitsUnresponsiveRuntimeTermination(
                        after: error
                    ) else {
                throw PlayCoverBackendError.terminateFailed(
                    "refusing to terminate PID \(pid): the live "
                        + "Runtime did not prove the recorded "
                        + "sessionID/PID/bundle/executable identity "
                        + "(\(error))"
                )
            }
            usedUnresponsiveRuntimeFallback = true
        }

        // The Runtime probe can block until its deadline. Re-read every
        // immutable and live identity immediately before signaling so a
        // generation mutation or PID reuse during that wait cannot redirect
        // termination.
        _ = try validateGeneration(session: session)
        let currentState = processState(pid)
        guard case .running(let currentExecutable) =
                currentState else {
            switch currentState {
            case .missing:
                return pid
            case .unverifiable(let errorNumber):
                throw PlayCoverBackendError.terminateFailed(
                    "cannot revalidate PlayCover App PID \(pid) "
                        + "before SIGTERM: errno \(errorNumber)"
                )
            case .running:
                fatalError("unreachable")
            }
        }
        guard PlayCoverRuntimeClient.canonicalPath(
            currentExecutable
        ) == PlayCoverRuntimeClient.canonicalPath(
            expectedExecutable
        ) else {
            throw PlayCoverBackendError.terminateFailed(
                "refusing to terminate PID \(pid): process "
                    + "identity changed before SIGTERM"
            )
        }
        let currentProcessStart =
            processStartTimeMicroseconds(pid)
        if let initialProcessStart,
           let currentProcessStart,
           initialProcessStart != currentProcessStart {
            throw PlayCoverBackendError.terminateFailed(
                "refusing to terminate PID \(pid): PID was reused "
                    + "before SIGTERM"
            )
        }
        if usedUnresponsiveRuntimeFallback {
            let (
                recordedStartUpperBound,
                recordedStartOverflow
            ) = UInt64(session.startedAt)
                .multipliedReportingOverflow(by: 1_000)
            guard let initialProcessStart,
                  let currentProcessStart,
                  !recordedStartOverflow,
                  initialProcessStart == currentProcessStart,
                  currentProcessStart <=
                    recordedStartUpperBound else {
                throw PlayCoverBackendError.terminateFailed(
                    "refusing unresponsive Runtime fallback for "
                        + "PID \(pid): stable process birth identity "
                        + "does not match the recorded session"
                )
            }
        }

        let signalResult = sendSignal(pid, SIGTERM)
        let signalError = errno
        if signalResult != 0, signalError == ESRCH {
            return pid
        }
        guard signalResult == 0 else {
            throw PlayCoverBackendError.terminateFailed(
                "SIGTERM failed for PID \(pid): errno \(signalError)"
            )
        }
        let deadline =
            ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            switch processState(pid) {
            case .missing:
                return pid
            case .running(let currentExecutable):
                if PlayCoverRuntimeClient.canonicalPath(
                currentExecutable
                ) != PlayCoverRuntimeClient.canonicalPath(
                    expectedExecutable
                ) {
                    // The exact App exited and the PID was reused.
                    // Never signal the replacement process.
                    return pid
                }
            case .unverifiable(let errorNumber):
                if errorNumber == ESRCH {
                    // SIGTERM was sent only after the session and
                    // executable identity were revalidated, together
                    // with stable birth identity when available or
                    // required. During exit, proc_pidpath can lose the
                    // process before kill(0) observes it as missing. No
                    // further signal is sent, so PID reuse cannot
                    // redirect termination to a replacement process.
                    return pid
                }
                throw PlayCoverBackendError.terminateFailed(
                    "cannot verify PlayCover App PID \(pid) "
                        + "after SIGTERM: errno \(errorNumber)"
                )
            }
            usleep(50_000)
        }
        throw PlayCoverBackendError.terminateFailed(
            "PlayCover App PID \(pid) did not exit after SIGTERM"
        )
    }

    static func validateGeneration(
        session: SessionService.Info
    ) throws -> PlayCoverPrepareManifest {
        guard session.deviceType == deviceType,
              session.startMode == deviceType,
              let appPath = session.playCoverAppPath,
              !appPath.isEmpty,
              let executablePath =
                session.playCoverExecutablePath,
              !executablePath.isEmpty,
              let generationKey =
                session.playCoverGenerationKey,
              !generationKey.isEmpty,
              let bundleIdentifier = session.bundleId,
              !bundleIdentifier.isEmpty,
              let sessionID = session.sessionIdentifier,
              !sessionID.isEmpty,
              UUID(uuidString: sessionID) != nil,
              let runtimeSocketPath =
                session.playCoverRuntimeSocketPath,
              !runtimeSocketPath.isEmpty,
              session.startedAt > 0,
              let runnerPID = session.runnerPid,
              runnerPID > 0,
              runnerPID <= Int(Int32.max) else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: PlayCover App generation "
                    + "identity is incomplete."
            )
        }
        let manifest = try fastVerify(
            appPath: appPath,
            expectedGenerationIdentity: nil
        ).manifest
        guard PlayCoverRuntimeClient.canonicalPath(
            manifest.preparedAppPath
        ) == PlayCoverRuntimeClient.canonicalPath(appPath),
            PlayCoverRuntimeClient.canonicalPath(
                manifest.executablePath
            ) == PlayCoverRuntimeClient.canonicalPath(
                executablePath
            ),
            manifest.generationKey == generationKey,
            manifest.bundleIdentifier == bundleIdentifier,
            session.udid
                == "playcover:\(manifest.bundleIdentifier)" else {
            throw PlayCoverBackendError.terminateFailed(
                "active session no longer matches the exact "
                    + "prepared App generation"
            )
        }
        let expectedSocket = try expectedRuntimeSocketPath(
            sessionID: sessionID,
            manifest: manifest
        )
        guard PlayCoverRuntimeClient.canonicalPath(
            runtimeSocketPath
        ) == PlayCoverRuntimeClient.canonicalPath(
            expectedSocket
        ) else {
            throw PlayCoverBackendError.terminateFailed(
                "active session Runtime socket does not match its "
                    + "exact sessionID and prepared generation"
            )
        }
        return manifest
    }

    static func validatePendingGeneration(
        _ record: PlayCoverPendingLaunchStore.Record
    ) throws -> PlayCoverPrepareManifest {
        let manifest = try fastVerify(
            appPath: record.appPath,
            expectedGenerationIdentity: nil
        ).manifest
        guard manifest.preparedAppPath == record.appPath,
              manifest.bundleIdentifier
                == record.bundleIdentifier,
              manifest.executablePath
                == record.executablePath,
              manifest.generationKey
                == record.generationKey else {
            throw PlayCoverBackendError.terminateFailed(
                "pending launch no longer matches its exact "
                    + "prepared App generation"
            )
        }
        return manifest
    }

    private static func fastVerify(
        appPath: String,
        expectedGenerationIdentity:
            PlayCoverGenerationIdentity?
    ) throws -> PlayCoverValidatedPreparedManifest {
        if let fastVerifyOverrideForTesting {
            return PlayCoverService
                .uncheckedValidatedPreparedManifestForTesting(
                    try fastVerifyOverrideForTesting(appPath),
                    expectedGenerationIdentity:
                        expectedGenerationIdentity
                )
        }
        return try PlayCoverService.fastVerifyEvidence(
            appPath: appPath,
            expectedGenerationIdentity:
                expectedGenerationIdentity
        )
    }

    private static func fastVerifiedLaunchCapability(
        appPath: String,
        expectedGenerationIdentity:
            PlayCoverGenerationIdentity?
    ) throws -> (
        evidence: PlayCoverValidatedPreparedManifest,
        currentGenerationToken:
            PlayCoverFastVerifiedGenerationToken?,
        capability: PlayCoverService.FastVerifiedLaunchCapability?
    ) {
        if fastVerifyOverrideForTesting != nil {
            let evidence = try fastVerify(
                appPath: appPath,
                expectedGenerationIdentity:
                    expectedGenerationIdentity
            )
            return (evidence, nil, nil)
        }
        let acquired =
            try PlayCoverService.acquireFastVerifiedLaunchCapability(
            appPath: appPath,
            expectedGenerationIdentity:
                expectedGenerationIdentity
        )
        return (
            acquired.evidence,
            acquired.currentGenerationToken,
            acquired.capability
        )
    }

    static func expectedRuntimeSocketPath(
        sessionID: String,
        manifest: PlayCoverPrepareManifest
    ) throws -> String {
        let app = URL(
            fileURLWithPath: manifest.preparedAppPath,
            isDirectory: true
        ).standardizedFileURL
        let generation = app.deletingLastPathComponent()
        let prepared = generation.deletingLastPathComponent()
        let playcover = prepared.deletingLastPathComponent()
        guard generation.lastPathComponent
                == manifest.generationKey,
              prepared.lastPathComponent == "prepared",
              playcover.lastPathComponent == "playcover" else {
            throw PlayCoverBackendError.terminateFailed(
                "prepared App path does not identify the immutable "
                    + "session generation"
            )
        }
        let socketToken = sessionID
            .unicodeScalars
            .filter {
                CharacterSet.alphanumerics.contains($0)
            }
            .map(String.init)
            .joined()
        guard !socketToken.isEmpty else {
            throw CLIParseError.invalidValue(
                "PlayCover sessionID cannot produce a runtime "
                    + "socket name."
            )
        }
        let socketName =
            "s-\(socketToken.prefix(32)).sock"
        // `run` may already have been removed when stop is recovering a
        // crashed session. Canonicalize the still-existing managed
        // `playcover` parent before appending the run/name components so the
        // `/tmp` -> `/private/tmp` alias cannot change socket identity merely
        // because the leaf directory disappeared.
        let canonicalPlaycoverPath: String
        #if canImport(Darwin)
        var buffer = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        if playcover.path.withCString({
            Darwin.realpath($0, &buffer)
        }) != nil {
            canonicalPlaycoverPath = String(cString: buffer)
        } else {
            canonicalPlaycoverPath = playcover.path
        }
        #else
        canonicalPlaycoverPath =
            playcover.resolvingSymlinksInPath().path
        #endif
        let expected = URL(
            fileURLWithPath: canonicalPlaycoverPath,
            isDirectory: true
        )
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent(socketName).path
        guard expected.utf8.count <= 103 else {
            throw CLIParseError.invalidValue(
                "IOS_USE_HOME is too long for a PlayCover Unix socket "
                    + "(\(expected.utf8.count) UTF-8 bytes; maximum 103)."
            )
        }
        return expected
    }

    private static func validateManagedGenerationPath(
        appPath: String,
        executablePath: String,
        generationKey: String,
        paths: IOSUsePaths
    ) throws {
        let validatedApp: String
        do {
            validatedApp =
                try PlayCoverManagedAppService
                    .validatedManagedPreparedAppPath(
                        appPath,
                        paths: paths
                    )
        } catch {
            throw PlayCoverBackendError.launchFailed(
                "last prepared App escapes the managed prepared "
                    + "root: \(error)"
            )
        }
        let root = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).standardizedFileURL.path
        let app = URL(
            fileURLWithPath: validatedApp,
            isDirectory: true
        )
        let lexicalExecutable = URL(
            fileURLWithPath: executablePath
        ).standardizedFileURL.path
        let canonicalExecutable =
            PlayCoverRuntimeClient.canonicalPath(executablePath)
        guard app.pathExtension == "app",
              app.deletingLastPathComponent().lastPathComponent
                == generationKey,
              app.deletingLastPathComponent()
                .deletingLastPathComponent().path == root,
              lexicalExecutable == canonicalExecutable,
              canonicalExecutable.hasPrefix(app.path + "/") else {
            throw PlayCoverBackendError.launchFailed(
                "last prepared App is not the recorded generation "
                    + "under this IOS_USE_HOME"
            )
        }
    }

    static func makeSessionInfo(
        from result: LaunchResult
    ) -> SessionService.Info {
        SessionService.Info(
            udid: "playcover:\(result.bundleIdentifier)",
            deviceName: result.productType,
            deviceVersion: "Mac Catalyst",
            deviceType: deviceType,
            runnerPid: Int(result.pid),
            startMode: deviceType,
            sessionIdentifier: result.sessionID,
            bundleId: result.bundleIdentifier,
            playCoverAppPath: result.appPath,
            playCoverExecutablePath: result.executablePath,
            playCoverGenerationKey: result.generationKey,
            playCoverRuntimeSocketPath:
                result.runtimeSocketPath,
            playCoverLogPath: result.logPath
        )
    }

    static func readPreparedReference(
        paths: IOSUsePaths
    ) throws -> PreparedReference? {
        #if canImport(Darwin)
        let playcoverDescriptor = Darwin.open(
            paths.playcover,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if playcoverDescriptor < 0, errno == ENOENT {
            return nil
        }
        guard playcoverDescriptor >= 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot open the PlayCover state directory without "
                    + "following links: errno \(errno)"
            )
        }
        defer { Darwin.close(playcoverDescriptor) }
        var directoryStatus = stat()
        guard fstat(playcoverDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o077 == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "PlayCover state directory is not owner-only"
            )
        }
        let filename = URL(
            fileURLWithPath: paths.playcoverLastPrepared
        ).lastPathComponent
        var referenceStatus = stat()
        if fstatat(
            playcoverDescriptor,
            filename,
            &referenceStatus,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT {
            return nil
        }
        #else
        guard FileManager.default.fileExists(
            atPath: paths.playcoverLastPrepared
        ) else {
            return nil
        }
        #endif
        do {
            #if canImport(Darwin)
            let data =
                try PlayCoverManagedAppService.readOwnedRegularFile(
                    parentDescriptor: playcoverDescriptor,
                    name: filename
                )
            #else
            let data = try Data(
                contentsOf: URL(
                    fileURLWithPath: paths.playcoverLastPrepared
                )
            )
            #endif
            let reference = try JSONDecoder().decode(
                PreparedReference.self,
                from: data
            )
            guard reference.schemaVersion == 3,
                  !reference.appPath.isEmpty,
                  !reference.bundleIdentifier.isEmpty,
                  !reference.executablePath.isEmpty,
                  !reference.generationKey.isEmpty else {
                throw PlayCoverBackendError.launchFailed(
                    "last prepared App record is incomplete or "
                        + "uses an unsupported schema"
                )
            }
            return reference
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.launchFailed(
                "cannot read \(paths.playcoverLastPrepared): "
                    + "\(error)"
            )
        }
    }

    private static func writeReference(
        _ reference: PreparedReference,
        paths: IOSUsePaths
    ) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: paths.playcover,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
            ]
            let data = try encoder.encode(reference)
            try data.write(
                to: URL(
                    fileURLWithPath:
                        paths.playcoverLastPrepared
                ),
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.playcoverLastPrepared
            )
        } catch {
            throw PlayCoverBackendError.prepareFailed(
                "cannot record the last prepared App: \(error)"
            )
        }
    }

    private static func ensureOwnerOnlyRunDirectory(
        _ path: String
    ) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if canImport(Darwin)
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT))
                == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              chmod(path, 0o700) == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "PlayCover runtime directory must be an "
                    + "owner-only directory"
            )
        }
        #endif
    }

    private static func processExecutablePath(
        _ pid: Int32
    ) -> String? {
        if let processExecutablePathOverrideForTesting {
            return processExecutablePathOverrideForTesting(pid)
        }
        return PlayCoverRuntimeClient.executablePath(for: pid)
    }

    static func processState(
        _ pid: Int32
    ) -> ProcessState {
        if let processStateOverrideForTesting {
            return processStateOverrideForTesting(pid)
        }
        if let executable = processExecutablePath(pid) {
            return .running(executablePath: executable)
        }
        let result = sendSignal(pid, 0)
        let errorNumber = errno
        if result != 0, errorNumber == ESRCH {
            return .missing
        }
        return .unverifiable(errno: errorNumber)
    }

    private static func processStartTimeMicroseconds(
        _ pid: Int32
    ) -> UInt64? {
        if let processStartTimeOverrideForTesting {
            return processStartTimeOverrideForTesting(pid)
        }
        return PlayCoverService.processStartTimeMicroseconds(
            for: pid
        )
    }

    private static func sendSignal(
        _ pid: Int32,
        _ signal: Int32
    ) -> Int32 {
        if let signalOverrideForTesting {
            return signalOverrideForTesting(pid, signal)
        }
        return Darwin.kill(pid, signal)
    }
}
