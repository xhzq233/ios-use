import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI

final class DiskUsageServiceTests: XCTestCase {
    func testParserAcceptsDuWithGlobalJSONOnly() throws {
        XCTAssertEqual(try CLIParser.parse(["du"]), .du)
        XCTAssertEqual(
            try CLIParser.parseInvocation(["du", "--json"]),
            ParsedInvocation(command: .du, json: true)
        )
        XCTAssertThrowsError(try CLIParser.parse(["du", "extra"]))
    }

    func testSnapshotReportsSharedMacDataAndEveryKnownHome()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeCurrentHomeData()
        try fixture.writeMacCacheData()
        let other = try fixture.makeOtherHome()
        IOSUseHomeDiscoveryStore.registerIfExisting(paths: fixture.paths)
        IOSUseHomeDiscoveryStore.registerIfExisting(paths: other)

        let snapshot = DiskUsageService.snapshot(paths: fixture.paths)

        XCTAssertTrue(snapshot.warnings.isEmpty, snapshot.warnings.joined(separator: "\n"))
        XCTAssertTrue(snapshot.items.contains {
            $0.scope == "mac"
                && $0.category == "prepared"
                && $0.name == "Fixture"
                && $0.details["bundle"] == "com.example.fixture"
                && $0.details["capability"] == "base"
                && $0.bytes > 0
                && $0.modifiedAt != nil
        })
        XCTAssertTrue(snapshot.items.contains {
            $0.scope == "mac" && $0.category == "frida-engine"
        })
        XCTAssertTrue(snapshot.items.contains {
            $0.scope == "mac" && $0.category == "playchain"
        })
        XCTAssertTrue(snapshot.items.contains {
            $0.scope == "home"
                && $0.category == "logs"
                && $0.details["homeID"] == fixture.paths.playcoverHomeID
        })
        XCTAssertTrue(snapshot.items.contains {
            $0.scope == "home"
                && $0.category == "artifacts"
                && $0.details["homeID"] == other.playcoverHomeID
        })
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
    }

    func testDuIsReadOnlyAndIgnoresCorruptDriverLock() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeCurrentHomeData()
        let state = URL(fileURLWithPath: fixture.paths.root)
            .appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: state,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: state.appendingPathComponent("driver.lock")
        )
        let descriptor = URL(
            fileURLWithPath: fixture.paths.knownHomes,
            isDirectory: true
        ).appendingPathComponent("\(fixture.paths.playcoverHomeID).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.path))

        let result = IOSUseCLI(pathsForTesting: fixture.paths)
            .run(arguments: ["du", "--json"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.logs + "/cli.log"
            ),
            "du must not create its own performance log"
        )
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        XCTAssertEqual(envelope["command"] as? String, "du")
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertNotNil(data["totalBytes"] as? Int)
        XCTAssertFalse(try XCTUnwrap(data["items"] as? [[String: Any]]).isEmpty)
    }

    func testNonStartCommandDoesNotRegisterHome()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            atPath: fixture.paths.root,
            withIntermediateDirectories: true
        )
        let descriptor = URL(
            fileURLWithPath: fixture.paths.knownHomes,
            isDirectory: true
        ).appendingPathComponent("\(fixture.paths.playcoverHomeID).json")

        _ = IOSUseCLI(
            pathsForTesting: fixture.paths,
            registerHomesForDiskUsage: true
        )
            .run(arguments: ["stop"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.path))
    }

    func testWalkerDoesNotFollowSymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let logs = URL(fileURLWithPath: fixture.paths.logs, isDirectory: true)
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        let outside = fixture.root.appendingPathComponent("outside.bin")
        try Data(repeating: 0x41, count: 2 * 1_024 * 1_024)
            .write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: logs.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        let snapshot = DiskUsageService.snapshot(paths: fixture.paths)
        let logItem = try XCTUnwrap(snapshot.items.first {
            $0.scope == "home" && $0.category == "logs"
        })
        XCTAssertLessThan(logItem.bytes, 512 * 1_024)
    }

    func testSnapshotDistinguishesMissingAndEmptyCurrentHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let missing = DiskUsageService.snapshot(paths: fixture.paths)
        XCTAssertTrue(missing.items.contains {
            $0.scope == "home"
                && $0.category == "missing"
                && $0.path == fixture.paths.root
                && !$0.exists
        })

        try FileManager.default.createDirectory(
            atPath: fixture.paths.root,
            withIntermediateDirectories: true
        )
        let empty = DiskUsageService.snapshot(paths: fixture.paths)
        XCTAssertTrue(empty.items.contains {
            $0.scope == "home"
                && $0.category == "empty"
                && $0.path == fixture.paths.root
                && $0.exists
        })
        XCTAssertTrue(empty.formatted().contains("  0 B  "))
    }

    func testSnapshotWarnsAndContinuesForInvalidHomeRecords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            atPath: fixture.paths.knownHomes,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let invalidName = String(repeating: "b", count: 64) + ".json"
        let oversizedName = String(repeating: "c", count: 64) + ".json"
        let invalid = URL(fileURLWithPath: fixture.paths.knownHomes)
            .appendingPathComponent(invalidName)
        let oversized = URL(fileURLWithPath: fixture.paths.knownHomes)
            .appendingPathComponent(oversizedName)
        try Data("not-json".utf8).write(to: invalid)
        try Data(repeating: 0x41, count: 8 * 1_024 + 1)
            .write(to: oversized)
        XCTAssertEqual(chmod(invalid.path, 0o600), 0)
        XCTAssertEqual(chmod(oversized.path, 0o600), 0)

        let snapshot = DiskUsageService.snapshot(paths: fixture.paths)

        XCTAssertTrue(snapshot.warnings.contains {
            $0.contains(invalidName)
        })
        XCTAssertTrue(snapshot.warnings.contains {
            $0.contains(oversizedName)
        })
    }

    func testSnapshotReportsIncompletePreparedStagingWithoutManifestNoise()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staging = URL(
            fileURLWithPath: fixture.paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(".staging-fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(
            to: staging.appendingPathComponent("partial.bin")
        )

        let snapshot = DiskUsageService.snapshot(paths: fixture.paths)

        XCTAssertTrue(snapshot.items.contains {
            $0.category == "prepared"
                && $0.name == "incomplete .staging-fixture"
                && $0.details["generation"] == ".staging-fixture"
                && $0.details["capability"] == nil
        })
        XCTAssertFalse(snapshot.warnings.contains {
            $0.contains(".staging-fixture/manifest.json")
        })
    }
}

