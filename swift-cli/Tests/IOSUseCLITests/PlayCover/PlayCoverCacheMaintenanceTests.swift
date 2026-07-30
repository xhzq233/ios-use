import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverCacheMaintenanceTests: XCTestCase {
    override func tearDown() {
        PlayCoverGenerationPruner.afterProtectedStateForTesting = nil
        PlayCoverGenerationPruner.afterInventoryForTesting = nil
        PlayCoverGenerationPruner
            .inventorySidecarReadObserverForTesting = nil
        super.tearDown()
    }

    func testRegistrySnapshotProtectsLastPendingAndActiveAcrossHomes()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let foreignPaths = fixture.makeForeignHomePaths()
        let activeKey = String(repeating: "a", count: 64)
        let localLastKey = String(repeating: "b", count: 64)
        let pendingKey = String(repeating: "c", count: 64)
        let activeSession = UUID().uuidString
        let pendingSession = UUID().uuidString

        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: activeKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.setPending(
            sessionID: activeSession,
            generationKey: activeKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.markActive(
            sessionID: activeSession,
            generationKey: activeKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.clearPending(
            sessionID: activeSession,
            generationKey: activeKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: localLastKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: pendingKey,
            paths: foreignPaths
        )
        try PlayCoverGlobalReferenceStore.setPending(
            sessionID: pendingSession,
            generationKey: pendingKey,
            paths: foreignPaths
        )

        var protected = Set<String>()
        try PlayCoverGlobalReferenceStore
            .withLockedProtectedGenerationKeys(
                paths: fixture.paths
            ) { keys, _ in
                protected = keys
            }

        XCTAssertEqual(
            protected,
            Set([activeKey, localLastKey, pendingKey])
        )
    }

    func testRegistryRejectsReplacingDifferentActivePin() throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let activeKey = String(repeating: "a", count: 64)
        let nextKey = String(repeating: "b", count: 64)
        let activeSession = UUID().uuidString

        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: activeKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.setPending(
            sessionID: activeSession,
            generationKey: activeKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.markActive(
            sessionID: activeSession,
            generationKey: activeKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.clearPending(
            sessionID: activeSession,
            generationKey: activeKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: nextKey,
            paths: fixture.paths
        )

        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore.setPending(
                sessionID: UUID().uuidString,
                generationKey: nextKey,
                paths: fixture.paths
            )
        )
        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore.markActive(
                sessionID: UUID().uuidString,
                generationKey: nextKey,
                paths: fixture.paths
            )
        )
        let reference = try XCTUnwrap(
            PlayCoverGlobalReferenceStore.read(paths: fixture.paths)
        )
        XCTAssertEqual(
            reference.active?.sessionID,
            activeSession
        )
        XCTAssertEqual(
            reference.active?.generationKey,
            activeKey
        )
        XCTAssertNil(reference.pending)
        XCTAssertEqual(reference.lastGenerationKey, nextKey)
    }

    func testRegistryFailsClosedWhenForeignReferenceDisappears()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let foreignPaths = fixture.makeForeignHomePaths()
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: String(repeating: "a", count: 64),
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: String(repeating: "b", count: 64),
            paths: foreignPaths
        )
        let foreignReference = URL(
            fileURLWithPath: foreignPaths.playcoverGlobalHomes,
            isDirectory: true
        ).appendingPathComponent(
            "\(foreignPaths.playcoverHomeID).json"
        )
        try FileManager.default.removeItem(at: foreignReference)

        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore
                .withLockedProtectedGenerationKeys(
                    paths: fixture.paths
                ) { _, _ in }
        )
    }

    func testStalePreparationCleanupRequiresCompleteRegistry()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let foreignPaths = fixture.makeForeignHomePaths()
        let localKey = String(repeating: "a", count: 64)
        let preparationID =
            try PlayCoverGlobalReferenceStore.beginPreparation(
                generationKey: localKey,
                paths: fixture.paths
            )
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: String(repeating: "b", count: 64),
            paths: foreignPaths
        )
        let foreignReference = URL(
            fileURLWithPath: foreignPaths.playcoverGlobalHomes,
            isDirectory: true
        ).appendingPathComponent(
            "\(foreignPaths.playcoverHomeID).json"
        )
        try FileManager.default.removeItem(at: foreignReference)

        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore
                .clearStalePreparationBeforeStart(
                    paths: fixture.paths
                )
        )
        let localReference = try JSONDecoder().decode(
            PlayCoverGlobalReferenceStore.HomeReference.self,
            from: Data(contentsOf: fixture.homeReferenceURL)
        )
        XCTAssertEqual(
            localReference.preparingGenerationKey,
            localKey
        )
        XCTAssertEqual(
            localReference.preparationID,
            preparationID
        )
    }

    func testRegistryFailsClosedWhenHomesDirectoryDisappears()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: String(repeating: "a", count: 64),
            paths: fixture.paths
        )
        try FileManager.default.removeItem(
            atPath: fixture.paths.playcoverGlobalHomes
        )

        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore
                .withLockedProtectedGenerationKeys(
                    paths: fixture.paths
                ) { _, _ in }
        )
    }

    func testLayoutFailsClosedWhenOnlyNonemptyObjectsSurvive()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let objects = URL(
            fileURLWithPath: fixture.paths.playcoverGlobalObjects,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: objects,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("surviving-generation".utf8).write(
            to: objects.appendingPathComponent("sentinel")
        )

        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore
                .withLockedProtectedGenerationKeys(
                    paths: fixture.paths
                ) { _, _ in }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.playcoverGlobalHomes
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.playcoverGlobalLocks
            )
        )
    }

    func testLayoutFailsClosedWithoutRecreatingMissingLocks()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: String(repeating: "a", count: 64),
            paths: fixture.paths
        )
        try FileManager.default.removeItem(
            atPath: fixture.paths.playcoverGlobalLocks
        )

        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore
                .withLockedProtectedGenerationKeys(
                    paths: fixture.paths
                ) { _, _ in }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.playcoverGlobalLocks
            )
        )
    }

    func testMissingRegistryFailsClosedWhenPreparedObjectsExist()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        _ = try PlayCoverManagedAppService.secureManagedDirectories(
            paths: fixture.paths
        )
        let object = URL(
            fileURLWithPath: fixture.paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(
            String(repeating: "a", count: 64),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: object,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore
                .withLockedProtectedGenerationKeys(
                    paths: fixture.paths
                ) { _, _ in }
        )
        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore.updateLast(
                generationKey: String(repeating: "b", count: 64),
                paths: fixture.paths
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(
                    fileURLWithPath:
                        fixture.paths.playcoverGlobalLocks,
                    isDirectory: true
                ).appendingPathComponent("registry-v1.json").path
            )
        )
    }

    func testConflictingPendingAndActiveReferenceFailsClosed()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let firstKey = String(repeating: "a", count: 64)
        let secondKey = String(repeating: "b", count: 64)
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: firstKey,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.setPending(
            sessionID: UUID().uuidString,
            generationKey: firstKey,
            paths: fixture.paths
        )
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.homeReferenceURL)
            ) as? [String: Any]
        )
        object["active"] = [
            "sessionID": UUID().uuidString,
            "generationKey": secondKey,
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: fixture.homeReferenceURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.homeReferenceURL.path
        )

        XCTAssertThrowsError(
            try PlayCoverGlobalReferenceStore
                .withLockedProtectedGenerationKeys(
                    paths: fixture.paths
                ) { _, _ in }
        )
    }

    func testRegistryRemovesValidatedCrashTemporaryBeforeSnapshot()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let key = String(repeating: "a", count: 64)
        try fixture.writeReference(generationKey: key)
        let temporary = URL(
            fileURLWithPath: fixture.paths.playcoverGlobalHomes,
            isDirectory: true
        ).appendingPathComponent(
            ".home-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("interrupted-write".utf8).write(
            to: temporary,
            options: .withoutOverwriting
        )
        XCTAssertEqual(chmod(temporary.path, 0o600), 0)

        var protected = Set<String>()
        try PlayCoverGlobalReferenceStore
            .withLockedProtectedGenerationKeys(
                paths: fixture.paths
            ) { keys, _ in
                protected = keys
            }

        XCTAssertEqual(protected, Set([key]))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: temporary.path)
        )
    }

    func testNextStartClearsCrashedPreparationPinAndGCRemovesStaging()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let crashedKey = String(repeating: "c", count: 64)
        _ = try PlayCoverGlobalReferenceStore.beginPreparation(
            generationKey: crashedKey,
            paths: fixture.paths
        )
        let staging = URL(
            fileURLWithPath: fixture.paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(
            ".staging-\(crashedKey)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("partial".utf8).write(
            to: staging.appendingPathComponent("partial")
        )
        XCTAssertEqual(
            try PlayCoverGlobalReferenceStore.read(
                paths: fixture.paths
            )?.preparingGenerationKey,
            crashedKey
        )

        try SessionOperationLock.withExclusiveLock(
            paths: fixture.paths
        ) {
            try PlayCoverPendingLaunchCoordinator
                .recoverBeforeStart(paths: fixture.paths)
        }

        XCTAssertNil(
            try PlayCoverGlobalReferenceStore.read(
                paths: fixture.paths
            )?.preparingGenerationKey
        )
        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey:
                    String(repeating: "d", count: 64)
            )
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging.path)
        )
    }

    func testOperationLockSerializesAnotherProcess() throws {
        guard FileManager.default.isExecutableFile(
            atPath: "/usr/bin/python3"
        ) else {
            throw XCTSkip("python3 is required for cross-process lock test")
        }
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let holderAcquired = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        let holderFinished = expectation(
            description: "operation lock holder finished"
        )
        let holderError = LockedBox<Error?>()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SessionOperationLock.withExclusiveLock(
                    paths: fixture.paths
                ) {
                    holderAcquired.signal()
                    _ = releaseHolder.wait(timeout: .now() + 5)
                }
            } catch {
                holderError.withValue { $0 = error }
            }
            holderFinished.fulfill()
        }
        XCTAssertEqual(
            holderAcquired.wait(timeout: .now() + 5),
            .success
        )

        let ready = fixture.root.appendingPathComponent("child-ready")
        let acquired = fixture.root.appendingPathComponent(
            "child-acquired"
        )
        let lockPath = fixture.root
            .appendingPathComponent("mac")
            .appendingPathComponent("operation.lock")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            """
            import fcntl, os, sys
            fd = os.open(sys.argv[1], os.O_RDWR)
            open(sys.argv[2], "w").close()
            fcntl.lockf(fd, fcntl.LOCK_EX)
            open(sys.argv[3], "w").close()
            os.close(fd)
            """,
            lockPath.path,
            ready.path,
            acquired.path,
        ]
        try child.run()
        try waitForFile(ready)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: acquired.path)
        )

        releaseHolder.signal()
        child.waitUntilExit()
        wait(for: [holderFinished], timeout: 5)

        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertNil(holderError.value)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: acquired.path)
        )
        let permissions = try FileManager.default.attributesOfItem(
            atPath: lockPath.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testOrdinaryStartUsesTheSameInProcessLifecycleLock()
        throws {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let holderAcquired = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        let startReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            try? SessionOperationLock.withExclusiveLock(
                paths: fixture.paths
            ) {
                holderAcquired.signal()
                _ = releaseHolder.wait(timeout: .now() + 5)
            }
        }
        XCTAssertEqual(
            holderAcquired.wait(timeout: .now() + 5),
            .success
        )

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? SessionService.start(
                udid: "missing-device",
                paths: fixture.paths,
                verbose: false
            )
            startReturned.signal()
        }
        XCTAssertEqual(
            startReturned.wait(timeout: .now() + 0.1),
            .timedOut
        )
        releaseHolder.signal()
        XCTAssertEqual(
            startReturned.wait(timeout: .now() + 5),
            .success
        )
    }

    func testUserOwnedPlayCoverSymlinkRejectsLockAndGC()
        throws {
        let fixture = try CacheMaintenanceFixture(
            createPlayCoverRun: false
        )
        defer { fixture.remove() }
        let external = URL(
            fileURLWithPath:
                "/tmp/iu-cache-external-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let key = String(repeating: "a", count: 64)
        let sentinel = external.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.paths.playcover,
            withDestinationPath: external.path
        )

        XCTAssertThrowsError(
            try SessionOperationLock.withExclusiveLock(
                paths: fixture.paths
            ) {}
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: external.appendingPathComponent(
                    "operation.lock"
                ).path
            )
        )
        try FileManager.default.removeItem(
            atPath: fixture.paths.playcover
        )
        let globalCache = URL(
            fileURLWithPath: fixture.paths.playcoverGlobalCache,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: globalCache.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: globalCache,
            withDestinationURL: external
        )
        let pruning =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: key
            )

        XCTAssertTrue(pruning.removedGenerationKeys.isEmpty)
        XCTAssertEqual(pruning.warnings.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path)
        )
    }

    func testPruneRetainsCurrentActiveLastAndThreeRecentInactive()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...8).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in keys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt: "2026-07-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeReference(generationKey: keys[6])
        try fixture.writeDriverLock(generationKey: keys[5])
        let transientNames = [
            ".staging-\(keys[0])-\(UUID().uuidString)",
            ".gc-\(keys[1])-\(UUID().uuidString)",
        ]
        for name in transientNames {
            let directory = URL(
                fileURLWithPath: fixture.paths.playcoverGlobalObjects,
                isDirectory: true
            ).appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Data("stale".utf8).write(
                to: directory.appendingPathComponent("sentinel")
            )
        }

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[7]
            )

        XCTAssertEqual(
            Set(result.removedGenerationKeys),
            Set([keys[0], keys[1]])
        )
        XCTAssertTrue(result.warnings.isEmpty)
        for key in keys[2...] {
            XCTAssertTrue(fixture.generationExists(key))
        }
        XCTAssertFalse(fixture.generationExists(keys[0]))
        XCTAssertFalse(fixture.generationExists(keys[1]))
        for name in transientNames {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: URL(
                        fileURLWithPath: fixture.paths.playcoverGlobalObjects,
                        isDirectory: true
                    ).appendingPathComponent(name).path
                )
            )
        }
    }

    func testPruneQuarantinesLegacyCompletedSchemaTwo() throws {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...4).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in keys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-06-\(String(format: "%02d", index + 1))T00:00:00Z",
                completedSchemaVersion: index == 0 ? 2 : 5
            )
        }
        try fixture.writeReference(generationKey: keys[1])
        try fixture.writeDriverLock(generationKey: keys[2])

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[3]
            )

        XCTAssertEqual(result.removedGenerationKeys, [keys[0]])
        XCTAssertTrue(
            result.warnings.contains {
                $0.contains(keys[0]) && $0.contains("quarantined")
            }
        )
        XCTAssertFalse(fixture.generationExists(keys[0]))
    }

    func testPruneUsesFastVerifiedTokenOnlyForCurrentManifest()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...5).map {
            String(repeating: String($0), count: 64)
        }
        let completedAt = keys.indices.map {
            "2026-05-\(String(format: "%02d", $0 + 1))T00:00:00Z"
        }
        for index in keys.indices {
            try fixture.createGeneration(
                key: keys[index],
                completedAt: completedAt[index]
            )
        }
        try fixture.writeReference(generationKey: keys[3])
        try fixture.writeDriverLock(generationKey: keys[2])
        let token = try fixture.makeFastVerifiedToken(
            generationKey: keys[4],
            completedAt: completedAt[4]
        )
        var reads:
            [PlayCoverGenerationPruner.InventorySidecarReadEvent] = []
        PlayCoverGenerationPruner
            .inventorySidecarReadObserverForTesting = {
                reads.append($0)
            }

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[4],
                currentGenerationToken: token
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
        for key in keys {
            XCTAssertEqual(
                reads.filter {
                    $0.generationKey == key
                        && $0.filename
                            == PlayCoverService.completedFilename
                }.count,
                1
            )
            XCTAssertEqual(
                reads.filter {
                    $0.generationKey == key
                        && $0.filename
                            == PlayCoverService.manifestFilename
                }.count,
                key == keys[4] ? 0 : 1
            )
        }
    }

    func testPruneRetainsCurrentWhenFastVerifiedMarkerChanges()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let key = String(repeating: "b", count: 64)
        let completedAt = "2026-05-20T00:00:00Z"
        try fixture.createGeneration(
            key: key,
            completedAt: completedAt
        )
        try fixture.writeReference(generationKey: key)
        try fixture.writeDriverLock(generationKey: key)
        let token = try fixture.makeFastVerifiedToken(
            generationKey: key,
            completedAt: completedAt
        )
        let changed = PlayCoverCompletedGeneration(
            schemaVersion: token.completed.schemaVersion,
            generationKey: token.completed.generationKey,
            manifestSHA256: token.completed.manifestSHA256,
            executableSHA256: token.completed.executableSHA256,
            runtimeSHA256: String(repeating: "a", count: 64)
        )
        try fixture.writeCompleted(
            changed,
            generationKey: key
        )
        var reads:
            [PlayCoverGenerationPruner.InventorySidecarReadEvent] = []
        PlayCoverGenerationPruner
            .inventorySidecarReadObserverForTesting = {
                reads.append($0)
            }

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: key,
                currentGenerationToken: token
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        XCTAssertTrue(fixture.generationExists(key))
        XCTAssertTrue(
            result.warnings.contains {
                $0.contains("protected corrupt generation \(key)")
                    && $0.contains(
                        "completed sidecar changed after fast verification"
                    )
            }
        )
        XCTAssertEqual(
            reads.filter {
                $0.generationKey == key
                    && $0.filename
                        == PlayCoverService.completedFilename
            }.count,
            1
        )
        XCTAssertFalse(
            reads.contains {
                $0.generationKey == key
                    && $0.filename
                        == PlayCoverService.manifestFilename
            }
        )
    }

    func testPruneRetainsCurrentWhenFastVerifiedVnodeChanges()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let key = String(repeating: "c", count: 64)
        let completedAt = "2026-05-21T00:00:00Z"
        try fixture.createGeneration(
            key: key,
            completedAt: completedAt
        )
        try fixture.writeReference(generationKey: key)
        try fixture.writeDriverLock(generationKey: key)
        let token = try fixture.makeFastVerifiedToken(
            generationKey: key,
            completedAt: completedAt
        )
        PlayCoverGenerationPruner.afterProtectedStateForTesting = {
            try fixture.replaceGenerationDirectory(generationKey: key)
        }

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: key,
                currentGenerationToken: token
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        XCTAssertTrue(fixture.generationExists(key))
        XCTAssertTrue(
            result.warnings.contains {
                $0.contains("protected corrupt generation \(key)")
                    && $0.contains(
                        "generation vnode changed after fast verification"
                    )
            }
        )
    }

    func testPruneSkipsMismatchedFastVerifiedGenerationToken()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let tokenKey = String(repeating: "d", count: 64)
        let currentKey = String(repeating: "e", count: 64)
        try fixture.createGeneration(
            key: tokenKey,
            completedAt: "2026-05-22T00:00:00Z"
        )
        try fixture.createGeneration(
            key: currentKey,
            completedAt: "2026-05-23T00:00:00Z"
        )
        try fixture.writeReference(generationKey: currentKey)
        try fixture.writeDriverLock(generationKey: currentKey)
        let token = try fixture.makeFastVerifiedToken(
            generationKey: tokenKey,
            completedAt: "2026-05-22T00:00:00Z"
        )
        var reads:
            [PlayCoverGenerationPruner.InventorySidecarReadEvent] = []
        PlayCoverGenerationPruner
            .inventorySidecarReadObserverForTesting = {
                reads.append($0)
            }

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: currentKey,
                currentGenerationToken: token
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(
            result.warnings[0].contains(
                "fast-verified current generation token does not match"
            )
        )
    }

    func testPruneProtectsOldestGenerationWithValidPendingLaunch()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...8).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in keys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-07-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeReference(generationKey: keys[6])
        try fixture.writeDriverLock(generationKey: keys[5])
        let foreignPaths = fixture.makeForeignHomePaths()
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: keys[0],
            paths: foreignPaths
        )
        try PlayCoverGlobalReferenceStore.setPending(
            sessionID: UUID().uuidString,
            generationKey: keys[0],
            paths: foreignPaths
        )

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[7]
            )

        XCTAssertEqual(result.removedGenerationKeys, [keys[1]])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(fixture.generationExists(keys[0]))
        XCTAssertFalse(fixture.generationExists(keys[1]))
    }

    func testPruneFailsClosedForInvalidOwnerOnlyGlobalHomeReference()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...8).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in keys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-06-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeReference(generationKey: keys[6])
        try fixture.writeDriverLock(generationKey: keys[5])
        try fixture.writeInvalidOwnerOnlyHomeReference(
            generationKey: keys[0]
        )
        let transientName =
            ".staging-\(keys[0])-\(UUID().uuidString)"
        let transient = URL(
            fileURLWithPath: fixture.paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(transientName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: transient,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[7]
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(
            result.warnings.first?.contains(
                "prepared cache could not be safely pruned"
            ) == true
        )
        for key in keys {
            XCTAssertTrue(fixture.generationExists(key))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: transient.path),
            "invalid global Home ref must skip transaction residue cleanup"
        )
    }

    func testPruneRetainsValidManifestLargerThanOneMiB()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...4).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in keys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-07-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        let largeManifestKey = keys[3]
        try fixture.writeSidecarJSON(
            [
                "schemaVersion": 5,
                "backend": "mac",
                "generationKey": largeManifestKey,
                "completedAt": "2026-07-04T00:00:00Z",
                "fixturePadding": String(repeating: "x", count: 4_300_000),
            ],
            named: PlayCoverService.manifestFilename,
            generationKey: largeManifestKey
        )
        let manifestSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: fixture.generationDirectory(largeManifestKey)
                    .appendingPathComponent(
                        PlayCoverService.manifestFilename
                    ).path
            )[.size] as? NSNumber
        ).intValue
        XCTAssertGreaterThan(manifestSize, 1_048_576)
        XCTAssertLessThanOrEqual(
            manifestSize,
            PlayCoverService.generationManifestMaximumBytes
        )
        try fixture.writeReference(generationKey: keys[2])
        try fixture.writeDriverLock(generationKey: keys[1])

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[0]
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(fixture.generationExists(largeManifestKey))
    }

    func testPruneFailsClosedForMalformedState() throws {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...5).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in keys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt: "2026-06-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeDriverLock(generationKey: keys[4])
        try Data("not-json".utf8).write(
            to: fixture.homeReferenceURL
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.homeReferenceURL.path
        )

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[4]
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        for key in keys {
            XCTAssertTrue(fixture.generationExists(key))
        }
    }

    func testPruneQuarantinesEveryCorruptSidecarKindAndFreesTheKey()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let protectedKeys = (1...3).map {
            String(repeating: String($0), count: 64)
        }
        let corruptKeys = ["4", "5", "6", "7", "8", "9", "a"].map {
            String(repeating: $0, count: 64)
        }
        for (index, key) in (protectedKeys + corruptKeys).enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-04-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeReference(generationKey: protectedKeys[1])
        try fixture.writeDriverLock(generationKey: protectedKeys[0])

        try fixture.removeSidecar(
            PlayCoverService.manifestFilename,
            generationKey: corruptKeys[0]
        )
        try fixture.removeSidecar(
            PlayCoverService.completedFilename,
            generationKey: corruptKeys[1]
        )
        try fixture.truncateSidecar(
            PlayCoverService.manifestFilename,
            generationKey: corruptKeys[2],
            byteCount:
                PlayCoverService.generationManifestMaximumBytes + 1
        )
        try fixture.writeSidecar(
            Data("not-json".utf8),
            named: PlayCoverService.manifestFilename,
            generationKey: corruptKeys[3]
        )
        try fixture.writeSidecarJSON(
            [
                "schemaVersion": 3,
                "backend": "mac",
                "generationKey": protectedKeys[0],
                "completedAt": "2026-04-08T00:00:00Z",
            ],
            named: PlayCoverService.manifestFilename,
            generationKey: corruptKeys[4]
        )
        try fixture.writeSidecarJSON(
            [
                "schemaVersion": 5,
                "generationKey": protectedKeys[0],
            ],
            named: PlayCoverService.completedFilename,
            generationKey: corruptKeys[5]
        )
        try fixture.writeSidecarJSON(
            [
                "schemaVersion": 3,
                "generationKey": protectedKeys[0],
            ],
            named: PlayCoverService.completedFilename,
            generationKey: corruptKeys[6]
        )

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: protectedKeys[2]
            )

        XCTAssertEqual(
            Set(result.removedGenerationKeys),
            Set(corruptKeys)
        )
        for key in corruptKeys {
            XCTAssertFalse(fixture.generationExists(key))
            XCTAssertTrue(
                result.warnings.contains {
                    $0.contains(key)
                        && $0.contains("quarantined")
                }
            )
        }
        for key in protectedKeys {
            XCTAssertTrue(fixture.generationExists(key))
        }

        try fixture.createGeneration(
            key: corruptKeys[0],
            completedAt: "2026-04-20T00:00:00Z"
        )
        XCTAssertTrue(
            fixture.generationExists(corruptKeys[0]),
            "quarantine must free the exact generation namespace for prepare"
        )
    }

    func testPruneNeverQuarantinesCorruptCurrentReferenceOrActive()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...3).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in keys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-03-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeReference(generationKey: keys[1])
        try fixture.writeDriverLock(generationKey: keys[0])
        for key in keys {
            try fixture.writeSidecar(
                Data("corrupt".utf8),
                named: PlayCoverService.completedFilename,
                generationKey: key
            )
        }

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[2]
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        for key in keys {
            XCTAssertTrue(fixture.generationExists(key))
            XCTAssertTrue(
                result.warnings.contains {
                    $0.contains("protected corrupt generation \(key)")
                        && $0.contains("retained")
                }
            )
        }
    }

    func testPruneDoesNotFollowGenerationSymlinkOrInventoryRace()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let protectedKeys = (1...3).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in protectedKeys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-02-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeReference(generationKey: protectedKeys[1])
        try fixture.writeDriverLock(generationKey: protectedKeys[0])

        let external = fixture.root.appendingPathComponent(
            "external",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = external.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)

        let symlinkKey = String(repeating: "4", count: 64)
        try FileManager.default.createSymbolicLink(
            at: fixture.generationDirectory(symlinkKey),
            withDestinationURL: external
        )
        let racedKey = String(repeating: "5", count: 64)
        try fixture.createGeneration(
            key: racedKey,
            completedAt: "2026-02-05T00:00:00Z"
        )
        try fixture.writeSidecar(
            Data("corrupt".utf8),
            named: PlayCoverService.completedFilename,
            generationKey: racedKey
        )
        let displaced = fixture.root.appendingPathComponent(
            "raced-generation",
            isDirectory: true
        )
        PlayCoverGenerationPruner.afterInventoryForTesting = {
            PlayCoverGenerationPruner.afterInventoryForTesting = nil
            try FileManager.default.moveItem(
                at: fixture.generationDirectory(racedKey),
                to: displaced
            )
            try FileManager.default.createSymbolicLink(
                at: fixture.generationDirectory(racedKey),
                withDestinationURL: external
            )
        }

        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: protectedKeys[2]
            )

        XCTAssertTrue(result.removedGenerationKeys.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(fixture.isGenerationSymlink(symlinkKey))
        XCTAssertTrue(fixture.isGenerationSymlink(racedKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        XCTAssertTrue(
            result.warnings.contains {
                $0.contains(symlinkKey)
                    && $0.contains("ownership could not be validated")
            }
        )
        XCTAssertTrue(
            result.warnings.contains {
                $0.contains(racedKey)
                    && $0.contains("identity changed before tombstone")
            }
        )
    }

    func testCorruptGenerationQuarantineUsesABudgetAcrossConsecutiveGC()
        throws
    {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let protectedKeys = (1...3).map {
            String(repeating: String($0), count: 64)
        }
        let corruptKeys = Array("456789abcd").map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in (protectedKeys + corruptKeys).enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-01-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeReference(generationKey: protectedKeys[1])
        try fixture.writeDriverLock(generationKey: protectedKeys[0])
        for key in corruptKeys {
            try fixture.removeSidecar(
                PlayCoverService.completedFilename,
                generationKey: key
            )
        }

        let first =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: protectedKeys[2]
            )
        XCTAssertEqual(
            first.removedGenerationKeys.count,
            PlayCoverGenerationPruner.corruptGenerationQuarantineLimit
        )
        XCTAssertTrue(
            first.warnings.contains {
                $0.contains("quarantine budget 8 was reached")
                    && $0.contains("2 generation(s) were deferred")
            }
        )

        let second =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: protectedKeys[2]
            )
        XCTAssertEqual(second.removedGenerationKeys.count, 2)
        let third =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: protectedKeys[2]
            )
        XCTAssertTrue(third.removedGenerationKeys.isEmpty)
        XCTAssertTrue(third.warnings.isEmpty)
        for key in corruptKeys {
            XCTAssertFalse(fixture.generationExists(key))
        }
    }

    func testPruneKeepsDeletionAnchoredWhenPreparedPathIsSwapped()
        throws {
        let fixture = try CacheMaintenanceFixture()
        defer { fixture.remove() }
        let keys = (1...8).map {
            String(repeating: String($0), count: 64)
        }
        for (index, key) in keys.enumerated() {
            try fixture.createGeneration(
                key: key,
                completedAt:
                    "2026-05-\(String(format: "%02d", index + 1))T00:00:00Z"
            )
        }
        try fixture.writeReference(generationKey: keys[6])
        try fixture.writeDriverLock(generationKey: keys[5])

        let external = URL(
            fileURLWithPath:
                "/tmp/iu-cache-swap-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let prepared = URL(
            fileURLWithPath: fixture.paths.playcoverGlobalObjects,
            isDirectory: true
        )
        let externalGeneration = external.appendingPathComponent(
            keys[0],
            isDirectory: true
        )
        try FileManager.default.copyItem(
            at: prepared.appendingPathComponent(
                keys[0],
                isDirectory: true
            ),
            to: externalGeneration
        )
        let sentinel = externalGeneration.appendingPathComponent(
            "external-sentinel"
        )
        try Data("keep".utf8).write(to: sentinel)
        let displaced = prepared.deletingLastPathComponent()
            .appendingPathComponent(
                "prepared-displaced",
                isDirectory: true
            )

        PlayCoverGenerationPruner.afterProtectedStateForTesting = {
            PlayCoverGenerationPruner.afterProtectedStateForTesting = nil
            try FileManager.default.moveItem(
                at: prepared,
                to: displaced
            )
            try FileManager.default.createSymbolicLink(
                at: prepared,
                withDestinationURL: external
            )
        }
        let result =
            PlayCoverGenerationPruner.pruneAfterSuccessfulStart(
                paths: fixture.paths,
                currentGenerationKey: keys[7]
            )

        XCTAssertEqual(
            Set(result.removedGenerationKeys),
            Set([keys[0], keys[1]])
        )
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path),
            "anchored GC must never delete through the swapped symlink"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: externalGeneration.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: displaced.appendingPathComponent(keys[0]).path
            )
        )
    }

    private func waitForFile(_ url: URL) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw XCTSkip("child process did not reach lock attempt")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    convenience init() where Value: ExpressibleByNilLiteral {
        self.init(nil)
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}

