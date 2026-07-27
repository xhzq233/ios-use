import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI

final class PlayCoverPendingLaunchCoordinatorTests:
    XCTestCase
{
    private struct Fixture {
        let root: URL
        let paths: IOSUsePaths
        let manifest: PlayCoverPrepareManifest
        let intent: PlayCoverPendingLaunchStore.Intent
        let inventory: [PlayCoverPendingLaunchStore.AliasEntry]
    }

    override func tearDown() {
        PlayCoverSessionService.fastVerifyOverrideForTesting = nil
        PlayCoverSessionService.launchOverrideForTesting = nil
        PlayCoverSessionService.terminateOverrideForTesting = nil
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = nil
        PlayCoverPendingLaunchRecovery
            .exactExecutableCensusOverrideForTesting = nil
        PlayCoverPendingLaunchRecovery
            .ownedProcessStateOverrideForTesting = nil
        PlayCoverPendingLaunchRecovery
            .candidateAuthenticationOverrideForTesting = nil
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = nil
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = nil
        PlayCoverService.failedLaunchSignalOverrideForTesting = nil
        PlayCoverService.keyCoverLockOverrideForTesting = nil
        PlayCoverService.launchAliasRootOverrideForTesting = nil
        SessionService.simulatorDriverTerminatorForTesting = nil
        SessionService.realDriverTerminatorForTesting = nil
        DeviceService.listDevicesOverrideForTesting = nil
        super.tearDown()
    }

    func testStatusReportsPendingIntentWithoutMutatingIt()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        DeviceService.listDevicesOverrideForTesting = { _, _ in [] }
        let before = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )

        let output = try StatusService.status(paths: fixture.paths)

        XCTAssertTrue(output.contains("launchPending"))
        XCTAssertTrue(output.contains("phase: intent"))
        XCTAssertTrue(output.contains(before.sessionID))
        XCTAssertEqual(
            try PlayCoverPendingLaunchStore.load(paths: fixture.paths),
            before
        )
        guard case .object(let root) =
                StatusService.machineSnapshot(
                    paths: fixture.paths
                ).data,
              case .object(let driver)? = root["driver"] else {
            return XCTFail(
                "machine status omitted pending launch evidence"
            )
        }
        XCTAssertEqual(driver["status"], .string("launchPending"))
        XCTAssertEqual(driver["phase"], .string("intent"))
        XCTAssertEqual(
            driver["sessionIdentifier"],
            .string(before.sessionID)
        )
        XCTAssertEqual(
            driver["bundleId"],
            .string(before.bundleIdentifier)
        )
        XCTAssertEqual(
            driver["playcoverGenerationKey"],
            .string(before.generationKey)
        )
        XCTAssertEqual(driver["ownerPid"], .null)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.intent.aliasPath
            )
        )
    }

    func testStatusDoesNotAuthenticateArmedCandidatesOrMutateJournal()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        let boot = UUID().uuidString.lowercased()
        let before = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: boot
        )
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = { boot }
        PlayCoverPendingLaunchRecovery
            .exactExecutableCensusOverrideForTesting = { _ in
                .complete([
                    .init(
                        pid: 8_101,
                        processBirthMicroseconds: 8_102
                    ),
                ])
            }
        PlayCoverPendingLaunchRecovery
            .candidateAuthenticationOverrideForTesting = { _, _ in
                XCTFail("status must not challenge a live candidate")
                return false
            }

        let snapshot = try XCTUnwrap(
            PlayCoverPendingLaunchCoordinator.readOnlySnapshot(
                paths: fixture.paths
            )
        )

        XCTAssertEqual(snapshot.status, "unresolvedOpen")
        XCTAssertEqual(snapshot.phase, .submissionArmed)
        XCTAssertEqual(
            try PlayCoverPendingLaunchStore.load(paths: fixture.paths),
            before
        )
    }

    func testSameBootArmedLaunchBlocksStartBeforeNewLaunch()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        let boot = UUID().uuidString.lowercased()
        _ = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: boot
        )
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = { boot }
        PlayCoverPendingLaunchRecovery
            .exactExecutableCensusOverrideForTesting = { _ in
                .complete([])
            }
        var launched = false
        PlayCoverSessionService.launchOverrideForTesting = {
            _, _, _, _, _ in
            launched = true
            throw CLIParseError.invalidValue(
                "launch override must not run"
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": fixture.root.path]
        ).run(arguments: ["start", "--playcover"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(launched)
        XCTAssertTrue(result.stderr.contains("unresolved"))
        XCTAssertEqual(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )?.phase,
            .submissionArmed
        )
        XCTAssertNil(
            try SessionService.readDriverLockInfo(
                paths: fixture.paths
            )
        )
    }

    func testStopCompletesNeverSubmittedCleanupWithoutDriverLock()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )

        let output = try SessionService.stop(paths: fixture.paths)

        XCTAssertTrue(
            output.contains("PlayCover pending launch stopped")
        )
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        XCTAssertNil(
            try SessionService.readDriverLockInfo(
                paths: fixture.paths
            )
        )
    }

    func testPendingCleanupPreservesJournalAndFacadeUntilKeyCoverRetry()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        try FileManager.default.createDirectory(
            atPath: fixture.manifest.preparedAppPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("fixture".utf8).write(
            to: URL(
                fileURLWithPath:
                    fixture.manifest.executablePath
            )
        )
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        let alias = try PlayCoverService.createSessionLaunchAlias(
            manifest: fixture.manifest,
            sessionID: fixture.intent.sessionID
        )
        var aliasStatus = stat()
        XCTAssertEqual(lstat(alias.bundleURL.path, &aliasStatus), 0)
        _ = try PlayCoverPendingLaunchStore.markAliasReady(
            sessionID: fixture.intent.sessionID,
            device: UInt64(aliasStatus.st_dev),
            inode: UInt64(aliasStatus.st_ino),
            inventory: fixture.inventory,
            paths: fixture.paths
        )
        var lockAttempts = 0
        PlayCoverService.keyCoverLockOverrideForTesting = { _, _ in
            lockAttempts += 1
            if lockAttempts == 1 {
                throw CLIParseError.invalidValue(
                    "injected KeyCover failure"
                )
            }
        }

        let first = IOSUseCLI(
            environment: [
                "IOS_USE_HOME": fixture.root.path,
            ]
        ).run(
            arguments: ["--json", "stop"]
        )
        XCTAssertEqual(first.exitCode, 1)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(first.stderr.utf8)
            ) as? [String: Any]
        )
        let machineError = try XCTUnwrap(
            envelope["error"] as? [String: Any]
        )
        XCTAssertEqual(
            machineError["code"] as? String,
            "playcover_stop_cleanup_failed"
        )
        XCTAssertEqual(
            machineError["phase"] as? String,
            "playcover_stop_cleanup"
        )
        XCTAssertEqual(
            machineError["mutationMayHaveApplied"] as? Bool,
            true
        )
        XCTAssertEqual(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )?.phase,
            .confirmedStopped
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: alias.bundleURL.path
            )
        )

        let output = try SessionService.stop(paths: fixture.paths)

        XCTAssertTrue(
            output.contains("PlayCover pending launch stopped")
        )
        XCTAssertEqual(lockAttempts, 2)
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: alias.bundleURL.path
            )
        )
    }

    func testStopCleansDurableOwnerWhichAlreadyExited()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        let boot = UUID().uuidString.lowercased()
        _ = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: boot
        )
        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 9_101,
            processBirthMicroseconds: 9_102,
            source: .authenticatedRuntime
        )
        _ = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.intent.sessionID,
            owner: owner,
            callbackSucceeded: false,
            paths: fixture.paths
        )
        PlayCoverPendingLaunchRecovery
            .ownedProcessStateOverrideForTesting = { pid in
                XCTAssertEqual(pid, owner.pid)
                return .missing
            }
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = {
            _, _ in
            XCTFail("an exited owner must not be signalled")
        }

        let output = try SessionService.stop(paths: fixture.paths)

        XCTAssertTrue(output.contains("pid \(owner.pid)"))
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
    }

    func testStopAuthenticatesThenTerminatesExactPendingOwner()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        let boot = UUID().uuidString.lowercased()
        _ = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: boot
        )
        let pid: Int32 = 9_201
        let birth: UInt64 = 9_202
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = { boot }
        PlayCoverPendingLaunchRecovery
            .exactExecutableCensusOverrideForTesting = { path in
                XCTAssertEqual(
                    path,
                    fixture.manifest.executablePath
                )
                return .complete([
                    .init(
                        pid: pid,
                        processBirthMicroseconds: birth
                    ),
                ])
            }
        PlayCoverPendingLaunchRecovery
            .ownedProcessStateOverrideForTesting = { candidatePID in
                XCTAssertEqual(candidatePID, pid)
                return .running(
                    executablePath:
                        fixture.manifest.executablePath,
                    processBirthMicroseconds: birth
                )
            }
        PlayCoverPendingLaunchRecovery
            .candidateAuthenticationOverrideForTesting = {
                candidate,
                evidence in
                XCTAssertEqual(candidate.pid, pid)
                XCTAssertEqual(
                    evidence.sessionID,
                    fixture.intent.sessionID
                )
                return true
            }
        var terminated:
            PlayCoverService.LaunchedApplicationIdentity?
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = {
            identity,
            manifest in
            XCTAssertEqual(manifest, fixture.manifest)
            terminated = identity
        }

        let output = try SessionService.stop(paths: fixture.paths)

        XCTAssertTrue(output.contains("pid \(pid)"))
        XCTAssertEqual(terminated?.pid, pid)
        XCTAssertEqual(
            terminated?.processStartTimeMicroseconds,
            birth
        )
        XCTAssertEqual(
            terminated?.source,
            .authenticatedRuntime
        )
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
    }

    func testTerminalCallbackAndCompleteEmptyCensusCanClean()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        let boot = UUID().uuidString.lowercased()
        _ = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: boot
        )
        _ = try PlayCoverPendingLaunchStore
            .markTerminalCallbackFailure(
                sessionID: fixture.intent.sessionID,
                errorDescription: "LaunchServices callback failed",
                paths: fixture.paths
            )
        PlayCoverPendingLaunchRecovery
            .bootSessionUUIDOverrideForTesting = { boot }
        PlayCoverPendingLaunchRecovery
            .exactExecutableCensusOverrideForTesting = { _ in
                .complete([])
            }

        _ = try SessionService.stop(paths: fixture.paths)

        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
    }

    func testStopResumesCommitRollbackAfterStoppedProof()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        _ = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: UUID().uuidString
        )
        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 9_301,
            processBirthMicroseconds: 9_302,
            source: .authenticatedRuntime
        )
        _ = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.intent.sessionID,
            owner: owner,
            callbackSucceeded: false,
            paths: fixture.paths
        )
        let result = PlayCoverSessionService.LaunchResult(
            sessionID: fixture.intent.sessionID,
            appPath: fixture.manifest.preparedAppPath,
            bundleIdentifier:
                fixture.manifest.bundleIdentifier,
            executablePath: fixture.manifest.executablePath,
            generationKey: fixture.manifest.generationKey,
            productType: "iPhone16,2",
            pid: owner.pid,
            runtimeSocketPath:
                fixture.intent.runtimeSocketPath,
            usesPendingLaunchJournal: true,
            reused: true
        )
        _ = try PlayCoverPendingLaunchStore.markConfirmedStopped(
                sessionID: result.sessionID,
                cleanupProof: .stoppedExactOwner,
                paths: fixture.paths
            )
        try FileManager.default.createDirectory(
            atPath: fixture.manifest.preparedAppPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: fixture.paths.playcoverRun,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try SessionService.writeDriverLock(
            info: PlayCoverSessionService.makeSessionInfo(
                from: result
            ),
            paths: fixture.paths
        )
        PlayCoverSessionService.terminateOverrideForTesting = {
            _ in
            XCTFail(
                "a durable stopped proof must not signal the process"
            )
            return 0
        }

        let output = try SessionService.stop(paths: fixture.paths)

        XCTAssertTrue(output.contains("pid \(owner.pid)"))
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        XCTAssertNil(
            try SessionService.readDriverLockInfo(
                paths: fixture.paths
            )
        )
    }

    func testStatusReportsMissingDurableDriverHandoffAsUnresolved()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        _ = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: UUID().uuidString
        )
        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 9_351,
            processBirthMicroseconds: 9_352,
            source: .authenticatedRuntime
        )
        _ = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.intent.sessionID,
            owner: owner,
            callbackSucceeded: false,
            paths: fixture.paths
        )
        _ = try PlayCoverPendingLaunchStore.markDriverLockCommitted(
            sessionID: fixture.intent.sessionID,
            paths: fixture.paths
        )
        _ = try PlayCoverPendingLaunchStore.markConfirmedStopped(
            sessionID: fixture.intent.sessionID,
            cleanupProof: .driverLockRetired,
            paths: fixture.paths
        )

        let snapshot = try XCTUnwrap(
            PlayCoverPendingLaunchCoordinator.readOnlySnapshot(
                paths: fixture.paths
            )
        )

        XCTAssertEqual(snapshot.status, "unresolvedOpen")
        XCTAssertEqual(snapshot.phase, .confirmedStopped)
        XCTAssertTrue(snapshot.reason.contains("driver.lock is missing"))
    }

    func testForeignDriverLockBlocksStopBeforeBackendMutation()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pending = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        let simulator = SessionService.Info(
            udid: "simulator-1",
            deviceName: "iPhone",
            deviceVersion: "18.0",
            deviceType: "simulator"
        )
        try SessionService.writeDriverLock(
            info: simulator,
            paths: fixture.paths
        )
        SessionService.simulatorDriverTerminatorForTesting = { _ in
            XCTFail(
                "foreign backend must not be terminated while "
                    + "PlayCover recovery evidence exists"
            )
            return true
        }

        XCTAssertThrowsError(
            try SessionService.stop(paths: fixture.paths)
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "different active driver.lock"
                )
            )
        }
        XCTAssertEqual(
            try PlayCoverPendingLaunchStore.load(paths: fixture.paths),
            pending
        )
        XCTAssertEqual(
            try SessionService.readDriverLockInfo(
                paths: fixture.paths
            ),
            simulator
        )
    }

    func testCommitRollbackTerminatesUsingDurableBirthIdentity()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        _ = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: UUID().uuidString
        )
        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 9_401,
            processBirthMicroseconds: 9_402,
            source: .workspaceCallback
        )
        _ = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.intent.sessionID,
            owner: owner,
            callbackSucceeded: true,
            paths: fixture.paths
        )
        let result = makeLaunchResult(
            fixture,
            owner: owner
        )
        var terminated:
            PlayCoverService.LaunchedApplicationIdentity?
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = {
            identity,
            manifest in
            XCTAssertEqual(manifest, fixture.manifest)
            terminated = identity
        }

        try PlayCoverPendingLaunchCoordinator
            .rollbackAfterDriverCommitFailure(
                result: result,
                paths: fixture.paths
            )

        XCTAssertEqual(terminated?.pid, owner.pid)
        XCTAssertEqual(
            terminated?.processStartTimeMicroseconds,
            owner.processBirthMicroseconds
        )
        XCTAssertEqual(terminated?.source, .workspaceCallback)
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
    }

    func testRestartCompletesEveryDurableDriverLockHandoffPhase()
        throws
    {
        enum HandoffPhase {
            case owned
            case driverLockCommitted
            case confirmedStopped
        }
        try [
            HandoffPhase.owned,
            .driverLockCommitted,
            .confirmedStopped,
        ].forEach { phase in
            let fixture = try makeFixture()
            defer {
                try? FileManager.default.removeItem(at: fixture.root)
            }
            _ = try advanceToSubmissionArmed(
                fixture,
                bootSessionUUID: UUID().uuidString
            )
            let owner = PlayCoverPendingLaunchStore.Owner(
                pid: 9_451,
                processBirthMicroseconds: 9_452,
                source: .authenticatedRuntime
            )
            _ = try PlayCoverPendingLaunchStore.markOwned(
                sessionID: fixture.intent.sessionID,
                owner: owner,
                callbackSucceeded: false,
                paths: fixture.paths
            )
            let driver = PlayCoverSessionService.makeSessionInfo(
                from: makeLaunchResult(
                    fixture,
                    owner: owner
                )
            )
            try FileManager.default.createDirectory(
                atPath: fixture.manifest.preparedAppPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try SessionService.writeDriverLock(
                info: driver,
                paths: fixture.paths
            )
            switch phase {
            case .owned:
                break
            case .driverLockCommitted:
                _ = try PlayCoverPendingLaunchStore
                    .markDriverLockCommitted(
                        sessionID: fixture.intent.sessionID,
                        paths: fixture.paths
                    )
            case .confirmedStopped:
                _ = try PlayCoverPendingLaunchStore
                    .markDriverLockCommitted(
                        sessionID: fixture.intent.sessionID,
                        paths: fixture.paths
                    )
                _ = try PlayCoverPendingLaunchStore
                    .markConfirmedStopped(
                        sessionID: fixture.intent.sessionID,
                        cleanupProof: .driverLockRetired,
                        paths: fixture.paths
                    )
            }
            PlayCoverPendingLaunchRecovery
                .ownedProcessStateOverrideForTesting = { pid in
                    XCTAssertEqual(pid, owner.pid)
                    return .running(
                        executablePath:
                            fixture.manifest.executablePath,
                        processBirthMicroseconds:
                            owner.processBirthMicroseconds
                    )
                }

            try PlayCoverPendingLaunchCoordinator.recoverBeforeStart(
                paths: fixture.paths
            )

            XCTAssertNil(
                try PlayCoverPendingLaunchStore.load(
                    paths: fixture.paths
                )
            )
            XCTAssertEqual(
                try SessionService.readDriverLockInfo(
                    paths: fixture.paths
                ),
                driver
            )
        }
    }

    func testMatchingDriverLockWithExitedOwnerCleansInsteadOfHandoff()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        configureManifestValidation(fixture)
        _ = try advanceToSubmissionArmed(
            fixture,
            bootSessionUUID: UUID().uuidString
        )
        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 9_501,
            processBirthMicroseconds: 9_502,
            source: .authenticatedRuntime
        )
        _ = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.intent.sessionID,
            owner: owner,
            callbackSucceeded: false,
            paths: fixture.paths
        )
        let result = makeLaunchResult(
            fixture,
            owner: owner
        )
        try FileManager.default.createDirectory(
            atPath: fixture.manifest.preparedAppPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try SessionService.writeDriverLock(
            info: PlayCoverSessionService.makeSessionInfo(
                from: result
            ),
            paths: fixture.paths
        )
        PlayCoverPendingLaunchRecovery
            .ownedProcessStateOverrideForTesting = { pid in
                XCTAssertEqual(pid, owner.pid)
                return .missing
            }
        PlayCoverSessionService.terminateOverrideForTesting = {
            _ in
            XCTFail("an exited exact owner must not be signalled")
            return 0
        }

        let output = try SessionService.stop(paths: fixture.paths)

        XCTAssertTrue(output.contains("pid \(owner.pid)"))
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        XCTAssertNil(
            try SessionService.readDriverLockInfo(
                paths: fixture.paths
            )
        )
    }

    private func configureManifestValidation(_ fixture: Fixture) {
        PlayCoverSessionService.fastVerifyOverrideForTesting = {
            appPath in
            XCTAssertEqual(
                appPath,
                fixture.manifest.preparedAppPath
            )
            return fixture.manifest
        }
    }

    private func makeLaunchResult(
        _ fixture: Fixture,
        owner: PlayCoverPendingLaunchStore.Owner
    ) -> PlayCoverSessionService.LaunchResult {
        .init(
            sessionID: fixture.intent.sessionID,
            appPath: fixture.manifest.preparedAppPath,
            bundleIdentifier:
                fixture.manifest.bundleIdentifier,
            executablePath: fixture.manifest.executablePath,
            generationKey: fixture.manifest.generationKey,
            productType: "iPhone16,2",
            pid: owner.pid,
            runtimeSocketPath:
                fixture.intent.runtimeSocketPath,
            usesPendingLaunchJournal: true,
            reused: true
        )
    }

    @discardableResult
    private func advanceToSubmissionArmed(
        _ fixture: Fixture,
        bootSessionUUID: String
    ) throws -> PlayCoverPendingLaunchStore.Record {
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        _ = try PlayCoverPendingLaunchStore.markAliasReady(
            sessionID: fixture.intent.sessionID,
            device: 1,
            inode: 2,
            inventory: fixture.inventory,
            paths: fixture.paths
        )
        return try PlayCoverPendingLaunchStore
            .markSubmissionArmed(
                sessionID: fixture.intent.sessionID,
                bootSessionUUID: bootSessionUUID,
                paths: fixture.paths
            )
    }

    private func makeFixture() throws -> Fixture {
        var template =
            Array("/tmp/iu-pending-coordinator-XXXXXX".utf8CString)
        guard let pointer = mkdtemp(&template) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        let root = URL(
            fileURLWithPath: String(cString: pointer),
            isDirectory: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root.path]
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverRun,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let generationKey = String(repeating: "b", count: 64)
        let appPath = paths.playcoverPrepared
            + "/\(generationKey)/Fixture.app"
        let executablePath = appPath + "/Fixture"
        let object: [String: Any] = [
            "schemaVersion": 3,
            "backend": "playcover-headless",
            "sourceAppPath": root.path + "/Source.app",
            "preparedAppPath": appPath,
            "bundleIdentifier": "com.example.fixture",
            "executableName": "Fixture",
            "executablePath": executablePath,
            "sourceContentHash": String(repeating: "1", count: 64),
            "sourceHashAfterPreparation":
                String(repeating: "1", count: 64),
            "runtimeBuildHash": String(repeating: "2", count: 64),
            "prepareRevision":
                PlayCoverService.prepareImplementationRevision,
            "generationKey": generationKey,
            "runtimeLoadPath": PlayCoverMachO.runtimeLoadPath,
            "runtimeFrameworkName":
                PlayCoverService.runtimeFrameworkName,
            "convertedMachOs": ["Fixture"],
            "signingOrder": ["Fixture"],
            "sourceInventory": [],
            "sourceMachOs": [],
            "inventory": [],
            "machOs": [],
            "entitlementDiff": [
                "original": [:],
                "playCoverBaseline": [:],
                "final": [:],
                "addedByPlayCover": [],
                "addedByIOSUse": [],
                "changedFromOriginal": [],
                "removedFromOriginal": [],
            ],
            "completedAt": "2026-07-28T00:00:00Z",
        ]
        let manifest = try JSONDecoder().decode(
            PlayCoverPrepareManifest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let sessionID = UUID().uuidString.lowercased()
        PlayCoverService.launchAliasRootOverrideForTesting =
            root.appendingPathComponent(
                "launch-aliases",
                isDirectory: true
            )
        let intent = PlayCoverPendingLaunchStore.Intent(
            sessionID: sessionID,
            runtimeSocketPath:
                try paths.playCoverRuntimeSocketPath(
                    sessionID: sessionID
                ),
            generationKey: generationKey,
            appPath: appPath,
            bundleIdentifier: manifest.bundleIdentifier,
            executablePath: executablePath,
            aliasPath: PlayCoverService.sessionLaunchAlias(
                sessionID: sessionID
            ).bundleURL.path
        )
        return Fixture(
            root: root,
            paths: paths,
            manifest: manifest,
            intent: intent,
            inventory: [
                .init(
                    name: "Fixture",
                    destination: executablePath
                ),
            ]
        )
    }
}
