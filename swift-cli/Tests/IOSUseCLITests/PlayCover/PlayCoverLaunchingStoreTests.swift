import Foundation
@testable import IOSUseCLI
import XCTest

final class PlayCoverLaunchingStoreTests: XCTestCase {
    func testRoundTripPersistsOnePhaseFreeRecord() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionID = UUID().uuidString
        let record = PlayCoverLaunchingStore.Record(
            sessionID: sessionID,
            runtimeSocketPath: try fixture.paths.macRuntimeSocketPath(
                sessionID: sessionID
            ),
            bundleIdentifier: "com.example.demo",
            executableRelativePath: "Demo",
            submittedAt: 42,
            logPath: nil
        )

        try PlayCoverLaunchingStore.create(record, paths: fixture.paths)

        XCTAssertEqual(
            try PlayCoverLaunchingStore.load(paths: fixture.paths),
            record
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: URL(
                        fileURLWithPath: fixture.paths.playcoverLaunching
                    )
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "sessionID",
                "runtimeSocketPath",
                "bundleIdentifier",
                "executableRelativePath",
                "submittedAt",
            ])
        )

        try PlayCoverLaunchingStore.remove(
            sessionID: sessionID,
            paths: fixture.paths
        )
        XCTAssertNil(try PlayCoverLaunchingStore.load(paths: fixture.paths))
    }

    func testCreateRejectsASecondUnresolvedLaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try record(paths: fixture.paths)
        try PlayCoverLaunchingStore.create(first, paths: fixture.paths)

        XCTAssertThrowsError(
            try PlayCoverLaunchingStore.create(
                try record(paths: fixture.paths),
                paths: fixture.paths
            )
        )
    }

    func testRemoveRefusesAnotherSession() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let value = try record(paths: fixture.paths)
        try PlayCoverLaunchingStore.create(value, paths: fixture.paths)

        XCTAssertThrowsError(
            try PlayCoverLaunchingStore.remove(
                sessionID: UUID().uuidString,
                paths: fixture.paths
            )
        )
        XCTAssertEqual(
            try PlayCoverLaunchingStore.load(paths: fixture.paths),
            value
        )
    }

    private func record(
        paths: IOSUsePaths
    ) throws -> PlayCoverLaunchingStore.Record {
        let sessionID = UUID().uuidString
        return PlayCoverLaunchingStore.Record(
            sessionID: sessionID,
            runtimeSocketPath: try paths.macRuntimeSocketPath(
                sessionID: sessionID
            ),
            bundleIdentifier: "com.example.demo",
            executableRelativePath: "Demo",
            submittedAt: 1,
            logPath: nil
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        paths: IOSUsePaths
    ) {
        let root = URL(
            fileURLWithPath: "/tmp/iu-launch-"
                + String(UUID().uuidString.prefix(8)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": root.appendingPathComponent("home").path,
            ],
            accountHomeDirectoryOverrideForTesting:
                root.appendingPathComponent("account").path,
            socketRootOverrideForTesting:
                root.appendingPathComponent("sockets").path
        )
        return (root, paths)
    }
}