private struct CacheMaintenanceFixture {
    let root: URL
    let paths: IOSUsePaths

    init(createPlayCoverRun: Bool = true) throws {
        root = URL(
            fileURLWithPath:
                "/tmp/iu-cache-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": root.path]
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        if createPlayCoverRun {
            try FileManager.default.createDirectory(
                atPath: paths.playcoverRun,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(paths.playcoverRun, 0o700)
        }
    }

    func createGeneration(
        key: String,
        completedAt: String,
        completedSchemaVersion: Int = 5
    ) throws {
        _ = try PlayCoverManagedAppService.secureManagedDirectories(
            paths: paths
        )
        let registry = URL(
            fileURLWithPath: paths.playcoverGlobalLocks,
            isDirectory: true
        ).appendingPathComponent("registry-v1.json")
        if !FileManager.default.fileExists(atPath: registry.path) {
            // These tests materialize completed generations below the
            // service boundary. Establish the durable registry first, as
            // production beginPreparation does before staging any object.
            try PlayCoverGlobalReferenceStore.updateLast(
                generationKey: String(repeating: "0", count: 64),
                paths: paths
            )
        }
        let directory = generationDirectory(key)
        try FileManager.default.createDirectory(
            at: appURL(key),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)
        _ = chmod(appURL(key).path, 0o755)
        let manifest: [String: Any] = [
            "schemaVersion": 5,
            "backend": "mac",
            "generationKey": key,
            "completedAt": completedAt,
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )
        let completed: [String: Any] = [
            "schemaVersion": completedSchemaVersion,
            "generationKey": key,
            "manifestSHA256": SHA256.hash(data: manifestData)
                .map { String(format: "%02x", $0) }
                .joined(),
            "executableSHA256": String(repeating: "e", count: 64),
            "runtimeSHA256": String(repeating: "f", count: 64),
        ]
        try manifestData.write(
            to: directory.appendingPathComponent(
                PlayCoverService.manifestFilename
            )
        )
        try JSONSerialization.data(
            withJSONObject: completed,
            options: [.sortedKeys]
        ).write(
            to: directory.appendingPathComponent(
                PlayCoverService.completedFilename
            )
        )
    }

    func writeReference(generationKey: String) throws {
        try PlayCoverGlobalReferenceStore.updateLast(
            generationKey: generationKey,
            paths: paths
        )
    }

    var homeReferenceURL: URL {
        URL(
            fileURLWithPath: paths.playcoverGlobalHomes,
            isDirectory: true
        ).appendingPathComponent(
            "\(paths.playcoverHomeID).json",
            isDirectory: false
        )
    }

    func makeForeignHomePaths() -> IOSUsePaths {
        let accountHome = root.appendingPathComponent(
            ".account-global-test",
            isDirectory: true
        )
        let foreignHome = root.appendingPathComponent(
            "foreign-ios-use-home",
            isDirectory: true
        )
        return resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": foreignHome.path],
            accountHomeDirectory: accountHome.path
        )
    }

