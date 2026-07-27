import CryptoKit
import Foundation
import IOSUsePlayDevice
import PlayCoverUpstream
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverUnterminatedLaunchError: Error,
    CustomStringConvertible
{
    let sessionID: String
    let pid: Int32
    let bundleIdentifier: String
    let executablePath: String
    let appPath: String
    let generationKey: String
    let runtimeSocketPath: String
    let originalError: String
    let rollbackError: String

    var description: String {
        "PlayCover launch failed and exact process \(pid) could "
            + "not be confirmed stopped; an active session lock "
            + "must be preserved. Original error: \(originalError). "
            + "Rollback error: \(rollbackError)"
    }
}

public enum PlayCoverService {
    enum FastVerifyEvent: Equatable {
        case beforeMetadataOpen(String)
        case afterMetadataOpen(String)
        case afterMetadataRead(String)
        case beforeFileHash(String)
        case afterFileHash(String)
        case beforeCodeSignature(String)
        case afterCodeSignature(String)
    }

    public static let manifestFilename = "manifest.json"
    static let completedFilename = "completed.json"
    static let generationManifestMaximumBytes = 64 * 1_024 * 1_024
    static let completedMarkerMaximumBytes = 1_048_576
    public static let runtimeFrameworkName = "IOSUsePlayRuntime.framework"
    public static let runtimeExecutableName = "IOSUsePlayRuntime"
    static let prepareImplementationRevision =
        "ios-use-headless-v11+playcover-"
        + PlayCoverUpstreamEngine.playCoverRevision
        + "+inject-"
        + PlayCoverUpstreamEngine.injectRevision
        + "+rules-"
        + PlayCoverUpstreamEngine.defaultRulesRevision

    static var failedLaunchTerminatorOverrideForTesting:
        ((
            LaunchedApplicationIdentity,
            PlayCoverPrepareManifest
        ) throws -> Void)?
    static var failedLaunchProcessStateOverrideForTesting:
        ((Int32) -> FailedLaunchProcessState)?
    static var failedLaunchSignalOverrideForTesting:
        ((Int32, Int32) -> Int32)?
    static var fastVerifyEventOverrideForTesting:
        ((FastVerifyEvent) throws -> Void)?

    public static func inspect(
        appPath: String
    ) throws -> PlayCoverAppInspection {
        try inspectPreparationSource(appPath: appPath).inspection
    }

    static func inspectPreparationSource(
        appPath: String
    ) throws -> PlayCoverPreparationSource {
        do {
            return PlayCoverPreparationSource(
                try PlayCoverUpstreamEngine.inspect(
                    appURL: URL(
                        fileURLWithPath: appPath,
                        isDirectory: true
                    )
                )
            )
        } catch let error as PlayCoverUpstreamError {
            throw PlayCoverMachO.map(error)
        }
    }

    static func makePreparationPlan(
        source: PlayCoverPreparationSource,
        runtimeFrameworkPath: String,
        generationKeyOverride: ((
            PlayCoverAppInspection,
            String,
            String
        ) throws -> String)? = nil
    ) throws -> PlayCoverPreparationPlan {
        let runtimePath = URL(
            fileURLWithPath: runtimeFrameworkPath,
            isDirectory: true
        ).standardizedFileURL.path
        let runtimeHash = try runtimeBuildHash(
            frameworkPath: runtimePath
        )
        let revision = prepareImplementationRevision
        let generationKey: String
        if let generationKeyOverride {
            generationKey = try generationKeyOverride(
                source.inspection,
                runtimeHash,
                revision
            )
        } else {
            generationKey = makeGenerationKey(
                sourceContentHash: source.inspection.sourceContentHash,
                runtimeBuildHash: runtimeHash,
                prepareRevision: revision
            )
        }
        return PlayCoverPreparationPlan(
            source: source,
            runtimeFrameworkPath: runtimePath,
            runtimeBuildHash: runtimeHash,
            prepareRevision: revision,
            generationKey: generationKey
        )
    }

    /// Prepares one managed staging App. `publishedAppPath` allows the caller
    /// to atomically rename the containing generation directory after this
    /// method returns while writing final paths into the sidecar manifest.
    public static func prepare(
        sourceAppPath: String,
        outputAppPath: String,
        runtimeFrameworkPath: String,
        paths: IOSUsePaths,
        generationKey expectedGenerationKey: String? = nil,
        publishedAppPath: String? = nil
    ) throws -> PlayCoverPrepareManifest {
        let plan = try makePreparationPlan(
            source: inspectPreparationSource(
                appPath: sourceAppPath
            ),
            runtimeFrameworkPath: runtimeFrameworkPath
        )
        if let expectedGenerationKey,
           expectedGenerationKey != plan.generationKey {
            throw PlayCoverBackendError.prepareFailed(
                "generation key changed between cache resolution and prepare"
            )
        }
        return try prepare(
            plan: plan,
            outputAppPath: outputAppPath,
            paths: paths,
            publishedAppPath: publishedAppPath
        )
    }

    static func prepare(
        plan: PlayCoverPreparationPlan,
        outputAppPath: String,
        paths: IOSUsePaths,
        publishedAppPath: String? = nil
    ) throws -> PlayCoverPrepareManifest {
        try prepareMeasured(
            plan: plan,
            outputAppPath: outputAppPath,
            paths: paths,
            publishedAppPath: publishedAppPath
        ).manifest
    }

    static func prepareMeasured(
        plan: PlayCoverPreparationPlan,
        outputAppPath: String,
        stagingIOAppPath: String? = nil,
        paths: IOSUsePaths,
        publishedAppPath: String? = nil
    ) throws -> PlayCoverPreparedArtifact {
        try validatePreparationPlan(plan)
        let source = plan.source.inspection
        let stagingIdentityURL = URL(
            fileURLWithPath: outputAppPath,
            isDirectory: true
        ).standardizedFileURL
        let stagingURL = URL(
            fileURLWithPath: stagingIOAppPath ?? outputAppPath,
            isDirectory: true
        ).standardizedFileURL
        let publishedURL = URL(
            fileURLWithPath: publishedAppPath ?? outputAppPath,
            isDirectory: true
        ).standardizedFileURL
        try requireManagedPath(
            stagingIdentityURL,
            paths: paths,
            operation: "staging"
        )
        if stagingIOAppPath != nil {
            try requireSameStagingDirectory(
                identityApp: stagingIdentityURL,
                ioApp: stagingURL
            )
        }
        try requireManagedPath(
            publishedURL,
            paths: paths,
            operation: "published App"
        )

        let runtimeURL = URL(
            fileURLWithPath: plan.runtimeFrameworkPath,
            isDirectory: true
        ).standardizedFileURL
        let canonicalManagedHome = URL(
            fileURLWithPath: paths.root,
            isDirectory: true
        ).resolvingSymlinksInPath()
        let sandboxSocket = canonicalManagedHome
            .appendingPathComponent(
                "playcover/run/s-runtime.sock"
            ).path
        let upstream: PlayCoverUpstreamPrepareResult
        do {
            upstream = try PlayCoverUpstreamEngine.prepare(
                PlayCoverUpstreamPrepareOptions(
                    sourceApp: URL(
                        fileURLWithPath: source.appPath,
                        isDirectory: true
                    ),
                    stagingApp: stagingURL,
                    managedStagingApp: stagingIdentityURL,
                    runtimeFramework: runtimeURL,
                    managedHome: canonicalManagedHome,
                    runtimeSocketPath: sandboxSocket,
                    runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
                    expectedRuntimeBuildHash: plan.runtimeBuildHash
                ),
                sourceInspection: plan.source.upstreamInspection
            )
        } catch let error as PlayCoverUpstreamError {
            throw PlayCoverMachO.map(error)
        }

        let prepared = PlayCoverAppInspection(
            upstream.prepared,
            appPath: publishedURL.path
        )
        let manifest = PlayCoverPrepareManifest(
            sourceAppPath: source.appPath,
            preparedAppPath: publishedURL.path,
            bundleIdentifier: prepared.bundleIdentifier,
            executableName: prepared.executableName,
            executablePath: prepared.executablePath,
            sourceContentHash: source.sourceContentHash,
            sourceHashAfterPreparation: upstream.sourceHashAfterPrepare,
            runtimeBuildHash: plan.runtimeBuildHash,
            prepareRevision: plan.prepareRevision,
            generationKey: plan.generationKey,
            runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
            runtimeFrameworkName: runtimeFrameworkName,
            convertedMachOs: upstream.convertedMachOs,
            signingOrder: upstream.signingOrder,
            sourceInventory: source.inventory,
            sourceMachOs: source.machOs,
            inventory: prepared.inventory,
            machOs: prepared.machOs,
            entitlementDiff: PlayCoverEntitlementDiff(
                upstream.entitlementDiff
            ),
            completedAt: ISO8601DateFormatter().string(from: Date())
        )
        try writeGenerationSidecars(
            manifest: manifest,
            actualAppURL: stagingURL
        )
        return PlayCoverPreparedArtifact(
            manifest: manifest,
            phaseTimings: upstream.phaseTimings,
            upstreamResult: upstream
        )
    }

