import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI

final class PlayCoverPendingLaunchStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let paths: IOSUsePaths
        let sessionID: String
        let generationKey: String
        let appPath: String
        let executablePath: String
        let inventory: [PlayCoverPendingLaunchStore.AliasEntry]
        let intent: PlayCoverPendingLaunchStore.Intent
    }

    override func tearDown() {
        PlayCoverService.launchAliasRootOverrideForTesting = nil
        super.tearDown()
    }

    func testDurableJournalFollowsTheCompleteLifecycle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var record = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        XCTAssertEqual(record.phase, .intent)
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.createIntent(
                fixture.intent,
                paths: fixture.paths
            )
        )
        assertPrivateRegularFile(
            fixture.paths.playcoverPendingLaunch
        )
        assertPrivateRegularFile(
            fixture.paths.playcoverPendingLaunchLock
        )

        record = try PlayCoverPendingLaunchStore.markAliasReady(
            sessionID: fixture.sessionID,
            device: 42,
            inode: 84,
            inventory: fixture.inventory,
            paths: fixture.paths
        )
        XCTAssertEqual(record.phase, .aliasReady)

        let bootSessionID = UUID().uuidString
        record = try PlayCoverPendingLaunchStore
            .markSubmissionArmed(
                sessionID: fixture.sessionID,
                bootSessionUUID: bootSessionID,
                paths: fixture.paths
            )
        XCTAssertEqual(record.phase, .submissionArmed)
        XCTAssertEqual(
            record.submissionBootSessionUUID,
            bootSessionID.lowercased()
        )

        let callbackOwner = PlayCoverPendingLaunchStore.Owner(
            pid: 123,
            processBirthMicroseconds: 456,
            source: .workspaceCallback
        )
        record = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.sessionID,
            owner: callbackOwner,
            callbackSucceeded: true,
            paths: fixture.paths
        )
        XCTAssertEqual(record.phase, .owned)
        XCTAssertEqual(record.terminalCallback?.outcome, .success)

        let authenticatedOwner = PlayCoverPendingLaunchStore.Owner(
            pid: callbackOwner.pid,
            processBirthMicroseconds:
                callbackOwner.processBirthMicroseconds,
            source: .authenticatedRuntime
        )
        record = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.sessionID,
            owner: authenticatedOwner,
            callbackSucceeded: false,
            paths: fixture.paths
        )
        XCTAssertEqual(record.owner, callbackOwner)

        record = try PlayCoverPendingLaunchStore
            .markDriverLockCommitted(
                sessionID: fixture.sessionID,
                paths: fixture.paths
            )
        XCTAssertEqual(record.phase, .driverLockCommitted)

        record = try PlayCoverPendingLaunchStore
            .markConfirmedStopped(
                sessionID: fixture.sessionID,
                cleanupProof: .stoppedExactOwner,
                paths: fixture.paths
            )
        XCTAssertEqual(record.phase, .confirmedStopped)
        XCTAssertEqual(record.cleanupProof, .stoppedExactOwner)

        try PlayCoverPendingLaunchStore.removeConfirmed(
            sessionID: fixture.sessionID,
            paths: fixture.paths
        )
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.paths.playcoverPendingLaunchLock
            )
        )
    }

    func testTerminalFailureCanBeFollowedByAuthenticatedOwner()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try advanceToSubmissionArmed(fixture)

        var record = try PlayCoverPendingLaunchStore
            .markTerminalCallbackFailure(
                sessionID: fixture.sessionID,
                errorDescription: "LaunchServices rejected callback",
                paths: fixture.paths
            )
        XCTAssertEqual(record.phase, .terminalCallback)
        XCTAssertEqual(record.terminalCallback?.outcome, .failure)

        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 991,
            processBirthMicroseconds: 992,
            source: .authenticatedRuntime
        )
        record = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.sessionID,
            owner: owner,
            callbackSucceeded: false,
            paths: fixture.paths
        )
        XCTAssertEqual(record.phase, .owned)
        XCTAssertEqual(record.owner, owner)
        XCTAssertEqual(record.terminalCallback?.outcome, .failure)
    }

    func testDurableDriverLockRetiresMatchingPendingJournal()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try advanceToSubmissionArmed(fixture)
        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 601,
            processBirthMicroseconds: 602,
            source: .authenticatedRuntime
        )
        _ = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.sessionID,
            owner: owner,
            callbackSucceeded: false,
            paths: fixture.paths
        )
        try PlayCoverGlobalReferenceStore.setPending(
            sessionID: fixture.sessionID,
            generationKey: fixture.generationKey,
            paths: fixture.paths
        )
        let result = PlayCoverSessionService.LaunchResult(
            sessionID: fixture.sessionID,
            appPath: fixture.appPath,
            bundleIdentifier: "com.example.fixture",
            executablePath: fixture.executablePath,
            generationKey: fixture.generationKey,
            productType: "iPhone16,2",
            pid: owner.pid,
            runtimeSocketPath:
                fixture.intent.runtimeSocketPath,
            usesPendingLaunchJournal: true,
            reused: true
        )

        try PlayCoverSessionService
            .retirePendingLaunchJournalAfterDriverCommit(
                result: result,
                paths: fixture.paths
            )

        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
    }

    func testInvalidBootAndCleanupTransitionsDoNotMutateJournal()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )

        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.markSubmissionArmed(
                sessionID: fixture.sessionID,
                bootSessionUUID: "not-a-uuid",
                paths: fixture.paths
            )
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.markConfirmedStopped(
                sessionID: fixture.sessionID,
                cleanupProof: .stoppedExactOwner,
                paths: fixture.paths
            )
        )
        XCTAssertEqual(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )?.phase,
            .intent
        )

        let confirmed = try PlayCoverPendingLaunchStore
            .markConfirmedStopped(
                sessionID: fixture.sessionID,
                cleanupProof: .neverSubmitted,
                paths: fixture.paths
            )
        XCTAssertEqual(confirmed.phase, .confirmedStopped)
        XCTAssertEqual(confirmed.cleanupProof, .neverSubmitted)
    }

    func testConflictingOwnerAndCallbackEvidenceFailsClosed()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try advanceToSubmissionArmed(fixture)

        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 7,
            processBirthMicroseconds: 8,
            source: .authenticatedRuntime
        )
        _ = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.sessionID,
            owner: owner,
            callbackSucceeded: false,
            paths: fixture.paths
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.markOwned(
                sessionID: fixture.sessionID,
                owner: PlayCoverPendingLaunchStore.Owner(
                    pid: owner.pid,
                    processBirthMicroseconds:
                        owner.processBirthMicroseconds + 1,
                    source: .workspaceCallback
                ),
                callbackSucceeded: true,
                paths: fixture.paths
            )
        )

        _ = try PlayCoverPendingLaunchStore
            .markTerminalCallbackFailure(
                sessionID: fixture.sessionID,
                errorDescription: "terminal",
                paths: fixture.paths
            )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.markOwned(
                sessionID: fixture.sessionID,
                owner: PlayCoverPendingLaunchStore.Owner(
                    pid: owner.pid,
                    processBirthMicroseconds:
                        owner.processBirthMicroseconds,
                    source: .workspaceCallback
                ),
                callbackSucceeded: true,
                paths: fixture.paths
            )
        )
    }

    func testJournalRejectsUnknownFieldsAndUnsafeFileTypes()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )

        let journal = URL(
            fileURLWithPath: fixture.paths.playcoverPendingLaunch
        )
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: journal)
            ) as? [String: Any]
        )
        object["unexpected"] = true
        try replaceJournal(
            with: try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ),
            at: journal
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )

        try FileManager.default.removeItem(at: journal)
        let victim = fixture.root.appendingPathComponent("victim")
        try Data("{}".utf8).write(to: victim)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: victim.path
        )
        #if canImport(Darwin)
        XCTAssertEqual(
            Darwin.link(victim.path, journal.path),
            0,
            "hardlink fixture failed with errno \(errno)"
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        try FileManager.default.removeItem(at: journal)
        XCTAssertEqual(
            Darwin.symlink(victim.path, journal.path),
            0,
            "symlink fixture failed with errno \(errno)"
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        try FileManager.default.removeItem(at: journal)
        try Data(
            repeating: 0x61,
            count: PlayCoverPendingLaunchStore.maximumBytes + 1
        ).write(to: journal)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: journal.path
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        try replaceJournal(
            with: Data("{}".utf8),
            at: journal
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: journal.path
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        try FileManager.default.removeItem(at: journal)
        XCTAssertEqual(
            Darwin.mkfifo(journal.path, 0o600),
            0,
            "FIFO fixture failed with errno \(errno)"
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        #endif
    }

    func testUnsafeLockIsRejectedEvenWhenJournalIsAbsent()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        try FileManager.default.removeItem(
            atPath: fixture.paths.playcoverPendingLaunch
        )
        try FileManager.default.removeItem(
            atPath: fixture.paths.playcoverPendingLaunchLock
        )
        let victim = fixture.root.appendingPathComponent("lock-victim")
        try Data().write(to: victim)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: victim.path
        )
        #if canImport(Darwin)
        XCTAssertEqual(
            Darwin.link(
                victim.path,
                fixture.paths.playcoverPendingLaunchLock
            ),
            0,
            "hardlink fixture failed with errno \(errno)"
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
        var victimStatus = stat()
        XCTAssertEqual(
            Darwin.lstat(victim.path, &victimStatus),
            0
        )
        XCTAssertEqual(victimStatus.st_mode & 0o7777, 0o600)
        XCTAssertEqual(victimStatus.st_nlink, 2)
        #endif
    }

    func testNonCanonicalIdentityAndUnsortedInventoryAreRejected()
        throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var badIntent = fixture.intent
        badIntent = PlayCoverPendingLaunchStore.Intent(
            sessionID: badIntent.sessionID,
            runtimeSocketPath:
                fixture.paths.playcoverRun + "/../run/"
                    + URL(
                        fileURLWithPath:
                            badIntent.runtimeSocketPath
                      ).lastPathComponent,
            generationKey: badIntent.generationKey,
            appPath: badIntent.appPath,
            bundleIdentifier: badIntent.bundleIdentifier,
            executablePath: badIntent.executablePath,
            aliasPath: badIntent.aliasPath
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.createIntent(
                badIntent,
                paths: fixture.paths
            )
        )

        badIntent = PlayCoverPendingLaunchStore.Intent(
            sessionID: fixture.intent.sessionID,
            runtimeSocketPath: fixture.intent.runtimeSocketPath,
            generationKey: fixture.intent.generationKey,
            appPath: fixture.appPath + "/../Fixture.app",
            bundleIdentifier: fixture.intent.bundleIdentifier,
            executablePath: fixture.intent.executablePath,
            aliasPath: fixture.intent.aliasPath
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.createIntent(
                badIntent,
                paths: fixture.paths
            )
        )

        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.markAliasReady(
                sessionID: fixture.sessionID,
                device: 1,
                inode: 2,
                inventory: fixture.inventory.reversed(),
                paths: fixture.paths
            )
        )
    }

    func testPrivateTmpIdentityRemainsValidAfterPathsExist()
        throws {
        #if canImport(Darwin)
        let root = try makeTemporaryRoot(
            templatePath: "/private/tmp/iu-pending-XXXXXX"
        )
        let fixture = try makeFixture(root: root)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: URL(
                fileURLWithPath: fixture.appPath,
                isDirectory: true
            ),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data().write(
            to: URL(
                fileURLWithPath: fixture.executablePath,
                isDirectory: false
            )
        )

        var record = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        let inventory = fixture.inventory.map {
            PlayCoverPendingLaunchStore.AliasEntry(
                name: $0.name,
                destination:
                    record.appPath + "/" + $0.name
            )
        }
        for entry in inventory {
            XCTAssertEqual(
                entry.destination,
                record.appPath + "/" + entry.name
            )
        }
        record = try PlayCoverPendingLaunchStore.markAliasReady(
            sessionID: fixture.sessionID,
            device: 42,
            inode: 84,
            inventory: inventory,
            paths: fixture.paths
        )

        XCTAssertEqual(record.appPath, fixture.appPath)
        XCTAssertEqual(record.executablePath, fixture.executablePath)
        XCTAssertEqual(record.aliasInventory, inventory)
        XCTAssertEqual(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            ),
            record
        )
        #endif
    }

    func testUnsafeManagedDirectoryDoesNotLookLikeNoPendingLaunch()
        throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": root.path]
        )
        try Data("not a directory".utf8).write(
            to: URL(fileURLWithPath: paths.playcover)
        )

        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(paths: paths)
        )
    }

    private func makeFixture(root explicitRoot: URL? = nil)
        throws -> Fixture {
        let root: URL
        if let explicitRoot {
            root = explicitRoot
        } else {
            root = try makeTemporaryRoot()
        }
        let paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": root.path]
        )
        let sessionID = UUID().uuidString.lowercased()
        let generationKey = String(repeating: "a", count: 64)
        let app = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        )
        .appendingPathComponent(generationKey, isDirectory: true)
        .appendingPathComponent("Fixture.app", isDirectory: true)
        let executable = app.appendingPathComponent(
            "Fixture",
            isDirectory: false
        )
        let aliasRoot = root.appendingPathComponent(
            "launch-aliases",
            isDirectory: true
        )
        PlayCoverService.launchAliasRootOverrideForTesting = aliasRoot
        let alias = PlayCoverService.sessionLaunchAlias(
            sessionID: sessionID
        ).bundleURL.path
        let inventory = [
            PlayCoverPendingLaunchStore.AliasEntry(
                name: "Fixture",
                destination: executable.path
            ),
            PlayCoverPendingLaunchStore.AliasEntry(
                name: "Info.plist",
                destination: app.appendingPathComponent(
                    "Info.plist"
                ).path
            ),
        ]
        let intent = PlayCoverPendingLaunchStore.Intent(
            sessionID: sessionID,
            runtimeSocketPath: try paths.macRuntimeSocketPath(
                sessionID: sessionID
            ),
            generationKey: generationKey,
            appPath: app.path,
            bundleIdentifier: "com.example.fixture",
            executablePath: executable.path,
            aliasPath: alias
        )
        return Fixture(
            root: root,
            paths: paths,
            sessionID: sessionID,
            generationKey: generationKey,
            appPath: app.path,
            executablePath: executable.path,
            inventory: inventory,
            intent: intent
        )
    }

    private func makeTemporaryRoot(
        templatePath: String = "/tmp/iu-pending-XXXXXX"
    ) throws -> URL {
        #if canImport(Darwin)
        var template = Array(templatePath.utf8CString)
        guard let pointer = Darwin.mkdtemp(&template) else {
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
        return root
        #else
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "iu-pending-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
        #endif
    }

    @discardableResult
    private func advanceToSubmissionArmed(
        _ fixture: Fixture
    ) throws -> PlayCoverPendingLaunchStore.Record {
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        _ = try PlayCoverPendingLaunchStore.markAliasReady(
            sessionID: fixture.sessionID,
            device: 42,
            inode: 84,
            inventory: fixture.inventory,
            paths: fixture.paths
        )
        return try PlayCoverPendingLaunchStore
            .markSubmissionArmed(
                sessionID: fixture.sessionID,
                bootSessionUUID: UUID().uuidString,
                paths: fixture.paths
            )
    }

    private func replaceJournal(
        with data: Data,
        at url: URL
    ) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func assertPrivateRegularFile(
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        #if canImport(Darwin)
        var status = stat()
        XCTAssertEqual(
            Darwin.lstat(path, &status),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            status.st_mode & S_IFMT,
            S_IFREG,
            file: file,
            line: line
        )
        XCTAssertEqual(
            status.st_mode & 0o7777,
            0o600,
            file: file,
            line: line
        )
        XCTAssertEqual(
            status.st_nlink,
            1,
            file: file,
            line: line
        )
        #endif
    }
}
