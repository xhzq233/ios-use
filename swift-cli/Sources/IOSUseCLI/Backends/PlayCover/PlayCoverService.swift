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
        "ios-use-headless-v8+playcover-"
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
        do {
            return PlayCoverAppInspection(
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
        let source = try inspect(appPath: sourceAppPath)
        let runtimeHash = try runtimeBuildHash(
            frameworkPath: runtimeFrameworkPath
        )
        let generationKey = makeGenerationKey(
            sourceContentHash: source.sourceContentHash,
            runtimeBuildHash: runtimeHash
        )
        if let expectedGenerationKey,
           expectedGenerationKey != generationKey {
            throw PlayCoverBackendError.prepareFailed(
                "generation key changed between cache resolution and prepare"
            )
        }

        let stagingURL = URL(
            fileURLWithPath: outputAppPath,
            isDirectory: true
        ).standardizedFileURL
        let publishedURL = URL(
            fileURLWithPath: publishedAppPath ?? outputAppPath,
            isDirectory: true
        ).standardizedFileURL
        try requireManagedPath(stagingURL, paths: paths, operation: "staging")
        try requireManagedPath(
            publishedURL,
            paths: paths,
            operation: "published App"
        )

        let runtimeURL = URL(
            fileURLWithPath: runtimeFrameworkPath,
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
                    runtimeFramework: runtimeURL,
                    managedHome: canonicalManagedHome,
                    runtimeSocketPath: sandboxSocket,
                    runtimeLoadPath: PlayCoverMachO.runtimeLoadPath
                )
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
            runtimeBuildHash: runtimeHash,
            prepareRevision: prepareImplementationRevision,
            generationKey: generationKey,
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
        return manifest
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
        let manifest = try fastVerify(appPath: appPath)
        try prepareRuntimeSocket(runtimeSocketPath)

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
            let identity = try launchPreparedApplication(
                manifest: manifest,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath,
                timeout: timeout
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

            let deadline = ProcessInfo.processInfo.systemUptime + timeout
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
                    Thread.sleep(forTimeInterval: 0.05)
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
            try removeOwnedSocketIfStale(runtimeSocketPath)
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
            try? removeOwnedSocketIfStale(identity.runtimeSocketPath)
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
        try removeOwnedSocketIfStale(identity.runtimeSocketPath)
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
        runtimeBuildHash: String
    ) -> String {
        var hasher = SHA256()
        update(&hasher, sourceContentHash)
        update(&hasher, runtimeBuildHash)
        update(&hasher, prepareImplementationRevision)
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
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: []
        ) else {
            throw PlayCoverBackendError.missingRuntime(
                "cannot enumerate \(root.path)"
            )
        }
        var entries: [(String, URL, String, UInt16, UInt64)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            let kind: String
            if values.isSymbolicLink == true {
                kind = "symlink"
            } else if values.isDirectory == true {
                kind = "directory"
            } else if values.isRegularFile == true {
                kind = "file"
            } else {
                kind = "other"
            }
            entries.append(
                (
                    String(
                        url.path.dropFirst(root.path.count + 1)
                    ),
                    url,
                    kind,
                    UInt16(
                        truncating: (
                            try FileManager.default.attributesOfItem(
                                atPath: url.path
                            )[.posixPermissions] as? NSNumber
                        ) ?? 0
                    ),
                    UInt64(values.fileSize ?? 0)
                )
            )
        }
        var hasher = SHA256()
        for (relative, url, kind, permissions, size) in entries.sorted(by: {
            $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
        }) {
            update(&hasher, relative)
            update(&hasher, kind)
            update(&hasher, String(permissions))
            update(&hasher, String(size))
            if kind == "file" {
                updateLength(&hasher, size)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1_048_576),
                      !data.isEmpty {
                    hasher.update(data: data)
                }
            } else if kind == "symlink" {
                update(
                    &hasher,
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: url.path
                    )
                )
            }
        }
        return hex(hasher.finalize())
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

    private static func validateHello(
        _ payload: PlayCoverRuntimeResponsePayload,
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
            throw PlayCoverBackendError.launchFailed(
                "Runtime hello identity/geometry is not the fixed "
                    + "\(IOSUsePlayDeviceLogicalWidth)x"
                    + "\(IOSUsePlayDeviceLogicalHeight)@"
                    + "\(IOSUsePlayDeviceScale)x contract"
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
                runtimeBuildHash: manifest.runtimeBuildHash
              ),
              !manifest.sourceInventory.isEmpty,
              !manifest.sourceMachOs.isEmpty,
              Set(manifest.sourceInventory.map(\.relativePath)).count
                == manifest.sourceInventory.count,
              Set(manifest.sourceMachOs.map(\.relativePath)).count
                == manifest.sourceMachOs.count,
              manifest.entitlementDiff.removedFromOriginal.isEmpty else {
            throw PlayCoverBackendError.verificationFailed(
                "manifest schema, identity, generation, or entitlement "
                    + "preservation is invalid"
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

    private static func launchPreparedApplication(
        manifest: PlayCoverPrepareManifest,
        sessionID: String,
        runtimeSocketPath: String,
        timeout: Double
    ) throws -> LaunchedApplicationIdentity {
        #if canImport(AppKit)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.environment = sanitizedLaunchEnvironment(
            sessionID: sessionID,
            runtimeSocketPath: runtimeSocketPath,
            managedHomePath: managedHomePath(for: manifest)
        )
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
               let bundlePath = application.bundleURL?.standardizedFileURL.path,
               let executablePath = application.executableURL?
                    .standardizedFileURL.path {
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
                            "NSWorkspace returned incomplete App identity"
                        )
                    )
                )
            }
            semaphore.signal()
        }
        guard semaphore.wait(
            timeout: .now() + min(timeout, 10)
        ) == .success,
              let value = box.get() else {
            throw PlayCoverBackendError.launchFailed(
                "NSWorkspace launch completion timed out"
            )
        }
        do {
            return try value.get()
        } catch {
            throw PlayCoverBackendError.launchFailed(
                "NSWorkspace could not launch prepared App: \(error)"
            )
        }
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

    private static func prepareRuntimeSocket(_ path: String) throws {
        let socketURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: socketURL.deletingLastPathComponent().path
        )
        try removeOwnedSocketIfStale(path)
    }

    private static func removeOwnedSocketIfStale(_ path: String) throws {
        #if canImport(Darwin)
        var original = stat()
        guard lstat(path, &original) == 0 else {
            if errno == ENOENT { return }
            throw PlayCoverBackendError.launchFailed(
                "cannot inspect Runtime socket: errno \(errno)"
            )
        }
        guard original.st_mode & S_IFMT == S_IFSOCK,
              original.st_uid == geteuid() else {
            throw PlayCoverBackendError.launchFailed(
                "refusing non-socket, symlink, or foreign Runtime path"
            )
        }
        var address = try unixAddress(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot probe Runtime socket: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if connected == 0 {
            throw PlayCoverBackendError.launchFailed(
                "a live Runtime is already listening at \(path)"
            )
        }
        guard errno == ECONNREFUSED || errno == ENOENT else {
            throw PlayCoverBackendError.launchFailed(
                "cannot prove Runtime socket is stale: errno \(errno)"
            )
        }
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_dev == original.st_dev,
              current.st_ino == original.st_ino,
              current.st_mode & S_IFMT == S_IFSOCK,
              current.st_uid == geteuid() else {
            if errno == ENOENT { return }
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket changed during cleanup"
            )
        }
        guard Darwin.unlink(path) == 0 || errno == ENOENT else {
            throw PlayCoverBackendError.launchFailed(
                "cannot remove stale Runtime socket: errno \(errno)"
            )
        }
        #endif
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty,
              !bytes.contains(0),
              bytes.count + 1 <= capacity else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket path is invalid or exceeds \(capacity - 1) bytes"
            )
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.initializeMemory(as: UInt8.self, repeating: 0)
            $0.copyBytes(from: bytes)
        }
        return address
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
