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
        let intent: PlayCoverPendingLaunchStore.Intent
    }

    override func tearDown() {
        PlayCoverService.launchAliasRootOverrideForTesting = nil
        super.tearDown()
    }

    func testJournalHasOnlyThreePhases() throws {
        XCTAssertEqual(
            [
                PlayCoverPendingLaunchStore.Phase.intent,
                .owned,
                .driverLockCommitted,
            ].map(\.rawValue),
            ["intent", "owned", "driverLockCommitted"]
        )
    }

    func testIntentOwnedCommittedAndStrictRemoval() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var record = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        XCTAssertEqual(record.phase, .intent)
        XCTAssertNil(record.owner)
        assertPrivateRegularFile(
            fixture.paths.playcoverPendingLaunch
        )
        assertPrivateRegularFile(
            fixture.paths.playcoverPendingLaunchLock
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.createIntent(
                fixture.intent,
                paths: fixture.paths
            )
        )

        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 123,
            processBirthMicroseconds: 456,
            source: .authenticatedRuntime
        )
        record = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.sessionID,
            owner: owner,
            paths: fixture.paths
        )
        XCTAssertEqual(record.phase, .owned)
        XCTAssertEqual(record.owner, owner)
        XCTAssertEqual(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            ),
            record
        )

        record = try PlayCoverPendingLaunchStore
            .markDriverLockCommitted(
                sessionID: fixture.sessionID,
                paths: fixture.paths
            )
        XCTAssertEqual(record.phase, .driverLockCommitted)
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.remove(
                sessionID: fixture.sessionID,
                expectedPhase: .owned,
                paths: fixture.paths
            )
        )
        try PlayCoverPendingLaunchStore.remove(
            sessionID: fixture.sessionID,
            expectedPhase: .driverLockCommitted,
            paths: fixture.paths
        )
        XCTAssertNil(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
    }

    func testOwnedReplayMustMatchExactOwner() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        let owner = PlayCoverPendingLaunchStore.Owner(
            pid: 71,
            processBirthMicroseconds: 91,
            source: .workspaceCallback
        )
        _ = try PlayCoverPendingLaunchStore.markOwned(
            sessionID: fixture.sessionID,
            owner: owner,
            paths: fixture.paths
        )
        XCTAssertNoThrow(
            try PlayCoverPendingLaunchStore.markOwned(
                sessionID: fixture.sessionID,
                owner: owner,
                paths: fixture.paths
            )
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.markOwned(
                sessionID: fixture.sessionID,
                owner: .init(
                    pid: owner.pid,
                    processBirthMicroseconds:
                        owner.processBirthMicroseconds + 1,
                    source: owner.source
                ),
                paths: fixture.paths
            )
        )
    }

    func testIntentCannotCommitDriverLock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try PlayCoverPendingLaunchStore.createIntent(
            fixture.intent,
            paths: fixture.paths
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore
                .markDriverLockCommitted(
                    sessionID: fixture.sessionID,
                    paths: fixture.paths
                )
        )
    }

    func testUnexpectedFieldAndUnknownPhaseAreRejected() throws {
        for mutation in [
            { (root: inout [String: Any]) in
                root["unexpected"] = true
            },
            { (root: inout [String: Any]) in
                root["phase"] = "unknown"
            },
        ] {
            let fixture = try makeFixture()
            defer {
                try? FileManager.default.removeItem(at: fixture.root)
            }
            _ = try PlayCoverPendingLaunchStore.createIntent(
                fixture.intent,
                paths: fixture.paths
            )
            let url = URL(
                fileURLWithPath:
                    fixture.paths.playcoverPendingLaunch
            )
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: url)
                ) as? [String: Any]
            )
            mutation(&root)
            try replaceJournal(
                JSONSerialization.data(
                    withJSONObject: root,
                    options: [.sortedKeys]
                ),
                at: url
            )
            XCTAssertThrowsError(
                try PlayCoverPendingLaunchStore.load(
                    paths: fixture.paths
                )
            )
        }
    }

    func testJournalSymlinkIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try SessionOperationLock.withExclusiveLock(
            paths: fixture.paths
        ) {}
        let target = fixture.root.appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.paths.playcoverPendingLaunch,
            withDestinationPath: target.path
        )
        XCTAssertThrowsError(
            try PlayCoverPendingLaunchStore.load(
                paths: fixture.paths
            )
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeTemporaryRoot()
        let paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": root.path]
        )
        let sessionID = UUID().uuidString
        let generationKey = String(repeating: "a", count: 64)
        let app = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(
            generationKey,
            isDirectory: true
        ).appendingPathComponent("App.app", isDirectory: true)
        let executable = app.appendingPathComponent("Fixture")
        let aliasRoot = root.appendingPathComponent(
            "launch-aliases",
            isDirectory: true
        )
        PlayCoverService.launchAliasRootOverrideForTesting = aliasRoot
        let intent = PlayCoverPendingLaunchStore.Intent(
            sessionID: sessionID,
            runtimeSocketPath: try paths.macRuntimeSocketPath(
                sessionID: sessionID
            ),
            generationKey: generationKey,
            appPath: app.path,
            bundleIdentifier: "com.example.fixture",
            executablePath: executable.path,
            aliasPath: PlayCoverService.sessionLaunchAlias(
                sessionID: sessionID
            ).bundleURL.path
        )
        return Fixture(
            root: root,
            paths: paths,
            sessionID: sessionID,
            intent: intent
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        #if canImport(Darwin)
        var template = Array("/tmp/iu-pending-XXXXXX".utf8CString)
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
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
        #endif
    }

    private func replaceJournal(
        _ data: Data,
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
        XCTAssertEqual(lstat(path, &status), 0, file: file, line: line)
        XCTAssertEqual(
            status.st_mode & S_IFMT,
            S_IFREG,
            file: file,
            line: line
        )
        XCTAssertEqual(
            status.st_mode & 0o777,
            0o600,
            file: file,
            line: line
        )
        XCTAssertEqual(status.st_nlink, 1, file: file, line: line)
        #endif
    }
}