    static func validatePreparationPlan(
        _ plan: PlayCoverPreparationPlan
    ) throws {
        let sourceHash = plan.source.inspection.sourceContentHash
        let upstreamSourceHash =
            plan.source.upstreamInspection.sourceContentHash
        let sourcePath = canonicalPath(
            plan.source.inspection.appPath
        )
        let upstreamSourcePath = canonicalPath(
            plan.source.upstreamInspection.appPath
        )
        guard plan.prepareRevision == prepareImplementationRevision,
              isSHA256(sourceHash),
              upstreamSourceHash == sourceHash,
              sourcePath == upstreamSourcePath,
              isSHA256(plan.runtimeBuildHash),
              isSHA256(plan.generationKey) else {
            throw PlayCoverBackendError.prepareFailed(
                "preparation plan identity is invalid"
            )
        }
    }

    /// Full verification. Managed cache reuse calls `fastVerifyGeneration`
    /// instead so reuse does not repeat conversion-time enumeration.
    public static func verify(
        appPath: String
    ) throws -> PlayCoverVerification {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let manifestEvidence = try readManifest(for: app)
        let manifest = manifestEvidence.value
        try fastVerifyGeneration(
            appPath: app.path,
            manifestEvidence: manifestEvidence
        )
        let upstream: PlayCoverUpstreamAppInspection
        do {
            upstream = try PlayCoverUpstreamEngine.verify(
                appURL: app,
                runtimeLoadPath: manifest.runtimeLoadPath
            )
        } catch let error as PlayCoverUpstreamError {
            throw PlayCoverMachO.map(error)
        }
        let prepared = PlayCoverAppInspection(upstream)
        guard let manifestMain = manifest.machOs.first(where: {
            $0.relativePath
                == prepared.mainExecutableRelativePath
        }) else {
            throw PlayCoverBackendError.verificationFailed(
                "manifest is missing its main executable"
            )
        }
        guard prepared.bundleIdentifier == manifest.bundleIdentifier,
              prepared.executableName == manifest.executableName,
              prepared.mainExecutable.fileSHA256
                == manifestMain.fileSHA256,
              prepared.inventory == manifest.inventory,
              prepared.machOs == manifest.machOs else {
            throw PlayCoverBackendError.verificationFailed(
                "prepared App inventory/Mach-O/entitlement seals no longer "
                    + "match its manifest"
            )
        }
        try verifyRecordedCodeObjects(
            app: app,
            manifest: manifest,
            fast: false
        )
        return PlayCoverVerification(
            manifest: manifest,
            mainExecutable: prepared.mainExecutable,
            signatureValid: true
        )
    }

    /// Reads the immutable generation identity and performs only the bounded
    /// reuse checks: marker/manifest identity, main/Runtime hashes and each
    /// recorded code-object signature exactly once. It deliberately does not
    /// enumerate or inspect the App tree.
    static func fastVerify(
        appPath: String
    ) throws -> PlayCoverPrepareManifest {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let manifestEvidence = try readManifest(for: app)
        let manifest = manifestEvidence.value
        try fastVerifyGeneration(
            appPath: app.path,
            manifestEvidence: manifestEvidence
        )
        return manifest
    }

    /// Reads and validates only the recorded generation identity. The caller
    /// must run `fastVerify` immediately before launch before trusting it.
    static func readPreparedManifest(
        appPath: String
    ) throws -> PlayCoverPrepareManifest {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let manifest = try readManifest(for: app).value
        try validateManifest(manifest, appURL: app)
        return manifest
    }

    static func fastVerifyGeneration(
        appPath: String,
        manifest suppliedManifest: PlayCoverPrepareManifest? = nil
    ) throws {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let manifestEvidence: DecodedMetadata<PlayCoverPrepareManifest>
        if let suppliedManifest {
            manifestEvidence = DecodedMetadata(
                value: suppliedManifest,
                rawData: try canonicalJSON(suppliedManifest)
            )
        } else {
            manifestEvidence = try readManifest(for: app)
        }
        try fastVerifyGeneration(
            appPath: app.path,
            manifestEvidence: manifestEvidence
        )
    }

    private static func fastVerifyGeneration(
        appPath: String,
        manifestEvidence: DecodedMetadata<PlayCoverPrepareManifest>
    ) throws {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let manifest = manifestEvidence.value
        try validateManifest(manifest, appURL: app)
        let marker = try readJSON(
            PlayCoverCompletedGeneration.self,
            from: completedURL(for: app),
            maximumBytes: completedMarkerMaximumBytes
        )
        guard marker.schemaVersion == 2,
              marker.generationKey == manifest.generationKey else {
            throw PlayCoverBackendError.cacheTampered(
                "completed marker identity does not match the manifest"
            )
        }
        guard marker.manifestSHA256
                == sha256(manifestEvidence.rawData) else {
            throw PlayCoverBackendError.cacheTampered(
                "manifest hash does not match immutable completed marker"
            )
        }
        guard marker.inventorySHA256
                == sha256(try canonicalJSON(manifest.inventory)),
              marker.machoSealSHA256
                == sha256(try canonicalJSON(manifest.machOs)) else {
            throw PlayCoverBackendError.cacheTampered(
                "completed inventory/Mach-O seal does not match manifest"
            )
        }
        let executable = URL(fileURLWithPath: manifest.executablePath)
        let runtime = app
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(
                runtimeFrameworkName,
                isDirectory: true
            )
            .appendingPathComponent(runtimeExecutableName)
        let executableRelativePath = try recordedRelativePath(
            executable,
            in: app
        )
        let runtimeRelativePath = try recordedRelativePath(runtime, in: app)
        let verification = try verifyRecordedCodeObjects(
            app: app,
            manifest: manifest,
            fast: true,
            requiredHashes: [
                executableRelativePath,
                runtimeRelativePath,
            ]
        )
        guard
            let actualExecutableHash =
                verification.fileSHA256[executableRelativePath],
            verification.executablePaths.contains(executableRelativePath),
            marker.executableSHA256 == actualExecutableHash
        else {
            throw PlayCoverBackendError.cacheTampered(
                "prepared executable hash changed"
            )
        }
        guard
            let actualRuntimeHash =
                verification.fileSHA256[runtimeRelativePath],
            verification.executablePaths.contains(runtimeRelativePath),
            marker.runtimeSHA256 == actualRuntimeHash
        else {
            throw PlayCoverBackendError.cacheTampered(
                "embedded Runtime hash changed"
            )
        }
    }

    public static func launch(
        appPath: String,
        sessionID: String,
        runtimeSocketPath: String,
        timeout: Double = 15
    ) throws -> PlayCoverLaunchIdentity {
        let manifest = try fastVerify(appPath: appPath)
        return try launchVerified(
            manifest: manifest,
            sessionID: sessionID,
            runtimeSocketPath: runtimeSocketPath,
            timeout: timeout
        )
    }