private extension DiskUsageServiceTests {
    final class Fixture {
        let root: URL
        let account: URL
        let paths: IOSUsePaths

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-use-du-\(UUID().uuidString)")
            account = root.appendingPathComponent("account", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(
                at: account,
                withIntermediateDirectories: true
            )
            paths = IOSUsePaths.resolve(
                environment: ["IOS_USE_HOME": home.path],
                accountHomeDirectoryOverrideForTesting: account.path,
                socketRootOverrideForTesting:
                    root.appendingPathComponent("sockets").path
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func writeCurrentHomeData() throws {
            let logs = URL(fileURLWithPath: paths.logs, isDirectory: true)
            let artifacts = URL(fileURLWithPath: paths.artifacts, isDirectory: true)
            try FileManager.default.createDirectory(
                at: logs,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: artifacts,
                withIntermediateDirectories: true
            )
            try Data("driver log".utf8).write(
                to: logs.appendingPathComponent("driver.log")
            )
            try Data("artifact".utf8).write(
                to: artifacts.appendingPathComponent("capture.bin")
            )
        }

        func writeMacCacheData() throws {
            let generation = String(repeating: "a", count: 64)
            let generationURL = URL(
                fileURLWithPath: paths.playcoverGlobalObjects,
                isDirectory: true
            ).appendingPathComponent(generation, isDirectory: true)
            let app = generationURL.appendingPathComponent(
                "App.app",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: app,
                withIntermediateDirectories: true
            )
            let plist: [String: Any] = [
                "CFBundleDisplayName": "Fixture",
                "CFBundleIdentifier": "com.example.fixture",
            ]
            try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            ).write(to: app.appendingPathComponent("Info.plist"))
            try JSONSerialization.data(withJSONObject: [
                "fridaEnabled": false,
            ]).write(to: generationURL.appendingPathComponent("manifest.json"))

            let engine = URL(
                fileURLWithPath: paths.playcoverFridaEngineObjects,
                isDirectory: true
            ).appendingPathComponent("engine", isDirectory: true)
            try FileManager.default.createDirectory(
                at: engine,
                withIntermediateDirectories: true
            )
            try Data("engine".utf8).write(
                to: engine.appendingPathComponent("binary")
            )
            let playchain = URL(
                fileURLWithPath: paths.playcoverPlayChain,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: playchain,
                withIntermediateDirectories: true
            )
            try Data("db".utf8).write(
                to: playchain.appendingPathComponent("fixture.db")
            )
        }

        func makeOtherHome() throws -> IOSUsePaths {
            let otherRoot = root.appendingPathComponent(
                "other-home",
                isDirectory: true
            )
            let other = IOSUsePaths.resolve(
                environment: ["IOS_USE_HOME": otherRoot.path],
                accountHomeDirectoryOverrideForTesting: account.path,
                socketRootOverrideForTesting:
                    root.appendingPathComponent("sockets").path
            )
            try FileManager.default.createDirectory(
                atPath: other.artifacts,
                withIntermediateDirectories: true
            )
            try Data("other artifact".utf8).write(
                to: URL(fileURLWithPath: other.artifacts)
                    .appendingPathComponent("other.bin")
            )
            return other
        }
    }
}
