import Darwin
import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverCacheMaintenanceTests: XCTestCase {
    override func tearDown() {
        PlayCoverGenerationPruner.afterProtectedStateForTesting = nil
        super.tearDown()
    }

    func testStartTimingRendersEveryRequestedPhase() {
        let timing = PlayCoverStartTiming(
            inspectNanoseconds: 1_500_000,
            cloneNanoseconds: nil,
            convertNanoseconds: 2_000_000,
            signNanoseconds: 3_200_000,
            verifyNanoseconds: 4_000_000,
            launchNanoseconds: 5_500_000,
            totalNanoseconds: 16_300_000
        )

        XCTAssertEqual(
            timing.outputLine,
            "inspect=1.5ms clone=skipped convert=2.0ms "
                + "sign=3.2ms verify=4.0ms launch=5.5ms "
                + "total=16.3ms"
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
            .appendingPathComponent("playcover")
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
        completedAt: String
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
            "schemaVersion": 3,
            "backend": "playcover-headless",
            "generationKey": key,
            "completedAt": completedAt,
        ]
        let completed: [String: Any] = [
            "schemaVersion": 2,
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
                udid: "playcover:com.example.fixture",
                deviceName: "iPhone16,2",
                deviceVersion: "17.0",
                deviceType: PlayCoverSessionService.deviceType,
                runnerPid: 42,
                startMode: "playcover",
                sessionIdentifier: sessionID,
                bundleId: "com.example.fixture",
                playCoverAppPath: appURL(generationKey).path,
                playCoverExecutablePath:
                    appURL(generationKey)
                        .appendingPathComponent("Fixture").path,
                playCoverGenerationKey: generationKey,
                playCoverRuntimeSocketPath:
                    try paths.playCoverRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: paths
        )
    }

    func generationExists(_ key: String) -> Bool {
        FileManager.default.fileExists(
            atPath: generationDirectory(key).path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func generationDirectory(_ key: String) -> URL {
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