    static func launchVerified(
        manifest: PlayCoverPrepareManifest,
        sessionID: String,
        runtimeSocketPath: String,
        timeout: Double = 15
    ) throws -> PlayCoverLaunchIdentity {
        guard !sessionID.isEmpty,
              sessionID.utf8.count <= 128 else {
            throw PlayCoverBackendError.launchFailed(
                "sessionID is empty or too long"
            )
        }
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw PlayCoverBackendError.launchFailed(
                "timeout must be in (0, 60] seconds"
            )
        }
        let app = URL(
            fileURLWithPath: manifest.preparedAppPath,
            isDirectory: true
        ).standardizedFileURL
        try validateManifest(manifest, appURL: app)
        let expectedRuntimeSocketPath =
            try PlayCoverSessionService.expectedRuntimeSocketPath(
                sessionID: sessionID,
                manifest: manifest
            )
        guard canonicalPath(runtimeSocketPath)
                == canonicalPath(expectedRuntimeSocketPath) else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket path does not match the random "
                    + "session and managed generation"
            )
        }
        try validateFreshRuntimeSocketPath(runtimeSocketPath)

        var launched: LaunchedApplicationIdentity?
        var keyCoverUnlocked = false
        do {
            try PlayCoverHeadlessKeyCover.unlock(
                bundleIdentifier: manifest.bundleIdentifier,
                managedHome: URL(
                    fileURLWithPath: managedHomePath(for: manifest),
                    isDirectory: true
                )
            )
            keyCoverUnlocked = true
            let deadline =
                ProcessInfo.processInfo.systemUptime + timeout
            let identity = try launchPreparedApplication(
                manifest: manifest,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath,
                deadline: deadline
            )
            launched = identity
            guard identity.pid > 0,
                  identity.bundleIdentifier == manifest.bundleIdentifier,
                  canonicalPath(identity.bundleURLPath)
                    == canonicalPath(manifest.preparedAppPath),
                  canonicalPath(identity.executablePath)
                    == canonicalPath(manifest.executablePath) else {
                throw PlayCoverBackendError.launchFailed(
                    "NSWorkspace returned PID/bundle/App/executable identity "
                        + "that does not match the prepared generation"
                )
            }

            var lastError: Error?
            while ProcessInfo.processInfo.systemUptime < deadline {
                do {
                    let remaining = max(
                        0.02,
                        deadline - ProcessInfo.processInfo.systemUptime
                    )
                    let payload = try PlayCoverRuntimeClient(
                        socketPath: runtimeSocketPath,
                        sessionID: sessionID,
                        expectedPID: identity.pid,
                        expectedBundleIdentifier: manifest.bundleIdentifier,
                        expectedExecutablePath: manifest.executablePath,
                        timeoutSeconds: min(0.25, remaining)
                    ).hello()
                    let hello = try validateHello(
                        payload,
                        sessionID: sessionID,
                        manifest: manifest,
                        pid: identity.pid
                    )
                    return PlayCoverLaunchIdentity(
                        sessionID: sessionID,
                        pid: identity.pid,
                        bundleIdentifier: manifest.bundleIdentifier,
                        executablePath: manifest.executablePath,
                        appPath: manifest.preparedAppPath,
                        generationKey: manifest.generationKey,
                        runtimeSocketPath: runtimeSocketPath,
                        hello: hello
                    )
                } catch {
                    lastError = error
                    Thread.sleep(
                        forTimeInterval: min(
                            0.05,
                            max(
                                0,
                                deadline -
                                    ProcessInfo.processInfo.systemUptime
                            )
                        )
                    )
                }
            }
            throw PlayCoverBackendError.launchTimedOut(
                "no verified Runtime hello within \(timeout) seconds"
                    + (lastError.map { "; last error: \($0)" } ?? "")
            )
        } catch {
            if let launched {
                do {
                    try terminateFailedLaunch(
                        identity: launched,
                        manifest: manifest
                    )
                } catch let rollbackError {
                    throw PlayCoverUnterminatedLaunchError(
                        sessionID: sessionID,
                        pid: launched.pid,
                        bundleIdentifier:
                            manifest.bundleIdentifier,
                        executablePath:
                            manifest.executablePath,
                        appPath: manifest.preparedAppPath,
                        generationKey: manifest.generationKey,
                        runtimeSocketPath: runtimeSocketPath,
                        originalError: String(describing: error),
                        rollbackError:
                            String(describing: rollbackError)
                    )
                }
            }
            if keyCoverUnlocked {
                try PlayCoverHeadlessKeyCover.lock(
                    bundleIdentifier: manifest.bundleIdentifier,
                    managedHome: URL(
                        fileURLWithPath: managedHomePath(for: manifest),
                        isDirectory: true
                    )
                )
            }
            throw error
        }
    }

    @discardableResult
    public static func terminate(
        identity: PlayCoverLaunchIdentity
    ) throws -> Int32 {
        let manifest = try fastVerify(appPath: identity.appPath)
        guard identity.pid > 0,
              identity.bundleIdentifier == manifest.bundleIdentifier,
              identity.generationKey == manifest.generationKey,
              canonicalPath(identity.appPath)
                == canonicalPath(manifest.preparedAppPath),
              canonicalPath(identity.executablePath)
                == canonicalPath(manifest.executablePath) else {
            throw PlayCoverBackendError.terminateFailed(
                "session identity does not match the prepared generation"
            )
        }
        guard let actualExecutable = PlayCoverRuntimeClient.executablePath(
            for: identity.pid
        ) else {
            return identity.pid
        }
        guard canonicalPath(actualExecutable)
                == canonicalPath(identity.executablePath) else {
            throw PlayCoverBackendError.terminateFailed(
                "refusing to signal PID whose executable does not match"
            )
        }
        #if canImport(Darwin)
        guard Darwin.kill(identity.pid, SIGTERM) == 0 || errno == ESRCH else {
            throw PlayCoverBackendError.terminateFailed(
                "SIGTERM failed for pid \(identity.pid): errno \(errno)"
            )
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, Darwin.kill(identity.pid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard Darwin.kill(identity.pid, 0) != 0, errno == ESRCH else {
            throw PlayCoverBackendError.terminateFailed(
                "pid \(identity.pid) did not exit after SIGTERM"
            )
        }
        #endif
        try PlayCoverHeadlessKeyCover.lock(
            bundleIdentifier: manifest.bundleIdentifier,
            managedHome: URL(
                fileURLWithPath: managedHomePath(for: manifest),
                isDirectory: true
            )
        )
        return identity.pid
    }

    /// Only failures that mean no authenticated Runtime response was
    /// available may use the host-owned termination fallback. Identity and
    /// protocol failures are deliberately excluded: they are evidence that a
    /// responder exists but does not match the active session contract.
    static func permitsUnresponsiveRuntimeTermination(
        after error: Error
    ) -> Bool {
        guard let runtimeError =
                error as? PlayCoverRuntimeClientError else {
            return false
        }
        switch runtimeError {
        case .socketCreateFailed,
             .socketOptionFailed,
             .connectFailed,
             .writeFailed,
             .readFailed,
             .timeout,
             .unexpectedEOF:
            return true
        case .invalidSocketPath,
             .invalidTimeout,
             .peerCredentialFailed,
             .peerUIDMismatch,
             .peerPIDCredentialFailed,
             .peerPIDMismatch,
             .processExecutableLookupFailed,
             .processExecutableMismatch,
             .requestEncodingFailed,
             .requestFrameTooLarge,
             .emptyResponseFrame,
             .responseFrameTooLarge,
             .responseIsNotUTF8,
             .responseDecodingFailed,
             .unsupportedSchemaVersion,
             .requestIDMismatch,
             .sessionIDMismatch,
             .responseIdentityMismatch,
             .malformedResponse,
             .remoteError:
            return false
        }
    }

    /// Returns a stable birth token for one Darwin PID. Combining this with
    /// proc_pidpath prevents a same-executable PID reuse from being mistaken
    /// for the process recorded in an older session lock.
    static func processStartTimeMicroseconds(
        for pid: Int32
    ) -> UInt64? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(
            MemoryLayout<proc_bsdinfo>.size
        )
        let actualSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard actualSize == expectedSize else { return nil }
        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        guard microseconds < 1_000_000,
              seconds <=
                (UInt64.max - microseconds) / 1_000_000 else {
            return nil
        }
        return seconds * 1_000_000 + microseconds
        #else
        return nil
        #endif
    }

    static func makeGenerationKey(
        sourceContentHash: String,
        runtimeBuildHash: String,
        prepareRevision: String
    ) -> String {
        var hasher = SHA256()
        update(&hasher, sourceContentHash)
        update(&hasher, runtimeBuildHash)
        update(&hasher, prepareRevision)
        return hex(hasher.finalize())
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    static func runtimeBuildHash(
        frameworkPath: String
    ) throws -> String {
        let root = URL(
            fileURLWithPath: frameworkPath,
            isDirectory: true
        ).standardizedFileURL
        var directory: ObjCBool = false
        guard root.lastPathComponent == runtimeFrameworkName,
              FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &directory
              ),
              directory.boolValue else {
            throw PlayCoverBackendError.missingRuntime(root.path)
        }
        do {
            return try PlayCoverUpstreamEngine.runtimeBuildHash(
                frameworkURL: root
            )
        } catch PlayCoverUpstreamError.invalidApp(let message) {
            throw PlayCoverBackendError.missingRuntime(message)
        }
    }

    static func sanitizedLaunchEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment,
        sessionID: String? = nil,
        runtimeSocketPath: String? = nil,
        managedHomePath: String? = nil
    ) -> [String: String] {
        let allowed = [
            "HOME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LOGNAME",
            "TMPDIR",
            "USER",
            "__CF_USER_TEXT_ENCODING",
        ]
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in allowed {
            if let value = source[key], !value.isEmpty {
                result[key] = value
            }
        }
        if let managedHomePath {
            result["HOME"] = managedHomePath
        }
        if let sessionID {
            result["IOS_USE_PLAY_SESSION_ID"] = sessionID
        }
        if let runtimeSocketPath {
            result["IOS_USE_PLAY_RUNTIME_SOCKET"] = runtimeSocketPath
        }
        return result
    }

    static func launchConfigurationEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment,
        sessionID: String,
        runtimeSocketPath: String,
        managedHomePath: String
    ) -> [String: String] {
        // NSWorkspace overlays OpenConfiguration.environment on the
        // caller's inherited environment. Explicitly clear every inherited
        // key that is outside the launch allowlist so shell credentials
        // cannot reach the prepared App.
        var result = source.mapValues { _ in "" }
        result.merge(
            sanitizedLaunchEnvironment(
                source: source,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath,
                managedHomePath: managedHomePath
            )
        ) { _, allowed in allowed }
        return result
    }

    private static func validateHello(
        _ payload: PlayCoverRuntimeHelloPayload,
        sessionID: String,
        manifest: PlayCoverPrepareManifest,
        pid: Int32
    ) throws -> PlayCoverHello {
        let geometry = payload.geometry
        let expectedLogicalWidth = Double(IOSUsePlayDeviceLogicalWidth)
        let expectedLogicalHeight = Double(IOSUsePlayDeviceLogicalHeight)
        let expectedScale = Double(IOSUsePlayDeviceScale)
        let expectedNativeWidth = Double(IOSUsePlayDeviceNativeWidth)
        let expectedNativeHeight = Double(IOSUsePlayDeviceNativeHeight)
        guard payload.pid == pid,
              payload.bundleIdentifier == manifest.bundleIdentifier,
              canonicalPath(payload.executablePath)
                == canonicalPath(manifest.executablePath),
              payload.stage == "ready",
              geometry.logical.width == expectedLogicalWidth,
              geometry.logical.height == expectedLogicalHeight,
              geometry.native.width == expectedNativeWidth,
              geometry.native.height == expectedNativeHeight,
              geometry.scale == expectedScale,
              geometry.window.width == expectedLogicalWidth,
              geometry.window.height == expectedLogicalHeight else {
            var hostSummary = "host=missing"
            if let host = geometry.host {
                hostSummary = [
                    "status=\(host.status)",
                    "frame=\(host.frame.width)x\(host.frame.height)",
                    "content=\(host.contentBounds.width)x"
                        + "\(host.contentBounds.height)",
                    "canvas=\(host.canvasRect.width)x"
                        + "\(host.canvasRect.height)",
                    "canvasBounds=\(host.canvasBounds.width)x"
                        + "\(host.canvasBounds.height)",
                    "displayScale=\(host.displayScale)",
                    "hostPolicy=\(host.hostPolicy)",
                    "opaque=\(host.opaque)",
                    "publicTitleBar=\(host.publicTitleBar)",
                    "titleVisible=\(host.titleVisible)",
                    "resizable=\(host.resizable)",
                    "title=\(host.title)",
                    "expectedTitle=\(host.titleExpected)",
                    "captureReady=\(host.capture.ready)",
                    "captureError=\(host.capture.error ?? "none")",
                ].joined(separator: ",")
            }
            var appKitFailure = "unavailable"
            var sceneGeometryFailure = "unavailable"
            if case .object(let appKit)? =
                payload.observed["appKit"] {
                if case .string(let failure)? =
                    appKit["failure"] {
                    appKitFailure = failure
                }
                if case .object(let sceneGeometry)? =
                    appKit["sceneGeometry"],
                   case .string(let failure)? =
                    sceneGeometry["failure"] {
                    sceneGeometryFailure = failure
                }
            }
            let observedSummary = [
                "stage=\(payload.stage)",
                "pid=\(payload.pid)/\(pid)",
                "bundle=\(payload.bundleIdentifier)/"
                    + "\(manifest.bundleIdentifier)",
                "logical=\(geometry.logical.width)x"
                    + "\(geometry.logical.height)",
                "native=\(geometry.native.width)x"
                    + "\(geometry.native.height)",
                "scale=\(geometry.scale)",
                "window=\(geometry.window.width)x"
                    + "\(geometry.window.height)",
                hostSummary,
                "appKitFailure=\(appKitFailure)",
                "sceneGeometryFailure=\(sceneGeometryFailure)",
            ].joined(separator: "; ")
            throw PlayCoverBackendError.launchFailed(
                "Runtime hello identity/geometry is not the fixed "
                    + "\(IOSUsePlayDeviceLogicalWidth)x"
                    + "\(IOSUsePlayDeviceLogicalHeight)@"
                    + "\(IOSUsePlayDeviceScale)x contract: "
                    + observedSummary
            )
        }
        return PlayCoverHello(
            schemaVersion: PlayCoverRuntimeClient.schemaVersion,
            sessionID: sessionID,
            pid: payload.pid,
            bundleIdentifier: payload.bundleIdentifier,
            executablePath: payload.executablePath,
            logicalWidth: geometry.logical.width,
            logicalHeight: geometry.logical.height,
            nativeWidth: geometry.native.width,
            nativeHeight: geometry.native.height,
            scale: geometry.scale,
            windowWidth: geometry.window.width,
            windowHeight: geometry.window.height,
            stage: payload.stage,
            capabilities: payload.capabilities
        )
    }

    private static func writeGenerationSidecars(
        manifest: PlayCoverPrepareManifest,
        actualAppURL: URL
    ) throws {
        let generation = actualAppURL.deletingLastPathComponent()
        let manifestData = try canonicalJSON(manifest)
        let runtime = actualAppURL
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(
                runtimeFrameworkName,
                isDirectory: true
            )
            .appendingPathComponent(runtimeExecutableName)
        let marker = PlayCoverCompletedGeneration(
            schemaVersion: 2,
            generationKey: manifest.generationKey,
            manifestSHA256: sha256(manifestData),
            inventorySHA256: sha256(
                try canonicalJSON(manifest.inventory)
            ),
            machoSealSHA256: sha256(
                try canonicalJSON(manifest.machOs)
            ),
            executableSHA256: try fileSHA256(
                URL(fileURLWithPath: actualExecutablePath(
                    manifest: manifest,
                    actualAppURL: actualAppURL
                ))
            ),
            runtimeSHA256: try fileSHA256(runtime)
        )
        try writeAtomically(
            manifestData,
            to: generation.appendingPathComponent(manifestFilename)
        )
        try writeAtomically(
            canonicalJSON(marker),
            to: generation.appendingPathComponent(completedFilename)
        )
    }

    private static func actualExecutablePath(
        manifest: PlayCoverPrepareManifest,
        actualAppURL: URL
    ) -> String {
        actualAppURL.appendingPathComponent(manifest.executableName).path
    }

    private static func validateManifest(
        _ manifest: PlayCoverPrepareManifest,
        appURL: URL
    ) throws {
        guard manifest.schemaVersion == 3,
              manifest.backend == "playcover-headless",
              manifest.prepareRevision == prepareImplementationRevision,
              manifest.sourceContentHash
                == manifest.sourceHashAfterPreparation,
              manifest.runtimeLoadPath == PlayCoverMachO.runtimeLoadPath,
              manifest.runtimeFrameworkName == runtimeFrameworkName,
              canonicalPath(manifest.preparedAppPath)
                == canonicalPath(appURL.path),
              canonicalPath(manifest.executablePath)
                == canonicalPath(
                    appURL.appendingPathComponent(
                        manifest.executableName
                    ).path
                ),
              manifest.generationKey == makeGenerationKey(
                sourceContentHash: manifest.sourceContentHash,
                runtimeBuildHash: manifest.runtimeBuildHash,
                prepareRevision: manifest.prepareRevision
              ),
              !manifest.sourceInventory.isEmpty,
              !manifest.sourceMachOs.isEmpty,
              Set(manifest.sourceInventory.map(\.relativePath)).count
                == manifest.sourceInventory.count,
              Set(manifest.sourceMachOs.map(\.relativePath)).count
                == manifest.sourceMachOs.count else {
            throw PlayCoverBackendError.verificationFailed(
                "manifest schema, identity, or generation is invalid"
            )
        }
    }

    private struct RecordedCodeVerification {
        let fileSHA256: [String: String]
        let executablePaths: Set<String>
    }

    @discardableResult
    private static func verifyRecordedCodeObjects(
        app: URL,
        manifest: PlayCoverPrepareManifest,
        fast: Bool,
        requiredHashes: Set<String> = []
    ) throws -> RecordedCodeVerification {
        var codePaths = Set(manifest.inventory.compactMap {
            $0.codeObjectKind == nil ? nil : $0.relativePath
        })
        codePaths.insert(".")
        let nestedContainers = codePaths.filter {
            $0 != "."
                && ($0.hasSuffix(".appex")
                    || $0.hasSuffix(".framework")
                    || $0.hasSuffix(".bundle"))
        }
        let relevantEntries = manifest.inventory.filter { entry in
            if !fast { return true }
            return entry.relativePath == "Info.plist"
                || requiredHashes.contains(entry.relativePath)
                || entry.codeObjectKind != nil
                || nestedContainers.contains(entry.relativePath)
        }
        let appDescriptor = Darwin.open(
            app.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard appDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open the prepared App root: errno \(errno)"
            )
        }
        defer { Darwin.close(appDescriptor) }
        var appStatus = stat()
        guard fstat(appDescriptor, &appStatus) == 0,
              appStatus.st_mode & S_IFMT == S_IFDIR else {
            throw PlayCoverBackendError.cacheTampered(
                "prepared App root is not a stable directory"
            )
        }
        var verifiedStatuses: [String: stat] = [".": appStatus]
        var hashes: [String: String] = [:]
        var executablePaths = Set<String>()
        for entry in relevantEntries {
            let result = try verifyRecordedEntry(
                entry,
                appDescriptor: appDescriptor,
                hashContents: !fast
                    || requiredHashes.contains(entry.relativePath)
            )
            verifiedStatuses[entry.relativePath] = result.status
            if let hash = result.sha256 {
                hashes[entry.relativePath] = hash
            }
            if result.status.st_mode & S_IFMT == S_IFREG,
               result.status.st_mode & 0o111 != 0 {
                executablePaths.insert(entry.relativePath)
            }
        }
        guard requiredHashes.isSubset(of: Set(hashes.keys)) else {
            throw PlayCoverBackendError.cacheTampered(
                "manifest is missing a required executable hash entry"
            )
        }
        let orderedCodePaths =
            codePaths.filter { $0 != "." }.sorted() + ["."]
        for relative in orderedCodePaths {
            let url = relative == "."
                ? app
                : try recordedURL(app: app, relativePath: relative)
            try emitFastVerifyEvent(.beforeCodeSignature(relative))
            let result = try Shell.runWithResult(
                "/usr/bin/codesign",
                arguments: ["--verify", "--strict", url.path]
            )
            guard result.exitCode == 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "recorded code object signature is invalid "
                        + "(\(relative)): \(result.stderr)"
                )
            }
            try emitFastVerifyEvent(.afterCodeSignature(relative))
            guard
                let expected = verifiedStatuses[relative],
                try recordedPathStillHasIdentity(
                    relative,
                    appDescriptor: appDescriptor,
                    expected: expected
                )
            else {
                throw PlayCoverBackendError.cacheTampered(
                    "recorded code object changed during signature "
                        + "verification: \(relative)"
                )
            }
        }
        return RecordedCodeVerification(
            fileSHA256: hashes,
            executablePaths: executablePaths
        )
    }

    private struct RecordedEntryVerification {
        let status: stat
        let sha256: String?
    }

    private static func verifyRecordedEntry(
        _ entry: PlayCoverInventoryEntry,
        appDescriptor: Int32,
        hashContents: Bool
    ) throws -> RecordedEntryVerification {
        try withRecordedParentDescriptor(
            appDescriptor: appDescriptor,
            relativePath: entry.relativePath
        ) { parentDescriptor, name in
            var pathStatus = stat()
            guard fstatat(
                parentDescriptor,
                name,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "recorded path is missing: \(entry.relativePath)"
                )
            }
            let actualKind: String
            switch pathStatus.st_mode & S_IFMT {
            case S_IFDIR: actualKind = "directory"
            case S_IFREG: actualKind = "regularFile"
            case S_IFLNK: actualKind = "symbolicLink"
            default: actualKind = "other"
            }
            guard actualKind == entry.kind,
                  pathStatus.st_uid == geteuid(),
                  UInt16(pathStatus.st_mode & 0o7777)
                    == entry.posixPermissions else {
                throw PlayCoverBackendError.cacheTampered(
                    "recorded path kind/owner/permissions changed: "
                        + entry.relativePath
                )
            }
            if entry.kind == "regularFile" {
                let descriptor = Darwin.openat(
                    parentDescriptor,
                    name,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw PlayCoverBackendError.cacheTampered(
                        "cannot open recorded file without following links: "
                            + "\(entry.relativePath), errno \(errno)"
                    )
                }
                defer { Darwin.close(descriptor) }
                var openedStatus = stat()
                guard fstat(descriptor, &openedStatus) == 0,
                      sameRecordedIdentity(pathStatus, openedStatus),
                      openedStatus.st_mode & S_IFMT == S_IFREG,
                      openedStatus.st_size >= 0,
                      UInt64(openedStatus.st_size) == entry.size else {
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded file changed before it could be read: "
                            + entry.relativePath
                    )
                }
                let hash: String?
                if hashContents {
                    try emitFastVerifyEvent(
                        .beforeFileHash(entry.relativePath)
                    )
                    hash = try fileSHA256(descriptor: descriptor)
                    try emitFastVerifyEvent(
                        .afterFileHash(entry.relativePath)
                    )
                } else {
                    hash = nil
                }
                var finalStatus = stat()
                guard fstat(descriptor, &finalStatus) == 0,
                      sameRecordedIdentity(openedStatus, finalStatus),
                      finalStatus.st_size == openedStatus.st_size else {
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded file changed while it was read: "
                            + entry.relativePath
                    )
                }
                if hashContents, hash != entry.sha256 {
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded file changed: \(entry.relativePath)"
                    )
                }
                return RecordedEntryVerification(
                    status: finalStatus,
                    sha256: hash
                )
            }
            if entry.kind == "symbolicLink" {
                var buffer = [CChar](
                    repeating: 0,
                    count: Int(PATH_MAX) + 1
                )
                let count = Darwin.readlinkat(
                    parentDescriptor,
                    name,
                    &buffer,
                    buffer.count - 1
                )
                guard count >= 0, count < buffer.count - 1 else {
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded symbolic link cannot be read safely: "
                            + entry.relativePath
                    )
                }
                buffer[Int(count)] = 0
                guard String(cString: buffer)
                        == entry.symbolicLinkDestination else {
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded symbolic link changed: "
                            + entry.relativePath
                    )
                }
            }
            return RecordedEntryVerification(
                status: pathStatus,
                sha256: nil
            )
        }
    }

    private static func withRecordedParentDescriptor<T>(
        appDescriptor: Int32,
        relativePath: String,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        let parts = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !parts.isEmpty,
              parts.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw PlayCoverBackendError.cacheTampered(
                "manifest contains unsafe relative path: \(relativePath)"
            )
        }
        var ownedDescriptors: [Int32] = []
        defer {
            for descriptor in ownedDescriptors.reversed() {
                Darwin.close(descriptor)
            }
        }
        var parentDescriptor = appDescriptor
        if parts.count > 1 {
            for part in parts.dropLast() {
                let descriptor = Darwin.openat(
                    parentDescriptor,
                    String(part),
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded parent is not an anchored directory "
                            + "(\(relativePath)): errno \(errno)"
                    )
                }
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                      status.st_mode & S_IFMT == S_IFDIR,
                      status.st_uid == geteuid() else {
                    Darwin.close(descriptor)
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded parent is not an owned directory: "
                            + relativePath
                    )
                }
                ownedDescriptors.append(descriptor)
                parentDescriptor = descriptor
            }
        }
        return try body(parentDescriptor, String(parts[parts.count - 1]))
    }

    private static func recordedPathStillHasIdentity(
        _ relativePath: String,
        appDescriptor: Int32,
        expected: stat
    ) throws -> Bool {
        if relativePath == "." {
            var actual = stat()
            return fstat(appDescriptor, &actual) == 0
                && sameRecordedIdentity(expected, actual)
        }
        return try withRecordedParentDescriptor(
            appDescriptor: appDescriptor,
            relativePath: relativePath
        ) { parentDescriptor, name in
            var actual = stat()
            return fstatat(
                parentDescriptor,
                name,
                &actual,
                AT_SYMLINK_NOFOLLOW
            ) == 0 && sameRecordedIdentity(expected, actual)
        }
    }

    private static func sameRecordedIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_size == rhs.st_size
    }

    private static func recordedRelativePath(
        _ url: URL,
        in app: URL
    ) throws -> String {
        let root = app.resolvingSymlinksInPath().standardizedFileURL.path
        let value = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard value.hasPrefix(root + "/") else {
            throw PlayCoverBackendError.cacheTampered(
                "recorded path escaped the prepared App: \(url.path)"
            )
        }
        let relative = String(value.dropFirst(root.count + 1))
        _ = try recordedURL(app: app, relativePath: relative)
        return relative
    }

    private static func recordedURL(
        app: URL,
        relativePath: String
    ) throws -> URL {
        guard relativePath != ".",
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw PlayCoverBackendError.cacheTampered(
                "manifest contains unsafe relative path: \(relativePath)"
            )
        }
        let value = app.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard value.path.hasPrefix(app.standardizedFileURL.path + "/") else {
            throw PlayCoverBackendError.cacheTampered(
                "manifest path escapes prepared App: \(relativePath)"
            )
        }
        return value
    }

    private struct DecodedMetadata<Value> {
        let value: Value
        let rawData: Data
    }

    private static func readManifest(
        for appURL: URL
    ) throws -> DecodedMetadata<PlayCoverPrepareManifest> {
        try readJSONMetadata(
            PlayCoverPrepareManifest.self,
            from: manifestURL(for: appURL),
            maximumBytes: generationManifestMaximumBytes
        )
    }

    private static func manifestURL(for appURL: URL) -> URL {
        appURL.deletingLastPathComponent()
            .appendingPathComponent(manifestFilename)
    }

    private static func completedURL(for appURL: URL) -> URL {
        appURL.deletingLastPathComponent()
            .appendingPathComponent(completedFilename)
    }

    static func requireManagedPath(
        _ url: URL,
        paths: IOSUsePaths,
        operation: String
    ) throws {
        let managedLexical = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).standardizedFileURL.path
        let candidateLexical = url.standardizedFileURL.path
        // Foundation normalizes an existing `/private/tmp/.../prepared`
        // directory to `/tmp/.../prepared`, while a not-yet-created generation
        // below it may retain the `/private/tmp` spelling. Canonicalize the
        // existing prefix of both paths before comparing containment.
        let managed = canonicalizingExistingPrefix(managedLexical)
        let candidate = canonicalizingExistingPrefix(candidateLexical)
        guard candidate.hasPrefix(managed + "/") else {
            throw PlayCoverBackendError.prepareFailed(
                "\(operation) path must be below IOS_USE_HOME managed "
                    + "prepared directory: \(managed)"
            )
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in URL(fileURLWithPath: candidateLexical)
            .pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var status = stat()
            if lstat(current.path, &status) != 0 {
                if errno == ENOENT { break }
                throw PlayCoverBackendError.prepareFailed(
                    "\(operation) containment check failed: errno \(errno)"
                )
            }
            guard status.st_mode & S_IFMT != S_IFLNK
                    || status.st_uid != geteuid() else {
                throw PlayCoverBackendError.prepareFailed(
                    "\(operation) path contains symbolic link: "
                        + current.path
                )
            }
        }
    }

    private static func requireSameStagingDirectory(
        identityApp: URL,
        ioApp: URL
    ) throws {
        guard identityApp.lastPathComponent == ioApp.lastPathComponent,
              identityApp.pathExtension == "app" else {
            throw PlayCoverBackendError.prepareFailed(
                "staging identity and I/O App names disagree"
            )
        }
        var identity = stat()
        var io = stat()
        let identityParent = identityApp.deletingLastPathComponent().path
        let ioParent = ioApp.deletingLastPathComponent().path
        guard lstat(identityParent, &identity) == 0,
              lstat(ioParent, &io) == 0,
              identity.st_mode & S_IFMT == S_IFDIR,
              io.st_mode & S_IFMT == S_IFDIR,
              identity.st_dev == io.st_dev,
              identity.st_ino == io.st_ino else {
            throw PlayCoverBackendError.prepareFailed(
                "staging lexical path no longer names its anchored vnode"
            )
        }
    }

    private static func readJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        maximumBytes: Int
    ) throws -> T {
        try readJSONMetadata(
            type,
            from: url,
            maximumBytes: maximumBytes
        ).value
    }

    private static func readJSONMetadata<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        maximumBytes: Int
    ) throws -> DecodedMetadata<T> {
        try emitFastVerifyEvent(
            .beforeMetadataOpen(url.lastPathComponent)
        )
        let parent = url.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open generation metadata directory without "
                    + "following links: \(parent.path), errno \(errno)"
            )
        }
        defer { Darwin.close(parentDescriptor) }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              parentStatus.st_mode & 0o077 == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "generation metadata directory is not owner-only"
            )
        }
        do {
            let data = try PlayCoverManagedAppService.readOwnedRegularFile(
                parentDescriptor: parentDescriptor,
                name: url.lastPathComponent,
                maximumBytes: maximumBytes,
                afterOpen: {
                    try emitFastVerifyEvent(
                        .afterMetadataOpen(url.lastPathComponent)
                    )
                }
            )
            guard !data.isEmpty else {
                throw PlayCoverBackendError.cacheTampered(
                    "\(url.lastPathComponent) is empty"
                )
            }
            try emitFastVerifyEvent(
                .afterMetadataRead(url.lastPathComponent)
            )
            return DecodedMetadata(
                value: try JSONDecoder().decode(
                    type,
                    from: data
                ),
                rawData: data
            )
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "cannot decode \(url.path): \(error)"
            )
        }
    }

    private static func emitFastVerifyEvent(
        _ event: FastVerifyEvent
    ) throws {
        try fastVerifyEventOverrideForTesting?(event)
    }

    private static func writeAtomically(
        _ data: Data,
        to url: URL
    ) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
            )
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: temporary.path
            )
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PlayCoverBackendError.prepareFailed(
                "cannot atomically publish \(url.path): \(error)"
            )
        }
    }

    enum LaunchIdentitySource: Equatable {
        case workspaceCallback
        case authenticatedRuntime
        case observedCandidate
    }

    struct LaunchedApplicationIdentity: Equatable {
        let pid: Int32
        let bundleIdentifier: String
        let bundleURLPath: String
        let executablePath: String
        let processStartTimeMicroseconds: UInt64?
        let source: LaunchIdentitySource
    }

    enum FailedLaunchProcessState: Equatable {
        case running(
            executablePath: String,
            processStartTimeMicroseconds: UInt64?
        )
        case missing
        case unverifiable(errno: Int32)
    }

    private final class LaunchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<LaunchedApplicationIdentity, Error>?

        func set(_ newValue: Result<LaunchedApplicationIdentity, Error>) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> Result<LaunchedApplicationIdentity, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func acceptsOwnedLaunchIdentity(
        pid: Int32,
        bundleIdentifier: String,
        bundleURLPath: String,
        executablePath: String,
        existingPIDs: Set<Int32>,
        manifest: PlayCoverPrepareManifest
    ) -> Bool {
        pid > 0
            && !existingPIDs.contains(pid)
            && bundleIdentifier == manifest.bundleIdentifier
            && canonicalPath(bundleURLPath)
                == canonicalPath(manifest.preparedAppPath)
            && canonicalPath(executablePath)
                == canonicalPath(manifest.executablePath)
    }

    static func mayClaimLaunchIdentity(
        _ candidate: LaunchedApplicationIdentity,
        callbackIdentity: LaunchedApplicationIdentity?,
        runtimeAuthenticated: Bool
    ) -> Bool {
        if runtimeAuthenticated {
            return true
        }
        guard candidate.source == .workspaceCallback,
              let callbackIdentity,
              callbackIdentity.source == .workspaceCallback else {
            return false
        }
        return candidate == callbackIdentity
    }

    private static func launchPreparedApplication(
        manifest: PlayCoverPrepareManifest,
        sessionID: String,
        runtimeSocketPath: String,
        deadline: TimeInterval
    ) throws -> LaunchedApplicationIdentity {
        #if canImport(AppKit)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        // Give this invocation its own callback process even if Finder or
        // another NSWorkspace client launches the same bundle concurrently.
        // Poll-only candidates remain unowned until they authenticate the
        // random Runtime session below.
        configuration.createsNewApplicationInstance = true
        configuration.environment = launchConfigurationEnvironment(
            sessionID: sessionID,
            runtimeSocketPath: runtimeSocketPath,
            managedHomePath: managedHomePath(for: manifest)
        )
        let existingApplications =
            NSRunningApplication.runningApplications(
                withBundleIdentifier: manifest.bundleIdentifier
            )
        let existingPIDs = Set(
            existingApplications.map(\.processIdentifier)
        )
        guard !existingApplications.contains(where: { application in
            guard let bundlePath = application.bundleURL?
                    .standardizedFileURL.path,
                  let executablePath = application.executableURL?
                    .standardizedFileURL.path else {
                return false
            }
            return canonicalPath(bundlePath)
                    == canonicalPath(manifest.preparedAppPath)
                && canonicalPath(executablePath)
                    == canonicalPath(manifest.executablePath)
        }) else {
            throw PlayCoverBackendError.launchFailed(
                "the exact prepared App is already running outside "
                    + "this start invocation"
            )
        }
        let box = LaunchBox()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(
            at: URL(
                fileURLWithPath: manifest.preparedAppPath,
                isDirectory: true
            ),
            configuration: configuration
        ) { application, error in
            if let application,
               let bundleIdentifier = application.bundleIdentifier,
               let bundlePath = application.bundleURL?
                    .standardizedFileURL.path,
               let executablePath = application.executableURL?
                    .standardizedFileURL.path,
               acceptsOwnedLaunchIdentity(
                    pid: application.processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    bundleURLPath: bundlePath,
                    executablePath: executablePath,
                    existingPIDs: existingPIDs,
                    manifest: manifest
               ) {
                box.set(
                    .success(
                        LaunchedApplicationIdentity(
                            pid: application.processIdentifier,
                            bundleIdentifier: bundleIdentifier,
                            bundleURLPath: bundlePath,
                            executablePath: executablePath,
                            processStartTimeMicroseconds:
                                processStartTimeMicroseconds(
                                    for: application.processIdentifier
                                ),
                            source: .workspaceCallback
                        )
                    )
                )
            } else {
                box.set(
                    .failure(
                        error ?? PlayCoverBackendError.launchFailed(
                            "NSWorkspace returned a pre-existing, "
                                + "incomplete, or mismatched App identity"
                        )
                    )
                )
            }
            semaphore.signal()
        }
        // The caller supplies the one monotonic `start --timeout` deadline
        // shared by launch discovery and the subsequent ready Runtime hello.
        // Large Apps may exceed LaunchServices' historical ten-second window,
        // but discovery must not restart the public timeout.
        var callbackError: Error?
        func authenticatesCurrentLaunch(
            _ identity: LaunchedApplicationIdentity
        ) -> Bool {
            do {
                let runtime = PlayCoverRuntimeClient(
                    socketPath: runtimeSocketPath,
                    sessionID: sessionID,
                    expectedPID: identity.pid,
                    expectedBundleIdentifier:
                        manifest.bundleIdentifier,
                    expectedExecutablePath:
                        manifest.executablePath,
                    timeoutSeconds: min(
                        0.05,
                        max(
                            0.01,
                            deadline -
                                ProcessInfo.processInfo.systemUptime
                        )
                    )
                )
                let ping = try runtime.ping()
                if !ping.hasCompleteIdentity {
                    _ = try runtime.hello()
                }
                return true
            } catch {
                return false
            }
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            // A large UIKit App can create its RunningBoard process and bind
            // the injected Runtime socket before NSWorkspace invokes its
            // completion handler. Resolve that newly-created, exact managed
            // App identity instead of treating a slow callback as a failed
            // launch.
            let candidates = NSRunningApplication.runningApplications(
                withBundleIdentifier: manifest.bundleIdentifier
            ).compactMap { application
                -> LaunchedApplicationIdentity? in
                guard let bundleIdentifier =
                        application.bundleIdentifier,
                      let bundlePath = application.bundleURL?
                        .standardizedFileURL.path,
                      let executablePath = application.executableURL?
                        .standardizedFileURL.path,
                      acceptsOwnedLaunchIdentity(
                        pid: application.processIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        bundleURLPath: bundlePath,
                        executablePath: executablePath,
                        existingPIDs: existingPIDs,
                        manifest: manifest
                      ) else {
                    return nil
                }
                return LaunchedApplicationIdentity(
                    pid: application.processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    bundleURLPath: bundlePath,
                    executablePath: executablePath,
                    processStartTimeMicroseconds:
                        processStartTimeMicroseconds(
                            for: application.processIdentifier
                        ),
                    source: .observedCandidate
                )
            }
            // A process that merely appeared after the initial snapshot may
            // have been launched concurrently by Finder or another
            // NSWorkspace client. A poll-only candidate never grants rollback
            // ownership until that exact PID authenticates this invocation's
            // random session/socket identity.
            let provenCandidates = candidates.filter {
                authenticatesCurrentLaunch($0)
            }
            if provenCandidates.count == 1,
               let identity = provenCandidates.first {
                return LaunchedApplicationIdentity(
                    pid: identity.pid,
                    bundleIdentifier: identity.bundleIdentifier,
                    bundleURLPath: identity.bundleURLPath,
                    executablePath: identity.executablePath,
                    processStartTimeMicroseconds:
                        identity.processStartTimeMicroseconds,
                    source: .authenticatedRuntime
                )
            }
            if provenCandidates.count > 1 {
                throw PlayCoverBackendError.launchFailed(
                    "multiple App processes authenticated the same "
                        + "launch session"
                )
            }

            // Check the callback after polling. LaunchServices can report a
            // generic error after RunningBoard has already created the exact
            // process; returning the owned candidate avoids orphaning it.
            if let value = box.get() {
                switch value {
                case .success(let identity):
                    if mayClaimLaunchIdentity(
                        identity,
                        callbackIdentity: identity,
                        runtimeAuthenticated: false
                    ) {
                        return identity
                    }
                case .failure(let error):
                    // A newly-created exact process may not be visible to
                    // NSRunningApplication in the same poll that observes the
                    // callback failure. Keep polling to the bounded deadline
                    // so it can be claimed and rolled back by the caller.
                    callbackError = error
                }
            }

            if Thread.isMainThread {
                let remaining = max(
                    0,
                    deadline - ProcessInfo.processInfo.systemUptime
                )
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(
                        min(0.05, remaining)
                    )
                )
            } else {
                let remaining = max(
                    0,
                    deadline - ProcessInfo.processInfo.systemUptime
                )
                _ = semaphore.wait(
                    timeout: .now() + min(0.05, remaining)
                )
            }
        }
        throw PlayCoverBackendError.launchFailed(
            "NSWorkspace did not return or expose a matching App process"
                + (
                    callbackError.map {
                        "; callback error: \($0)"
                    } ?? ""
                )
        )
        #else
        throw PlayCoverBackendError.launchFailed(
            "PlayCover launch is supported only on macOS"
        )
        #endif
    }

    static func terminateFailedLaunch(
        identity: LaunchedApplicationIdentity,
        manifest: PlayCoverPrepareManifest
    ) throws {
        if let failedLaunchTerminatorOverrideForTesting {
            try failedLaunchTerminatorOverrideForTesting(
                identity,
                manifest
            )
            return
        }
        let pid = identity.pid
        guard identity.source == .workspaceCallback
                || identity.source == .authenticatedRuntime else {
            throw PlayCoverBackendError.launchFailed(
                "rollback refuses a process not owned by the "
                    + "NSWorkspace callback or authenticated Runtime"
            )
        }
        guard let expectedProcessStart =
                identity.processStartTimeMicroseconds else {
            throw PlayCoverBackendError.launchFailed(
                "rollback cannot verify pid \(pid): the owned launch "
                    + "has no stable process birth token"
            )
        }
        switch failedLaunchProcessState(pid) {
        case .missing:
            return
        case .unverifiable(let errorNumber):
            throw PlayCoverBackendError.launchFailed(
                "rollback cannot verify pid \(pid): errno "
                    + "\(errorNumber)"
            )
        case .running(
            let executable,
            let currentProcessStart
        ):
            guard canonicalPath(executable)
                    == canonicalPath(manifest.executablePath),
                  currentProcessStart == expectedProcessStart else {
                // The owned App exited and the PID was reused. This also
                // handles same-executable reuse, which path-only checks miss.
                return
            }
        }
        #if canImport(Darwin)
        let termResult = sendFailedLaunchSignal(pid, SIGTERM)
        let termError = errno
        if termResult != 0, termError == ESRCH {
            return
        }
        guard termResult == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "rollback SIGTERM failed: errno \(termError)"
            )
        }
        if try waitForExactProcessExit(
            pid: pid,
            expectedExecutablePath: manifest.executablePath,
            expectedProcessStartTimeMicroseconds:
                expectedProcessStart,
            timeout: 2
        ) {
            return
        }
        let killResult = sendFailedLaunchSignal(pid, SIGKILL)
        let killError = errno
        if killResult != 0, killError == ESRCH {
            return
        }
        guard killResult == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "rollback SIGKILL failed: errno \(killError)"
            )
        }
        guard try waitForExactProcessExit(
            pid: pid,
            expectedExecutablePath: manifest.executablePath,
            expectedProcessStartTimeMicroseconds:
                expectedProcessStart,
            timeout: 2
        ) else {
            throw PlayCoverBackendError.launchFailed(
                "rollback could not confirm pid \(pid) exited "
                    + "after SIGKILL"
            )
        }
        #endif
    }

    private static func waitForExactProcessExit(
        pid: Int32,
        expectedExecutablePath: String,
        expectedProcessStartTimeMicroseconds: UInt64,
        timeout: Double
    ) throws -> Bool {
        #if canImport(Darwin)
        let deadline =
            ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            switch failedLaunchProcessState(pid) {
            case .missing:
                return true
            case .running(
                let executable,
                let processStartTimeMicroseconds
            ):
                if canonicalPath(executable)
                    != canonicalPath(expectedExecutablePath)
                    || processStartTimeMicroseconds
                        != expectedProcessStartTimeMicroseconds {
                    // The exact process exited and its PID was reused.
                    return true
                }
            case .unverifiable(let errorNumber):
                if errorNumber == ESRCH {
                    // A termination signal was sent only after the owned
                    // process matched the exact executable and stable birth
                    // token. During exit, proc_pidpath can lose that process
                    // before kill(0) reports it missing. Stop here without
                    // sending another signal, so PID reuse cannot redirect
                    // rollback to a replacement process.
                    return true
                }
                throw PlayCoverBackendError.launchFailed(
                    "rollback cannot verify pid \(pid): "
                        + "errno \(errorNumber)"
                )
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return false
            }
            usleep(50_000)
        } while true
        #else
        return true
        #endif
    }

    private static func failedLaunchProcessState(
        _ pid: Int32
    ) -> FailedLaunchProcessState {
        if let failedLaunchProcessStateOverrideForTesting {
            return failedLaunchProcessStateOverrideForTesting(pid)
        }
        if let executable =
                PlayCoverRuntimeClient.executablePath(for: pid) {
            return .running(
                executablePath: executable,
                processStartTimeMicroseconds:
                    processStartTimeMicroseconds(for: pid)
            )
        }
        #if canImport(Darwin)
        let probe = Darwin.kill(pid, 0)
        let probeError = errno
        if probe != 0, probeError == ESRCH {
            return .missing
        }
        return .unverifiable(errno: probeError)
        #else
        return .missing
        #endif
    }

    private static func sendFailedLaunchSignal(
        _ pid: Int32,
        _ signal: Int32
    ) -> Int32 {
        if let failedLaunchSignalOverrideForTesting {
            return failedLaunchSignalOverrideForTesting(pid, signal)
        }
        #if canImport(Darwin)
        return Darwin.kill(pid, signal)
        #else
        return -1
        #endif
    }

    static func validateFreshRuntimeSocketPath(_ path: String) throws {
        let socketURL = URL(fileURLWithPath: path)
        let directoryPath =
            socketURL.deletingLastPathComponent().path
        let socketName = socketURL.lastPathComponent
        #if canImport(Darwin)
        let directory = Darwin.open(
            directoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot open the owner-only Runtime socket "
                    + "directory: errno \(errno)"
            )
        }
        defer { Darwin.close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(0o077)) == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket directory is not an owner-only "
                    + "directory"
            )
        }
        var existing = stat()
        let inspectionResult = socketName.withCString {
            fstatat(
                directory,
                $0,
                &existing,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard inspectionResult != 0 else {
            throw PlayCoverBackendError.launchFailed(
                "refusing an existing Runtime socket path for a "
                    + "new random session"
            )
        }
        guard errno == ENOENT else {
            throw PlayCoverBackendError.launchFailed(
                "cannot inspect Runtime socket path: errno \(errno)"
            )
        }
        #else
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryPath,
            isDirectory: &isDirectory
        ),
            isDirectory.boolValue,
            !FileManager.default.fileExists(atPath: path) else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket directory or new path is invalid"
            )
        }
        #endif
    }

    private static func canonicalJSON<T: Encodable>(
        _ value: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576),
              !data.isEmpty {
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    static func fileSHA256(
        descriptor: Int32
    ) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    descriptor,
                    $0.baseAddress,
                    $0.count
                )
            }
            if count > 0 {
                buffer.withUnsafeBytes {
                    hasher.update(
                        bufferPointer: UnsafeRawBufferPointer(
                            start: $0.baseAddress,
                            count: count
                        )
                    )
                }
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw PlayCoverBackendError.cacheTampered(
                "recorded file could not be hashed: errno \(errno)"
            )
        }
        return hex(hasher.finalize())
    }

    private static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func update(
        _ hasher: inout SHA256,
        _ value: String
    ) {
        let data = Data(value.utf8)
        updateLength(&hasher, UInt64(data.count))
        hasher.update(data: data)
    }

    private static func updateLength(
        _ hasher: inout SHA256,
        _ length: UInt64
    ) {
        var bigEndian = length.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            hasher.update(data: Data($0))
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String
        where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func canonicalizingExistingPrefix(
        _ path: String
    ) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = existing.path.withCString {
            Darwin.realpath($0, &buffer)
        }
        var result = resolved == nil
            ? existing.path
            : String(cString: buffer)
        for component in suffix {
            result = (result as NSString).appendingPathComponent(component)
        }
        return result
    }

    private static func managedHomePath(
        for manifest: PlayCoverPrepareManifest
    ) -> String {
        canonicalPath(
            URL(fileURLWithPath: manifest.preparedAppPath)
                .deletingLastPathComponent() // generation
                .deletingLastPathComponent() // prepared
                .deletingLastPathComponent() // playcover
                .deletingLastPathComponent() // IOS_USE_HOME
                .path
        )
    }
}
