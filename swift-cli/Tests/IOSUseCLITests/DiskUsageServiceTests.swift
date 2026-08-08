import Foundation
@testable import IOSUseCLI
import XCTest

final class DiskUsageServiceTests: XCTestCase {
    func testSnapshotReportsCurrentSlotsLegacyCacheAndPersistentData()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try makeSlot(
            bundleIdentifier: "com.example.one",
            displayName: "Example",
            paths: fixture.paths
        )
        try writeBytes(
            8_192,
            to: URL(fileURLWithPath: fixture.paths.playcoverLegacyPrepared)
                .appendingPathComponent("objects/old/App.app/old")
        )
        try writeBytes(
            4_096,
            to: URL(
                fileURLWithPath:
                    fixture.paths.playcoverLegacyLaunchFacades
            ).appendingPathComponent("old.app/link")
        )
        try writeBytes(
            2_048,
            to: URL(
                fileURLWithPath: fixture.paths.playcoverFridaSourceCache
            ).appendingPathComponent("source")
        )
        try writeBytes(
            1_024,
            to: URL(fileURLWithPath: fixture.paths.playcoverPlayChain)
                .appendingPathComponent("com.example.one.db")
        )
        try writeBytes(
            512,
            to: URL(fileURLWithPath: fixture.paths.logs)
                .appendingPathComponent("cli.log")
        )

        let snapshot = DiskUsageService.snapshot(paths: fixture.paths)

        let slot = try XCTUnwrap(snapshot.items.first {
            $0.category == "app-slot"
                && $0.details["bundle"] == "com.example.one"
        })
        XCTAssertEqual(slot.name, "Example")
        XCTAssertEqual(
            slot.details["installRevision"],
            String(repeating: "a", count: 64)
        )
        XCTAssertTrue(slot.complete)
        XCTAssertEqual(
            snapshot.items.filter { $0.category == "legacy-cache" }
                .map(\.name).sorted(),
            ["Legacy launch facades", "Legacy prepared cache"]
        )
        XCTAssertTrue(snapshot.items.contains {
            $0.category == "frida-development"
        })
        XCTAssertTrue(snapshot.items.contains {
            $0.category == "playchain"
                && $0.storageClass == "app-data"
        })
        XCTAssertTrue(snapshot.items.contains {
            $0.scope == "home" && $0.category == "logs"
        })
        XCTAssertEqual(
            Set(snapshot.items.map(\.storageClass)),
            Set([
                "rebuildable-cache",
                "app-data",
                "home-data",
            ])
        )
        let human = snapshot.formatted()
        XCTAssertTrue(human.contains("Rebuildable cache"))
        XCTAssertTrue(human.contains("Persistent App data"))
        XCTAssertTrue(human.contains("IOS_USE_HOME data"))
        XCTAssertTrue(human.contains("Example"))
    }

    func testLegacyGenerationMetadataIsNeverParsedOrRequired() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacyRoot = URL(
            fileURLWithPath: fixture.paths.playcoverLegacyPrepared,
            isDirectory: true
        )
        let invalidManifest = legacyRoot
            .appendingPathComponent("objects/not-a-generation/manifest.json")
        try write(Data("not json".utf8), to: invalidManifest)
        let oldHomeReference = URL(
            fileURLWithPath: fixture.paths.playcover,
            isDirectory: true
        ).appendingPathComponent("last-generation.json")
        try write(Data("poison".utf8), to: oldHomeReference)
        let before = try Data(contentsOf: oldHomeReference)

        let snapshot = DiskUsageService.snapshot(paths: fixture.paths)

        XCTAssertEqual(try Data(contentsOf: oldHomeReference), before)
        XCTAssertTrue(snapshot.items.contains {
            $0.category == "legacy-cache"
                && $0.path == fixture.paths.playcoverLegacyPrepared
        })
        XCTAssertFalse(snapshot.warnings.contains {
            $0.contains("generation") || $0.contains("manifest")
        })
    }

    func testSlotWithInvalidMetadataIsPartialButOtherDataStillReports()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broken = URL(
            fileURLWithPath: fixture.paths.playcoverApps,
            isDirectory: true
        ).appendingPathComponent("com.example.broken")
        try write(Data("{}".utf8), to: broken.appendingPathComponent("slot.json"))
        try writeBytes(
            128,
            to: URL(fileURLWithPath: fixture.paths.playcoverPlayChain)
                .appendingPathComponent("com.example.broken.db")
        )

        let snapshot = DiskUsageService.snapshot(paths: fixture.paths)

        let slot = try XCTUnwrap(snapshot.items.first {
            $0.category == "app-slot"
        })
        XCTAssertFalse(slot.complete)
        XCTAssertTrue(snapshot.warnings.contains {
            $0.contains("cannot read Mac slot metadata")
        })
        XCTAssertTrue(snapshot.items.contains {
            $0.category == "playchain"
        })
    }

    func testWalkerDoesNotFollowSymlinks() throws {
        #if canImport(Darwin)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside.bin")
        try Data(repeating: 7, count: 2 * 1_024 * 1_024).write(to: outside)
        let link = URL(
            fileURLWithPath: fixture.paths.playcoverLegacyPrepared,
            isDirectory: true
        ).appendingPathComponent("outside-link")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outside.path
        )

        let item = try XCTUnwrap(
            DiskUsageService.snapshot(paths: fixture.paths).items.first {
                $0.category == "legacy-cache"
            }
        )
        XCTAssertLessThan(item.bytes, 2 * 1_024 * 1_024)
        #endif
    }

    func testTraversalLimitIsExplicitlyPartial() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for index in 0..<8 {
            try writeBytes(
                64,
                to: URL(
                    fileURLWithPath: fixture.paths.playcoverLegacyPrepared
                ).appendingPathComponent("entry-\(index)")
            )
        }

        let snapshot = DiskUsageService.snapshot(
            paths: fixture.paths,
            traversalEntryLimit: 2
        )

        XCTAssertTrue(snapshot.warnings.contains {
            $0.contains("traversal limit")
        })
        XCTAssertTrue(snapshot.items.contains { !$0.complete })
    }

    func testParserAcceptsDuWithOnlyGlobalJSON() throws {
        let command = try CLIParser.parse(["du", "--json"])
        guard case .du = command else {
            return XCTFail("expected du")
        }
    }

    private struct Fixture {
        let root: URL
        let paths: IOSUsePaths
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(
            fileURLWithPath: "/tmp/iu-du-"
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
        return Fixture(root: root, paths: paths)
    }

    private func makeSlot(
        bundleIdentifier: String,
        displayName: String,
        paths: IOSUsePaths
    ) throws {
        let slot = URL(
            fileURLWithPath: paths.playcoverApps,
            isDirectory: true
        ).appendingPathComponent(bundleIdentifier, isDirectory: true)
        let app = slot.appendingPathComponent("\(displayName).app")
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleDisplayName": displayName,
                "CFBundleExecutable": "Demo",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        try writeBytes(256, to: app.appendingPathComponent("Demo"))
        let metadata = PlayCoverSlotMetadata(
            bundleIdentifier: bundleIdentifier,
            appRelativePath: "\(displayName).app",
            executableRelativePath: "Demo",
            installRevision: String(repeating: "a", count: 64)
        )
        try JSONEncoder().encode(metadata).write(
            to: slot.appendingPathComponent("slot.json")
        )
    }

    private func writeBytes(_ count: Int, to url: URL) throws {
        try write(Data(repeating: 1, count: count), to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url)
    }
}
