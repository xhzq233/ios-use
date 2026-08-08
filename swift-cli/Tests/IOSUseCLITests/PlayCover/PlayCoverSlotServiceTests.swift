import Foundation
@testable import IOSUseCLI
import XCTest

final class PlayCoverSlotServiceTests: XCTestCase {
    func testFirstInstallRenamePublishesExactlyOneDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".staging-demo")
        let current = root.appendingPathComponent("com.example.demo")
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        try Data("new".utf8).write(
            to: staging.appendingPathComponent("marker")
        )

        try PlayCoverSlotService.publishForTesting(
            staging: staging,
            current: current,
            replacing: false,
            appsRoot: root
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(
            try String(
                contentsOf: current.appendingPathComponent("marker"),
                encoding: .utf8
            ),
            "new"
        )
    }

    func testUpdateSwapNeverDeletesCurrentBeforeReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".staging-demo")
        let current = root.appendingPathComponent("com.example.demo")
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: current,
            withIntermediateDirectories: false
        )
        try Data("new".utf8).write(
            to: staging.appendingPathComponent("marker")
        )
        try Data("old".utf8).write(
            to: current.appendingPathComponent("marker")
        )

        try PlayCoverSlotService.publishForTesting(
            staging: staging,
            current: current,
            replacing: true,
            appsRoot: root
        )

        XCTAssertEqual(
            try String(
                contentsOf: current.appendingPathComponent("marker"),
                encoding: .utf8
            ),
            "new"
        )
        XCTAssertEqual(
            try String(
                contentsOf: staging.appendingPathComponent("marker"),
                encoding: .utf8
            ),
            "old"
        )
    }

    func testResidueRecoveryIsScopedToOneBundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = "com.example.demo"
        let prefix = PlayCoverSlotService.stagingPrefixForTesting(
            bundleIdentifier: bundle
        )
        let otherPrefix = PlayCoverSlotService.stagingPrefixForTesting(
            bundleIdentifier: "com.example.other"
        )
        let ownResidue = root.appendingPathComponent(prefix + "one")
        let otherResidue = root.appendingPathComponent(otherPrefix + "two")
        let current = root.appendingPathComponent(bundle)
        for directory in [ownResidue, otherResidue, current] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }

        try PlayCoverSlotService.recoverResiduesForTesting(
            bundleIdentifier: bundle,
            appsRoot: root
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ownResidue.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: otherResidue.path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testReadRequiresOneAppSlotMetadataAndAlwaysOnFrameworks() throws {
        let fixture = try makeSlotFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let slot = try PlayCoverSlotService.read(
            bundleIdentifier: fixture.bundleIdentifier,
            paths: fixture.paths,
            expectedInstallRevision: fixture.installRevision
        )

        XCTAssertEqual(slot.metadata.bundleIdentifier, fixture.bundleIdentifier)
        XCTAssertEqual(slot.metadata.appRelativePath, "Demo.app")
        XCTAssertEqual(
            URL(fileURLWithPath: slot.executablePath).lastPathComponent,
            "Demo"
        )
    }

    func testReadRejectsAnExtraVisibleApp() throws {
        let fixture = try makeSlotFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.slotDirectory.appendingPathComponent("Old.app"),
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try PlayCoverSlotService.read(
                bundleIdentifier: fixture.bundleIdentifier,
                paths: fixture.paths
            )
        )
    }

    func testReadRejectsInfoPlistExecutableMismatch() throws {
        let fixture = try makeSlotFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let infoURL = fixture.slotDirectory
            .appendingPathComponent("Demo.app/Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": fixture.bundleIdentifier,
                "CFBundleExecutable": "OldDemo",
            ],
            format: .binary,
            options: 0
        )
        try data.write(to: infoURL)

        XCTAssertThrowsError(
            try PlayCoverSlotService.read(
                bundleIdentifier: fixture.bundleIdentifier,
                paths: fixture.paths
            )
        )
    }

    func testHomeSelectionStoresOnlyBundleIdentifier() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)

        try PlayCoverHomeStore.updateCurrentBundle(
            "com.example.demo",
            paths: paths
        )

        XCTAssertEqual(
            try PlayCoverHomeStore.readCurrentBundle(paths: paths),
            "com.example.demo"
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: URL(
                        fileURLWithPath: paths.playcoverCurrentBundle
                    )
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set(["bundleIdentifier"]))
    }

    func testRuntimeResolutionIgnoresLegacyHomeLocalFramework() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        let cliDirectory = root.appendingPathComponent("bin")
        let installedRuntime = cliDirectory.appendingPathComponent(
            ".ios-use/playcover/IOSUsePlayRuntime.framework"
        )
        let legacyRuntime = URL(
            fileURLWithPath: paths.root,
            isDirectory: true
        ).appendingPathComponent(
            "mac/IOSUsePlayRuntime.framework"
        )
        for runtime in [installedRuntime, legacyRuntime] {
            try FileManager.default.createDirectory(
                at: runtime,
                withIntermediateDirectories: true
            )
            let executable = runtime.appendingPathComponent(
                "IOSUsePlayRuntime"
            )
            try Data("runtime".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        PlayCoverSlotService.executablePathOverrideForTesting = {
            cliDirectory.appendingPathComponent("ios-use").path
        }
        defer {
            PlayCoverSlotService.executablePathOverrideForTesting = nil
        }

        XCTAssertEqual(
            try PlayCoverSlotService.resolveDefaultRuntime(paths: paths),
            installedRuntime.standardizedFileURL.path
        )
    }

    func testBundleIdentifierCannotEscapeSlotRoot() throws {
        for value in ["", ".", "..", "a/b", "bad\0id", "bad\nid"] {
            XCTAssertThrowsError(
                try PlayCoverSlotService.validateBundleIdentifier(value)
            )
        }
    }

    private struct SlotFixture {
        let root: URL
        let paths: IOSUsePaths
        let slotDirectory: URL
        let bundleIdentifier: String
        let installRevision: String
    }

    private func makeSlotFixture() throws -> SlotFixture {
        let root = try temporaryDirectory()
        let paths = makePaths(root: root)
        let bundleIdentifier = "com.example.demo"
        let installRevision = String(repeating: "a", count: 64)
        let slotDirectory = URL(
            fileURLWithPath: paths.playcoverApps,
            isDirectory: true
        ).appendingPathComponent(bundleIdentifier)
        let app = slotDirectory.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent(
                "Frameworks/IOSUsePlayRuntime.framework"
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent(
                "Frameworks/IOSUseFridaEngine.framework"
            ),
            withIntermediateDirectories: true
        )
        let executable = app.appendingPathComponent("Demo")
        let runtime = app.appendingPathComponent(
            "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime"
        )
        let engine = app.appendingPathComponent(
            "Frameworks/IOSUseFridaEngine.framework/IOSUseFridaEngine"
        )
        for file in [executable, runtime, engine] {
            try Data("binary".utf8).write(to: file)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "Demo",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try plistData.write(to: app.appendingPathComponent("Info.plist"))
        let metadata = PlayCoverSlotMetadata(
            bundleIdentifier: bundleIdentifier,
            appRelativePath: "Demo.app",
            executableRelativePath: "Demo",
            installRevision: installRevision
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadataURL = slotDirectory.appendingPathComponent("slot.json")
        try encoder.encode(metadata).write(to: metadataURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: metadataURL.path
        )
        return SlotFixture(
            root: root,
            paths: paths,
            slotDirectory: slotDirectory,
            bundleIdentifier: bundleIdentifier,
            installRevision: installRevision
        )
    }

    private func makePaths(root: URL) -> IOSUsePaths {
        IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": root.appendingPathComponent("home").path,
            ],
            accountHomeDirectoryOverrideForTesting:
                root.appendingPathComponent("account").path,
            socketRootOverrideForTesting:
                root.appendingPathComponent("sockets").path
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(
            fileURLWithPath: "/tmp/iu-slot-"
                + String(UUID().uuidString.prefix(8)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}