    func writeDriverLock(generationKey: String) throws {
        let sessionID = UUID().uuidString
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "mac",
                deviceName: "iPhone16,2",
                deviceVersion: "17.0",
                deviceType: PlayCoverSessionService.deviceType,
                runnerPid: 42,
                startMode: "mac",
                sessionIdentifier: sessionID,
                bundleId: "com.example.fixture",
                macAppPath: appURL(generationKey).path,
                macExecutablePath:
                    appURL(generationKey)
                        .appendingPathComponent("Fixture").path,
                macGenerationKey: generationKey,
                macRuntimeSocketPath:
                    try paths.macRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: paths
        )
        try PlayCoverGlobalReferenceStore.setPending(
            sessionID: sessionID,
            generationKey: generationKey,
            paths: paths
        )
        try PlayCoverGlobalReferenceStore.markActive(
            sessionID: sessionID,
            generationKey: generationKey,
            paths: paths
        )
        try PlayCoverGlobalReferenceStore.clearPending(
            sessionID: sessionID,
            generationKey: generationKey,
            paths: paths
        )
    }

    func writePendingIntent(generationKey: String) throws {
        let sessionID = UUID().uuidString.lowercased()
        _ = try PlayCoverPendingLaunchStore.createIntent(
            PlayCoverPendingLaunchStore.Intent(
                sessionID: sessionID,
                runtimeSocketPath:
                    try paths.macRuntimeSocketPath(
                        sessionID: sessionID
                    ),
                generationKey: generationKey,
                appPath: appURL(generationKey).path,
                bundleIdentifier: "com.example.fixture",
                executablePath:
                    appURL(generationKey)
                        .appendingPathComponent("Fixture").path,
                aliasPath: PlayCoverService.sessionLaunchAlias(
                    sessionID: sessionID
                ).bundleURL.path
            ),
            paths: paths
        )
        try PlayCoverGlobalReferenceStore.setPending(
            sessionID: sessionID,
            generationKey: generationKey,
            paths: paths
        )
    }

    func writeInvalidOwnerOnlyHomeReference(
        generationKey: String
    ) throws {
        let reference = homeReferenceURL
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: reference)
            ) as? [String: Any]
        )
        object["pending"] = [
            "sessionID": "../hostile-session",
            "generationKey": generationKey,
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: reference)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: reference.path
        )
    }

    func generationExists(_ key: String) -> Bool {
        FileManager.default.fileExists(
            atPath: generationDirectory(key).path
        )
    }

    func isGenerationSymlink(_ key: String) -> Bool {
        var status = stat()
        return lstat(generationDirectory(key).path, &status) == 0
            && status.st_mode & S_IFMT == S_IFLNK
    }

    func removeSidecar(
        _ name: String,
        generationKey: String
    ) throws {
        try FileManager.default.removeItem(
            at: generationDirectory(generationKey)
                .appendingPathComponent(name)
        )
    }

    func writeSidecar(
        _ data: Data,
        named name: String,
        generationKey: String
    ) throws {
        try data.write(
            to: generationDirectory(generationKey)
                .appendingPathComponent(name),
            options: .atomic
        )
    }

    func writeSidecarJSON(
        _ object: [String: Any],
        named name: String,
        generationKey: String
    ) throws {
        try writeSidecar(
            JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ),
            named: name,
            generationKey: generationKey
        )
    }

    func makeFastVerifiedToken(
        generationKey: String,
        completedAt: String
    ) throws -> PlayCoverFastVerifiedGenerationToken {
        let completed = PlayCoverCompletedGeneration(
            schemaVersion: 5,
            generationKey: generationKey,
            manifestSHA256: String(repeating: "d", count: 64),
            executableSHA256: String(repeating: "e", count: 64),
            runtimeSHA256: String(repeating: "f", count: 64)
        )
        try writeCompleted(
            completed,
            generationKey: generationKey
        )
        return try PlayCoverService
            .uncheckedFastVerifiedGenerationTokenForTesting(
                generationKey: generationKey,
                completedAt: completedAt,
                completed: completed,
                generationURL:
                    generationDirectory(generationKey)
            )
    }

    func writeCompleted(
        _ completed: PlayCoverCompletedGeneration,
        generationKey: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        try writeSidecar(
            encoder.encode(completed),
            named: PlayCoverService.completedFilename,
            generationKey: generationKey
        )
    }

    func replaceGenerationDirectory(
        generationKey: String
    ) throws {
        let original = generationDirectory(generationKey)
        let replacement = original.deletingLastPathComponent()
            .appendingPathComponent(
                ".replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.copyItem(
            at: original,
            to: replacement
        )
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(
            at: replacement,
            to: original
        )
        _ = chmod(original.path, 0o700)
    }

    func truncateSidecar(
        _ name: String,
        generationKey: String,
        byteCount: Int
    ) throws {
        let handle = try FileHandle(
            forWritingTo: generationDirectory(generationKey)
                .appendingPathComponent(name)
        )
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func generationDirectory(_ key: String) -> URL {
        URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(key, isDirectory: true)
    }

    private func appURL(_ key: String) -> URL {
        generationDirectory(key).appendingPathComponent(
            "Fixture.app",
            isDirectory: true
        )
    }
}
