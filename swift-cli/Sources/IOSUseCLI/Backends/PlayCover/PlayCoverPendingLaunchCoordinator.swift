import Foundation
import PlayCoverUpstream

enum PlayCoverPendingLaunchCoordinator {
    struct RecoveryResult: Equatable, Sendable {
        let sessionID: String
        let pid: Int32?
    }

    struct Snapshot: Equatable, Sendable {
        let status: String
        let phase: PlayCoverPendingLaunchStore.Phase
        let sessionID: String
        let generationKey: String
        let bundleIdentifier: String
        let ownerPID: Int32?
        let reason: String
    }

    static func readOnlySnapshot(
        paths: IOSUsePaths
    ) throws -> Snapshot? {
        guard let record = try PlayCoverPendingLaunchStore.load(
            paths: paths
        ) else {
            return nil
        }
        _ = try PlayCoverSessionService
            .validatePendingGeneration(record)
        if record.phase == .confirmedStopped {
            let missingDriverHandoff =
                record.cleanupProof == .driverLockRetired
            return Snapshot(
                status: missingDriverHandoff
                    ? "unresolvedOpen"
                    : "launchPending",
                phase: record.phase,
                sessionID: record.sessionID,
                generationKey: record.generationKey,
                bundleIdentifier: record.bundleIdentifier,
                ownerPID: record.owner?.pid,
                reason: missingDriverHandoff
                    ? "driver.lock handoff is durable, but "
                        + "driver.lock is missing"
                    : "durable cleanup is pending "
                        + "(\(record.cleanupProof?.rawValue ?? "unknown"))"
            )
        }
        let decision = try evaluate(
            record,
            authenticateCandidates: false
        )
        return Snapshot(
            status: decision.isUnresolved
                ? "unresolvedOpen"
                : "launchPending",
            phase: record.phase,
            sessionID: record.sessionID,
            generationKey: record.generationKey,
            bundleIdentifier: record.bundleIdentifier,
            ownerPID: record.owner?.pid,
            reason: decision.reason
        )
    }

    static func recoverBeforeStart(
        paths: IOSUsePaths
    ) throws {
        guard let record = try PlayCoverPendingLaunchStore.load(
            paths: paths
        ) else {
            return
        }
        if let driver = try SessionService
            .readDriverLockInfo(paths: paths) {
            _ = try reconcilePendingWithDriverLock(
                record,
                driver: driver,
                paths: paths
            )
            return
        }
        _ = try recoverPendingWithoutDriverLock(
            paths: paths
        )
    }

    @discardableResult
    static func stopPendingWithoutDriverLock(
        paths: IOSUsePaths
    ) throws -> RecoveryResult? {
        try recoverPendingWithoutDriverLock(paths: paths)
    }

    @discardableResult
    static func reconcilePendingWithDriverLock(
        _ driver: SessionService.Info,
        paths: IOSUsePaths
    ) throws -> RecoveryResult? {
        guard let record = try PlayCoverPendingLaunchStore.load(
            paths: paths
        ) else {
            return nil
        }
        return try reconcilePendingWithDriverLock(
            record,
            driver: driver,
            paths: paths
        )
    }

