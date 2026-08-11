import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#endif
import PlayCoverUpstream

struct PlayCoverSlotLaunchIdentity: Equatable, Sendable {
    let sessionID: String
    let pid: Int32
    let bundleIdentifier: String
    let appPath: String
    let executablePath: String
    let installRevision: String
    let runtimeSocketPath: String
    let processStartTimeMicroseconds: UInt64?
    let hello: PlayCoverHello
}

struct PlayCoverSlotUnterminatedLaunchError:
    Error,
    CustomStringConvertible
{
    let identity: PlayCoverSlotLaunchIdentityCandidate
    let slot: PlayCoverInstalledSlot
    let sessionID: String
    let runtimeSocketPath: String
    let originalError: String
    let rollbackError: String

    var description: String {
        "Mac launch failed and exact process \(identity.pid) could not be "
            + "confirmed stopped. Original error: \(originalError). "
            + "Rollback error: \(rollbackError)"
    }
}

struct PlayCoverSlotLaunchIdentityCandidate: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case workspaceCallback
        case authenticatedRuntime
    }

    let pid: Int32
    let bundleIdentifier: String
    let bundleURLPath: String
    let executablePath: String
    let processStartTimeMicroseconds: UInt64?
    let source: Source
}

enum PlayCoverSlotLauncher {
    #if canImport(AppKit)
    static var workspaceOpenOverrideForTesting: ((
        URL,
        NSWorkspace.OpenConfiguration,
        @escaping (NSRunningApplication?, Error?) -> Void
    ) -> Void)?
    static var workspaceSubmissionObserverForTesting: ((
        URL,
        [String: String]
    ) -> Void)?
    #endif
    static var processStateOverrideForTesting:
        ((Int32) -> PlayCoverSessionService.ProcessState)?
    static var signalOverrideForTesting: ((Int32, Int32) -> Int32)?
    static var processStartTimeOverrideForTesting: ((Int32) -> UInt64?)?
    static var authenticateOverrideForTesting: ((
        Int32,
        PlayCoverInstalledSlot,
        PlayCoverLaunchingStore.Record,
        PlayCoverStdioLogIdentity?
    ) throws -> PlayCoverHello)?

