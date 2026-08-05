import Foundation
import IOSUsePlayDevice
import XCTest
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI
@testable import PlayCoverUpstream

final class PlayCoverCoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PlayCoverService.signingIdentityResolverOverrideForTesting = {
            _ in makePlayCoverTestSigningIdentity()
        }
    }

    override func tearDown() {
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = nil
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = nil
        PlayCoverService.failedLaunchSignalOverrideForTesting = nil
        PlayCoverService.keyCoverLockOverrideForTesting = nil
        PlayCoverService.launchAliasRootOverrideForTesting = nil
        PlayCoverService.launchIntegrityEventOverrideForTesting = nil
        PlayCoverService.signingIdentityResolverOverrideForTesting = nil
        PlayCoverService.rootCodeSignatureInspectorOverrideForTesting = nil
        PlayCoverService.upstreamPrepareOverrideForTesting = nil
        PlayCoverService.signingIdentityNowOverrideForTesting = nil
        #if canImport(AppKit)
        PlayCoverService.workspaceOpenOverrideForTesting = nil
        PlayCoverService.workspaceSubmissionObserverForTesting = nil
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = nil
        #endif
        PlayCoverManagedAppService.inspectOverrideForTesting = nil
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

    func testPathsKeepSessionStateLocalAndPreparedCacheAccountGlobal()
        throws {
        let paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": "/state/ios-use"]
        )

        XCTAssertEqual(paths.playcover, "/state/ios-use/mac")
        XCTAssertEqual(paths.playcoverRun, "/state/ios-use/mac/run")
        XCTAssertEqual(
            paths.playcoverLogs,
            "/state/ios-use/logs/mac"
        )
        XCTAssertEqual(
            paths.playcoverPendingLaunch,
            "/state/ios-use/mac/pending-launch.json"
        )
        XCTAssertEqual(
            paths.playcoverPendingLaunchLock,
            "/state/ios-use/mac/pending-launch.lock"
        )
        XCTAssertEqual(
            paths.playcoverGlobalObjects,
            "\(paths.playcoverGlobalCache)/objects"
        )
        XCTAssertTrue(
            paths.knownHomes.hasSuffix(
                "/Library/Application Support/dev.ios-use/homes"
            ),
            paths.knownHomes
        )
        XCTAssertFalse(
            paths.knownHomes.hasPrefix(paths.accountCacheRoot + "/"),
            paths.knownHomes
        )
        XCTAssertTrue(
            paths.accountApplicationSupportRoot.hasSuffix(
                "/Library/Application Support/dev.ios-use"
            ),
            paths.accountApplicationSupportRoot
        )
        XCTAssertEqual(
            paths.playcoverSigningBinding,
            paths.accountApplicationSupportRoot
                + "/mac-stable-signing-binding-v1.json"
        )
        XCTAssertTrue(
            paths.playcoverLaunchFacades.hasSuffix(
                "/Applications/ios-use"
            ),
            paths.playcoverLaunchFacades
        )
        XCTAssertEqual(
            paths.playcoverRuntime,
            "/state/ios-use/mac/IOSUsePlayRuntime.framework"
        )
        let socket = try paths.macRuntimeSocketPath(
            sessionID: "ABC-def_123"
        )
        XCTAssertTrue(
            socket.hasPrefix(paths.playcoverSocketRoot + "/s-")
        )
        XCTAssertTrue(socket.hasSuffix(".sock"))
        XCTAssertFalse(socket.contains("ABC"))
    }

    func testProductionAccountRootsIgnorePoisonedHOME() throws {
        let password = try XCTUnwrap(getpwuid(geteuid()))
        let expectedAccountHome = String(
            cString: try XCTUnwrap(password.pointee.pw_dir)
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "HOME": "/tmp/attacker-controlled-home",
                "IOS_USE_HOME":
                    "/tmp/ios-use-logical-\(UUID().uuidString)",
            ]
        )

        XCTAssertTrue(
            paths.playcoverGlobalCache.hasPrefix(
                URL(
                    fileURLWithPath: expectedAccountHome,
                    isDirectory: true
                ).resolvingSymlinksInPath().path + "/"
            ),
            paths.playcoverGlobalCache
        )
        XCTAssertFalse(
            paths.playcoverGlobalCache.contains(
                "attacker-controlled-home"
            )
        )
        for path in [
            paths.accountApplicationSupportRoot,
            paths.playcoverSigningBinding,
            paths.playcoverLaunchFacades,
        ] {
            XCTAssertTrue(
                path.hasPrefix(
                    URL(
                        fileURLWithPath: expectedAccountHome,
                        isDirectory: true
                    ).resolvingSymlinksInPath().path + "/"
                ),
                path
            )
            XCTAssertFalse(path.contains("attacker-controlled-home"))
        }
    }

    func testSessionSocketIsBoundedIndependentlyOfLogicalHome() throws {
        let accountHome = "/tmp/iu-account-"
            + UUID().uuidString
        defer {
            if FileManager.default.fileExists(atPath: accountHome) {
                try? FileManager.default.removeItem(
                    atPath: accountHome
                )
            }
        }
        let paths = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": "/tmp/" + String(repeating: "x", count: 96),
            ],
            accountHomeDirectory: accountHome
        )

        XCTAssertLessThanOrEqual(
            try paths.macRuntimeSocketPath(sessionID: "session")
                .utf8.count,
            103
        )
    }

    func testSessionSocketUsesIsolatedAccountTestRoot() throws {
        let lexicalRoot = URL(
            fileURLWithPath:
                "/tmp/ios-use-play-path-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if FileManager.default.fileExists(
                atPath: lexicalRoot.path
            ) {
                try? FileManager.default.removeItem(at: lexicalRoot)
            }
        }
        let paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": lexicalRoot.path]
        )
        let socket = try paths.macRuntimeSocketPath(
            sessionID: "tmp-alias"
        )

        XCTAssertTrue(
            socket.hasPrefix(paths.playcoverSocketRoot + "/s-")
        )
        XCTAssertFalse(socket.contains("tmpalias"))
    }

    func testGenerationKeyUsesContentRuntimeRevisionAndSigner() {
        let source = String(repeating: "a", count: 64)
        let runtime = String(repeating: "b", count: 64)
        let namespace = String(repeating: "e", count: 64)
        let revision = PlayCoverService.prepareImplementationRevision
        let signer = makePlayCoverTestSigningIdentity()
        let first = PlayCoverService.makeGenerationKey(
            sourceContentHash: source,
            runtimeBuildHash: runtime,
            prepareRevision: revision,
            accountNamespacePolicyHash: namespace,
            signerPublicKeySPKISHA256: signer.publicKeySPKISHA256,
            signerCertificateSHA256: signer.certificateSHA256,
            signingPolicyRevision: signer.policy.revision
        )
        let second = PlayCoverService.makeGenerationKey(
            sourceContentHash: source,
            runtimeBuildHash: runtime,
            prepareRevision: revision,
            accountNamespacePolicyHash: namespace,
            signerPublicKeySPKISHA256: signer.publicKeySPKISHA256,
            signerCertificateSHA256: signer.certificateSHA256,
            signingPolicyRevision: signer.policy.revision
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: String(repeating: "c", count: 64),
                runtimeBuildHash: runtime,
                prepareRevision: revision,
                accountNamespacePolicyHash: namespace,
                signerPublicKeySPKISHA256:
                    signer.publicKeySPKISHA256,
                signerCertificateSHA256:
                    signer.certificateSHA256,
                signingPolicyRevision: signer.policy.revision
            )
        )
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: source,
                runtimeBuildHash: String(repeating: "d", count: 64),
                prepareRevision: revision,
                accountNamespacePolicyHash: namespace,
                signerPublicKeySPKISHA256:
                    signer.publicKeySPKISHA256,
                signerCertificateSHA256:
                    signer.certificateSHA256,
                signingPolicyRevision: signer.policy.revision
            )
        )
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: source,
                runtimeBuildHash: runtime,
                prepareRevision: "different-prepare-revision",
                accountNamespacePolicyHash: namespace,
                signerPublicKeySPKISHA256:
                    signer.publicKeySPKISHA256,
                signerCertificateSHA256:
                    signer.certificateSHA256,
                signingPolicyRevision: signer.policy.revision
            )
        )
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: source,
                runtimeBuildHash: runtime,
                prepareRevision: revision,
                accountNamespacePolicyHash:
                    String(repeating: "f", count: 64),
                signerPublicKeySPKISHA256:
                    signer.publicKeySPKISHA256,
                signerCertificateSHA256:
                    signer.certificateSHA256,
                signingPolicyRevision: signer.policy.revision
            )
        )
        XCTAssertNotEqual(
            first,
            PlayCoverService.makeGenerationKey(
                sourceContentHash: source,
                runtimeBuildHash: runtime,
                prepareRevision: revision,
                accountNamespacePolicyHash: namespace,
                signerPublicKeySPKISHA256:
                    String(repeating: "C", count: 64),
                signerCertificateSHA256:
                    signer.certificateSHA256,
                signingPolicyRevision: signer.policy.revision
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
        XCTAssertTrue(
            PlayCoverService.prepareImplementationRevision.hasPrefix(
                "ios-use-headless-v18+"
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
        try makeThinMachO(
            encrypted: false,
            platform: 6
        ).write(to: runtimeExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeExecutable.path
        )

        let source = try PlayCoverService.inspectPreparationSource(
            appPath: fixture.app.path
        )
        let paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": fixture.root.path]
        )
        let plan = try PlayCoverService.makePreparationPlan(
            source: source,
            runtimeFrameworkPath: runtime.path,
            paths: paths
        )

        XCTAssertEqual(plan.source, source)
        XCTAssertEqual(
            plan.source.inspection.sourceContentHash,
            plan.source.upstreamInspection.sourceContentHash
        )
        XCTAssertEqual(plan.runtimeFrameworkPath, runtime.path)
        XCTAssertEqual(plan.runtimeBuildHash.count, 64)
        XCTAssertEqual(
            plan.runtimeEvidence.mainExecutableRelativePath,
            PlayCoverService.runtimeExecutableName
        )
        XCTAssertEqual(
            plan.generationIdentity.sourceContentHash,
            plan.source.inspection.sourceContentHash
        )
        XCTAssertEqual(
            plan.generationKey,
            PlayCoverService.makeGenerationKey(
                sourceContentHash:
                    plan.source.inspection.sourceContentHash,
                runtimeBuildHash: plan.runtimeBuildHash,
                prepareRevision: plan.prepareRevision,
                accountNamespacePolicyHash:
                    plan.accountNamespacePolicyHash,
                signerPublicKeySPKISHA256:
                    plan.signingIdentity.publicKeySPKISHA256,
                signerCertificateSHA256:
                    plan.signingIdentity.certificateSHA256,
                signingPolicyRevision:
                    plan.signingIdentity.policy.revision
            )
        )
        XCTAssertNoThrow(
            try PlayCoverService.validatePreparationPlan(
                plan
            ),
            "Service must forward the immutable computed generation "
                + "identity without deriving it again"
        )
    }

    func testAccountNamespacePolicyChangesGenerationWithoutBindingLogicalHome()
        throws
    {
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
        try makeThinMachO(
            encrypted: false,
            platform: 6
        ).write(to: runtimeExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeExecutable.path
        )
        let source = try PlayCoverService.inspectPreparationSource(
            appPath: fixture.app.path
        )
        let accountA = fixture.root.appendingPathComponent(
            "account-a",
            isDirectory: true
        )
        let accountB = fixture.root.appendingPathComponent(
            "account-b",
            isDirectory: true
        )
        let socketToken = UUID().uuidString.prefix(8)
        let socketA = "/private/tmp/iu-policy-a-\(socketToken)"
        let socketB = "/private/tmp/iu-policy-b-\(socketToken)"
        func paths(
            logicalHome: String,
            accountHome: URL,
            socketRoot: String
        ) -> IOSUsePaths {
            IOSUsePaths.resolve(
                environment: ["IOS_USE_HOME": logicalHome],
                accountHomeDirectoryOverrideForTesting:
                    accountHome.path,
                socketRootOverrideForTesting: socketRoot
            )
        }
        let firstPaths = paths(
            logicalHome: fixture.root
                .appendingPathComponent("logical-a").path,
            accountHome: accountA,
            socketRoot: socketA
        )
        let differentLogicalHomePaths = paths(
            logicalHome: fixture.root
                .appendingPathComponent("logical-b").path,
            accountHome: accountA,
            socketRoot: socketA
        )
        let differentAccountPaths = paths(
            logicalHome: fixture.root
                .appendingPathComponent("logical-a").path,
            accountHome: accountB,
            socketRoot: socketA
        )
        let differentSocketPaths = paths(
            logicalHome: fixture.root
                .appendingPathComponent("logical-a").path,
            accountHome: accountA,
            socketRoot: socketB
        )
        let first = try PlayCoverService.makePreparationPlan(
            source: source,
            runtimeFrameworkPath: runtime.path,
            paths: firstPaths
        )
        let differentLogicalHome =
            try PlayCoverService.makePreparationPlan(
                source: source,
                runtimeFrameworkPath: runtime.path,
                paths: differentLogicalHomePaths
            )
        let differentAccount =
            try PlayCoverService.makePreparationPlan(
                source: source,
                runtimeFrameworkPath: runtime.path,
                paths: differentAccountPaths
            )
        let differentSocket =
            try PlayCoverService.makePreparationPlan(
                source: source,
                runtimeFrameworkPath: runtime.path,
                paths: differentSocketPaths
            )

        XCTAssertNotEqual(
            firstPaths.playcoverHomeID,
            differentLogicalHomePaths.playcoverHomeID
        )
        XCTAssertEqual(
            first.accountNamespacePolicyHash,
            differentLogicalHome.accountNamespacePolicyHash
        )
        XCTAssertEqual(
            first.generationKey,
            differentLogicalHome.generationKey
        )
        XCTAssertNotEqual(
            first.accountNamespacePolicyHash,
            differentAccount.accountNamespacePolicyHash
        )
        XCTAssertNotEqual(
            first.generationKey,
            differentAccount.generationKey
        )
        XCTAssertNotEqual(
            first.accountNamespacePolicyHash,
            differentSocket.accountNamespacePolicyHash
        )
        XCTAssertNotEqual(
            first.generationKey,
            differentSocket.generationKey
        )
    }

    func testPrepareRejectsInspectorCDHashMismatchBeforePublish()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent(
                        "managed-home",
                        isDirectory: true
                    ).path,
            ]
        )
        let runtime = URL(
            fileURLWithPath: paths.playcoverRuntime,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let runtimeExecutable = runtime.appendingPathComponent(
            PlayCoverService.runtimeExecutableName
        )
        try makeThinMachO(
            encrypted: false,
            platform: 6
        ).write(to: runtimeExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeExecutable.path
        )

        let identity = makePlayCoverTestSigningIdentity(
            codesignSelector: "-"
        )
        PlayCoverService.signingIdentityResolverOverrideForTesting = {
            _ in identity
        }
        let source = try PlayCoverService.inspectPreparationSource(
            appPath: fixture.app.path
        )
        let plan = try PlayCoverService.makePreparationPlan(
            source: source,
            runtimeFrameworkPath: runtime.path,
            paths: paths
        )
        let finalInspectionCDHash = String(
            repeating: "c",
            count: 40
        )
        var prepareCallCount = 0
        PlayCoverService.upstreamPrepareOverrideForTesting = {
            options,
            sourceInspection in
            prepareCallCount += 1
            try FileManager.default.copyItem(
                at: options.sourceApp,
                to: options.stagingApp
            )
            let preparedSignature = PlayCoverUpstreamSignature(
                isSigned: true,
                isValid: true,
                cdHash: finalInspectionCDHash,
                identifier: sourceInspection.bundleIdentifier,
                entitlementsPlist: nil
            )
            let preparedInspection = PlayCoverUpstreamAppInspection(
                appPath: options.stagingApp.path,
                sourceContentHash:
                    sourceInspection.sourceContentHash,
                infoPlistSHA256:
                    sourceInspection.infoPlistSHA256,
                bundleIdentifier:
                    sourceInspection.bundleIdentifier,
                executableName:
                    sourceInspection.executableName,
                executablePath: options.stagingApp
                    .appendingPathComponent(
                        sourceInspection.mainExecutableRelativePath
                    ).path,
                mainExecutableRelativePath:
                    sourceInspection.mainExecutableRelativePath,
                signature: preparedSignature,
                provisioning: sourceInspection.provisioning,
                inventory: sourceInspection.inventory,
                machOs: sourceInspection.machOs
            )
            return PlayCoverUpstreamPrepareResult(
                sourceBefore: sourceInspection,
                sourceHashAfterPrepare:
                    sourceInspection.sourceContentHash,
                prepared: preparedInspection,
                convertedMachOs:
                    sourceInspection.machOs.map(\.relativePath),
                signingOrder: ["."],
                entitlementDiff: PlayCoverUpstreamEntitlementDiff(
                    original: [:],
                    playCoverBaseline: [:],
                    final: [:],
                    addedByPlayCover: [],
                    addedByIOSUse: [],
                    changedFromOriginal: [],
                    removedFromOriginal: []
                )
            )
        }
        var inspectorCallCount = 0
        PlayCoverService.rootCodeSignatureInspectorOverrideForTesting = {
            appURL in
            inspectorCallCount += 1
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: appURL.path)
            )
            return makePlayCoverTestRootCodeSignature(
                bundleIdentifier: source.inspection.bundleIdentifier,
                identity: identity,
                cdHash: String(repeating: "D", count: 40)
            )
        }

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                fixture.app.path,
                paths: paths
            )
        ) { error in
            guard case .codeSigningFailed(let message) =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(
                message.contains("final prepared inspection"),
                message
            )
        }

        XCTAssertEqual(prepareCallCount, 1)
        XCTAssertEqual(inspectorCallCount, 1)
        let publishedGeneration = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(
            plan.generationKey,
            isDirectory: true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: publishedGeneration.path
            ),
            "a CDHash mismatch must fail before sidecars or publication"
        )
        if FileManager.default.fileExists(
            atPath: paths.playcoverGlobalObjects
        ) {
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    atPath: paths.playcoverGlobalObjects
                ).allSatisfy {
                    !$0.hasPrefix(".staging-")
                        && $0 != plan.generationKey
                },
                "failed preparation must not retain staging or published "
                    + "generation state"
            )
        }
    }

    func testManifestIsCompactAndContainsNoAbsoluteOrFullInventoryFields()
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

        XCTAssertEqual(manifest.backend, "mac")
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
            "sourceAppPath",
            "preparedAppPath",
            "executablePath",
            "sourceInventory",
            "sourceMachOs",
            "\"inventory\"",
            "\"machOs\"",
            "convertedMachOs",
            "entitlementDiff",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), encoded)
        }
        XCTAssertFalse(encoded.contains(fixture.root.path), encoded)
        XCTAssertTrue(encoded.contains("\"codeObjects\""), encoded)
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
                "IOS_USE_PLAY_STDIO_LOG": "1",
                "IOS_USE_PLAY_STDIO_LOG_PATH": "/untrusted/log",
                "IOS_USE_PLAY_STDIO_LOG_DEVICE": "9",
                "IOS_USE_PLAY_STDIO_LOG_INODE": "8",
            ],
            sessionID: "session-one",
            runtimeSocketPath: "/state/run/s-sessionone.sock",
            generationKey: String(repeating: "b", count: 64),
            playChainPath: "/state/managed-home"
        )

        XCTAssertEqual(result["HOME"], "/Users/test")
        XCTAssertEqual(result["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(result["IOS_USE_PLAY_SESSION_ID"], "session-one")
        XCTAssertEqual(
            result["IOS_USE_PLAY_RUNTIME_SOCKET"],
            "/state/run/s-sessionone.sock"
        )
        XCTAssertEqual(result["API_TOKEN"], "")
        XCTAssertEqual(result["SSH_AUTH_SOCK"], "")
        XCTAssertEqual(result["IOS_USE_PLAY_STDIO_LOG"], "")
        XCTAssertEqual(result["IOS_USE_PLAY_STDIO_LOG_PATH"], "")
        XCTAssertEqual(result["IOS_USE_PLAY_STDIO_LOG_DEVICE"], "")
        XCTAssertEqual(result["IOS_USE_PLAY_STDIO_LOG_INODE"], "")
        XCTAssertFalse(result.values.contains("secret"))
    }

    func testLaunchEnvironmentForwardsExactStdioIdentity() {
        let log = PlayCoverStdioLogIdentity(
            path: "/state/mac/logs/stdio-session.log",
            device: 12,
            inode: 34
        )
        let result = PlayCoverService.launchConfigurationEnvironment(
            source: [
                "HOME": "/Users/test",
                "IOS_USE_PLAY_STDIO_LOG_PATH": "/untrusted/log",
            ],
            sessionID: "session-one",
            runtimeSocketPath: "/state/run/s-sessionone.sock",
            generationKey: String(repeating: "b", count: 64),
            playChainPath: "/state",
            stdioLog: log
        )

        XCTAssertEqual(result["IOS_USE_PLAY_STDIO_LOG"], "1")
        XCTAssertEqual(result["IOS_USE_PLAY_STDIO_LOG_PATH"], "")
        XCTAssertNil(result["IOS_USE_PLAY_STDIO_LOG_DEVICE"])
        XCTAssertNil(result["IOS_USE_PLAY_STDIO_LOG_INODE"])
        XCTAssertFalse(result.values.contains("/untrusted/log"))
    }

    func testReadyGateRequiresExactRequestedStdioIdentity() {
        let expected = PlayCoverStdioLogIdentity(
            path: "/state/mac/logs/stdio-session.log",
            device: 12,
            inode: 34
        )
        let redirected = PlayCoverRuntimeStdioState(
            status: "redirected",
            path: expected.path,
            device: expected.device,
            inode: expected.inode,
            failureStage: nil,
            errorNumber: nil
        )
        XCTAssertNoThrow(
            try PlayCoverService.validateStdio(
                redirected,
                expected: expected
            )
        )
        XCTAssertNoThrow(
            try PlayCoverService.validateStdio(
                .init(
                    status: "disabled",
                    path: nil,
                    device: nil,
                    inode: nil,
                    failureStage: nil,
                    errorNumber: nil
                ),
                expected: nil
            )
        )
        for mismatched in [
            PlayCoverRuntimeStdioState(
                status: "failed",
                path: expected.path,
                device: expected.device,
                inode: expected.inode,
                failureStage: "open-exact-log-file",
                errorNumber: EACCES
            ),
            PlayCoverRuntimeStdioState(
                status: "redirected",
                path: expected.path + ".other",
                device: expected.device,
                inode: expected.inode,
                failureStage: nil,
                errorNumber: nil
            ),
            PlayCoverRuntimeStdioState(
                status: "redirected",
                path: expected.path,
                device: expected.device,
                inode: expected.inode + 1,
                failureStage: nil,
                errorNumber: nil
            ),
        ] {
            XCTAssertThrowsError(
                try PlayCoverService.validateStdio(
                    mismatched,
                    expected: expected
                )
            )
        }
        XCTAssertThrowsError(
            try PlayCoverService.validateStdio(
                redirected,
                expected: nil
            )
        )
    }

    func testRuntimeHelloFailureTaxonomyClassifiesEveryRuntimeClientError() {
        func details(
            retryable: Bool,
            fatal: Bool
        ) -> PlayCoverRuntimeErrorDetails {
            PlayCoverRuntimeErrorDetails(
                category: "startup",
                phase: "hello",
                retryable: retryable,
                fatal: fatal,
                target: nil,
                candidateCount: 0,
                candidates: [],
                suggestions: []
            )
        }
        func remote(
            _ details: PlayCoverRuntimeErrorDetails?
        ) -> PlayCoverRuntimeClientError {
            .remoteError(
                code: "runtime_not_ready",
                message: "Runtime is not ready",
                details: details
            )
        }

        let retryable: [PlayCoverRuntimeClientError] = [
            .socketCreateFailed(errno: EMFILE),
            .socketOptionFailed(
                option: "SO_NOSIGPIPE",
                errno: ENOPROTOOPT
            ),
            .connectFailed(errno: ECONNREFUSED),
            .writeFailed(errno: EPIPE),
            .readFailed(errno: EIO),
            .timeout(operation: "read response header"),
            .unexpectedEOF(
                operation: "read response body",
                expectedBytes: 10,
                receivedBytes: 3
            ),
            remote(details(retryable: true, fatal: false)),
        ]
        for error in retryable {
            XCTAssertFalse(
                PlayCoverService.runtimeHelloFailureIsTerminal(error),
                "\(error)"
            )
        }

        let terminal: [PlayCoverRuntimeClientError] = [
            .invalidSocketPath(.empty),
            .invalidSocketPath(.containsNUL),
            .invalidSocketPath(
                .tooLong(actualUTF8Bytes: 105, maximumUTF8Bytes: 104)
            ),
            .invalidTimeout,
            .peerCredentialFailed(errno: EACCES),
            .peerUIDMismatch(expected: 501, actual: 502),
            .peerPIDCredentialFailed(errno: EACCES),
            .peerPIDMismatch(expected: 41, actual: 42),
            .processExecutableLookupFailed(pid: 42),
            .processExecutableMismatch,
            .requestEncodingFailed,
            .requestFrameTooLarge(
                actualBytes: 65,
                maximumBytes: 64
            ),
            .emptyResponseFrame,
            .responseFrameTooLarge(
                actualBytes: 65,
                maximumBytes: 64
            ),
            .responseIsNotUTF8,
            .responseDecodingFailed,
            .requestIDMismatch,
            .sessionIDMismatch,
            .responseIdentityMismatch("PID"),
            .malformedResponse("hello response type mismatch"),
            remote(nil),
            remote(details(retryable: false, fatal: false)),
            remote(details(retryable: true, fatal: true)),
            remote(details(retryable: false, fatal: true)),
        ]
        for error in terminal {
            XCTAssertTrue(
                PlayCoverService.runtimeHelloFailureIsTerminal(error),
                "\(error)"
            )
        }
    }

    func testRuntimeHelloFailureTaxonomyClassifiesBackendAndUnknownErrors() {
        XCTAssertFalse(
            PlayCoverService.runtimeHelloFailureIsTerminal(
                PlayCoverBackendError.launchFailed(
                    "window is not ready"
                )
            )
        )

        let terminal: [PlayCoverBackendError] = [
            .invalidApp("fixture"),
            .unsupportedMachO("fixture"),
            .malformedMachO("fixture"),
            .encryptedMachO("fixture"),
            .duplicateRuntimeLoad("fixture"),
            .machOTransformFailed("fixture"),
            .entitlementFailed("fixture"),
            .codeSigningFailed("fixture"),
            .outputExists("fixture"),
            .missingRuntime("fixture"),
            .prepareFailed("fixture"),
            .verificationFailed("fixture"),
            .cacheTampered("fixture"),
            .stdioLogFailed("exact identity mismatch"),
            .launchTimedOut("fixture"),
            .terminateFailed("fixture"),
            .capabilityUnavailable("fixture"),
        ]
        for error in terminal {
            XCTAssertTrue(
                PlayCoverService.runtimeHelloFailureIsTerminal(error),
                "\(error)"
            )
        }
        XCTAssertTrue(
            PlayCoverService.runtimeHelloFailureIsTerminal(
                NSError(
                    domain: "PlayCoverCoreTests.UnknownHelloFailure",
                    code: 1
                )
            )
        )
    }

    func testAuthenticatedHelloDoesNotWaitForUIReadiness() throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.app.path,
            generationKey: String(repeating: "a", count: 64)
        )
        let pid: Int32 = 42
        let capabilities = [
            "hello", "ping", "diagnostics", "screenshot", "dom",
            "waitFor", "tap", "longPress", "swipe", "input",
            "dismissAlert", "dismissAlertByLabel", "open",
        ]
        func payload(
            generationKey: String? = nil,
            controlStage: String = "ready",
            uiState: String = "initializing",
            uiStage: String = "waiting-for-window"
        ) -> PlayCoverRuntimeHelloPayload {
            PlayCoverRuntimeHelloPayload(
                pid: pid,
                bundleIdentifier: manifest.bundleIdentifier,
                executablePath: manifest.executablePath,
                generationKey: generationKey
                    ?? manifest.generationKey,
                capabilities: capabilities,
                controlStage: controlStage,
                controlFailure: controlStage == "ready"
                    ? nil
                    : "required hook failed",
                uiState: .init(
                    state: uiState,
                    stage: uiStage,
                    failure: uiState == "failed"
                        ? "UI failed"
                        : nil
                ),
                stdio: .init(
                    status: "disabled",
                    path: nil,
                    device: nil,
                    inode: nil,
                    failureStage: nil,
                    errorNumber: nil
                )
            )
        }
        XCTAssertNoThrow(
            try PlayCoverService.validateHello(
                payload(),
                sessionID: "control-session",
                manifest: manifest,
                pid: pid,
                stdioLog: nil
            )
        )
        XCTAssertNoThrow(
            try PlayCoverService.validateHello(
                payload(
                    uiState: "backgrounded",
                    uiStage: "inactive-space"
                ),
                sessionID: "control-session",
                manifest: manifest,
                pid: pid,
                stdioLog: nil
            )
        )
        XCTAssertThrowsError(
            try PlayCoverService.validateHello(
                payload(
                    generationKey: String(repeating: "b", count: 64)
                ),
                sessionID: "control-session",
                manifest: manifest,
                pid: pid,
                stdioLog: nil
            )
        )
        XCTAssertThrowsError(
            try PlayCoverService.validateHello(
                payload(controlStage: "required-hook-failed"),
                sessionID: "control-session",
                manifest: manifest,
                pid: pid,
                stdioLog: nil
            )
        )
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
        let launchAliasPath = fixture.root
            .appendingPathComponent("Launch.app").path

        XCTAssertTrue(
            PlayCoverService.acceptsOwnedLaunchIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: launchAliasPath,
                executablePath: manifest.executablePath,
                existingPIDs: [41],
                manifest: manifest,
                launchAliasPath: launchAliasPath
            )
        )
        XCTAssertFalse(
            PlayCoverService.acceptsOwnedLaunchIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: launchAliasPath,
                executablePath: manifest.executablePath,
                existingPIDs: [42],
                manifest: manifest,
                launchAliasPath: launchAliasPath
            ),
            "a completion callback must never claim a pre-existing PID"
        )
        XCTAssertFalse(
            PlayCoverService.acceptsOwnedLaunchIdentity(
                pid: 43,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                existingPIDs: [],
                manifest: manifest,
                launchAliasPath: launchAliasPath
            ),
            "a callback that reports the prepared App cannot grant ownership"
        )
        XCTAssertFalse(
            PlayCoverService.acceptsOwnedLaunchIdentity(
                pid: 44,
                bundleIdentifier: "com.example.other",
                bundleURLPath: launchAliasPath,
                executablePath: manifest.executablePath,
                existingPIDs: [],
                manifest: manifest,
                launchAliasPath: launchAliasPath
            )
        )
    }

    func testPreparedBundlePathRequiresExactRuntimeAuthentication()
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
        let launchAliasPath = fixture.root
            .appendingPathComponent("Launch.app").path

        for bundlePath in [
            launchAliasPath,
            manifest.preparedAppPath,
        ] {
            XCTAssertTrue(
                PlayCoverService.acceptsRuntimeLaunchCandidateIdentity(
                    pid: 42,
                    bundleIdentifier: manifest.bundleIdentifier,
                    bundleURLPath: bundlePath,
                    executablePath: manifest.executablePath,
                    existingPIDs: [41],
                    manifest: manifest,
                    launchAliasPath: launchAliasPath
                ),
                "LaunchServices may expose either exact bundle spelling"
            )
        }
        XCTAssertFalse(
            PlayCoverService.acceptsRuntimeLaunchCandidateIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                existingPIDs: [42],
                manifest: manifest,
                launchAliasPath: launchAliasPath
            ),
            "a pre-existing PID is never challenged or claimed"
        )
        XCTAssertFalse(
            PlayCoverService.acceptsRuntimeLaunchCandidateIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: fixture.app.path,
                executablePath: manifest.executablePath,
                existingPIDs: [],
                manifest: manifest,
                launchAliasPath: launchAliasPath
            ),
            "an unrelated App path is not a Runtime candidate"
        )
        let callbackAtAlias =
            PlayCoverService.LaunchedApplicationIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: launchAliasPath,
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 10,
                source: .workspaceCallback
            )
        let callbackAtPrepared =
            PlayCoverService.LaunchedApplicationIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 10,
                source: .workspaceCallback
            )
        let observedAtPrepared =
            PlayCoverService.LaunchedApplicationIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 10,
                source: .observedCandidate
            )
        let authenticatedAtPrepared =
            PlayCoverService.LaunchedApplicationIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 10,
                source: .authenticatedRuntime
            )

        XCTAssertTrue(
            PlayCoverService.acceptsClaimedLaunchIdentity(
                callbackAtAlias,
                manifest: manifest,
                launchAliasPath: launchAliasPath
            )
        )
        XCTAssertFalse(
            PlayCoverService.acceptsClaimedLaunchIdentity(
                callbackAtPrepared,
                manifest: manifest,
                launchAliasPath: launchAliasPath
            ),
            "a callback alone cannot claim the canonical prepared path"
        )
        XCTAssertFalse(
            PlayCoverService.acceptsClaimedLaunchIdentity(
                observedAtPrepared,
                manifest: manifest,
                launchAliasPath: launchAliasPath
            ),
            "polling alone cannot claim the canonical prepared path"
        )
        XCTAssertTrue(
            PlayCoverService.acceptsClaimedLaunchIdentity(
                authenticatedAtPrepared,
                manifest: manifest,
                launchAliasPath: launchAliasPath
            ),
            "the exact current Runtime session grants the claim"
        )
        XCTAssertEqual(
            try PlayCoverService.authenticatedRuntimeClaim(
                from: [observedAtPrepared]
            ),
            authenticatedAtPrepared
        )
        let secondObserved =
            PlayCoverService.LaunchedApplicationIdentity(
                pid: 43,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: manifest.preparedAppPath,
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds: 11,
                source: .observedCandidate
            )
        XCTAssertThrowsError(
            try PlayCoverService.authenticatedRuntimeClaim(
                from: [observedAtPrepared, secondObserved]
            )
        ) { error in
            guard case .launchFailed(let message) =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(
                message.contains(
                    "multiple App processes authenticated"
                )
            )
        }
    }

    func testSessionLaunchAliasUsesPinnedTopLevelSymlinkFarm()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("hidden".utf8).write(
            to: fixture.app.appendingPathComponent(".launch-hidden")
        )
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.app.path,
            generationKey: String(repeating: "1", count: 64)
        )
        let aliasRoot = fixture.root.appendingPathComponent(
            "launch-aliases",
            isDirectory: true
        )
        PlayCoverService.launchAliasRootOverrideForTesting = aliasRoot

        let alias = try PlayCoverService.createSessionLaunchAlias(
            manifest: manifest,
            sessionID: "session-alias"
        )

        var aliasStatus = stat()
        XCTAssertEqual(lstat(alias.bundleURL.path, &aliasStatus), 0)
        XCTAssertEqual(aliasStatus.st_mode & S_IFMT, S_IFDIR)
        let sourceNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.app.path
        ).sorted()
        let aliasNames = try FileManager.default.contentsOfDirectory(
            atPath: alias.bundleURL.path
        ).sorted()
        XCTAssertEqual(aliasNames, sourceNames)
        XCTAssertTrue(aliasNames.contains(".launch-hidden"))
        for name in aliasNames {
            let destination = try FileManager.default
                .destinationOfSymbolicLink(
                    atPath: alias.bundleURL
                        .appendingPathComponent(name).path
                )
            XCTAssertEqual(
                destination,
                fixture.app.appendingPathComponent(name).path
            )
        }
        XCTAssertThrowsError(
            try PlayCoverService.createSessionLaunchAlias(
                manifest: manifest,
                sessionID: "session-alias"
            )
        ) { error in
            guard case .launchFailed(let message) =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("already exists"))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: alias.bundleURL.path
            ),
            "an unresolved session alias must remain fail-closed"
        )
        let nextAlias = try PlayCoverService.createSessionLaunchAlias(
            manifest: manifest,
            sessionID: "next-session-alias"
        )
        XCTAssertNotEqual(
            nextAlias,
            alias,
            "an unresolved prior session alias must not block a new start"
        )
        try PlayCoverService.removeSessionLaunchAlias(
            nextAlias,
            manifest: manifest
        )
        try PlayCoverService.removeSessionLaunchAlias(
            sessionID: "session-alias",
            manifest: manifest
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: alias.bundleURL.path
            )
        )
    }

    func testSessionLaunchAliasCleanupRefusesUnexpectedRegularFile()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.app.path,
            generationKey: String(repeating: "2", count: 64)
        )
        PlayCoverService.launchAliasRootOverrideForTesting =
            fixture.root.appendingPathComponent(
                "launch-aliases",
                isDirectory: true
            )
        let alias = try PlayCoverService.createSessionLaunchAlias(
            manifest: manifest,
            sessionID: "tampered-alias"
        )
        let infoAlias = alias.bundleURL.appendingPathComponent(
            "Info.plist"
        )
        try FileManager.default.removeItem(at: infoAlias)
        try Data("not a symlink".utf8).write(to: infoAlias)

        XCTAssertThrowsError(
            try PlayCoverService.removeSessionLaunchAlias(
                sessionID: "tampered-alias",
                manifest: manifest
            )
        ) { error in
            guard case .cacheTampered =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        var status = stat()
        XCTAssertEqual(lstat(infoAlias.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
    }

    #if canImport(AppKit)
    func testWorkspaceCallbackFailureSubmitsOnceAndPreservesIntent()
        throws {
        let fixture = try makePendingWorkspaceLaunchFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
        }
        var submissionCount = 0
        PlayCoverService.workspaceOpenOverrideForTesting = {
            _, _, completion in
            submissionCount += 1
            completion(
                nil,
                NSError(
                    domain: "PlayCoverCoreTests",
                    code: 7
                )
            )
        }

        _ = try runPendingWorkspaceLaunch(
            fixture,
            deadline: ProcessInfo.processInfo.systemUptime + 0.03
        )

        XCTAssertEqual(submissionCount, 1)
        let pending = try XCTUnwrap(
            PlayCoverPendingLaunchStore.load(paths: fixture.paths)
        )
        XCTAssertEqual(pending.phase, .intent)
        XCTAssertNil(pending.owner)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pending.aliasPath
            )
        )
    }

    func testWorkspaceLaunchSubmitsTheSessionAlias() throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.app.path,
            generationKey: String(repeating: "3", count: 64)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.root.path
        )
        let aliasRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent(
                "\(fixture.root.lastPathComponent)-launch-aliases",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: aliasRoot) }
        PlayCoverService.launchAliasRootOverrideForTesting = aliasRoot
        let sessionID = "workspace-alias"
        let socketPath = fixture.root.appendingPathComponent(
            "runtime.sock"
        ).path
        var submittedURL: URL?
        var submittedEnvironment: [String: String]?
        PlayCoverService.workspaceOpenOverrideForTesting = {
            url,
            configuration,
            completion in
            submittedURL = url
            submittedEnvironment = configuration.environment
            completion(
                nil,
                NSError(
                    domain: "PlayCoverCoreTests",
                    code: 1
                )
            )
        }
        var alias: PlayCoverService.SessionLaunchAlias?
        var openSubmitted = false
        var postSubmissionIntegrityError: Error?

        try PlayCoverService.withUncheckedLaunchCapabilityForTesting(
            appPath: manifest.preparedAppPath
        ) { capability in
            XCTAssertThrowsError(
                try PlayCoverService.launchPreparedApplication(
                    manifest: manifest,
                    launchCapability: capability,
                    sessionID: sessionID,
                    runtimeSocketPath: socketPath,
                    playChainPath: fixture.root
                        .appendingPathComponent("runtime-home").path,
                    deadline:
                        ProcessInfo.processInfo.systemUptime + 0.05,
                    launchAlias: &alias,
                    launchSubmitted: &openSubmitted,
                    postSubmissionIntegrityError:
                        &postSubmissionIntegrityError
                )
            )
        }

        let expectedAlias =
            PlayCoverService.sessionLaunchAlias(sessionID: sessionID)
        XCTAssertTrue(openSubmitted)
        XCTAssertEqual(alias, expectedAlias)
        XCTAssertEqual(submittedURL, expectedAlias.bundleURL)
        XCTAssertEqual(
            submittedEnvironment?["IOS_USE_PLAY_SESSION_ID"],
            sessionID
        )
        XCTAssertEqual(
            submittedEnvironment?["IOS_USE_PLAY_RUNTIME_SOCKET"],
            socketPath
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: expectedAlias.bundleURL.path
            ),
            "a submitted asynchronous open remains recoverable"
        )
        try PlayCoverService.removeSessionLaunchAlias(
            expectedAlias,
            manifest: manifest
        )
    }
    #endif

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
        let launchAliasPath = fixture.root
            .appendingPathComponent("Launch.app").path
        let callbackIdentity =
            PlayCoverService.LaunchedApplicationIdentity(
                pid: 42,
                bundleIdentifier: manifest.bundleIdentifier,
                bundleURLPath: launchAliasPath,
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
        let paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": "/state/ios-use"]
        )

        XCTAssertEqual(
            PlayCoverManagedAppService.runtimeCandidates(
                paths: paths,
                executablePath: "/opt/ios-use/bin/ios-use"
            ),
            [
                "/state/ios-use/mac/IOSUsePlayRuntime.framework",
                "/opt/ios-use/bin/.ios-use/playcover/"
                    + "IOSUsePlayRuntime.framework",
                "/opt/ios-use/share/ios-use/mac/"
                    + "IOSUsePlayRuntime.framework",
            ]
        )
    }

    func testRuntimeCandidatesIgnoreImplicitMutableHome() {
        let paths = resolvePlayCoverTestPaths(
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
                "/share/ios-use/mac/"
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
        let paths = resolvePlayCoverTestPaths(
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
        var manifestReadCount = 0
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
            atPath: paths.playcoverGlobalObjects
        ).filter { $0.hasPrefix(".staging-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testOversizedCompactManifestRollsBackStagingBeforePublication()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home").path,
            ]
        )
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        let generationKey = String(repeating: "e", count: 64)
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: generationKey
        )
        let originalPrepare = try XCTUnwrap(
            PlayCoverManagedAppService.prepareOverrideForTesting
        )
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            plan,
            staging,
            paths,
            published in
            let normal = try originalPrepare(
                plan,
                staging,
                paths,
                published
            )
            var object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(normal)
                ) as? [String: Any]
            )
            object["codeObjects"] = [
                [
                    "relativePath": String(
                        repeating: "x",
                        count:
                            PlayCoverService
                                .generationManifestMaximumBytes
                            + 1_024
                    ),
                    "kind": "regularFile",
                    "sha256": String(repeating: "a", count: 64),
                ],
            ]
            let oversized = try JSONDecoder().decode(
                PlayCoverPrepareManifest.self,
                from: JSONSerialization.data(
                    withJSONObject: object
                )
            ).resolving(
                appURL: URL(
                    fileURLWithPath: published,
                    isDirectory: true
                )
            )
            _ = try PlayCoverService.generationSidecars(
                manifest: oversized
            )
            return oversized
        }

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                fixture.app.path,
                paths: paths
            )
        ) { error in
            guard case .verificationFailed(let message) =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(
                message.contains(
                    "manifest exceeds the managed generation size limit"
                )
            )
        }
        let generation = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(
            generationKey,
            isDirectory: true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: generation.path)
        )
        let residues = try FileManager.default.contentsOfDirectory(
            atPath: paths.playcoverGlobalObjects
        ).filter {
            $0.hasPrefix(".staging-\(generationKey)-")
        }
        XCTAssertTrue(residues.isEmpty)
        XCTAssertNil(try PlayCoverHomeStore.readLast(paths: paths))
    }

    func testManagedPathAcceptsEquivalentPrivateTmpAlias()
        throws
    {
        let lexicalHome = URL(
            fileURLWithPath:
                "/tmp/IOSUsePlayCoverAlias-\(UUID().uuidString)",
            isDirectory: true
        )
        let privateHome = URL(
            fileURLWithPath: "/private" + lexicalHome.path,
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: lexicalHome)
        }
        let paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": privateHome.path]
        )
        let privatePrepared = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: privatePrepared,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let generation = String(repeating: "7", count: 64)
        let lexicalPrepared = URL(
            fileURLWithPath: privatePrepared.path.replacingOccurrences(
                of: "/private/tmp/",
                with: "/tmp/"
            ),
            isDirectory: true
        )
        let notYetCreatedApp = lexicalPrepared
            .appendingPathComponent(
                generation,
                isDirectory: true
            )
            .appendingPathComponent(
                "com.example.fixture.app",
                isDirectory: true
            )

        XCTAssertNoThrow(
            try PlayCoverService.requireManagedPath(
                notYetCreatedApp,
                paths: paths,
                operation: "staging"
            )
        )

        XCTAssertThrowsError(
            try PlayCoverService.requireManagedPath(
                privateHome.appendingPathComponent(
                    "outside.app",
                    isDirectory: true
                ),
                paths: paths,
                operation: "staging"
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "path must be below the account-global "
                        + "managed prepared directory"
                )
            )
        }
    }

    func testConcurrentGenerationPublishHasOneWinnerAndOneReuse()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = resolvePlayCoverTestPaths(
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
            atPath: paths.playcoverGlobalObjects
        ).filter { $0.hasPrefix(".staging-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testIncompleteGenerationIsTamperingAndIsNeverOverwritten()
        throws {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paths = resolvePlayCoverTestPaths(
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
            fileURLWithPath: paths.playcoverGlobalObjects,
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
        let paths = resolvePlayCoverTestPaths(
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
                runtimeBuildHash: wrongRuntimeHash,
                accountNamespacePolicyHash:
                    plan.accountNamespacePolicyHash
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
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(generationKey, isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: generation.path)
        )
    }

    func testManagedExplicitAppRejectsDifferentSocketNamespacePolicy()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let logicalHome = fixture.root.appendingPathComponent(
            "logical-home",
            isDirectory: true
        ).path
        let accountHome = fixture.root.appendingPathComponent(
            "account-home",
            isDirectory: true
        ).path
        let token = UUID().uuidString.prefix(8)
        let firstPaths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": logicalHome],
            accountHomeDirectoryOverrideForTesting: accountHome,
            socketRootOverrideForTesting:
                "/private/tmp/iu-explicit-a-\(token)"
        )
        let movedPaths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": logicalHome],
            accountHomeDirectoryOverrideForTesting: accountHome,
            socketRootOverrideForTesting:
                "/private/tmp/iu-explicit-b-\(token)"
        )
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )
        try installFakeManagedPipeline(
            source: inspection,
            generationKey: String(repeating: "8", count: 64)
        )
        let prepared = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: firstPaths
        )

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                prepared.manifest.preparedAppPath,
                paths: movedPaths
            )
        ) {
            guard case .cacheTampered(let message) =
                    $0 as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(
                message.contains("current account Runtime namespace"),
                message
            )
        }
    }

    func testManagedPreparedRootAndAppRejectSymlinkEscape()
        throws
    {
        let fixture = try makeSourceApp()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let generationKey = String(repeating: "f", count: 64)

        let childPaths = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("child-home").path,
            ]
        )
        let generation = URL(
            fileURLWithPath: childPaths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(generationKey, isDirectory: true)
        try PlayCoverHomeStore.updateLast(
            generationKey: generationKey,
            paths: childPaths
        )
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
            "App.app",
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

        let rootPaths = resolvePlayCoverTestPaths(
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
            "App.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalApp,
            withIntermediateDirectories: true
        )
        _ = try PlayCoverManagedAppService.secureManagedDirectories(
            paths: rootPaths
        )
        try FileManager.default.removeItem(
            atPath: rootPaths.playcoverGlobalObjects
        )
        try FileManager.default.createSymbolicLink(
            at: URL(
                fileURLWithPath: rootPaths.playcoverGlobalObjects
            ),
            withDestinationURL: externalPrepared
        )

        XCTAssertThrowsError(
            try PlayCoverManagedAppService.resolveExplicitApp(
                rootPaths.playcoverGlobalObjects
                    + "/\(generationKey)/App.app",
                paths: rootPaths
            )
        ) {
            guard let backendError =
                    $0 as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \($0)")
            }
            switch backendError {
            case .cacheTampered(let message):
                XCTAssertTrue(
                    message.contains("symbolic-link escape"),
                    message
                )
            case .prepareFailed(let message):
                XCTAssertTrue(
                    message.contains("symbolic link"),
                    message
                )
            default:
                XCTFail("unexpected error: \($0)")
            }
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
        let paths = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent(
                        "logical-home",
                        isDirectory: true
                    ).path,
            ],
            accountHomeDirectory:
                link.path + "/account-home"
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: external
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
        try makeThinMachO(
            encrypted: false,
            platform: 6
        ).write(to: runtimeExecutable)
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
        let paths = resolvePlayCoverTestPaths(
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
            fileURLWithPath: paths.playcoverGlobalObjects,
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
            guard let backendError =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            switch backendError {
            case .cacheTampered:
                break
            case .prepareFailed(let message):
                XCTAssertTrue(
                    message.contains("symbolic link"),
                    message
                )
            default:
                XCTFail("unexpected error: \(error)")
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

    func testManagedPrepareNamespaceGuardRejectsMacCacheRename()
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
        let paths = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("managed-home").path,
            ]
        )
        _ = try PlayCoverManagedAppService.secureManagedDirectories(
            paths: paths
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
        let prepared = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        )
        let macCache = prepared.deletingLastPathComponent()
        let displaced = macCache.deletingLastPathComponent()
            .appendingPathComponent(
                "mac-cache-displaced",
                isDirectory: true
            )
        let stableProbeName = "stable-vnode-probe"
        var usedStableVnodePath = false
        var macCacheRenameRejected = false
        let macCacheFlagsBefore = try fileFlags(macCache)
        let preparedFlagsBefore = try fileFlags(prepared)
        PlayCoverManagedAppService
            .afterStagingPathResolvedForTesting = { staging in
                usedStableVnodePath =
                    staging.path.hasPrefix("/.vol/")
                XCTAssertNotEqual(
                    try self.fileFlags(macCache) & UInt32(UF_APPEND),
                    0
                )
                XCTAssertNotEqual(
                    try self.fileFlags(prepared) & UInt32(UF_APPEND),
                    0
                )
                do {
                    try FileManager.default.moveItem(
                        at: macCache,
                        to: displaced
                    )
                } catch {
                    macCacheRenameRejected = true
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
        XCTAssertTrue(macCacheRenameRejected)
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
        XCTAssertEqual(try fileFlags(macCache), macCacheFlagsBefore)
        XCTAssertEqual(try fileFlags(prepared), preparedFlagsBefore)
        try FileManager.default.moveItem(at: macCache, to: displaced)
        try FileManager.default.moveItem(at: displaced, to: macCache)
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
        let paths = resolvePlayCoverTestPaths(
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
                    URL(fileURLWithPath: paths.playcoverGlobalObjects)
                        .appendingPathComponent(
                            try XCTUnwrap(
                                FileManager.default.contentsOfDirectory(
                                    atPath: paths.playcoverGlobalObjects
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
        let paths = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("managed-home").path,
            ]
        )
        _ = try PlayCoverManagedAppService.secureManagedDirectories(
            paths: paths
        )
        let prepared = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        )
        let macCache = prepared.deletingLastPathComponent()
        let macCacheFlagsBefore = try fileFlags(macCache)
        let preparedFlagsBefore = try fileFlags(prepared)
        let macCacheModeBefore = try fileMode(macCache)
        let preparedModeBefore = try fileMode(prepared)
        var sawProtectedNamespace = false
        PlayCoverManagedAppService
            .afterStagingPathResolvedForTesting = { _ in
                sawProtectedNamespace =
                    try self.fileFlags(macCache) & UInt32(UF_APPEND) != 0
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
        XCTAssertEqual(try fileFlags(macCache), macCacheFlagsBefore)
        XCTAssertEqual(try fileFlags(prepared), preparedFlagsBefore)
        XCTAssertEqual(try fileMode(macCache), macCacheModeBefore)
        XCTAssertEqual(try fileMode(prepared), preparedModeBefore)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: paths.playcoverGlobalObjects
            ).allSatisfy { !$0.hasPrefix(".staging-") }
        )
    }

    func testPrepareNamespaceGuardRecoversStaleOwnedFlags()
        throws
    {
        let fixture = try makeSourceApp()
        let paths = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("managed-home").path,
            ]
        )
        defer {
            try? clearAppendOnlyFlag(
                URL(
                    fileURLWithPath: paths.playcoverGlobalCache
                )
            )
            try? clearAppendOnlyFlag(
                URL(
                    fileURLWithPath: paths.playcoverGlobalObjects
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
        _ = try PlayCoverManagedAppService.secureManagedDirectories(
            paths: paths
        )
        let prepared = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        )
        let macCache = prepared.deletingLastPathComponent()
        try setAppendOnlyFlag(macCache)
        try setAppendOnlyFlag(prepared)

        _ = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: paths
        )

        XCTAssertEqual(
            try fileFlags(macCache) & UInt32(UF_APPEND),
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

    func testPendingLaunchOwnerRevalidationRejectsPIDReuse()
        throws
    {
        let executablePath = "/tmp/Prepared.app/Fixture"
        let identity = PlayCoverService.LaunchedApplicationIdentity(
            pid: 42,
            bundleIdentifier: "com.example.fixture",
            bundleURLPath: "/tmp/Launch.app",
            executablePath: executablePath,
            processStartTimeMicroseconds: 100,
            source: .workspaceCallback
        )
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            pid in
            XCTAssertEqual(pid, identity.pid)
            return .running(
                executablePath: executablePath,
                processStartTimeMicroseconds: 100
            )
        }

        XCTAssertNoThrow(
            try PlayCoverService.revalidatePendingLaunchIdentity(
                identity
            )
        )

        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            _ in .running(
                executablePath: executablePath,
                processStartTimeMicroseconds: 101
            )
        }
        XCTAssertThrowsError(
            try PlayCoverService.revalidatePendingLaunchIdentity(
                identity
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "PID was reused before ownership commit"
                )
            )
        }
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

    func testFailedLaunchRollbackRejectsMissingLiveBirthTokenBeforeSignal()
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
                processStartTimeMicroseconds: nil
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
                identity: identity,
                manifest: manifest
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "live executable has no stable process birth token"
                )
            )
        }
        XCTAssertEqual(signalCount, 0)
    }

    func testFailedLaunchRollbackRejectsMissingBirthTokenAfterSIGTERM()
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
        var processProbeCount = 0
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            _ in
            processProbeCount += 1
            return .running(
                executablePath: manifest.executablePath,
                processStartTimeMicroseconds:
                    processProbeCount == 1 ? 100 : nil
            )
        }
        var signals: [Int32] = []
        PlayCoverService.failedLaunchSignalOverrideForTesting = {
            _,
            signal in
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
                    "live executable has no stable process birth token"
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
        let manifest = try makeManifest(
            inspection: inspection,
            preparedAppPath: fixture.root
                .appendingPathComponent("Prepared.app").path,
            generationKey: String(repeating: "e", count: 64)
        )
        let identity = PlayCoverService.LaunchedApplicationIdentity(
            pid: 42,
            bundleIdentifier: manifest.bundleIdentifier,
            bundleURLPath: manifest.preparedAppPath,
            executablePath: manifest.executablePath,
            processStartTimeMicroseconds: 100,
            source: .workspaceCallback
        )
        var killed = false
        var processProbeCount = 0
        PlayCoverService.failedLaunchProcessStateOverrideForTesting = {
            pid in
            XCTAssertEqual(pid, identity.pid)
            processProbeCount += 1
            return killed
                ? .missing
                : .running(
                    executablePath: manifest.executablePath,
                    processStartTimeMicroseconds: 100
                )
        }
        var signals: [Int32] = []
        PlayCoverService.failedLaunchSignalOverrideForTesting = {
            pid,
            signal in
            XCTAssertEqual(pid, identity.pid)
            signals.append(signal)
            if signal == SIGKILL {
                killed = true
            }
            return 0
        }

        try PlayCoverService.terminateFailedLaunch(
            identity: identity,
            manifest: manifest
        )

        XCTAssertTrue(killed)
        XCTAssertGreaterThan(processProbeCount, 2)
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
    }

    func testSameContentReusesOneGlobalGenerationAcrossHomes()
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
        let accountHome = fixture.root.appendingPathComponent(
            "account",
            isDirectory: true
        ).path
        let homeOne = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home-one").path,
            ],
            accountHomeDirectory: accountHome
        )
        let homeTwo = resolvePlayCoverTestPaths(
            environment: [
                "IOS_USE_HOME": fixture.root
                    .appendingPathComponent("home-two").path,
            ],
            accountHomeDirectory: accountHome
        )

        let first = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: homeOne
        )
        let second = try PlayCoverManagedAppService.resolveExplicitApp(
            fixture.app.path,
            paths: homeTwo
        )

        XCTAssertEqual(
            first.manifest.preparedAppPath,
            second.manifest.preparedAppPath
        )
        XCTAssertEqual(
            first.manifest.generationKey,
            second.manifest.generationKey
        )
        XCTAssertFalse(first.reused)
        XCTAssertTrue(second.reused)
    }

    #if canImport(AppKit)
    func testBundleStartLockRejectsAnAlreadyRunningBundle() throws {
        let fixture = try makeBundleStartLockPaths()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = {
            bundleIdentifier in
            XCTAssertEqual(bundleIdentifier, "com.example.fixture")
            return [321]
        }

        XCTAssertThrowsError(
            try PlayCoverBundleStartLock.acquire(
                bundleIdentifier: "com.example.fixture",
                paths: fixture.first
            )
        ) { error in
            guard case .bundleAlreadyRunning(
                bundleIdentifier: "com.example.fixture",
                pid: 321
            ) = error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBundleStartLockSerializesTwoHomesForTheSameBundle()
        throws {
        let fixture = try makeBundleStartLockPaths()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = {
            _ in []
        }
        var first: PlayCoverBundleStartLock? =
            try PlayCoverBundleStartLock.acquire(
                bundleIdentifier: "com.example.fixture",
                paths: fixture.first
            )
        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let failed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            do {
                let second = try PlayCoverBundleStartLock.acquire(
                    bundleIdentifier: "com.example.fixture",
                    paths: fixture.second
                )
                withExtendedLifetime(second) {}
            } catch {
                failed.signal()
            }
            completed.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 0.1), .timedOut)
        first = nil
        XCTAssertNil(first)
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(failed.wait(timeout: .now()), .timedOut)
    }
    #endif

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
        let paths = resolvePlayCoverTestPaths(
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
        let paths = resolvePlayCoverTestPaths(
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

    #if canImport(AppKit)
    private struct PendingWorkspaceLaunchFixture {
        let root: URL
        let paths: IOSUsePaths
        let manifest: PlayCoverPrepareManifest
        let sessionID: String
        let runtimeSocketPath: String
    }

    private func makePendingWorkspaceLaunchFixture() throws
        -> PendingWorkspaceLaunchFixture {
        let source = try makeSourceApp()
        defer {
            try? FileManager.default.removeItem(at: source.root)
        }
        var template = Array(
            "/tmp/iu-pending-launch-XXXXXX".utf8CString
        )
        let rootPointer = try XCTUnwrap(Darwin.mkdtemp(&template))
        let root = URL(
            fileURLWithPath: String(cString: rootPointer),
            isDirectory: true
        )
        do {
            let paths = resolvePlayCoverTestPaths(
                environment: ["IOS_USE_HOME": root.path]
            )
            try SessionOperationLock.withExclusiveLock(
                paths: paths
            ) {}
            _ = try PlayCoverManagedAppService
                .secureManagedDirectories(paths: paths)
            let generationKey = String(repeating: "7", count: 64)
            let generation = URL(
                fileURLWithPath: paths.playcoverGlobalObjects,
                isDirectory: true
            ).appendingPathComponent(
                generationKey,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: generation,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let app = generation.appendingPathComponent(
                "App.app",
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: source.app,
                to: app
            )
            let inspection = try PlayCoverService.inspect(
                appPath: app.path
            )
            let manifest = try makeManifest(
                inspection: inspection,
                preparedAppPath: app.path,
                generationKey: generationKey,
                accountNamespacePolicyHash:
                    PlayCoverService.accountNamespacePolicyHash(
                        paths: paths
                    )
            )
            let launchAliasRoot = root.appendingPathComponent(
                "launch-aliases",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: launchAliasRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            PlayCoverService.launchAliasRootOverrideForTesting =
                launchAliasRoot
            let sessionID = UUID().uuidString
            let runtimeSocketPath =
                try paths.macRuntimeSocketPath(
                    sessionID: sessionID
                )
            _ = try PlayCoverPendingLaunchStore.createIntent(
                PlayCoverPendingLaunchStore.Intent(
                    sessionID: sessionID,
                    runtimeSocketPath: runtimeSocketPath,
                    generationKey: generationKey,
                    appPath: app.path,
                    bundleIdentifier: manifest.bundleIdentifier,
                    executablePath: manifest.executablePath,
                    aliasPath: PlayCoverService.sessionLaunchAlias(
                        sessionID: sessionID
                    ).bundleURL.path
                ),
                paths: paths
            )
            return PendingWorkspaceLaunchFixture(
                root: root,
                paths: paths,
                manifest: manifest,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func runPendingWorkspaceLaunch(
        _ fixture: PendingWorkspaceLaunchFixture,
        deadline: TimeInterval
    ) throws -> Error {
        var launchAlias: PlayCoverService.SessionLaunchAlias?
        var workspaceOpenSubmitted = false
        var postSubmissionIntegrityError: Error?
        do {
            try PlayCoverService
                .withUncheckedLaunchCapabilityForTesting(
                    appPath:
                        fixture.manifest.preparedAppPath
                ) { capability in
                    _ = try PlayCoverService
                        .launchPreparedApplication(
                            manifest: fixture.manifest,
                            launchCapability: capability,
                            sessionID: fixture.sessionID,
                            runtimeSocketPath:
                                fixture.runtimeSocketPath,
                            playChainPath:
                                fixture.paths.playcoverPlayChain,
                            pendingLaunchPaths: fixture.paths,
                            deadline: deadline,
                            launchAlias: &launchAlias,
                            launchSubmitted:
                                &workspaceOpenSubmitted,
                            postSubmissionIntegrityError:
                                &postSubmissionIntegrityError
                        )
                }
        } catch {
            return error
        }
        return NSError(
            domain: "PlayCoverCoreTests",
            code: 99,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "test launch unexpectedly succeeded",
            ]
        )
    }
    #endif

    private struct AppFixture {
        let root: URL
        let app: URL
    }

    #if canImport(AppKit)
    private func makeBundleStartLockPaths() throws -> (
        root: URL,
        first: IOSUsePaths,
        second: IOSUsePaths
    ) {
        var template = Array("/tmp/iu-bundle-lock-XXXXXX".utf8CString)
        let pointer = try XCTUnwrap(Darwin.mkdtemp(&template))
        let root = URL(
            fileURLWithPath: String(cString: pointer),
            isDirectory: true
        )
        let account = root.appendingPathComponent(
            "account",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: account,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return (
            root,
            resolvePlayCoverTestPaths(
                environment: [
                    "IOS_USE_HOME": root.appendingPathComponent(
                        "home-a",
                        isDirectory: true
                    ).path,
                ],
                accountHomeDirectory: account.path
            ),
            resolvePlayCoverTestPaths(
                environment: [
                    "IOS_USE_HOME": root.appendingPathComponent(
                        "home-b",
                        isDirectory: true
                    ).path,
                ],
                accountHomeDirectory: account.path
            )
        )
    }
    #endif

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
                try self.makeThinMachO(
                    encrypted: false,
                    platform: 6
                ).write(to: executable)
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
            plan, staging, paths, published in
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
                runtimeBuildHash: plan.runtimeBuildHash,
                accountNamespacePolicyHash:
                    PlayCoverService.accountNamespacePolicyHash(
                        paths: paths
                    )
            )
            manifestLock.lock()
            manifests[
                URL(fileURLWithPath: published)
                    .resolvingSymlinksInPath().path
            ] = manifest
            manifestLock.unlock()
            return manifest
        }
        PlayCoverManagedAppService.readManifestOverrideForTesting = { path in
            manifestLock.lock()
            defer { manifestLock.unlock() }
            let canonical = URL(fileURLWithPath: path)
                .resolvingSymlinksInPath().path
            guard let manifest = manifests[canonical]
                    ?? (
                        manifests.count == 1
                        ? manifests.values.first
                        : nil
                    ) else {
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
        runtimeBuildHash: String = String(repeating: "d", count: 64),
        accountNamespacePolicyHash: String =
            String(repeating: "7", count: 64),
        executablePathOverride: String? = nil
    ) throws -> PlayCoverPrepareManifest {
        let prepared = URL(
            fileURLWithPath: preparedAppPath,
            isDirectory: true
        )
        let signingIdentity = makePlayCoverTestSigningIdentity()
        return PlayCoverPrepareManifest(
            sourceAppPath: inspection.appPath,
            preparedAppPath: prepared.path,
            bundleIdentifier: inspection.bundleIdentifier,
            executableName: inspection.executableName,
            executablePath: executablePathOverride
                ?? prepared.appendingPathComponent(
                    inspection.executableName
                ).path,
            sourceContentHash: inspection.sourceContentHash,
            sourceHashAfterPreparation: inspection.sourceContentHash,
            runtimeBuildHash: runtimeBuildHash,
            prepareRevision: PlayCoverService.prepareImplementationRevision,
            accountNamespacePolicyHash:
                accountNamespacePolicyHash,
            generationKey: generationKey,
            signingIdentity: signingIdentity,
            rootCodeSignature: makePlayCoverTestRootCodeSignature(
                bundleIdentifier: inspection.bundleIdentifier,
                identity: signingIdentity
            ),
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

    private func makeThinMachO(
        encrypted: Bool,
        platform: UInt32 = 2
    ) -> Data {
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
        appendU32(platform, to: &build)
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