    static func rollbackAfterDriverCommitFailure(
        result: PlayCoverSessionService.LaunchResult,
        paths: IOSUsePaths
    ) throws {
        guard result.usesPendingLaunchJournal else {
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "commit rollback requires a pending launch "
                    + "authority"
            )
        }
        guard let record = try PlayCoverPendingLaunchStore.load(
            paths: paths
        ) else {
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "exact rollback has no pending launch authority"
            )
        }
        try validate(record, matches: result)
        guard record.phase == .owned
                || record.phase == .driverLockCommitted else {
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "exact rollback lacks durable owned-process "
                    + "authority"
            )
        }
        let manifest = try PlayCoverSessionService
            .validatePendingGeneration(record)
        try PlayCoverService.terminateFailedLaunch(
            identity: launchedIdentity(record),
            manifest: manifest
        )
        let confirmed = try PlayCoverPendingLaunchStore
            .markConfirmedStopped(
                sessionID: result.sessionID,
                cleanupProof: .stoppedExactOwner,
                paths: paths
            )
        try DriverSessionStore.removeDriverLock(paths: paths)
        try finishCleanup(
            confirmed,
            manifest: manifest,
            paths: paths
        )
    }

    private static func reconcilePendingWithDriverLock(
        _ record: PlayCoverPendingLaunchStore.Record,
        driver: SessionService.Info,
        paths: IOSUsePaths
    ) throws -> RecoveryResult? {
        guard driver.deviceType
                == PlayCoverSessionService.deviceType else {
            throw CLIParseError.invalidValue(
                "A PlayCover pending launch exists beside a "
                    + "different active driver.lock; refusing "
                    + "to mutate either authority."
            )
        }
        try validate(record, matches: driver)
        if record.phase == .confirmedStopped,
           isStoppedOwnerProof(record.cleanupProof) {
            let manifest = try PlayCoverSessionService
                .validatePendingGeneration(record)
            try DriverSessionStore.removeDriverLock(paths: paths)
            try finishCleanup(
                record,
                manifest: manifest,
                paths: paths
            )
            return RecoveryResult(
                sessionID: record.sessionID,
                pid: record.owner?.pid
            )
        }
        if record.phase == .driverLockCommitted
            || (
                record.phase == .confirmedStopped
                    && record.cleanupProof == .driverLockRetired
            ) {
            try PlayCoverSessionService
                .retirePendingLaunchJournalAfterDriverCommit(
                    session: driver,
                    paths: paths
                )
            return nil
        }
        let decision = try evaluate(
            record,
            authenticateCandidates: false
        )
        switch decision {
        case .ownedProcessLive:
            try PlayCoverSessionService
                .retirePendingLaunchJournalAfterDriverCommit(
                    session: driver,
                    paths: paths
                )
            return nil
        case .safeCleanup(let proof):
            let confirmed:
                PlayCoverPendingLaunchStore.Record
            if record.phase == .confirmedStopped,
               record.cleanupProof == .driverLockRetired {
                confirmed = record
            } else {
                confirmed = try PlayCoverPendingLaunchStore
                    .markConfirmedStopped(
                        sessionID: record.sessionID,
                        cleanupProof: storeCleanupProof(proof),
                        paths: paths
                    )
            }
            let manifest = try PlayCoverSessionService
                .validatePendingGeneration(confirmed)
            try DriverSessionStore.removeDriverLock(paths: paths)
            try finishCleanup(
                confirmed,
                manifest: manifest,
                paths: paths
            )
            return RecoveryResult(
                sessionID: confirmed.sessionID,
                pid: confirmed.owner?.pid
            )
        case .authenticatedOwner:
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "driver.lock handoff unexpectedly lacked "
                    + "durable ownership"
            )
        case .unresolved(let reason):
            throw CLIParseError.invalidValue(
                "PlayCover driver.lock handoff is unresolved: "
                    + "\(reason). The driver.lock, pending journal, "
                    + "facade, and generation were preserved."
            )
        }
    }

    private static func isStoppedOwnerProof(
        _ proof: PlayCoverPendingLaunchStore.CleanupProof?
    ) -> Bool {
        switch proof {
        case .ownedProcessExited, .ownedPIDReused,
             .stoppedExactOwner:
            return true
        case .none, .neverSubmitted,
             .terminalCallbackAndEmptyCensus,
             .newBootAndEmptyCensus, .driverLockRetired:
            return false
        }
    }

    private static func launchedIdentity(
        _ record: PlayCoverPendingLaunchStore.Record
    ) throws -> PlayCoverService.LaunchedApplicationIdentity {
        guard let owner = record.owner else {
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "pending launch has no durable process owner"
            )
        }
        let source:
            PlayCoverService.LaunchIdentitySource
        switch owner.source {
        case .workspaceCallback:
            source = .workspaceCallback
        case .authenticatedRuntime:
            source = .authenticatedRuntime
        }
        return PlayCoverService.LaunchedApplicationIdentity(
            pid: owner.pid,
            bundleIdentifier: record.bundleIdentifier,
            bundleURLPath: record.aliasPath,
            executablePath: record.executablePath,
            processStartTimeMicroseconds:
                owner.processBirthMicroseconds,
            source: source
        )
    }

    private static func recoverPendingWithoutDriverLock(
        paths: IOSUsePaths
    ) throws -> RecoveryResult? {
        guard var record = try PlayCoverPendingLaunchStore.load(
            paths: paths
        ) else {
            return nil
        }
        let manifest = try PlayCoverSessionService
            .validatePendingGeneration(record)
        if record.phase == .confirmedStopped {
            guard record.cleanupProof != .driverLockRetired else {
                throw CLIParseError.invalidValue(
                    "Pending PlayCover launch was handed to a "
                        + "driver.lock that is now missing; refusing "
                        + "to discard recovery evidence."
                )
            }
            try finishCleanup(
                record,
                manifest: manifest,
                paths: paths
            )
            return RecoveryResult(
                sessionID: record.sessionID,
                pid: record.owner?.pid
            )
        }

        let decision = try evaluate(
            record,
            authenticateCandidates: true
        )
        switch decision {
        case .safeCleanup(let proof):
            record = try PlayCoverPendingLaunchStore
                .markConfirmedStopped(
                    sessionID: record.sessionID,
                    cleanupProof: storeCleanupProof(proof),
                    paths: paths
                )
            try finishCleanup(
                record,
                manifest: manifest,
                paths: paths
            )
            return RecoveryResult(
                sessionID: record.sessionID,
                pid: record.owner?.pid
            )
        case .authenticatedOwner(let owner):
            record = try PlayCoverPendingLaunchStore.markOwned(
                sessionID: record.sessionID,
                owner: storeOwner(owner),
                callbackSucceeded: false,
                paths: paths
            )
            let pid = try terminateAndCleanup(
                record,
                manifest: manifest,
                paths: paths
            )
            return RecoveryResult(
                sessionID: record.sessionID,
                pid: pid
            )
        case .ownedProcessLive:
            let pid = try terminateAndCleanup(
                record,
                manifest: manifest,
                paths: paths
            )
            return RecoveryResult(
                sessionID: record.sessionID,
                pid: pid
            )
        case .unresolved(let reason):
            throw CLIParseError.invalidValue(
                "PlayCover launch is unresolved: \(reason). "
                    + "The pending journal, facade, and generation "
                    + "were preserved."
            )
        }
    }

    private static func terminateAndCleanup(
        _ record: PlayCoverPendingLaunchStore.Record,
        manifest: PlayCoverPrepareManifest,
        paths: IOSUsePaths
    ) throws -> Int32 {
        guard let owner = record.owner else {
            throw CLIParseError.invalidValue(
                "Pending PlayCover owner disappeared before stop."
            )
        }
        try PlayCoverService.terminateFailedLaunch(
            identity: launchedIdentity(record),
            manifest: manifest
        )
        let confirmed = try PlayCoverPendingLaunchStore
            .markConfirmedStopped(
                sessionID: record.sessionID,
                cleanupProof: .stoppedExactOwner,
                paths: paths
            )
        try finishCleanup(
            confirmed,
            manifest: manifest,
            paths: paths
        )
        return owner.pid
    }

    private static func finishCleanup(
        _ record: PlayCoverPendingLaunchStore.Record,
        manifest: PlayCoverPrepareManifest,
        paths: IOSUsePaths
    ) throws {
        do {
            try PlayCoverService.lockKeyCover(for: manifest)
            try PlayCoverService.removeSessionLaunchAlias(
                pendingLaunch: record,
                manifest: manifest
            )
            try PlayCoverPendingLaunchStore.removeConfirmed(
                sessionID: record.sessionID,
                paths: paths
            )
        } catch {
            throw PlayCoverSessionCleanupError(
                operation: .stop,
                cleanupError: error,
                originalError: nil,
                logPath: nil
            )
        }
    }

    private static func validate(
        _ record: PlayCoverPendingLaunchStore.Record,
        matches result: PlayCoverSessionService.LaunchResult
    ) throws {
        guard record.sessionID == result.sessionID,
              record.owner?.pid == result.pid,
              record.appPath == result.appPath,
              record.bundleIdentifier == result.bundleIdentifier,
              record.executablePath == result.executablePath,
              record.generationKey == result.generationKey,
              record.runtimeSocketPath
                == result.runtimeSocketPath else {
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "launch result does not match pending authority"
            )
        }
    }

    private static func validate(
        _ record: PlayCoverPendingLaunchStore.Record,
        matches driver: SessionService.Info
    ) throws {
        guard let sessionID = driver.sessionIdentifier,
              let pid = driver.runnerPid,
              let appPath = driver.playCoverAppPath,
              let bundleIdentifier = driver.bundleId,
              let executablePath =
                driver.playCoverExecutablePath,
              let generationKey =
                driver.playCoverGenerationKey,
              let runtimeSocketPath =
                driver.playCoverRuntimeSocketPath,
              record.sessionID == sessionID,
              record.owner?.pid == Int32(exactly: pid),
              record.appPath == appPath,
              record.bundleIdentifier == bundleIdentifier,
              record.executablePath == executablePath,
              record.generationKey == generationKey,
              record.runtimeSocketPath == runtimeSocketPath else {
            throw PlayCoverPendingLaunchStoreError(
                message:
                    "driver.lock does not match pending authority"
            )
        }
    }

    private static func evaluate(
        _ record: PlayCoverPendingLaunchStore.Record,
        authenticateCandidates: Bool
    ) throws -> PlayCoverPendingLaunchRecovery.Decision {
        let evidence = recoveryEvidence(record)
        if let owner = evidence.owner {
            return PlayCoverPendingLaunchRecovery.decide(
                evidence: evidence,
                currentBootSessionUUID:
                    record.submissionBootSessionUUID ?? "",
                census: .complete([]),
                ownedProcessState:
                    PlayCoverPendingLaunchRecovery
                        .ownedProcessState(pid: owner.pid),
                authenticatedOwner: nil
            )
        }
        guard record.submissionBootSessionUUID != nil else {
            return .safeCleanup(.neverSubmitted)
        }
        let observation = try PlayCoverPendingLaunchRecovery
            .systemObservation(
                executablePath: record.executablePath
            )
        var authenticatedOwner:
            PlayCoverPendingLaunchRecovery.Owner?
        if authenticateCandidates,
           case .complete = observation.census {
            switch PlayCoverPendingLaunchRecovery
                .authenticateCandidateOwner(
                    evidence: evidence,
                    census: observation.census
                ) {
            case .success(let owner):
                authenticatedOwner = owner
            case .failure(let error):
                throw error
            }
        }
        return PlayCoverPendingLaunchRecovery.decide(
            evidence: evidence,
            currentBootSessionUUID:
                observation.bootSessionUUID,
            census: observation.census,
            ownedProcessState: nil,
            authenticatedOwner: authenticatedOwner
        )
    }

    private static func recoveryEvidence(
        _ record: PlayCoverPendingLaunchStore.Record
    ) -> PlayCoverPendingLaunchRecovery.Evidence {
        PlayCoverPendingLaunchRecovery.Evidence(
            sessionID: record.sessionID,
            runtimeSocketPath: record.runtimeSocketPath,
            bundleIdentifier: record.bundleIdentifier,
            executablePath: record.executablePath,
            submissionBootSessionUUID:
                record.submissionBootSessionUUID,
            terminalCallbackRecorded:
                record.terminalCallback != nil,
            owner: record.owner.map {
                PlayCoverPendingLaunchRecovery.Owner(
                    pid: $0.pid,
                    processBirthMicroseconds:
                        $0.processBirthMicroseconds,
                    source: $0.source == .workspaceCallback
                        ? .workspaceCallback
                        : .authenticatedRuntime
                )
            }
        )
    }

    private static func storeOwner(
        _ owner: PlayCoverPendingLaunchRecovery.Owner
    ) -> PlayCoverPendingLaunchStore.Owner {
        PlayCoverPendingLaunchStore.Owner(
            pid: owner.pid,
            processBirthMicroseconds:
                owner.processBirthMicroseconds,
            source: owner.source == .workspaceCallback
                ? .workspaceCallback
                : .authenticatedRuntime
        )
    }

    private static func storeCleanupProof(
        _ proof: PlayCoverPendingLaunchRecovery.CleanupProof
    ) -> PlayCoverPendingLaunchStore.CleanupProof {
        switch proof {
        case .neverSubmitted:
            return .neverSubmitted
        case .ownedProcessExited:
            return .ownedProcessExited
        case .ownedPIDReused:
            return .ownedPIDReused
        case .terminalCallbackAndEmptyCensus:
            return .terminalCallbackAndEmptyCensus
        case .newBootAndEmptyCensus:
            return .newBootAndEmptyCensus
        }
    }
}

private extension PlayCoverPendingLaunchRecovery.Decision {
    var isUnresolved: Bool {
        if case .unresolved = self {
            return true
        }
        return false
    }

    var reason: String {
        switch self {
        case .safeCleanup(let proof):
            return "safe cleanup pending: \(proof.rawValue)"
        case .authenticatedOwner(let owner):
            return "authenticated pending owner pid \(owner.pid)"
        case .ownedProcessLive(let owner):
            return "durable pending owner pid \(owner.pid) is live"
        case .unresolved(let reason):
            return reason
        }
    }
}