    static func launch(
        slot: PlayCoverInstalledSlot,
        sessionID: String,
        runtimeSocketPath: String,
        paths: IOSUsePaths,
        stdioLog: PlayCoverStdioLogIdentity?,
        timeout: Double
    ) throws -> PlayCoverSlotLaunchIdentity {
        guard UUID(uuidString: sessionID) != nil,
              timeout.isFinite,
              timeout > 0 else {
            throw PlayCoverBackendError.launchFailed(
                "Mac session identity or timeout is invalid"
            )
        }
        let expectedSocket = try paths.macRuntimeSocketPath(
            sessionID: sessionID
        )
        guard PlayCoverRuntimeClient.canonicalPath(runtimeSocketPath)
                == PlayCoverRuntimeClient.canonicalPath(expectedSocket) else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket path does not match the launch session"
            )
        }
        try PlayCoverService.validateFreshRuntimeSocketPath(
            runtimeSocketPath
        )
        let record = PlayCoverLaunchingStore.Record(
            sessionID: sessionID,
            runtimeSocketPath: runtimeSocketPath,
            bundleIdentifier: slot.metadata.bundleIdentifier,
            executableRelativePath:
                slot.metadata.executableRelativePath,
            submittedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            logPath: stdioLog?.path
        )
        try PlayCoverLaunchingStore.create(record, paths: paths)
        var submitted = false
        var owned: PlayCoverSlotLaunchIdentityCandidate?
        do {
            try PlayCoverHeadlessKeyCover.unlock(
                bundleIdentifier: slot.metadata.bundleIdentifier,
                playChainDirectory: URL(
                    fileURLWithPath: paths.playcoverPlayChain,
                    isDirectory: true
                )
            )
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            owned = try submitAndResolve(
                slot: slot,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath,
                playChainPath: paths.playcoverPlayChain,
                stdioLog: stdioLog,
                deadline: deadline,
                submitted: &submitted
            )
            guard let owned else {
                throw PlayCoverBackendError.launchFailed(
                    "NSWorkspace did not expose a matching App process"
                )
            }
            if let stdioLog {
                try PlayCoverStdioLogService.sendBootstrap(
                    stdioLog,
                    sessionID: sessionID,
                    runtimeSocketPath: runtimeSocketPath,
                    expectedPID: owned.pid,
                    expectedExecutablePath: slot.executablePath,
                    deadline: deadline
                )
            }
            var lastError: Error?
            while ProcessInfo.processInfo.systemUptime < deadline {
                do {
                    let remaining = deadline
                        - ProcessInfo.processInfo.systemUptime
                    let payload = try runtimeClient(
                        identity: owned,
                        slot: slot,
                        sessionID: sessionID,
                        runtimeSocketPath: runtimeSocketPath,
                        timeout: min(0.5, max(0.05, remaining))
                    ).hello()
                    let hello = try validateHello(
                        payload,
                        slot: slot,
                        sessionID: sessionID,
                        pid: owned.pid,
                        stdioLog: stdioLog
                    )
                    return PlayCoverSlotLaunchIdentity(
                        sessionID: sessionID,
                        pid: owned.pid,
                        bundleIdentifier:
                            slot.metadata.bundleIdentifier,
                        appPath: slot.appPath,
                        executablePath: slot.executablePath,
                        installRevision:
                            slot.metadata.installRevision,
                        runtimeSocketPath: runtimeSocketPath,
                        processStartTimeMicroseconds:
                            owned.processStartTimeMicroseconds,
                        hello: hello
                    )
                } catch {
                    if PlayCoverService.runtimeHelloFailureIsTerminal(error) {
                        throw error
                    }
                    lastError = error
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            throw PlayCoverBackendError.launchTimedOut(
                "no verified Runtime hello within \(timeout) seconds"
                    + (lastError.map { "; last error: \($0)" } ?? "")
            )
        } catch {
            if let owned {
                do {
                    try terminateExact(owned, slot: slot)
                    try PlayCoverLaunchingStore.remove(
                        sessionID: sessionID,
                        paths: paths
                    )
                } catch let rollbackError {
                    throw PlayCoverSlotUnterminatedLaunchError(
                        identity: owned,
                        slot: slot,
                        sessionID: sessionID,
                        runtimeSocketPath: runtimeSocketPath,
                        originalError: String(describing: error),
                        rollbackError: String(describing: rollbackError)
                    )
                }
            } else if !submitted {
                try? PlayCoverLaunchingStore.remove(
                    sessionID: sessionID,
                    paths: paths
                )
            }
            if owned != nil || !submitted {
                try? PlayCoverHeadlessKeyCover.lock(
                    bundleIdentifier: slot.metadata.bundleIdentifier,
                    playChainDirectory: URL(
                        fileURLWithPath: paths.playcoverPlayChain,
                        isDirectory: true
                    )
                )
            }
            throw error
        }
    }

    static func authenticate(
        pid: Int32,
        slot: PlayCoverInstalledSlot,
        record: PlayCoverLaunchingStore.Record,
        stdioLog: PlayCoverStdioLogIdentity? = nil,
        timeout: Double = 0.75
    ) throws -> PlayCoverHello {
        if let authenticateOverrideForTesting {
            return try authenticateOverrideForTesting(
                pid,
                slot,
                record,
                stdioLog
            )
        }
        let candidate = PlayCoverSlotLaunchIdentityCandidate(
            pid: pid,
            bundleIdentifier: slot.metadata.bundleIdentifier,
            bundleURLPath: slot.appPath,
            executablePath: slot.executablePath,
            processStartTimeMicroseconds: processStartTime(pid),
            source: .authenticatedRuntime
        )
        let payload = try runtimeClient(
            identity: candidate,
            slot: slot,
            sessionID: record.sessionID,
            runtimeSocketPath: record.runtimeSocketPath,
            timeout: timeout
        ).hello()
        return try validateHello(
            payload,
            slot: slot,
            sessionID: record.sessionID,
            pid: pid,
            stdioLog: stdioLog
        )
    }

    private static func submitAndResolve(
        slot: PlayCoverInstalledSlot,
        sessionID: String,
        runtimeSocketPath: String,
        playChainPath: String,
        stdioLog: PlayCoverStdioLogIdentity?,
        deadline: TimeInterval,
        submitted: inout Bool
    ) throws -> PlayCoverSlotLaunchIdentityCandidate {
        #if canImport(AppKit)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = true
        configuration.createsNewApplicationInstance = false
        configuration.environment = launchEnvironment(
            sessionID: sessionID,
            runtimeSocketPath: runtimeSocketPath,
            installRevision: slot.metadata.installRevision,
            playChainPath: playChainPath,
            stdioLog: stdioLog
        )
        let existingPIDs = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: slot.metadata.bundleIdentifier
            ).filter { !$0.isTerminated }.map(\.processIdentifier)
        )
        let box = CompletionBox()
        let semaphore = DispatchSemaphore(value: 0)
        let completion: (NSRunningApplication?, Error?) -> Void = {
            application,
            error in
            if let application,
               !application.isTerminated,
               !existingPIDs.contains(application.processIdentifier),
               let bundleIdentifier = application.bundleIdentifier,
               let bundlePath = application.bundleURL?.path,
               let executablePath = application.executableURL?.path,
               matches(
                pid: application.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                bundlePath: bundlePath,
                executablePath: executablePath,
                slot: slot
               ) {
                box.resolve(.success(
                    PlayCoverSlotLaunchIdentityCandidate(
                        pid: application.processIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        bundleURLPath: bundlePath,
                        executablePath: executablePath,
                        processStartTimeMicroseconds:
                            processStartTime(
                                application.processIdentifier
                            ),
                        source: .workspaceCallback
                    )
                ))
            } else {
                box.resolve(.failure(
                    error ?? PlayCoverBackendError.launchFailed(
                        "NSWorkspace returned a pre-existing or mismatched App"
                    )
                ))
            }
            semaphore.signal()
        }
        let appURL = URL(
            fileURLWithPath: slot.appPath,
            isDirectory: true
        )
        workspaceSubmissionObserverForTesting?(
            appURL,
            configuration.environment
        )
        submitted = true
        if let workspaceOpenOverrideForTesting {
            workspaceOpenOverrideForTesting(
                appURL,
                configuration,
                completion
            )
        } else {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
        #if DEBUG && canImport(Darwin)
        PlayCoverLaunchCrashCut.hit(.afterOpenReturned)
        #endif
        var callbackError: Error?
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let result = box.value {
                switch result {
                case .success(let identity):
                    return identity
                case .failure(let error):
                    callbackError = error
                }
            }
            let candidates = NSRunningApplication.runningApplications(
                withBundleIdentifier: slot.metadata.bundleIdentifier
            ).filter { !$0.isTerminated }.compactMap {
                application -> PlayCoverSlotLaunchIdentityCandidate? in
                guard !existingPIDs.contains(application.processIdentifier),
                      let bundleIdentifier = application.bundleIdentifier,
                      let bundlePath = application.bundleURL?.path,
                      let executablePath = application.executableURL?.path,
                      matches(
                        pid: application.processIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        bundlePath: bundlePath,
                        executablePath: executablePath,
                        slot: slot
                      ) else {
                    return nil
                }
                return PlayCoverSlotLaunchIdentityCandidate(
                    pid: application.processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    bundleURLPath: bundlePath,
                    executablePath: executablePath,
                    processStartTimeMicroseconds:
                        processStartTime(application.processIdentifier),
                    source: .authenticatedRuntime
                )
            }.filter {
                runtimePingAuthenticates(
                    $0,
                    slot: slot,
                    sessionID: sessionID,
                    runtimeSocketPath: runtimeSocketPath,
                    deadline: deadline
                )
            }
            guard candidates.count <= 1 else {
                throw PlayCoverBackendError.launchFailed(
                    "multiple App processes authenticated one launch session"
                )
            }
            if let identity = candidates.first {
                return identity
            }
            if Thread.isMainThread {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.05)
                )
            } else {
                _ = semaphore.wait(timeout: .now() + 0.05)
            }
        }
        throw PlayCoverBackendError.launchFailed(
            "NSWorkspace did not expose the fixed-slot App"
                + (callbackError.map { "; callback error: \($0)" } ?? "")
        )
        #else
        throw PlayCoverBackendError.launchFailed(
            "Mac launch is supported only on macOS"
        )
        #endif
    }

    private static func runtimePingAuthenticates(
        _ identity: PlayCoverSlotLaunchIdentityCandidate,
        slot: PlayCoverInstalledSlot,
        sessionID: String,
        runtimeSocketPath: String,
        deadline: TimeInterval
    ) -> Bool {
        do {
            let remaining = deadline
                - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            let payload = try runtimeClient(
                identity: identity,
                slot: slot,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath,
                timeout: min(0.05, remaining)
            ).ping()
            return payload.pong
                && payload.pid == identity.pid
                && payload.bundleIdentifier
                    == slot.metadata.bundleIdentifier
                && payload.executablePath.map {
                    PlayCoverRuntimeClient.canonicalPath($0)
                        == PlayCoverRuntimeClient.canonicalPath(
                            slot.executablePath
                        )
                } == true
        } catch {
            return false
        }
    }

    private static func runtimeClient(
        identity: PlayCoverSlotLaunchIdentityCandidate,
        slot: PlayCoverInstalledSlot,
        sessionID: String,
        runtimeSocketPath: String,
        timeout: Double
    ) -> PlayCoverRuntimeClient {
        PlayCoverRuntimeClient(
            socketPath: runtimeSocketPath,
            sessionID: sessionID,
            expectedPID: identity.pid,
            expectedBundleIdentifier: slot.metadata.bundleIdentifier,
            expectedExecutablePath: slot.executablePath,
            timeoutSeconds: timeout
        )
    }

    private static func validateHello(
        _ payload: PlayCoverRuntimeHelloPayload,
        slot: PlayCoverInstalledSlot,
        sessionID: String,
        pid: Int32,
        stdioLog: PlayCoverStdioLogIdentity?
    ) throws -> PlayCoverHello {
        try PlayCoverService.validateStdio(payload.stdio, expected: stdioLog)
        guard payload.pid == pid,
              payload.bundleIdentifier == slot.metadata.bundleIdentifier,
              payload.installRevision == slot.metadata.installRevision,
              PlayCoverRuntimeClient.canonicalPath(payload.executablePath)
                == PlayCoverRuntimeClient.canonicalPath(
                    slot.executablePath
                ) else {
            throw PlayCoverBackendError.verificationFailed(
                "authenticated Runtime hello does not match the current slot"
            )
        }
        guard payload.controlStage == "ready",
              payload.controlFailure == nil else {
            throw PlayCoverBackendError.verificationFailed(
                "authenticated Runtime control plane is not ready"
            )
        }
        let expectedCapabilities = Set([
            "hello", "ping", "diagnostics", "screenshot", "dom", "uiTree",
            "waitFor", "tap", "longPress", "swipe", "input",
            "dismissAlert", "dismissAlertByLabel", "debug",
        ])
        guard Set(payload.capabilities) == expectedCapabilities else {
            throw PlayCoverBackendError.verificationFailed(
                "authenticated Runtime capabilities are incomplete"
            )
        }
        return PlayCoverHello(
            sessionID: sessionID,
            pid: payload.pid,
            bundleIdentifier: payload.bundleIdentifier,
            executablePath: payload.executablePath,
            installRevision: payload.installRevision,
            controlStage: payload.controlStage,
            uiState: payload.uiState.state,
            uiStage: payload.uiState.stage,
            uiFailure: payload.uiState.failure,
            capabilities: payload.capabilities
        )
    }

    private static func matches(
        pid: Int32,
        bundleIdentifier: String,
        bundlePath: String,
        executablePath: String,
        slot: PlayCoverInstalledSlot
    ) -> Bool {
        pid > 0
            && bundleIdentifier == slot.metadata.bundleIdentifier
            && PlayCoverRuntimeClient.canonicalPath(bundlePath)
                == PlayCoverRuntimeClient.canonicalPath(slot.appPath)
            && PlayCoverRuntimeClient.canonicalPath(executablePath)
                == PlayCoverRuntimeClient.canonicalPath(slot.executablePath)
    }

    private static func launchEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment,
        sessionID: String,
        runtimeSocketPath: String,
        installRevision: String,
        playChainPath: String,
        stdioLog: PlayCoverStdioLogIdentity?
    ) -> [String: String] {
        var result = source.mapValues { _ in "" }
        var allowed = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in [
            "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "TMPDIR",
            "USER", "__CF_USER_TEXT_ENCODING",
        ] {
            if let value = source[key], !value.isEmpty {
                allowed[key] = value
            }
        }
        allowed["IOS_USE_PLAY_SESSION_ID"] = sessionID
        allowed["IOS_USE_PLAY_RUNTIME_SOCKET"] = runtimeSocketPath
        allowed["IOS_USE_PLAY_INSTALL_REVISION"] = installRevision
        allowed["IOS_USE_PLAYCHAIN_ROOT"] = playChainPath
        if stdioLog != nil {
            allowed["IOS_USE_PLAY_STDIO_LOG"] = "1"
        }
        result.merge(allowed) { _, allowed in allowed }
        return result
    }

    #if DEBUG
    static func launchEnvironmentForTesting(
        source: [String: String],
        sessionID: String,
        runtimeSocketPath: String,
        installRevision: String,
        playChainPath: String
    ) -> [String: String] {
        launchEnvironment(
            source: source,
            sessionID: sessionID,
            runtimeSocketPath: runtimeSocketPath,
            installRevision: installRevision,
            playChainPath: playChainPath,
            stdioLog: nil
        )
    }
    #endif

    static func terminateExact(
        _ identity: PlayCoverSlotLaunchIdentityCandidate,
        slot: PlayCoverInstalledSlot
    ) throws {
        let pid = identity.pid
        guard let expectedBirth = identity.processStartTimeMicroseconds else {
            throw PlayCoverBackendError.terminateFailed(
                "cannot terminate launch without a stable process birth token"
            )
        }
        switch processState(pid) {
        case .missing:
            return
        case .unverifiable(let errorNumber):
            throw PlayCoverBackendError.terminateFailed(
                "cannot verify launched PID \(pid): errno \(errorNumber)"
            )
        case .running(let executablePath):
            guard PlayCoverRuntimeClient.canonicalPath(executablePath)
                    == PlayCoverRuntimeClient.canonicalPath(
                        slot.executablePath
                    ),
                  processStartTime(pid) == expectedBirth else {
                throw PlayCoverBackendError.terminateFailed(
                    "launched PID identity changed before rollback"
                )
            }
        }
        #if canImport(Darwin)
        let result = sendSignal(pid, SIGTERM)
        let signalError = errno
        if result != 0, signalError == ESRCH { return }
        guard result == 0 else {
            throw PlayCoverBackendError.terminateFailed(
                "rollback SIGTERM failed: errno \(signalError)"
            )
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            switch processState(pid) {
            case .missing:
                return
            case .running(let executablePath):
                if PlayCoverRuntimeClient.canonicalPath(executablePath)
                    != PlayCoverRuntimeClient.canonicalPath(
                        slot.executablePath
                    ) || processStartTime(pid) != expectedBirth {
                    return
                }
            case .unverifiable(let errorNumber):
                if errorNumber == ESRCH { return }
                throw PlayCoverBackendError.terminateFailed(
                    "cannot verify rollback: errno \(errorNumber)"
                )
            }
            usleep(50_000)
        }
        throw PlayCoverBackendError.terminateFailed(
            "launched PID \(pid) did not exit after SIGTERM"
        )
        #endif
    }

    private static func processState(
        _ pid: Int32
    ) -> PlayCoverSessionService.ProcessState {
        if let processStateOverrideForTesting {
            return processStateOverrideForTesting(pid)
        }
        if let executable = PlayCoverRuntimeClient.executablePath(for: pid) {
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

    private static func processStartTime(_ pid: Int32) -> UInt64? {
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

    #if canImport(AppKit)
    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<PlayCoverSlotLaunchIdentityCandidate, Error>?

        var value: Result<PlayCoverSlotLaunchIdentityCandidate, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func resolve(
            _ result: Result<PlayCoverSlotLaunchIdentityCandidate, Error>
        ) {
            lock.lock()
            defer { lock.unlock() }
            if stored == nil { stored = result }
        }
    }
    #endif
}
