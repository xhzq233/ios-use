import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI

final class PlayCoverCoreTests: XCTestCase {
    override func tearDown() {
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = nil
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = nil
        PlayCoverService.failedLaunchSignalOverrideForTesting = nil
        PlayCoverManagedAppService.inspectOverrideForTesting = nil
        PlayCoverManagedAppService.verifyOverrideForTesting = nil
        PlayCoverManagedAppService.readManifestOverrideForTesting = nil
        PlayCoverManagedAppService.prepareOverrideForTesting = nil
        PlayCoverManagedAppService.runtimePathOverrideForTesting = nil
        PlayCoverManagedAppService.executablePathOverrideForTesting = nil
        PlayCoverManagedAppService.generationKeyOverrideForTesting = nil
        PlayCoverManagedAppService.afterManagedDirectoryOpenForTesting = nil
        PlayCoverManagedAppService
            .afterStagingPathResolvedForTesting = nil
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
        let revision = PlayCoverService.prepareImplementationRevision
        let first = PlayCoverService.makeGenerationKey(
            sourceContentHash: source,
            runtimeBuildHash: runtime,
            prepareRevision: revision
        )
        let second = PlayCoverService.makeGenerationKey(
            sourceContentHash: source,
            runtimeBuildHash: runtime,
            prepareRevision: revision
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: String(repeating: "c", count: 64),
                runtimeBuildHash: runtime,
                prepareRevision: revision
            )
        )
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: source,
                runtimeBuildHash: String(repeating: "d", count: 64),
                prepareRevision: revision
            )
        )
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: source,
                runtimeBuildHash: runtime,
                prepareRevision: "different-prepare-revision"
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

    func testPreparationPlanCarriesOneSourceAndRuntimeIdentity()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = fixture.root.appendingPathComponent(
            PlayCoverService.runtimeFrameworkName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        let runtimeExecutable = runtime.appendingPathComponent(
            PlayCoverService.runtimeExecutableName
        )
        try Data("runtime-build".utf8).write(to: runtimeExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeExecutable.path
        )

        let source = try PlayCoverService.inspectPreparationSource(
            appPath: fixture.app.path
        )
        let plan = try PlayCoverService.makePreparationPlan(
            source: source,
            runtimeFrameworkPath: runtime.path
        )

        XCTAssertEqual(plan.source, source)
        XCTAssertEqual(
            plan.source.inspection.sourceContentHash,
            plan.source.upstreamInspection.sourceContentHash
        )
        XCTAssertEqual(plan.runtimeFrameworkPath, runtime.path)
        XCTAssertEqual(plan.runtimeBuildHash.count, 64)
        XCTAssertEqual(
            plan.generationKey,
            PlayCoverService.makeGenerationKey(
                sourceContentHash:
                    plan.source.inspection.sourceContentHash,
                runtimeBuildHash: plan.runtimeBuildHash,
                prepareRevision: plan.prepareRevision
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

    func testWorkspaceLaunchEnvironmentClearsInheritedSecrets() {
        let result = PlayCoverService.launchConfigurationEnvironment(
            source: [
                "HOME": "/Users/test",
                "API_TOKEN": "secret",
                "SSH_AUTH_SOCK": "/private/agent.sock",
            ],
            sessionID: "session-one",
            runtimeSocketPath: "/state/run/s-sessionone.sock",
            managedHomePath: "/state/managed-home"
        )

        XCTAssertEqual(result["HOME"], "/state/managed-home")
        XCTAssertEqual(result["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(result["IOS_USE_PLAY_SESSION_ID"], "session-one")
        XCTAssertEqual(
            result["IOS_USE_PLAY_RUNTIME_SOCKET"],
            "/state/run/s-sessionone.sock"
        )
        XCTAssertEqual(result["API_TOKEN"], "")
        XCTAssertEqual(result["SSH_AUTH_SOCK"], "")
        XCTAssertFalse(result.values.contains("secret"))
    }

    func testLaunchIdentityMustBeNewAndMatchPreparedGeneration()
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

        XCTAssertTrue(
            PlayCoverService.acceptsOwnedLaunchIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                existingPIDs: [41],
                manifest: manifest
            )
        )
        XCTAssertFalse(
            PlayCoverService.acceptsOwnedLaunchIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                existingPIDs: [42],
                manifest: manifest
            ),
            "a completion callback must never claim a pre-existing PID"
        )
        XCTAssertFalse(
            PlayCoverService.acceptsOwnedLaunchIdentity(
                pid: 43,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: fixture.app.path,
                executablePath: manifest.executablePath,
                existingPIDs: [],
                manifest: manifest
            )
        )
        XCTAssertFalse(
            PlayCoverService.acceptsOwnedLaunchIdentity(
                pid: 44,
                bundleIdentifier: "com.example.other",
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                existingPIDs: [],
                manifest: manifest
            )
        )
    }

    func testConcurrentFinderCandidateNeedsCallbackOrRuntimeIdentity()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.root
                .appendingPathComponent("Prepared.app").path,
            generationKey: String(repeating: "b", count: 64)
        )
        let callbackIdentity =
            PlayCoverService.LaunchedApplicationIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 10,
                source: .workspaceCallback
            )
        let finderCandidate =
            PlayCoverService.LaunchedApplicationIdentity(
                pid: 43,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 11,
                source: .observedCandidate
            )

        XCTAssertTrue(
            PlayCoverService.mayClaimLaunchIdentity(
                callbackIdentity,
                callbackIdentity: callbackIdentity,
                runtimeAuthenticated: false
            )
        )
        XCTAssertFalse(
            PlayCoverService.mayClaimLaunchIdentity(
                finderCandidate,
                callbackIdentity: callbackIdentity,
                runtimeAuthenticated: false
            ),
            "a concurrent exact Finder launch is not owned by polling"
        )
        XCTAssertTrue(
            PlayCoverService.mayClaimLaunchIdentity(
                finderCandidate,
                callbackIdentity: callbackIdentity,
                runtimeAuthenticated: true
            ),
            "the random Runtime session may authenticate a slow callback"
        )
    }

    func testRuntimeCandidatesPreferExplicitManagedHome() {
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

    func testRuntimeCandidatesIgnoreImplicitMutableHome() {
        let paths = IOSUsePaths.resolve(
            environment: ["HOME": "/Users/example"]
        )

        XCTAssertFalse(paths.hasExplicitHome)
        XCTAssertEqual(
            PlayCoverManagedAppService.runtimeCandidates(
                paths: paths,
                executablePath: "/work/ios-use"
            ),
            [
                "/work/.ios-use/playcover/"
                    + "IOSUsePlayRuntime.framework",
                "/share/ios-use/playcover/"
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

    func testManagedGenerationPublishesAtomicallyWithoutResolutionVerification()
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
        var manifestReadCount = 0
        PlayCoverManagedAppService.verifyOverrideForTesting = { _ in
            fullVerifyCount += 1
            throw PlayCoverBackendError.verificationFailed(
                "full verify must not run during reuse"
            )
        }
        let originalManifestRead = try XCTUnwrap(
            PlayCoverManagedAppService.readManifestOverrideForTesting
        )
        PlayCoverManagedAppService.readManifestOverrideForTesting = { path in
            manifestReadCount += 1
            return try originalManifestRead(path)
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
        XCTAssertEqual(manifestReadCount, 2)
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
        let prepareStarted = DispatchSemaphore(value: 0)
        let continuePrepare = DispatchSemaphore(value: 0)
        let prepareCountLock = NSLock()
        var prepareCount = 0
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            plan,
            staging,
            paths,
            published in
            prepareCountLock.lock()
            prepareCount += 1
            prepareCountLock.unlock()
            prepareStarted.signal()
            guard continuePrepare.wait(
                    timeout: .now() + 5
                  ) == .success else {
                throw PlayCoverBackendError.prepareFailed(
                    "serialized prepare test barrier timed out"
                )
            }
            return try originalPrepare(
                plan,
                staging,
                paths,
                published
            )
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
            prepareStarted.wait(timeout: .now() + 5),
            .success
        )
        XCTAssertEqual(
            prepareStarted.wait(timeout: .now() + 0.2),
            .timedOut,
            "in-process preparation must serialize before path-based writes"
        )
        continuePrepare.signal()
        XCTAssertEqual(
            group.wait(timeout: .now() + 10),
            .success
        )

        let snapshot = results.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        prepareCountLock.lock()
        let finalPrepareCount = prepareCount
        prepareCountLock.unlock()
        XCTAssertEqual(finalPrepareCount, 1)
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
            plan, staging, paths, published in
            prepareCount += 1
            return try originalPrepare!(
                plan,
                staging,
                paths,
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

    func testManagedGenerationRejectsManifestFromDifferentRuntimePlan()
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
        let generationKey = String(repeating: "7", count: 64)
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: generationKey
        )
        let originalPrepare = try XCTUnwrap(
            PlayCoverManagedAppService.prepareOverrideForTesting
        )
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            plan, staging, paths, published in
            _ = try originalPrepare(
                plan,
                staging,
                paths,
                published
            )
            let wrongRuntimeHash =
                plan.runtimeBuildHash == String(repeating: "0", count: 64)
                ? String(repeating: "1", count: 64)
                : String(repeating: "0", count: 64)
            return try self.makeManifest(
                inspection: plan.source.inspection,
                preparedAppPath: published,
                generationKey: plan.generationKey,
                runtimeBuildHash: wrongRuntimeHash
            )
        }

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                fixture.app.path,
                paths: paths
            )
        ) {
            guard case .verificationFailed =
                    $0 as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        let generation = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).appendingPathComponent(generationKey, isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: generation.path)
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
        let preparationSource =
            try PlayCoverService.inspectPreparationSource(
                appPath: fixture.app.path
            )
        PlayCoverManagedAppService.inspectOverrideForTesting = {
            _ in preparationSource
        }
        PlayCoverManagedAppService.generationKeyOverrideForTesting = {
            _,
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

    func testManagedPrepareStaysAnchoredWhenPreparedPathIsSwapped()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let generationKey = String(repeating: "9", count: 64)
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: generationKey
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("managed-home").path,
            ]
        )
        let external = URL(
            fileURLWithPath:
                "/tmp/iu-prepare-swap-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = external.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let prepared = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        )
        let displaced = prepared.deletingLastPathComponent()
            .appendingPathComponent(
                "prepared-displaced",
                isDirectory: true
            )
        PlayCoverManagedAppService
            .afterManagedDirectoryOpenForTesting = {
                PlayCoverManagedAppService
                    .afterManagedDirectoryOpenForTesting = nil
                try FileManager.default.moveItem(
                    at: prepared,
                    to: displaced
                )
                try FileManager.default.createSymbolicLink(
                    at: prepared,
                    withDestinationURL: external
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
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: external.path
            ),
            ["sentinel"],
            "prepare/publish must not write through a swapped parent"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: displaced.appendingPathComponent(
                    generationKey,
                    isDirectory: true
                ).path
            ),
            "a detached prepared parent must fail before prepare/publish"
        )
    }

    func testManagedPrepareNamespaceGuardRejectsPlaycoverRename()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let generationKey = String(repeating: "6", count: 64)
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: generationKey
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("managed-home").path,
            ]
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverPrepared,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let external = fixture.root.appendingPathComponent(
            "external",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false
        )
        let sentinel = external.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let playcover = URL(
            fileURLWithPath: paths.playcover,
            isDirectory: true
        )
        let displaced = playcover.deletingLastPathComponent()
            .appendingPathComponent(
                "playcover-displaced",
                isDirectory: true
            )
        let stableProbeName = "stable-vnode-probe"
        var usedStableVnodePath = false
        var playcoverRenameRejected = false
        let playcoverFlagsBefore = try fileFlags(playcover)
        let prepared = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        )
        let preparedFlagsBefore = try fileFlags(prepared)
        PlayCoverManagedAppService
            .afterStagingPathResolvedForTesting = { staging in
                usedStableVnodePath =
                    staging.path.hasPrefix("/.vol/")
                XCTAssertNotEqual(
                    try self.fileFlags(playcover) & UInt32(UF_APPEND),
                    0
                )
                XCTAssertNotEqual(
                    try self.fileFlags(prepared) & UInt32(UF_APPEND),
                    0
                )
                do {
                    try FileManager.default.moveItem(
                        at: playcover,
                        to: displaced
                    )
                } catch {
                    playcoverRenameRejected = true
                }
                try Data("anchored".utf8).write(
                    to: staging.appendingPathComponent(
                        stableProbeName
                    )
                )
            }

        let resolution =
            try PlayCoverManagedAppService.resolveExplicitApp(
                fixture.app.path,
                paths: paths
            )

        XCTAssertTrue(usedStableVnodePath)
        XCTAssertTrue(playcoverRenameRejected)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: displaced.path
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: external.path
            ),
            ["sentinel"],
            "ancestor replacement must not redirect prepare writes"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(
                    fileURLWithPath:
                        resolution.manifest.preparedAppPath
                ).deletingLastPathComponent()
                    .appendingPathComponent(stableProbeName).path
            )
        )
        XCTAssertEqual(try fileFlags(playcover), playcoverFlagsBefore)
        XCTAssertEqual(try fileFlags(prepared), preparedFlagsBefore)
        try FileManager.default.moveItem(at: playcover, to: displaced)
        try FileManager.default.moveItem(at: displaced, to: playcover)
    }

    func testPrepareNamespaceGuardRejectsDirectStagingRename()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: String(repeating: "4", count: 64)
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("managed-home").path,
            ]
        )
        let moved = fixture.root.appendingPathComponent(
            "moved-staging",
            isDirectory: true
        )
        var stagingRenameRejected = false
        PlayCoverManagedAppService
            .afterStagingPathResolvedForTesting = { staging in
                let lexicalStaging =
                    URL(fileURLWithPath: paths.playcoverPrepared)
                        .appendingPathComponent(
                            try XCTUnwrap(
                                FileManager.default.contentsOfDirectory(
                                    atPath: paths.playcoverPrepared
                                ).first(where: {
                                    $0.hasPrefix(".staging-")
                                })
                            ),
                            isDirectory: true
                        )
                do {
                    try FileManager.default.moveItem(
                        at: lexicalStaging,
                        to: moved
                    )
                } catch {
                    stagingRenameRejected = true
                }
                let probe = staging.appendingPathComponent("probe")
                try Data("stable".utf8).write(to: probe)
            }

        let resolution =
            try PlayCoverManagedAppService.resolveExplicitApp(
                fixture.app.path,
                paths: paths
            )
        XCTAssertTrue(stagingRenameRejected)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: moved.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(
                    fileURLWithPath:
                        resolution.manifest.preparedAppPath
                ).deletingLastPathComponent()
                    .appendingPathComponent("probe").path
            )
        )
    }

    func testPrepareNamespaceGuardRestoresFlagsWhenPrepareThrows()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: String(repeating: "3", count: 64)
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("managed-home").path,
            ]
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverPrepared,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let playcover = URL(
            fileURLWithPath: paths.playcover,
            isDirectory: true
        )
        let prepared = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        )
        let playcoverFlagsBefore = try fileFlags(playcover)
        let preparedFlagsBefore = try fileFlags(prepared)
        let playcoverModeBefore = try fileMode(playcover)
        let preparedModeBefore = try fileMode(prepared)
        var sawProtectedNamespace = false
        PlayCoverManagedAppService
            .afterStagingPathResolvedForTesting = { _ in
                sawProtectedNamespace =
                    try self.fileFlags(playcover) & UInt32(UF_APPEND) != 0
                    && self.fileFlags(prepared) & UInt32(UF_APPEND) != 0
                throw PlayCoverBackendError.prepareFailed(
                    "injected prepare failure"
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
            XCTAssertTrue(message.contains("injected prepare failure"))
        }
        XCTAssertTrue(sawProtectedNamespace)
        XCTAssertEqual(try fileFlags(playcover), playcoverFlagsBefore)
        XCTAssertEqual(try fileFlags(prepared), preparedFlagsBefore)
        XCTAssertEqual(try fileMode(playcover), playcoverModeBefore)
        XCTAssertEqual(try fileMode(prepared), preparedModeBefore)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: paths.playcoverPrepared
            ).allSatisfy { !$0.hasPrefix(".staging-") }
        )
    }

    func testPrepareNamespaceGuardRecoversStaleOwnedFlags()
        throws
    {
        let fixture = try makeSourceApp()
        defer {
            try? clearAppendOnlyFlag(
                URL(
                    fileURLWithPath:
                        fixture.root.appendingPathComponent(
                            "managed-home/playcover"
                        ).path
                )
            )
            try? clearAppendOnlyFlag(
                URL(
                    fileURLWithPath:
                        fixture.root.appendingPathComponent(
                            "managed-home/playcover/prepared"
                        ).path
                )
            )
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: String(repeating: "2", count: 64)
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("managed-home").path,
            ]
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverPrepared,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let playcover = URL(
            fileURLWithPath: paths.playcover,
            isDirectory: true
        )
        let prepared = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        )
        try setAppendOnlyFlag(playcover)
        try setAppendOnlyFlag(prepared)

        _ = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: paths
        )

        XCTAssertEqual(
            try fileFlags(playcover) & UInt32(UF_APPEND),
            0
        )
        XCTAssertEqual(
            try fileFlags(prepared) & UInt32(UF_APPEND),
            0
        )
    }

    func testRuntimeHelloTimeoutRollsBackExactCallbackProcess()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.root
                .appendingPathComponent("Prepared.app").path,
            generationKey: String(repeating: "c", count: 64)
        )
        let identity = PlayCoverService.LaunchedApplicationIdentity(
            pid: 42,
            bundleIdentifier: manifest.bundleIdentifier,
            bundleURLPath: manifest.preparedAppPath,
            executablePath: manifest.executablePath,
            processStartTimeMicroseconds: 100,
            source: .workspaceCallback
        )
        var running = true
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            pid in
            XCTAssertEqual(pid, identity.pid)
            return running
                ? .running(
                    executablePath: manifest.executablePath,
                    processStartTimeMicroseconds: 100
                )
                : .missing
        }
        var signals: [Int32] = []
        PlayCoverService.failedLaunchSignalOverrideForTesting = {
            pid,
            signal in
            XCTAssertEqual(pid, identity.pid)
            signals.append(signal)
            running = false
            return 0
        }

        try PlayCoverService.terminateFailedLaunch(
            identity: identity,
            manifest: manifest
        )

        XCTAssertEqual(signals, [SIGTERM])
    }

    func testRuntimeHelloTimeoutRollbackTreatsPostSIGTERMESRCHAsExit()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.root
                .appendingPathComponent("Prepared.app").path,
            generationKey: String(repeating: "c", count: 64)
        )
        let identity = PlayCoverService.LaunchedApplicationIdentity(
            pid: 42,
            bundleIdentifier: manifest.bundleIdentifier,
            bundleURLPath: manifest.preparedAppPath,
            executablePath: manifest.executablePath,
            processStartTimeMicroseconds: 100,
            source: .workspaceCallback
        )
        var processProbeCount = 0
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            pid in
            XCTAssertEqual(pid, identity.pid)
            processProbeCount += 1
            switch processProbeCount {
            case 1:
                return .running(
                    executablePath: manifest.executablePath,
                    processStartTimeMicroseconds: 100
                )
            case 2:
                return .unverifiable(errno: ESRCH)
            default:
                XCTFail(
                    "rollback must finish on post-SIGTERM ESRCH"
                )
                return .missing
            }
        }
        var signals: [Int32] = []
        PlayCoverService.failedLaunchSignalOverrideForTesting = {
            pid,
            signal in
            XCTAssertEqual(pid, identity.pid)
            signals.append(signal)
            return 0
        }

        try PlayCoverService.terminateFailedLaunch(
            identity: identity,
            manifest: manifest
        )

        XCTAssertEqual(processProbeCount, 2)
        XCTAssertEqual(signals, [SIGTERM])
    }

    func testRuntimeHelloTimeoutRollbackRejectsPostSIGTERMNonESRCH()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.root
                .appendingPathComponent("Prepared.app").path,
            generationKey: String(repeating: "c", count: 64)
        )
        let identity = PlayCoverService.LaunchedApplicationIdentity(
            pid: 42,
            bundleIdentifier: manifest.bundleIdentifier,
            bundleURLPath: manifest.preparedAppPath,
            executablePath: manifest.executablePath,
            processStartTimeMicroseconds: 100,
            source: .workspaceCallback
        )
        var processProbeCount = 0
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            pid in
            XCTAssertEqual(pid, identity.pid)
            processProbeCount += 1
            return processProbeCount == 1
                ? .running(
                    executablePath: manifest.executablePath,
                    processStartTimeMicroseconds: 100
                )
                : .unverifiable(errno: EPERM)
        }
        var signals: [Int32] = []
        PlayCoverService.failedLaunchSignalOverrideForTesting = {
            pid,
            signal in
            XCTAssertEqual(pid, identity.pid)
            signals.append(signal)
            return 0
        }

        XCTAssertThrowsError(
            try PlayCoverService.terminateFailedLaunch(
                identity: identity,
                manifest: manifest
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "rollback cannot verify pid 42: errno \(EPERM)"
                )
            )
        }
        XCTAssertEqual(processProbeCount, 2)
        XCTAssertEqual(signals, [SIGTERM])
    }

    func testFailedLaunchRollbackPreservesSameExecutablePIDReuse()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.root
                .appendingPathComponent("Prepared.app").path,
            generationKey: String(repeating: "d", count: 64)
        )
        let identity = PlayCoverService.LaunchedApplicationIdentity(
            pid: 42,
            bundleIdentifier: manifest.bundleIdentifier,
            bundleURLPath: manifest.preparedAppPath,
            executablePath: manifest.executablePath,
            processStartTimeMicroseconds: 100,
            source: .workspaceCallback
        )
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            _ in .running(
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 101
            )
        }
        var signalCount = 0
        PlayCoverService.failedLaunchSignalOverrideForTesting = {
            _,
            _ in
            signalCount += 1
            return 0
        }

        try PlayCoverService.terminateFailedLaunch(
            identity: identity,
            manifest: manifest
        )

        XCTAssertEqual(signalCount, 0)
    }

    func testFailedLaunchRollbackRefusesUnownedConcurrentCandidate()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.root
                .appendingPathComponent("Prepared.app").path,
            generationKey: String(repeating: "e", count: 64)
        )
        let candidate = PlayCoverService.LaunchedApplicationIdentity(
            pid: 43,
            bundleIdentifier: manifest.bundleIdentifier,
            bundleURLPath: manifest.preparedAppPath,
            executablePath: manifest.executablePath,
            processStartTimeMicroseconds: 100,
            source: .observedCandidate
        )
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            _ in .running(
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 100
            )
        }
        var signalCount = 0
        PlayCoverService.failedLaunchSignalOverrideForTesting = {
            _,
            _ in
            signalCount += 1
            return 0
        }

        XCTAssertThrowsError(
            try PlayCoverService.terminateFailedLaunch(
                identity: candidate,
                manifest: manifest
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "not owned by the NSWorkspace callback"
                )
            )
        }
        XCTAssertEqual(signalCount, 0)
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
        let processStart = try XCTUnwrap(
            PlayCoverService.processStartTimeMicroseconds(
                for: process.processIdentifier
            )
        )

        try PlayCoverService.terminateFailedLaunch(
            identity: PlayCoverService.LaunchedApplicationIdentity(
                pid: process.processIdentifier,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: processStart,
                source: .workspaceCallback
            ),
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
            try PlayCoverService.inspectPreparationSource(
                appPath: path
            )
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
        let preparationSource =
            try PlayCoverService.inspectPreparationSource(
                appPath: source.appPath
            )
        PlayCoverManagedAppService.inspectOverrideForTesting = {
            _ in preparationSource
        }
        PlayCoverManagedAppService.generationKeyOverrideForTesting = {
            _, _, _ in generationKey
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
        let manifestLock = NSLock()
        var manifests: [String: PlayCoverPrepareManifest] = [:]
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            plan, staging, _, published in
            let stagingURL = URL(
                fileURLWithPath: staging,
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: URL(
                    fileURLWithPath: plan.source.inspection.appPath,
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
            let manifest = try self.makeManifest(
                inspection: plan.source.inspection,
                preparedAppPath: published,
                generationKey: plan.generationKey,
                runtimeBuildHash: plan.runtimeBuildHash
            )
            manifestLock.lock()
            manifests[published] = manifest
            manifestLock.unlock()
            return manifest
        }
        PlayCoverManagedAppService.readManifestOverrideForTesting = { path in
            manifestLock.lock()
            defer { manifestLock.unlock() }
            guard let manifest = manifests[path] else {
                throw PlayCoverBackendError.verificationFailed(
                    "fake manifest is missing for \(path)"
                )
            }
            return manifest
        }
    }

    private func makeManifest(
        inspection: PlayCoverAppInspection,
        preparedAppPath: String,
        generationKey: String,
        runtimeBuildHash: String = String(repeating: "d", count: 64)
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
            runtimeBuildHash: runtimeBuildHash,
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

    #if canImport(Darwin)
    private func fileFlags(_ url: URL) throws -> UInt32 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot inspect test directory flags: errno \(errno)"
            )
        }
        return status.st_flags
    }

    private func fileMode(_ url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot inspect test directory mode: errno \(errno)"
            )
        }
        return status.st_mode & 0o777
    }

    private func setAppendOnlyFlag(_ url: URL) throws {
        let flags = try fileFlags(url)
        guard Darwin.chflags(
                url.path,
                flags | UInt32(UF_APPEND)
              ) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot set test append-only flag: errno \(errno)"
            )
        }
    }

    private func clearAppendOnlyFlag(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let flags = try fileFlags(url)
        guard Darwin.chflags(
                url.path,
                flags & ~UInt32(UF_APPEND)
              ) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot clear test append-only flag: errno \(errno)"
            )
        }
    }
    #endif

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
