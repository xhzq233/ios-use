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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: external.appendingPathComponent(
                    "operation.lock"
                ).path
            )
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
                fileURLWithPath: fixture.paths.playcoverPrepared,
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
                        fileURLWithPath: fixture.paths.playcoverPrepared,
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
                completedSchemaVersion: index == 0 ? 2 : 4
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
        try fixture.writePendingIntent(generationKey: keys[0])

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

    func testPruneFailsClosedForInvalidOwnerOnlyPendingLaunch()
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
        try fixture.writeInvalidOwnerOnlyPendingLaunch(
            generationKey: keys[0]
        )
        let transientName =
            ".staging-\(keys[0])-\(UUID().uuidString)"
        let transient = URL(
            fileURLWithPath: fixture.paths.playcoverPrepared,
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
            result.warnings[0].contains(
                "prepared cache could not be safely pruned"
            )
        )
        for key in keys {
            XCTAssertTrue(fixture.generationExists(key))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: transient.path),
            "invalid pending launch must skip transaction residue cleanup"
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
                "schemaVersion": 4,
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
        try Data("not-json".utf8).write(
            to: URL(
                fileURLWithPath:
                    fixture.paths.playcoverLastPrepared
            )
        )
        try fixture.writeDriverLock(generationKey: keys[4])

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
                "generationKey": corruptKeys[5],
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
            fileURLWithPath: fixture.paths.playcoverPrepared,
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
        paths = IOSUsePaths.resolve(
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
        completedSchemaVersion: Int = 4
    ) throws {
        let directory = generationDirectory(key)
        try FileManager.default.createDirectory(
            at: appURL(key),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)
        _ = chmod(appURL(key).path, 0o755)
        let manifest: [String: Any] = [
            "schemaVersion": 4,
            "backend": "mac",
            "generationKey": key,
            "completedAt": completedAt,
        ]
        let completed: [String: Any] = [
            "schemaVersion": completedSchemaVersion,
            "generationKey": key,
        ]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(
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
        try FileManager.default.createDirectory(
            atPath: paths.playcover,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let reference: [String: Any] = [
            "schemaVersion": 3,
            "appPath": appURL(generationKey).path,
            "bundleIdentifier": "com.example.fixture",
            "executablePath":
                appURL(generationKey)
                    .appendingPathComponent("Fixture").path,
            "generationKey": generationKey,
        ]
        try JSONSerialization.data(
            withJSONObject: reference,
            options: [.sortedKeys]
        ).write(
            to: URL(
                fileURLWithPath: paths.playcoverLastPrepared
            )
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
    }

    func writeInvalidOwnerOnlyPendingLaunch(
        generationKey: String
    ) throws {
        try writePendingIntent(generationKey: generationKey)
        let journal = URL(
            fileURLWithPath: paths.playcoverPendingLaunch
        )
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: journal)
            ) as? [String: Any]
        )
        object["phase"] = "owned"
        object["owner"] = [
            "pid": 42,
            "processBirthMicroseconds": 84,
            "source": "workspaceCallback",
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: journal)
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
            schemaVersion: 4,
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
            fileURLWithPath: paths.playcoverPrepared,
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
