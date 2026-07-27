import CryptoKit
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI

final class PlayCoverFastVerifyTests: XCTestCase {
    override func tearDown() {
        Shell.runResultOverrideForTesting = nil
        PlayCoverService.fastVerifyEventOverrideForTesting = nil
        super.tearDown()
    }

    func testFastVerifyHashesRequiredExecutablesAndCodesignsCodeObjectsOnce()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        var calls: [String: Int] = [:]
        var beforeHashes: [String: Int] = [:]
        var afterHashes: [String: Int] = [:]
        var beforeSignatures: [String: Int] = [:]
        var afterSignatures: [String: Int] = [:]
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            switch event {
            case .beforeFileHash(let path):
                beforeHashes[path, default: 0] += 1
            case .afterFileHash(let path):
                afterHashes[path, default: 0] += 1
            case .beforeCodeSignature(let path):
                beforeSignatures[path, default: 0] += 1
            case .afterCodeSignature(let path):
                afterSignatures[path, default: 0] += 1
            case .beforeMetadataOpen,
                 .afterMetadataOpen,
                 .afterMetadataRead:
                break
            }
        }
        Shell.runResultOverrideForTesting = {
            executable,
            arguments,
            cwd in
            XCTAssertEqual(executable, "/usr/bin/codesign")
            XCTAssertEqual(Array(arguments.prefix(2)), ["--verify", "--strict"])
            XCTAssertNil(cwd)
            let path = try XCTUnwrap(arguments.last)
            calls[path, default: 0] += 1
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        try PlayCoverService.fastVerifyGeneration(
            appPath: fixture.app.path,
            manifest: fixture.manifest
        )

        let expectedHashes: Set<String> = [
            fixture.manifest.executableName,
            "Frameworks/\(PlayCoverService.runtimeFrameworkName)"
                + "/\(PlayCoverService.runtimeExecutableName)",
        ]
        let expectedPaths = Set(
            fixture.manifest.inventory.compactMap { entry -> String? in
                guard entry.codeObjectKind != nil else { return nil }
                return fixture.app
                    .appendingPathComponent(entry.relativePath).path
            }
        ).union([fixture.app.path])
        let expectedCodeRelativePaths = Set(
            fixture.manifest.inventory.compactMap {
                $0.codeObjectKind == nil ? nil : $0.relativePath
            }
        ).union(["."])

        XCTAssertEqual(Set(beforeHashes.keys), expectedHashes)
        XCTAssertEqual(beforeHashes, afterHashes)
        XCTAssertTrue(
            beforeHashes.values.allSatisfy { $0 == 1 },
            "required files were re-hashed: \(beforeHashes)"
        )
        XCTAssertEqual(Set(calls.keys), expectedPaths)
        XCTAssertTrue(
            calls.values.allSatisfy { $0 == 1 },
            "codesign calls were not unique: \(calls)"
        )
        XCTAssertEqual(Set(beforeSignatures.keys), expectedCodeRelativePaths)
        XCTAssertEqual(beforeSignatures, afterSignatures)
        XCTAssertTrue(
            beforeSignatures.values.allSatisfy { $0 == 1 },
            "code objects were re-verified: \(beforeSignatures)"
        )
    }

    func testManifestSymlinkFailsClosed() throws {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let saved = fixture.root.appendingPathComponent("saved-manifest")
        try FileManager.default.moveItem(
            at: fixture.manifestURL,
            to: saved
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.manifestURL,
            withDestinationURL: saved
        )

        assertFastVerifyTampered(fixture.app.path)
    }

    func testManifestFIFOIsRejectedWithoutBlocking() throws {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.manifestURL)
        XCTAssertEqual(mkfifo(fixture.manifestURL.path, 0o600), 0)
        let finished = DispatchSemaphore(value: 0)
        let result = LockedResult()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try PlayCoverService.fastVerify(
                    appPath: fixture.app.path
                )
                result.set(.success(()))
            } catch {
                result.set(.failure(error))
            }
            finished.signal()
        }

        let completedWithoutWriter =
            finished.wait(timeout: .now() + 1) == .success
        if !completedWithoutWriter {
            let writer = Darwin.open(
                fixture.manifestURL.path,
                O_WRONLY | O_NONBLOCK | O_CLOEXEC
            )
            if writer >= 0 {
                Darwin.close(writer)
            }
            _ = finished.wait(timeout: .now() + 1)
        }

        XCTAssertTrue(
            completedWithoutWriter,
            "opening hostile metadata FIFO blocked fast verification"
        )
        assertTampered(result.value)
        #else
        throw XCTSkip("FIFO verification is Darwin-only")
        #endif
    }

    func testOversizedManifestIsRejectedWithoutReadingPayload()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.manifestURL)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fixture.manifestURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        )
        let handle = try FileHandle(forWritingTo: fixture.manifestURL)
        try handle.truncate(
            atOffset: UInt64(64 * 1_024 * 1_024 + 1)
        )
        try handle.close()
        let started = ProcessInfo.processInfo.systemUptime

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - started,
            1,
            "oversized sparse metadata should be rejected by fstat"
        )
    }

    func testManifestAtomicReplacementDuringReadFailsClosed()
        throws
    {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent(
            "replacement-manifest"
        )
        try Data(contentsOf: fixture.manifestURL).write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacement.path
        )
        var replaced = false
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            guard event
                    == .afterMetadataOpen(
                        PlayCoverService.manifestFilename
                    ),
                  !replaced else {
                return
            }
            replaced = true
            guard Darwin.rename(
                    replacement.path,
                    fixture.manifestURL.path
                  ) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertTrue(replaced)
        #else
        throw XCTSkip("metadata replacement verification is Darwin-only")
        #endif
    }

    private func assertFastVerifyTampered(
        _ appPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try PlayCoverService.fastVerify(appPath: appPath),
            file: file,
            line: line
        ) { error in
            guard case .cacheTampered =
                    error as? PlayCoverBackendError else {
                return XCTFail(
                    "unexpected error: \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertTampered(
        _ result: Result<Void, Error>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let result else {
            return XCTFail(
                "fast verification did not complete",
                file: file,
                line: line
            )
        }
        switch result {
        case .success:
            XCTFail(
                "hostile generation metadata was accepted",
                file: file,
                line: line
            )
        case .failure(let error):
            guard case .cacheTampered =
                    error as? PlayCoverBackendError else {
                return XCTFail(
                    "unexpected error: \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Void, Error>?

    var value: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Result<Void, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private struct FastVerifyFixture {
    let root: URL
    let app: URL
    let manifest: PlayCoverPrepareManifest
    let manifestURL: URL
    let completedURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "IOSUsePlayCoverFastVerify-\(UUID().uuidString)",
            isDirectory: true
        )
        app = root.appendingPathComponent(
            "Fixture.app",
            isDirectory: true
        )
        manifestURL = root.appendingPathComponent(
            PlayCoverService.manifestFilename
        )
        completedURL = root.appendingPathComponent(
            PlayCoverService.completedFilename
        )
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.fastverify",
            "CFBundleExecutable": "Fixture",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let executable = app.appendingPathComponent("Fixture")
        try Self.makeThinMachO().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let source = try PlayCoverService.inspect(appPath: app.path)

        let runtimeFramework = app
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(
                PlayCoverService.runtimeFrameworkName,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: runtimeFramework,
            withIntermediateDirectories: true
        )
        let runtime = runtimeFramework.appendingPathComponent(
            PlayCoverService.runtimeExecutableName
        )
        try Self.makeThinMachO().write(to: runtime)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtime.path
        )
        let prepared = try PlayCoverService.inspect(appPath: app.path)
        let runtimeHash = try Self.fileSHA256(runtime)
        let generationKey = PlayCoverService.makeGenerationKey(
            sourceContentHash: source.sourceContentHash,
            runtimeBuildHash: runtimeHash,
            prepareRevision: PlayCoverService.prepareImplementationRevision
        )
        manifest = PlayCoverPrepareManifest(
            sourceAppPath: source.appPath,
            preparedAppPath: app.path,
            bundleIdentifier: prepared.bundleIdentifier,
            executableName: prepared.executableName,
            executablePath: prepared.executablePath,
            sourceContentHash: source.sourceContentHash,
            sourceHashAfterPreparation: source.sourceContentHash,
            runtimeBuildHash: runtimeHash,
            prepareRevision: PlayCoverService.prepareImplementationRevision,
            generationKey: generationKey,
            runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
            runtimeFrameworkName:
                PlayCoverService.runtimeFrameworkName,
            convertedMachOs: prepared.machOs.map(\.relativePath),
            signingOrder: prepared.inventory.compactMap {
                $0.codeObjectKind == nil ? nil : $0.relativePath
            } + ["."],
            sourceInventory: source.inventory,
            sourceMachOs: source.machOs,
            inventory: prepared.inventory,
            machOs: prepared.machOs,
            entitlementDiff: try Self.emptyEntitlementDiff(),
            completedAt: "2026-07-27T00:00:00Z"
        )
        let manifestData = try Self.canonicalJSON(manifest)
        let marker = PlayCoverCompletedGeneration(
            schemaVersion: 2,
            generationKey: generationKey,
            manifestSHA256: Self.sha256(manifestData),
            inventorySHA256: Self.sha256(
                try Self.canonicalJSON(manifest.inventory)
            ),
            machoSealSHA256: Self.sha256(
                try Self.canonicalJSON(manifest.machOs)
            ),
            executableSHA256: try Self.fileSHA256(executable),
            runtimeSHA256: runtimeHash
        )
        try manifestData.write(to: manifestURL, options: .atomic)
        try Self.canonicalJSON(marker).write(
            to: completedURL,
            options: .atomic
        )
        for sidecar in [manifestURL, completedURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: sidecar.path
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func emptyEntitlementDiff()
        throws -> PlayCoverEntitlementDiff
    {
        try JSONDecoder().decode(
            PlayCoverEntitlementDiff.self,
            from: Data(
                """
                {
                  "original": {},
                  "playCoverBaseline": {},
                  "final": {},
                  "addedByPlayCover": [],
                  "addedByIOSUse": [],
                  "changedFromOriginal": [],
                  "removedFromOriginal": []
                }
                """.utf8
            )
        )
    }

    private static func canonicalJSON<T: Encodable>(
        _ value: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func makeThinMachO() -> Data {
        var commands: [Data] = []
        var segment = Data()
        appendU32(0x19, to: &segment)
        appendU32(152, to: &segment)
        segment.append(Data(repeating: 0, count: 56))
        appendU32(1, to: &segment)
        appendU32(0, to: &segment)
        segment.append(Data(repeating: 0, count: 48))
        appendU32(512, to: &segment)
        segment.append(Data(repeating: 0, count: 28))
        commands.append(segment)

        var build = Data()
        appendU32(0x32, to: &build)
        appendU32(24, to: &build)
        appendU32(2, to: &build)
        appendU32(0x0011_0000, to: &build)
        appendU32(0x0011_0400, to: &build)
        appendU32(0, to: &build)
        commands.append(build)

        var result = Data([0xcf, 0xfa, 0xed, 0xfe])
        appendU32(0x0100_000c, to: &result)
        appendU32(0, to: &result)
        appendU32(2, to: &result)
        appendU32(UInt32(commands.count), to: &result)
        appendU32(
            UInt32(commands.reduce(0) { $0 + $1.count }),
            to: &result
        )
        appendU32(0, to: &result)
        appendU32(0, to: &result)
        for command in commands {
            result.append(command)
        }
        result.append(
            Data(repeating: 0, count: max(0, 512 - result.count))
        )
        result.append(Data(repeating: 0xab, count: 64))
        return result
    }

    private static func appendU32(
        _ value: UInt32,
        to data: inout Data
    ) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }
}
