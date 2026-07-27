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
    public static let manifestFilename = "manifest.json"
    static let completedFilename = "completed.json"
    public static let runtimeFrameworkName = "IOSUsePlayRuntime.framework"
    public static let runtimeExecutableName = "IOSUsePlayRuntime"
    static let prepareImplementationRevision =
        "ios-use-headless-v9+playcover-"
        + PlayCoverUpstreamEngine.playCoverRevision
        + "+inject-"
        + PlayCoverUpstreamEngine.injectRevision
        + "+rules-"
        + PlayCoverUpstreamEngine.defaultRulesRevision

    static var failedLaunchTerminatorOverrideForTesting:
        ((Int32, PlayCoverPrepareManifest) throws -> Void)?

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
        guard plan.source
                == PlayCoverPreparationSource(
                    plan.source.upstreamInspection
                ),
              plan.prepareRevision == prepareImplementationRevision,
              plan.runtimeBuildHash.count == 64,
              plan.runtimeBuildHash.allSatisfy({ $0.isHexDigit }),
              plan.generationKey == makeGenerationKey(
                sourceContentHash:
                    plan.source.inspection.sourceContentHash,
                runtimeBuildHash: plan.runtimeBuildHash,
                prepareRevision: plan.prepareRevision
              ) else {
            throw PlayCoverBackendError.prepareFailed(
                "preparation plan identity is invalid"
            )
        }
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
        let sourceEvidence = PlayCoverAppInspection(
            upstream.sourceBefore,
            appPath: source.appPath
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
            sourceInventory: sourceEvidence.inventory,
            sourceMachOs: sourceEvidence.machOs,
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

    /// Full verification. Managed cache reuse calls `fastVerifyGeneration`
    /// instead so reuse does not repeat conversion-time enumeration.
    public static func verify(
        appPath: String
    ) throws -> PlayCoverVerification {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let manifest = try readManifest(for: app)
        try validateManifest(manifest, appURL: app)
        try fastVerifyGeneration(appPath: app.path, manifest: manifest)
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
    /// reuse checks: marker/manifest identity, main/Runtime hashes and three
    /// signatures. It deliberately does not enumerate or inspect the App tree.
    static func fastVerify(
        appPath: String
    ) throws -> PlayCoverPrepareManifest {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let manifest = try readManifest(for: app)
        try validateManifest(manifest, appURL: app)
        try fastVerifyGeneration(appPath: app.path, manifest: manifest)
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
        let manifest = try readManifest(for: app)
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
        let manifest = try suppliedManifest ?? readManifest(for: app)
        try validateManifest(manifest, appURL: app)
        let marker = try readJSON(
            PlayCoverCompletedGeneration.self,
            from: completedURL(for: app)
        )
        guard marker.schemaVersion == 2,
              marker.generationKey == manifest.generationKey else {
            throw PlayCoverBackendError.cacheTampered(
                "completed marker identity does not match the manifest"
            )
        }
        let manifestData = try canonicalJSON(manifest)
        guard marker.manifestSHA256 == sha256(manifestData) else {
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
        let actualExecutableHash = try fileSHA256(executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              marker.executableSHA256 == actualExecutableHash else {
            throw PlayCoverBackendError.cacheTampered(
                "prepared executable hash changed"
            )
        }
        let runtime = app
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(
                runtimeFrameworkName,
                isDirectory: true
            )
            .appendingPathComponent(runtimeExecutableName)
        let actualRuntimeHash = try fileSHA256(runtime)
        guard FileManager.default.isExecutableFile(atPath: runtime.path),
              marker.runtimeSHA256 == actualRuntimeHash else {
            throw PlayCoverBackendError.cacheTampered(
                "embedded Runtime hash changed"
            )
        }
        for (url, label) in [
            (executable, "main executable"),
            (runtime, "embedded Runtime"),
            (app, "outer App"),
        ] {
            let result = try Shell.runWithResult(
                "/usr/bin/codesign",
                arguments: ["--verify", "--strict", url.path]
            )
            guard result.exitCode == 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "\(label) signature is invalid: "
                        + result.stderr.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                )
            }
        }
        try verifyRecordedCodeObjects(
            app: app,
            manifest: manifest,
            fast: true
        )
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
                        pid: launched.pid,
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

    private static func verifyRecordedCodeObjects(
        app: URL,
        manifest: PlayCoverPrepareManifest,
        fast: Bool
    ) throws {
        let codePaths = Set(manifest.inventory.compactMap {
            $0.codeObjectKind == nil ? nil : $0.relativePath
        })
        let nestedContainers = codePaths.filter {
            $0 != "."
                && ($0.hasSuffix(".appex")
                    || $0.hasSuffix(".framework")
                    || $0.hasSuffix(".bundle"))
        }
        let relevantEntries = manifest.inventory.filter { entry in
            if !fast { return true }
            if entry.relativePath == "Info.plist"
                || manifest.machOs.contains(where: {
                    $0.relativePath == entry.relativePath
                }) {
                return true
            }
            return nestedContainers.contains(where: {
                entry.relativePath == $0
                    || entry.relativePath.hasPrefix($0 + "/")
            })
        }
        for entry in relevantEntries {
            let url = try recordedURL(
                app: app,
                relativePath: entry.relativePath
            )
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "recorded path is missing: \(entry.relativePath)"
                )
            }
            let actualKind: String
            switch status.st_mode & S_IFMT {
            case S_IFDIR: actualKind = "directory"
            case S_IFREG: actualKind = "regularFile"
            case S_IFLNK: actualKind = "symbolicLink"
            default: actualKind = "other"
            }
            guard actualKind == entry.kind,
                  UInt16(status.st_mode & 0o7777)
                    == entry.posixPermissions else {
                throw PlayCoverBackendError.cacheTampered(
                    "recorded path kind/permissions changed: "
                        + entry.relativePath
                )
            }
            if entry.kind == "regularFile" {
                guard UInt64(status.st_size) == entry.size,
                      try fileSHA256(url) == entry.sha256 else {
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded file changed: \(entry.relativePath)"
                    )
                }
            } else if entry.kind == "symbolicLink" {
                guard try FileManager.default
                    .destinationOfSymbolicLink(atPath: url.path)
                        == entry.symbolicLinkDestination else {
                    throw PlayCoverBackendError.cacheTampered(
                        "recorded symbolic link changed: "
                            + entry.relativePath
                    )
                }
            }
        }
        for relative in codePaths.sorted() {
            let url = relative == "."
                ? app
                : try recordedURL(app: app, relativePath: relative)
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
        }
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

    private static func readManifest(
        for appURL: URL
    ) throws -> PlayCoverPrepareManifest {
        try readJSON(
            PlayCoverPrepareManifest.self,
            from: manifestURL(for: appURL)
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

    private static func requireManagedPath(
        _ url: URL,
        paths: IOSUsePaths,
        operation: String
    ) throws {
        let managed = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(managed + "/") else {
            throw PlayCoverBackendError.prepareFailed(
                "\(operation) path must be below IOS_USE_HOME managed "
                    + "prepared directory: \(managed)"
            )
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in URL(fileURLWithPath: candidate)
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
        from url: URL
    ) throws -> T {
        do {
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= 64 * 1_024 * 1_024 else {
                throw PlayCoverBackendError.cacheTampered(
                    "\(url.lastPathComponent) is not an immutable regular file"
                )
            }
            return try JSONDecoder().decode(
                type,
                from: Data(contentsOf: url)
            )
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "cannot decode \(url.path): \(error)"
            )
        }
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

    private struct LaunchedApplicationIdentity {
        let pid: Int32
        let bundleIdentifier: String
        let bundleURLPath: String
        let executablePath: String
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
                            executablePath: executablePath
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
                _ = try PlayCoverRuntimeClient(
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
                ).hello()
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
                    executablePath: executablePath
                )
            }
            // A process that merely appeared after the initial snapshot may
            // have been launched concurrently by Finder or another
            // NSWorkspace client. Neither polling nor callback success grants
            // rollback ownership until that exact PID authenticates this
            // invocation's session/socket identity.
            let provenCandidates = candidates.filter {
                authenticatesCurrentLaunch($0)
            }
            if provenCandidates.count == 1,
               let identity = provenCandidates.first {
                return identity
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
                    if authenticatesCurrentLaunch(identity) {
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
        pid: Int32,
        manifest: PlayCoverPrepareManifest
    ) throws {
        if let failedLaunchTerminatorOverrideForTesting {
            try failedLaunchTerminatorOverrideForTesting(pid, manifest)
            return
        }
        guard let executable =
                PlayCoverRuntimeClient.executablePath(for: pid) else {
            #if canImport(Darwin)
            let probe = Darwin.kill(pid, 0)
            let probeError = errno
            guard probe != 0, probeError == ESRCH else {
                throw PlayCoverBackendError.launchFailed(
                    "rollback cannot verify pid \(pid): "
                        + "proc_pidpath unavailable and kill(0) "
                        + "returned \(probe), errno \(probeError)"
                )
            }
            #endif
            return
        }
        guard canonicalPath(executable)
                == canonicalPath(manifest.executablePath) else {
            // The launched App already exited and the PID was reused.
            // Never signal the replacement process.
            return
        }
        #if canImport(Darwin)
        let termResult = Darwin.kill(pid, SIGTERM)
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
            timeout: 2
        ) {
            return
        }
        let killResult = Darwin.kill(pid, SIGKILL)
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
        timeout: Double
    ) throws -> Bool {
        #if canImport(Darwin)
        let deadline =
            ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if let executable =
                    PlayCoverRuntimeClient.executablePath(for: pid) {
                if canonicalPath(executable)
                    != canonicalPath(expectedExecutablePath) {
                    // The exact process exited and its PID was reused.
                    return true
                }
            } else {
                let probe = Darwin.kill(pid, 0)
                let probeError = errno
                if probe != 0, probeError == ESRCH {
                    return true
                }
                if probe != 0 {
                    throw PlayCoverBackendError.launchFailed(
                        "rollback cannot verify pid \(pid): "
                            + "errno \(probeError)"
                    )
                }
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
