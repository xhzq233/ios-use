import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI

final class PlayCoverCoreTests: XCTestCase {
    override func tearDown() {
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = nil
        PlayCoverManagedAppService.inspectOverrideForTesting = nil
        PlayCoverManagedAppService.verifyOverrideForTesting = nil
        PlayCoverManagedAppService.fastVerifyOverrideForTesting = nil
        PlayCoverManagedAppService.prepareOverrideForTesting = nil
        PlayCoverManagedAppService.runtimePathOverrideForTesting = nil
        PlayCoverManagedAppService.executablePathOverrideForTesting = nil
        PlayCoverManagedAppService.generationKeyOverrideForTesting = nil
        super.tearDown()
    }

    func testInspectionIsReadOnlyAndContainsNoRuntimeProfileState() throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executable = fixture.app.appendingPathComponent("Fixture")
        let executableBefore = try Data(contentsOf: executable)

        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(inspection),
            as: UTF8.self
        )

        XCTAssertEqual(inspection.bundleIdentifier, "com.example.fixture")
        XCTAssertEqual(inspection.mainExecutable.platform, 2)
        XCTAssertEqual(try Data(contentsOf: executable), executableBefore)
        for forbidden in [
            "profile",
            "bootstrap",
            "launchNonce",
            "preparedGenerationID",
            "logicalWidth",
            "nativeWidth",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), encoded)
        }
    }

    func testPathsContainOneManagedPlayCoverTreeAndSessionSocket()
        throws {
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": "/state/ios-use"]
        )

        XCTAssertEqual(paths.playcover, "/state/ios-use/playcover")
        XCTAssertEqual(paths.playcoverRun, "/state/ios-use/playcover/run")
        XCTAssertEqual(
            paths.playcoverPrepared,
            "/state/ios-use/playcover/prepared"
        )
        XCTAssertEqual(
            paths.playcoverRuntime,
            "/state/ios-use/playcover/IOSUsePlayRuntime.framework"
        )
        XCTAssertEqual(
            try paths.playCoverRuntimeSocketPath(
                sessionID: "ABC-def_123"
            ),
            "/state/ios-use/playcover/run/s-ABCdef123.sock"
        )
    }

    func testSessionSocketRejectsHomeOverDarwinLimit() {
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": "/tmp/" + String(repeating: "x", count: 96),
            ]
        )

        XCTAssertThrowsError(
            try paths.playCoverRuntimeSocketPath(sessionID: "session")
        )
    }

    func testSessionSocketCanonicalizesRootOwnedTmpAlias() throws {
        let lexicalRoot = URL(
            fileURLWithPath:
                "/tmp/ios-use-play-path-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: lexicalRoot)
        }
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": lexicalRoot.path]
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverRun,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let socket = try paths.playCoverRuntimeSocketPath(
            sessionID: "tmp-alias"
        )

        XCTAssertEqual(
            socket,
            "/private"
                + "\(paths.playcoverRun)/s-tmpalias.sock"
        )
        XCTAssertFalse(socket.hasPrefix("/tmp/"))
        XCTAssertTrue(socket.hasPrefix("/private/tmp/"))
    }

    func testGenerationKeyUsesOnlyContentRuntimeAndPinnedRevision() {
        let source = String(repeating: "a", count: 64)
        let runtime = String(repeating: "b", count: 64)
        let first = PlayCoverService.makeGenerationKey(
            sourceContentHash: source,
            runtimeBuildHash: runtime
        )
        let second = PlayCoverService.makeGenerationKey(
            sourceContentHash: source,
            runtimeBuildHash: runtime
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: String(repeating: "c", count: 64),
                runtimeBuildHash: runtime
            )
        )
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: source,
                runtimeBuildHash: String(repeating: "d", count: 64)
            )
        )
        XCTAssertTrue(
            PlayCoverService.prepareImplementationRevision.contains(
                "7190cc9ce57c8dee0e222918468f2579acc95e1b"
            )
        )
        XCTAssertTrue(
            PlayCoverService.prepareImplementationRevision.contains(
                "e6d3aa4abe106f90fd8c5a1ca04db15c19d324eb"
            )
        )
    }

    func testManifestHasSingleGenerationIdentityAndNoBootstrapFields()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.root
                .appendingPathComponent("Prepared.app").path,
            generationKey: String(repeating: "a", count: 64)
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(manifest),
            as: UTF8.self
        )

        XCTAssertEqual(manifest.schemaVersion, 3)
        XCTAssertEqual(manifest.backend, "playcover-headless")
        XCTAssertEqual(
            manifest.runtimeLoadPath,
            PlayCoverMachO.runtimeLoadPath
        )
        for forbidden in [
            "profile",
            "bootstrap",
            "launchNonce",
            "preparedGenerationID",
            "runtimeSocketPath",
            "logicalWidth",
            "nativeWidth",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), encoded)
        }
    }

    func testLaunchEnvironmentForwardsOnlyAllowlistAndDirectIdentity() {
        let result = PlayCoverService.sanitizedLaunchEnvironment(
            source: [
                "HOME": "/Users/test",
                "TMPDIR": "/tmp/test",
                "PATH": "/private/tooling",
                "API_TOKEN": "secret",
                "IOS_USE_HOME": "/private/state",
                "IOS_USE_PLAY_SESSION_ID": "stale",
                "IOS_USE_PLAY_RUNTIME_SOCKET": "/stale.sock",
            ],
            sessionID: "session-one",
            runtimeSocketPath: "/state/run/s-sessionone.sock"
        )

        XCTAssertEqual(result["HOME"], "/Users/test")
        XCTAssertEqual(result["TMPDIR"], "/tmp/test")
        XCTAssertEqual(result["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(result["IOS_USE_PLAY_SESSION_ID"], "session-one")
        XCTAssertEqual(
            result["IOS_USE_PLAY_RUNTIME_SOCKET"],
            "/state/run/s-sessionone.sock"
        )
        XCTAssertNil(result["API_TOKEN"])
        XCTAssertNil(result["IOS_USE_HOME"])
        XCTAssertEqual(
            Set(result.keys),
            [
                "HOME",
                "TMPDIR",
                "PATH",
                "IOS_USE_PLAY_SESSION_ID",
                "IOS_USE_PLAY_RUNTIME_SOCKET",
            ]
        )
    }

    func testRuntimeCandidatesPreferCurrentManagedHome() {
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": "/state/ios-use"]
        )

        XCTAssertEqual(
            PlayCoverManagedAppService.runtimeCandidates(
                paths: paths,
                executablePath: "/opt/ios-use/bin/ios-use"
            ),
            [
                "/state/ios-use/playcover/IOSUsePlayRuntime.framework",
                "/opt/ios-use/bin/.ios-use/playcover/"
                    + "IOSUsePlayRuntime.framework",
                "/opt/ios-use/share/ios-use/playcover/"
                    + "IOSUsePlayRuntime.framework",
            ]
        )
    }

    func testEncryptedMachOFacadeRejectsWithoutMutation() throws {
        let fixture = try makeSourceApp(encrypted: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executable = fixture.app.appendingPathComponent("Fixture")
        let before = try Data(contentsOf: executable)

        XCTAssertThrowsError(
            try PlayCoverMachO.convert(
                at: executable,
                injectRuntime: true
            )
        ) { error in
            guard case .encryptedMachO = error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: executable), before)
    }

    func testManagedGenerationPublishesAtomicallyAndReuseNeverFullVerifies()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home").path,
            ]
        )
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: String(repeating: "a", count: 64)
        )
        var fullVerifyCount = 0
        var fastVerifyCount = 0
        PlayCoverManagedAppService.verifyOverrideForTesting = { _ in
            fullVerifyCount += 1
            throw PlayCoverBackendError.verificationFailed(
                "full verify must not run during reuse"
            )
        }
        PlayCoverManagedAppService.fastVerifyOverrideForTesting = { path in
            fastVerifyCount += 1
            return try self.manifestForPublishedPath(
                path,
                source: inspection,
                generationKey: String(repeating: "a", count: 64)
            )
        }

        let prepared = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: paths
        )
        let reused = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: paths
        )

        XCTAssertFalse(prepared.reused)
        XCTAssertTrue(reused.reused)
        XCTAssertEqual(prepared.manifest, reused.manifest)
        XCTAssertEqual(fullVerifyCount, 0)
        XCTAssertEqual(fastVerifyCount, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: prepared.manifest.preparedAppPath
            )
        )
        let generationParent = URL(
            fileURLWithPath: prepared.manifest.preparedAppPath
        ).deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: generationParent.appendingPathComponent(
                    PlayCoverService.manifestFilename
                ).path
            )
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: paths.playcoverPrepared
        ).filter { $0.hasPrefix(".staging-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testConcurrentGenerationPublishHasOneWinnerAndOneReuse()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home").path,
            ]
        )
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let generationKey = String(repeating: "9", count: 64)
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: generationKey
        )
        _ = try PlayCoverManagedAppService.resolveDefaultRuntime(
            paths: paths
        )
        let originalPrepare = try XCTUnwrap(
            PlayCoverManagedAppService.prepareOverrideForTesting
        )
        let bothPrepared = DispatchSemaphore(value: 0)
        let publish = DispatchSemaphore(value: 0)
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            source,
            staging,
            runtime,
            paths,
            key,
            published in
            let manifest = try originalPrepare(
                source,
                staging,
                runtime,
                paths,
                key,
                published
            )
            bothPrepared.signal()
            guard publish.wait(timeout: .now() + 5) == .success else {
                throw PlayCoverBackendError.prepareFailed(
                    "concurrent publish test barrier timed out"
                )
            }
            return manifest
        }
        let group = DispatchGroup()
        let results = ConcurrentResolutionBox()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    results.append(
                        .success(
                            try PlayCoverManagedAppService
                                .resolveExplicitApp(
                                    fixture.app.path,
                                    paths: paths
                                )
                        )
                    )
                } catch {
                    results.append(.failure(error))
                }
            }
        }
        XCTAssertEqual(
            bothPrepared.wait(timeout: .now() + 5),
            .success
        )
        XCTAssertEqual(
            bothPrepared.wait(timeout: .now() + 5),
            .success
        )
        publish.signal()
        publish.signal()
        XCTAssertEqual(
            group.wait(timeout: .now() + 10),
            .success
        )

        let snapshot = results.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        let resolutions = try snapshot.map { try $0.get() }
        XCTAssertEqual(
            resolutions.map(\.reused).sorted {
                ($0 ? 1 : 0) < ($1 ? 1 : 0)
            },
            [false, true]
        )
        XCTAssertEqual(
            Set(resolutions.map(\.manifest.preparedAppPath)).count,
            1
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: paths.playcoverPrepared
        ).filter { $0.hasPrefix(".staging-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testIncompleteGenerationIsTamperingAndIsNeverOverwritten()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home").path,
            ]
        )
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let generationKey = String(repeating: "b", count: 64)
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: generationKey
        )
        let incomplete = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).appendingPathComponent(generationKey, isDirectory: true)
        try FileManager.default.createDirectory(
            at: incomplete,
            withIntermediateDirectories: true
        )
        var prepareCount = 0
        let originalPrepare =
            PlayCoverManagedAppService.prepareOverrideForTesting
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            source, staging, runtime, paths, key, published in
            prepareCount += 1
            return try originalPrepare!(
                source,
                staging,
                runtime,
                paths,
                key,
                published
            )
        }

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                fixture.app.path,
                paths: paths
            )
        ) { error in
            guard case .cacheTampered =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(prepareCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: incomplete.path)
        )
    }

    func testManagedPreparedRootAndAppRejectSymlinkEscape()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let generationKey = String(repeating: "f", count: 64)

        let childPaths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("child-home").path,
            ]
        )
        let generation = URL(
            fileURLWithPath: childPaths.playcoverPrepared,
            isDirectory: true
        ).appendingPathComponent(generationKey, isDirectory: true)
        try FileManager.default.createDirectory(
            at: generation,
            withIntermediateDirectories: true
        )
        let escapedApp = fixture.root.appendingPathComponent(
            "escaped.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: escapedApp,
            withIntermediateDirectories: true
        )
        let childLink = generation.appendingPathComponent(
            "Escaped.app",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: childLink,
            withDestinationURL: escapedApp
        )

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                childLink.path,
                paths: childPaths
            )
        ) {
            guard case .cacheTampered(let message) =
                    $0 as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(message.contains("symbolic-link escape"))
        }

        let rootPaths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("root-home").path,
            ]
        )
        let externalPrepared = fixture.root.appendingPathComponent(
            "external-prepared",
            isDirectory: true
        )
        let externalGeneration = externalPrepared
            .appendingPathComponent(generationKey, isDirectory: true)
        let externalApp = externalGeneration.appendingPathComponent(
            "Escaped.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalApp,
            withIntermediateDirectories: true
        )
        let preparedParent = URL(
            fileURLWithPath: rootPaths.playcoverPrepared
        ).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: preparedParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: URL(
                fileURLWithPath: rootPaths.playcoverPrepared
            ),
            withDestinationURL: externalPrepared
        )

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                rootPaths.playcoverPrepared
                    + "/\(generationKey)/Escaped.app",
                paths: rootPaths
            )
        ) {
            guard case .cacheTampered(let message) =
                    $0 as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(message.contains("symbolic-link escape"))
        }
    }

    func testManagedHomeRejectsUserOwnedIntermediateSymlinkBeforeWrite()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent(
            "external",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        let link = fixture.root.appendingPathComponent(
            "managed-link",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: external
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": link.appendingPathComponent(
                    "home",
                    isDirectory: true
                ).path,
            ]
        )
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        PlayCoverManagedAppService.inspectOverrideForTesting = {
            _ in inspection
        }
        PlayCoverManagedAppService.generationKeyOverrideForTesting = {
            _,
            _ in String(repeating: "8", count: 64)
        }
        let runtime = fixture.root.appendingPathComponent(
            "Runtime/IOSUsePlayRuntime.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        let runtimeExecutable = runtime.appendingPathComponent(
            PlayCoverService.runtimeExecutableName
        )
        try Data("runtime".utf8).write(to: runtimeExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeExecutable.path
        )
        PlayCoverManagedAppService.runtimePathOverrideForTesting = {
            _ in runtime.path
        }
        var prepareCount = 0
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            _,
            _,
            _,
            _,
            _,
            _ in
            prepareCount += 1
            throw PlayCoverBackendError.prepareFailed(
                "must not prepare through a symlinked home"
            )
        }

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                fixture.app.path,
                paths: paths
            )
        ) {
            guard case .prepareFailed(let message) =
                    $0 as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(
                message.contains(
                    "user-owned symbolic link"
                )
            )
        }
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: external.path
            ),
            []
        )
    }

    func testFailedLaunchRollbackEscalatesToKillAndWaitsForExit()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let prepared = fixture.root.appendingPathComponent(
            "Rollback.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: prepared,
            withIntermediateDirectories: true
        )
        let executable = prepared.appendingPathComponent(
            inspection.executableName
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sh"),
            to: executable
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: prepared.path,
            generationKey: String(repeating: "e", count: 64)
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-c",
            "trap '' TERM; while :; do sleep 1; done",
        ]
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        usleep(100_000)

        try PlayCoverService.terminateFailedLaunch(
            pid: process.processIdentifier,
            manifest: manifest
        )
        process.waitUntilExit()

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testSameContentIsIsolatedAcrossHomesAndForeignPreparedReuseFails()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let generationKey = String(repeating: "c", count: 64)
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: generationKey
        )
        PlayCoverManagedAppService.fastVerifyOverrideForTesting = { path in
            try self.manifestForPublishedPath(
                path,
                source: inspection,
                generationKey: generationKey
            )
        }
        let homeOne = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home-one").path,
            ]
        )
        let homeTwo = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home-two").path,
            ]
        )

        let first = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: homeOne
        )
        let second = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: homeTwo
        )

        XCTAssertNotEqual(
            first.manifest.preparedAppPath,
            second.manifest.preparedAppPath
        )
        XCTAssertEqual(
            first.manifest.generationKey,
            second.manifest.generationKey
        )
        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                first.manifest.preparedAppPath,
                paths: homeTwo
            )
        ) { error in
            guard case .cacheTampered =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSameContentAtDifferentSourcePathReusesGeneration() throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secondSource = fixture.root.appendingPathComponent(
            "SecondSource.app",
            isDirectory: true
        )
        try FileManager.default.copyItem(
            at: fixture.app,
            to: secondSource
        )
        let firstInspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let secondInspection = try PlayCoverService.inspect(
            appPath: secondSource.path
        )
        XCTAssertEqual(
            firstInspection.sourceContentHash,
            secondInspection.sourceContentHash
        )
        let generationKey = String(repeating: "e", count: 64)
        try installFakeManagedPipeline(
            source: firstInspection,
            generationKey: generationKey
        )
        PlayCoverManagedAppService.inspectOverrideForTesting = { path in
            try PlayCoverService.inspect(appPath: path)
        }
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home").path,
            ]
        )

        let first = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: paths
        )
        let second = try PlayCoverManagedAppService.resolveExplicitApp(
            secondSource.path,
            paths: paths
        )

        XCTAssertFalse(first.reused)
        XCTAssertTrue(second.reused)
        XCTAssertEqual(first.manifest, second.manifest)
    }

    func testPreparedEvidenceOutsideManagedHomeCannotBecomeSource()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home").path,
            ]
        )
        try Data("{}".utf8).write(
            to: fixture.root.appendingPathComponent(
                PlayCoverService.manifestFilename
            )
        )

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                fixture.app.path,
                paths: paths
            )
        ) { error in
            guard case .cacheTampered =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private struct AppFixture {
        let root: URL
        let app: URL
    }

    private func makeSourceApp(
        encrypted: Bool = false
    ) throws -> AppFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IOSUsePlayCoverCore-\(UUID().uuidString)",
                isDirectory: true
            )
        let app = root.appendingPathComponent(
            "Fixture.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleExecutable": "Fixture",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let executable = app.appendingPathComponent("Fixture")
        try makeThinMachO(encrypted: encrypted).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return AppFixture(root: root, app: app)
    }

    private func installFakeManagedPipeline(
        source: PlayCoverAppInspection,
        generationKey: String
    ) throws {
        PlayCoverManagedAppService.inspectOverrideForTesting = { _ in source }
        PlayCoverManagedAppService.generationKeyOverrideForTesting = {
            _, _ in generationKey
        }
        PlayCoverManagedAppService.runtimePathOverrideForTesting = { paths in
            let runtime = URL(
                fileURLWithPath: paths.playcoverRuntime,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: runtime,
                withIntermediateDirectories: true
            )
            let executable = runtime.appendingPathComponent(
                PlayCoverService.runtimeExecutableName
            )
            if !FileManager.default.fileExists(atPath: executable.path) {
                try Data("runtime".utf8).write(to: executable)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: executable.path
                )
            }
            return runtime.path
        }
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            _, staging, _, _, key, published in
            let stagingURL = URL(
                fileURLWithPath: staging,
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: URL(
                    fileURLWithPath: source.appPath,
                    isDirectory: true
                ),
                to: stagingURL
            )
            try Data("{}".utf8).write(
                to: stagingURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        PlayCoverService.manifestFilename
                    )
            )
            try Data("{}".utf8).write(
                to: stagingURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        PlayCoverService.completedFilename
                    )
            )
            return try self.makeManifest(
                inspection: source,
                preparedAppPath: published,
                generationKey: key
            )
        }
        PlayCoverManagedAppService.fastVerifyOverrideForTesting = { path in
            try self.manifestForPublishedPath(
                path,
                source: source,
                generationKey: generationKey
            )
        }
    }

    private func manifestForPublishedPath(
        _ path: String,
        source: PlayCoverAppInspection,
        generationKey: String
    ) throws -> PlayCoverPrepareManifest {
        try makeManifest(
            inspection: source,
            preparedAppPath: path,
            generationKey: generationKey
        )
    }

    private func makeManifest(
        inspection: PlayCoverAppInspection,
        preparedAppPath: String,
        generationKey: String
    ) throws -> PlayCoverPrepareManifest {
        let prepared = URL(
            fileURLWithPath: preparedAppPath,
            isDirectory: true
        ).standardizedFileURL
        return PlayCoverPrepareManifest(
            sourceAppPath: inspection.appPath,
            preparedAppPath: prepared.path,
            bundleIdentifier: inspection.bundleIdentifier,
            executableName: inspection.executableName,
            executablePath: prepared.appendingPathComponent(
                inspection.executableName
            ).path,
            sourceContentHash: inspection.sourceContentHash,
            sourceHashAfterPreparation: inspection.sourceContentHash,
            runtimeBuildHash: String(repeating: "d", count: 64),
            prepareRevision: PlayCoverService.prepareImplementationRevision,
            generationKey: generationKey,
            runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
            runtimeFrameworkName: PlayCoverService.runtimeFrameworkName,
            convertedMachOs: inspection.machOs.map(\.relativePath),
            signingOrder: ["."],
            sourceInventory: inspection.inventory,
            sourceMachOs: inspection.machOs,
            inventory: inspection.inventory,
            machOs: inspection.machOs,
            entitlementDiff: try emptyEntitlementDiff(),
            completedAt: "2026-07-25T00:00:00Z"
        )
    }

    private func emptyEntitlementDiff() throws
        -> PlayCoverEntitlementDiff {
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

    private func makeThinMachO(encrypted: Bool) -> Data {
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
        if encrypted {
            var encryption = Data()
            appendU32(0x2c, to: &encryption)
            appendU32(24, to: &encryption)
            appendU32(0, to: &encryption)
            appendU32(0, to: &encryption)
            appendU32(1, to: &encryption)
            appendU32(0, to: &encryption)
            commands.append(encryption)
        }

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

    private func appendU32(
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

private final class ConcurrentResolutionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [
        Result<PlayCoverManagedAppService.Resolution, Error>
    ] = []

    func append(
        _ value: Result<
            PlayCoverManagedAppService.Resolution,
            Error
        >
    ) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [
        Result<PlayCoverManagedAppService.Resolution, Error>
    ] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
