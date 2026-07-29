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

/// One content-addressed generation identity after its key has been computed
/// from a source plan or independently validated from immutable metadata.
///
/// Construction is file-private so other layers can carry this evidence but
/// cannot manufacture it from an untrusted manifest.
struct PlayCoverGenerationIdentity: Equatable, Sendable {
    let sourceContentHash: String
    let runtimeBuildHash: String
    let prepareRevision: String
    let signerPublicKeySPKISHA256: String
    let signerCertificateSHA256: String
    let signingPolicyRevision: String
    let generationKey: String

    fileprivate init(
        sourceContentHash: String,
        runtimeBuildHash: String,
        prepareRevision: String,
        signerPublicKeySPKISHA256: String,
        signerCertificateSHA256: String,
        signingPolicyRevision: String,
        generationKey: String
    ) {
        self.sourceContentHash = sourceContentHash
        self.runtimeBuildHash = runtimeBuildHash
        self.prepareRevision = prepareRevision
        self.signerPublicKeySPKISHA256 =
            signerPublicKeySPKISHA256
        self.signerCertificateSHA256 =
            signerCertificateSHA256
        self.signingPolicyRevision = signingPolicyRevision
        self.generationKey = generationKey
    }

    fileprivate init(manifest: PlayCoverPrepareManifest) {
        self.init(
            sourceContentHash: manifest.sourceContentHash,
            runtimeBuildHash: manifest.runtimeBuildHash,
            prepareRevision: manifest.prepareRevision,
            signerPublicKeySPKISHA256:
                manifest.signingIdentity.publicKeySPKISHA256,
            signerCertificateSHA256:
                manifest.signingIdentity.certificateSHA256,
            signingPolicyRevision:
                manifest.signingIdentity.policy.revision,
            generationKey: manifest.generationKey
        )
    }

    func matches(_ manifest: PlayCoverPrepareManifest) -> Bool {
        sourceContentHash == manifest.sourceContentHash
            && runtimeBuildHash == manifest.runtimeBuildHash
            && prepareRevision == manifest.prepareRevision
            && signerPublicKeySPKISHA256
                == manifest.signingIdentity.publicKeySPKISHA256
            && signerCertificateSHA256
                == manifest.signingIdentity.certificateSHA256
            && signingPolicyRevision
                == manifest.signingIdentity.policy.revision
            && generationKey == manifest.generationKey
    }
}

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
            + "not be confirmed stopped; the durable pending launch "
            + "journal must be preserved. Original error: "
            + "\(originalError). "
            + "Rollback error: \(rollbackError)"
    }
}

struct PlayCoverFastVerifiedGenerationToken: Equatable, Sendable {
    struct DirectoryIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    let generationKey: String
    let completedAt: String
    let completed: PlayCoverCompletedGeneration
    let directoryIdentity: DirectoryIdentity

    fileprivate init(
        generationKey: String,
        completedAt: String,
        completed: PlayCoverCompletedGeneration,
        directoryIdentity: DirectoryIdentity
    ) {
        self.generationKey = generationKey
        self.completedAt = completedAt
        self.completed = completed
        self.directoryIdentity = directoryIdentity
    }
}

public enum PlayCoverService {
    private static let upstreamStandardOutputLock = NSLock()

    enum FastVerifyEvent: Equatable {
        case afterGenerationOpen
        case afterPreparedAppOpen
        case beforeMetadataOpen(String)
        case afterMetadataOpen(String)
        case afterMetadataRead(String)
        case beforeFileHash(String)
        case afterFileHash(String)
        case beforeCodeSignature(String)
        case afterCodeSignature(String)
    }

    enum LaunchIntegrityEvent: Equatable {
        case afterFastVerificationBeforeLaunchBody
        case afterAliasBuiltBeforePreSubmitValidation
        case afterWorkspaceOpenReturnedBeforePostSubmitValidation
    }

    public static let manifestFilename = "manifest.json"
    static let completedFilename = "completed.json"
    static let generationManifestMaximumBytes = 64 * 1_024 * 1_024
    static let completedMarkerMaximumBytes = 1_048_576
    public static let runtimeFrameworkName = "IOSUsePlayRuntime.framework"
    public static let runtimeExecutableName = "IOSUsePlayRuntime"
    static let prepareImplementationRevision =
        "ios-use-headless-v14+playcover-"
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
    static var keyCoverLockOverrideForTesting:
        ((String, URL) throws -> Void)?
    static var launchAliasRootOverrideForTesting: URL?
    #if canImport(AppKit)
    static var workspaceOpenOverrideForTesting:
        ((
            URL,
            NSWorkspace.OpenConfiguration,
            @escaping (NSRunningApplication?, Error?) -> Void
        ) -> Void)?
    #endif
    static var fastVerifyEventOverrideForTesting:
        ((FastVerifyEvent) throws -> Void)?
    static var launchIntegrityEventOverrideForTesting:
        ((LaunchIntegrityEvent) throws -> Void)?
    static var generationKeyComputationObserverForTesting:
        (() -> Void)?
    static var manifestValidationObserverForTesting:
        (() -> Void)?
    static var signingIdentityResolverOverrideForTesting:
        ((Bool) throws -> PlayCoverSigningIdentityEvidence)?
    static var rootCodeSignatureInspectorOverrideForTesting:
        ((URL) throws -> PlayCoverRootCodeSignatureEvidence)?
    static var upstreamPrepareOverrideForTesting:
        ((
            PlayCoverUpstreamPrepareOptions,
            PlayCoverUpstreamAppInspection
        ) throws -> PlayCoverUpstreamPrepareResult)?
    static var signingIdentityNowOverrideForTesting:
        (() -> Date)?
    private static let fastVerifyHashQueue = DispatchQueue(
        label: "com.iosuse.playcover.fast-verify-hash",
        qos: .userInitiated
    )
    private static let fastVerifyNestedSignatureQueue = DispatchQueue(
        label: "com.iosuse.playcover.fast-verify-nested-signature",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let fastVerifyNestedSignatureWorkerLimit = 4

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
        signingIdentity suppliedSigningIdentity:
            PlayCoverSigningIdentityEvidence? = nil,
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
        let runtimeEvidence = try runtimeEvidence(
            frameworkPath: runtimePath
        )
        let runtimeHash = runtimeEvidence.buildHash
        let revision = prepareImplementationRevision
        let signingIdentity = try suppliedSigningIdentity
            ?? resolveSigningIdentity(initializeIfMissing: false)
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
                prepareRevision: revision,
                signerPublicKeySPKISHA256:
                    signingIdentity.publicKeySPKISHA256,
                signerCertificateSHA256:
                    signingIdentity.certificateSHA256,
                signingPolicyRevision:
                    signingIdentity.policy.revision
            )
        }
        return PlayCoverPreparationPlan(
            source: source,
            runtimeFrameworkPath: runtimePath,
            runtimeEvidence: runtimeEvidence,
            signingIdentity: signingIdentity,
            generationIdentity: PlayCoverGenerationIdentity(
                sourceContentHash: source.inspection.sourceContentHash,
                runtimeBuildHash: runtimeHash,
                prepareRevision: revision,
                signerPublicKeySPKISHA256:
                    signingIdentity.publicKeySPKISHA256,
                signerCertificateSHA256:
                    signingIdentity.certificateSHA256,
                signingPolicyRevision:
                    signingIdentity.policy.revision,
                generationKey: generationKey
            )
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
        let upstreamOptions = PlayCoverUpstreamPrepareOptions(
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
            codesignIdentity:
                plan.signingIdentity.codesignSelector,
            expectedRuntimeBuildHash: plan.runtimeBuildHash,
            expectedRuntimeEvidence: plan.runtimeEvidence
        )
        let upstream: PlayCoverUpstreamPrepareResult
        do {
            if let upstreamPrepareOverrideForTesting {
                upstream = try upstreamPrepareOverrideForTesting(
                    upstreamOptions,
                    plan.source.upstreamInspection
                )
            } else {
                upstream = try withSuppressedUpstreamStandardOutput {
                    try PlayCoverUpstreamEngine.prepare(
                        upstreamOptions,
                        sourceInspection: plan.source.upstreamInspection
                    )
                }
            }
        } catch let error as PlayCoverUpstreamError {
            throw PlayCoverMachO.map(error)
        }

        let prepared = PlayCoverAppInspection(
            upstream.prepared,
            appPath: publishedURL.path
        )
        let rootCodeSignature: PlayCoverRootCodeSignatureEvidence
        do {
            rootCodeSignature = try inspectRootCodeSignature(
                appURL: stagingURL,
                mainExecutableRelativePath:
                    upstream.prepared.mainExecutableRelativePath,
                scratchRootURL: URL(
                    fileURLWithPath: paths.root,
                    isDirectory: true
                )
            )
        } catch {
            throw PlayCoverBackendError.codeSigningFailed(
                "cannot inspect stable root signature: \(error)"
            )
        }
        try requireUnchangedSigningIdentityAfterPreparation(
            plan.signingIdentity
        )
        guard rootCodeSignature.certificateSHA256
                == plan.signingIdentity.certificateSHA256,
              rootCodeSignature.signingIdentifier
                == prepared.bundleIdentifier,
              upstream.prepared.signature.isSigned,
              upstream.prepared.signature.isValid,
              upstream.prepared.signature.identifier
                == rootCodeSignature.signingIdentifier,
              let inspectedCDHash = normalizedCDHash(
                  rootCodeSignature.cdHash
              ),
              let finalInspectionCDHash = normalizedCDHash(
                  upstream.prepared.signature.cdHash
              ),
              inspectedCDHash == finalInspectionCDHash else {
            throw PlayCoverBackendError.codeSigningFailed(
                "prepared root signature does not match the selected "
                    + "stable identity or final prepared inspection"
            )
        }
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
            signingIdentity: plan.signingIdentity,
            rootCodeSignature: rootCodeSignature,
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

    private static func withSuppressedUpstreamStandardOutput<T>(
        _ body: () throws -> T
    ) throws -> T {
#if canImport(Darwin)
        // Pinned PlayCover helpers synchronously print progress from this
        // prepare stack. Serialize the process-wide descriptor swap and flush
        // while fd 1 still points at the sink so buffered text cannot trail
        // the CLI result written after this method returns.
        upstreamStandardOutputLock.lock()
        defer { upstreamStandardOutputLock.unlock() }

        func isolationFailure(
            _ operation: String,
            errno errorNumber: Int32
        ) -> PlayCoverBackendError {
            .prepareFailed(
                "\(operation): errno \(errorNumber)"
            )
        }
        guard fflush(stdout) == 0 else {
            throw isolationFailure("pinned prepare stdout pre-flush failed",
                                   errno: errno)
        }
        let savedOutput = Darwin.fcntl(
            STDOUT_FILENO,
            F_DUPFD_CLOEXEC,
            STDERR_FILENO + 1
        )
        guard savedOutput >= 0 else {
            throw isolationFailure("pinned prepare stdout preserve failed",
                                   errno: errno)
        }
        defer { Darwin.close(savedOutput) }
        let nullOutput = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard nullOutput >= 0 else {
            throw isolationFailure("pinned prepare stdout sink failed",
                                   errno: errno)
        }
        defer { Darwin.close(nullOutput) }
        guard Darwin.dup2(nullOutput, STDOUT_FILENO) >= 0 else {
            throw isolationFailure("pinned prepare stdout redirect failed",
                                   errno: errno)
        }

        let result = Result<T, Error> { try body() }
        let flushStatus = fflush(stdout)
        let flushError = errno
        let restoreStatus = Darwin.dup2(savedOutput, STDOUT_FILENO)
        let restoreError = errno

        guard restoreStatus >= 0 else {
            throw isolationFailure("pinned prepare stdout restore failed",
                                   errno: restoreError)
        }
        guard flushStatus == 0 else {
            throw isolationFailure("pinned prepare stdout final flush failed",
                                   errno: flushError)
        }
        return try result.get()
#else
        return try body()
#endif
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
        let runtimePath = canonicalPath(plan.runtimeFrameworkPath)
        let runtimeEvidence = plan.runtimeEvidence
        guard plan.prepareRevision == prepareImplementationRevision,
              isSHA256(sourceHash),
              upstreamSourceHash == sourceHash,
              sourcePath == upstreamSourcePath,
              isSHA256(plan.runtimeBuildHash),
              runtimeEvidence.frameworkPath == runtimePath,
              runtimeEvidence.buildHash == plan.runtimeBuildHash,
              runtimeEvidence.mainExecutableRelativePath
                == runtimeExecutableName,
              runtimeEvidence.mainExecutable.relativePath
                == runtimeExecutableName,
              isSHA256(plan.generationKey),
              isValidSigningIdentity(plan.signingIdentity),
              plan.generationIdentity.signerPublicKeySPKISHA256
                == plan.signingIdentity.publicKeySPKISHA256,
              plan.generationIdentity.signerCertificateSHA256
                == plan.signingIdentity.certificateSHA256,
              plan.generationIdentity.signingPolicyRevision
                == plan.signingIdentity.policy.revision,
              plan.generationKey == makeGenerationKey(
                sourceContentHash: sourceHash,
                runtimeBuildHash: plan.runtimeBuildHash,
                prepareRevision: plan.prepareRevision,
                signerPublicKeySPKISHA256:
                    plan.signingIdentity.publicKeySPKISHA256,
                signerCertificateSHA256:
                    plan.signingIdentity.certificateSHA256,
                signingPolicyRevision:
                    plan.signingIdentity.policy.revision
              ) else {
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
        let validated = try fastVerifiedManifest(
            app: app,
            suppliedManifest: nil,
            expectedGenerationIdentity: nil
        )
        let manifest = validated.manifest
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
    /// independently signed code object in the pinned inside-out signing order
    /// exactly once. Bundle verification covers its recorded main executable.
    /// It deliberately does not enumerate or inspect the App tree.
    static func fastVerify(
        appPath: String
    ) throws -> PlayCoverPrepareManifest {
        try fastVerifyEvidence(
            appPath: appPath,
            expectedGenerationIdentity: nil
        ).manifest
    }

    static func fastVerifyEvidence(
        appPath: String,
        expectedGenerationIdentity: PlayCoverGenerationIdentity?
    ) throws -> PlayCoverValidatedPreparedManifest {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        return try fastVerifiedManifest(
            app: app,
            suppliedManifest: nil,
            expectedGenerationIdentity: expectedGenerationIdentity
        )
    }

    /// Reads and validates only the recorded generation identity. The caller
    /// must run `fastVerify` immediately before launch before trusting it.
    static func readPreparedManifest(
        appPath: String,
        expectedGenerationIdentity: PlayCoverGenerationIdentity? = nil
    ) throws -> PlayCoverPrepareManifest {
        try readPreparedManifestEvidence(
            appPath: appPath,
            expectedGenerationIdentity:
                expectedGenerationIdentity
        ).manifest
    }

    static func readPreparedManifestEvidence(
        appPath: String,
        expectedGenerationIdentity:
            PlayCoverGenerationIdentity? = nil
    ) throws -> PlayCoverValidatedPreparedManifest {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let manifest = try readManifest(for: app).value
        let generationIdentity = try validateManifest(
            manifest,
            appURL: app,
            expectedGenerationIdentity: expectedGenerationIdentity
        )
        return PlayCoverValidatedPreparedManifest(
            manifest: manifest,
            generationIdentity: generationIdentity
        )
    }

    /// Test overrides bypass immutable sidecars by design. Keep their
    /// unchecked identity construction inside this source file so production
    /// layers cannot manufacture trusted generation evidence.
    static func uncheckedValidatedPreparedManifestForTesting(
        _ manifest: PlayCoverPrepareManifest,
        expectedGenerationIdentity:
            PlayCoverGenerationIdentity?
    ) -> PlayCoverValidatedPreparedManifest {
        PlayCoverValidatedPreparedManifest(
            manifest: manifest,
            generationIdentity:
                expectedGenerationIdentity
                    ?? PlayCoverGenerationIdentity(
                        manifest: manifest
                    )
        )
    }

    static func fastVerifyGeneration(
        appPath: String,
        manifest suppliedManifest: PlayCoverPrepareManifest? = nil
    ) throws {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        _ = try fastVerifiedManifest(
            app: app,
            suppliedManifest: suppliedManifest,
            expectedGenerationIdentity: nil
        )
    }

    private static func fastVerifiedManifest(
        app: URL,
        suppliedManifest: PlayCoverPrepareManifest?,
        expectedGenerationIdentity: PlayCoverGenerationIdentity?
    ) throws -> PlayCoverValidatedPreparedManifest {
        try withFastVerifiedManifestDescriptors(
            app: app,
            suppliedManifest: suppliedManifest,
            expectedGenerationIdentity: expectedGenerationIdentity,
            captureLaunchEntries: false
        ) { evidence, _, _, _, _, _ in
            evidence
        }
    }

    private static func withFastVerifiedManifestDescriptors<T>(
        app: URL,
        suppliedManifest: PlayCoverPrepareManifest?,
        expectedGenerationIdentity: PlayCoverGenerationIdentity?,
        captureLaunchEntries: Bool,
        body: (
            PlayCoverValidatedPreparedManifest,
            PlayCoverCompletedGeneration,
            Int32,
            URL,
            Int32,
            [AnchoredLaunchAliasEntry]?
        ) throws -> T
    ) throws -> T {
        try withStableGenerationDescriptor(for: app) {
            generationDescriptor,
            generationURL in
            let manifestEvidence = try readJSONMetadata(
                PlayCoverPrepareManifest.self,
                generationDescriptor: generationDescriptor,
                generationURL: generationURL,
                filename: manifestFilename,
                maximumBytes: generationManifestMaximumBytes
            )
            let manifest = manifestEvidence.value
            let generationIdentity = try validateManifest(
                manifest,
                appURL: app,
                expectedGenerationIdentity:
                    expectedGenerationIdentity
            )
            if let suppliedManifest,
               suppliedManifest != manifest {
                throw PlayCoverBackendError.cacheTampered(
                    "supplied manifest does not match generation metadata"
                )
            }
            let marker = try readJSONMetadata(
                PlayCoverCompletedGeneration.self,
                generationDescriptor: generationDescriptor,
                generationURL: generationURL,
                filename: completedFilename,
                maximumBytes: completedMarkerMaximumBytes
            ).value
            guard marker.schemaVersion == 4,
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
            let runtimeRelativePath = try recordedRelativePath(
                runtime,
                in: app
            )
            return try withPreparedAppDescriptor(
                generationDescriptor: generationDescriptor,
                generationURL: generationURL,
                app: app
            ) { appDescriptor in
                let launchEntries = captureLaunchEntries
                    ? try anchoredLaunchAliasEntries(
                        app: app,
                        appDescriptor: appDescriptor
                    )
                    : nil
                let verification = try verifyRecordedCodeObjects(
                    app: app,
                    borrowedAppDescriptor: appDescriptor,
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
                    verification.executablePaths.contains(
                        executableRelativePath
                    ),
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
                if let launchEntries {
                    try validateAnchoredLaunchAliasEntries(
                        launchEntries,
                        appDescriptor: appDescriptor
                    )
                }
                let evidence = PlayCoverValidatedPreparedManifest(
                    manifest: manifest,
                    generationIdentity: generationIdentity
                )
                return try body(
                    evidence,
                    marker,
                    generationDescriptor,
                    generationURL,
                    appDescriptor,
                    launchEntries
                )
            }
        }
    }

    static func withFastVerifiedLaunchCapability<T>(
        appPath: String,
        expectedGenerationIdentity: PlayCoverGenerationIdentity?,
        body: (
            PlayCoverValidatedPreparedManifest,
            FastVerifiedLaunchCapability
        ) throws -> T
    ) throws -> T {
        let acquired = try acquireFastVerifiedLaunchCapability(
            appPath: appPath,
            expectedGenerationIdentity: expectedGenerationIdentity
        )
        defer { acquired.capability.close() }
        return try body(acquired.evidence, acquired.capability)
    }

    static func acquireFastVerifiedLaunchCapability(
        appPath: String,
        expectedGenerationIdentity: PlayCoverGenerationIdentity?
    ) throws -> (
        evidence: PlayCoverValidatedPreparedManifest,
        currentGenerationToken: PlayCoverFastVerifiedGenerationToken,
        capability: FastVerifiedLaunchCapability
    ) {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let acquired = try withFastVerifiedManifestDescriptors(
            app: app,
            suppliedManifest: nil,
            expectedGenerationIdentity: expectedGenerationIdentity,
            captureLaunchEntries: true
        ) {
            evidence,
            marker,
            generationDescriptor,
            generationURL,
            appDescriptor,
            launchEntries in
            guard let launchEntries else {
                throw PlayCoverBackendError.cacheTampered(
                    "fast verification did not capture launch inventory"
                )
            }
            let capability = try retainLaunchCapability(
                generationDescriptor: generationDescriptor,
                generationURL: generationURL,
                appDescriptor: appDescriptor,
                app: app,
                entries: launchEntries
            )
            let token = PlayCoverFastVerifiedGenerationToken(
                generationKey: evidence.manifest.generationKey,
                completedAt: evidence.manifest.completedAt,
                completed: marker,
                directoryIdentity: .init(
                    device: UInt64(
                        capability.generationStatus.st_dev
                    ),
                    inode: UInt64(
                        capability.generationStatus.st_ino
                    )
                )
            )
            return (evidence, token, capability)
        }
        try emitLaunchIntegrityEvent(
            .afterFastVerificationBeforeLaunchBody
        )
        return acquired
    }

    #if DEBUG && canImport(Darwin)
    static func uncheckedFastVerifiedGenerationTokenForTesting(
        generationKey: String,
        completedAt: String,
        completed: PlayCoverCompletedGeneration,
        generationURL: URL
    ) throws -> PlayCoverFastVerifiedGenerationToken {
        var status = stat()
        guard lstat(generationURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              completed.generationKey == generationKey else {
            throw PlayCoverBackendError.cacheTampered(
                "testing generation token identity is invalid"
            )
        }
        return PlayCoverFastVerifiedGenerationToken(
            generationKey: generationKey,
            completedAt: completedAt,
            completed: completed,
            directoryIdentity: .init(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
        )
    }
    #endif

    private static func retainLaunchCapability(
        generationDescriptor: Int32,
        generationURL: URL,
        appDescriptor: Int32,
        app: URL,
        entries: [AnchoredLaunchAliasEntry]
    ) throws -> FastVerifiedLaunchCapability {
        let retainedGenerationDescriptor = fcntl(
            generationDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard retainedGenerationDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot retain the fast-verified generation vnode: "
                    + "errno \(errno)"
            )
        }
        let retainedAppDescriptor = fcntl(
            appDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard retainedAppDescriptor >= 0 else {
            Darwin.close(retainedGenerationDescriptor)
            throw PlayCoverBackendError.cacheTampered(
                "cannot retain the fast-verified App vnode: errno \(errno)"
            )
        }
        var generationStatus = stat()
        var appStatus = stat()
        guard fstat(
                retainedGenerationDescriptor,
                &generationStatus
              ) == 0,
              fstat(retainedAppDescriptor, &appStatus) == 0 else {
            Darwin.close(retainedAppDescriptor)
            Darwin.close(retainedGenerationDescriptor)
            throw PlayCoverBackendError.cacheTampered(
                "cannot record the fast-verified launch vnodes"
            )
        }
        do {
            try validateAnchoredLaunchAliasEntries(
                entries,
                appDescriptor: retainedAppDescriptor
            )
            return FastVerifiedLaunchCapability(
                generationDescriptor: retainedGenerationDescriptor,
                generationURL: generationURL,
                generationStatus: generationStatus,
                appDescriptor: retainedAppDescriptor,
                appURL: app,
                appStatus: appStatus,
                entries: entries
            )
        } catch {
            Darwin.close(retainedAppDescriptor)
            Darwin.close(retainedGenerationDescriptor)
            throw error
        }
    }

    static func withUncheckedLaunchCapabilityForTesting<T>(
        appPath: String,
        body: (FastVerifiedLaunchCapability) throws -> T
    ) throws -> T {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let capability = try withStableGenerationDescriptor(for: app) {
            generationDescriptor,
            generationURL in
            try withPreparedAppDescriptor(
                generationDescriptor: generationDescriptor,
                generationURL: generationURL,
                app: app
            ) { appDescriptor in
                let entries = try anchoredLaunchAliasEntries(
                    app: app,
                    appDescriptor: appDescriptor
                )
                let capability = try retainLaunchCapability(
                    generationDescriptor: generationDescriptor,
                    generationURL: generationURL,
                    appDescriptor: appDescriptor,
                    app: app,
                    entries: entries
                )
                return capability
            }
        }
        defer { capability.close() }
        return try body(capability)
    }

    static func launchVerified(
        validatedManifest: PlayCoverValidatedPreparedManifest,
        launchCapability: FastVerifiedLaunchCapability,
        sessionID: String,
        runtimeSocketPath: String,
        stdioLog: PlayCoverStdioLogIdentity? = nil,
        pendingLaunchPaths: IOSUsePaths? = nil,
        launchPhaseTiming: inout PlayCoverLaunchPhaseTiming,
        timeout: Double = 15
    ) throws -> PlayCoverLaunchIdentity {
        launchPhaseTiming = .empty
        let manifest = validatedManifest.manifest
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
        if let stdioLog {
            guard stdioLog.path.hasPrefix("/"),
                  !stdioLog.path.utf8.contains(0),
                  stdioLog.inode > 0 else {
                throw PlayCoverBackendError.stdioLogFailed(
                    "PlayCover stdio log identity is incomplete"
                )
            }
        }
        if let pendingLaunchPaths {
            _ = try PlayCoverPendingLaunchStore.createIntent(
                PlayCoverPendingLaunchStore.Intent(
                    sessionID: sessionID,
                    runtimeSocketPath: runtimeSocketPath,
                    generationKey: manifest.generationKey,
                    appPath: manifest.preparedAppPath,
                    bundleIdentifier: manifest.bundleIdentifier,
                    executablePath: manifest.executablePath,
                    aliasPath: sessionLaunchAlias(
                        sessionID: sessionID
                    ).bundleURL.path
                ),
                paths: pendingLaunchPaths
            )
        }

        var launched: LaunchedApplicationIdentity?
        var launchAlias: SessionLaunchAlias?
        var workspaceOpenSubmitted = false
        var postSubmissionIntegrityError: Error?
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
                launchCapability: launchCapability,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath,
                stdioLog: stdioLog,
                pendingLaunchPaths: pendingLaunchPaths,
                deadline: deadline,
                launchAlias: &launchAlias,
                workspaceOpenSubmitted: &workspaceOpenSubmitted,
                postSubmissionIntegrityError:
                    &postSubmissionIntegrityError,
                launchPhaseTiming: &launchPhaseTiming
            )
            launched = identity
            guard let launchAlias,
                  acceptsClaimedLaunchIdentity(
                    identity,
                    manifest: manifest,
                    launchAliasPath: launchAlias.bundleURL.path
                  ) else {
                throw PlayCoverBackendError.launchFailed(
                    "NSWorkspace returned PID/bundle/App/executable identity "
                        + "that does not match the prepared generation"
                )
            }
            if let postSubmissionIntegrityError {
                throw postSubmissionIntegrityError
            }

            let readyGeometryStarted =
                PlayCoverMonotonicClock.now()
            var lastError: Error?
            while ProcessInfo.processInfo.systemUptime < deadline {
                do {
                    let remaining =
                        deadline - ProcessInfo.processInfo.systemUptime
                    let payload = try PlayCoverRuntimeClient(
                        socketPath: runtimeSocketPath,
                        sessionID: sessionID,
                        expectedPID: identity.pid,
                        expectedBundleIdentifier: manifest.bundleIdentifier,
                        expectedExecutablePath: manifest.executablePath,
                        // A Runtime hello can wait behind App startup on its
                        // main queue. Keep exactly one ready probe in flight:
                        // short client deadlines would close the connection,
                        // retry, and leave stale hello frames in Runtime FIFO.
                        timeoutSeconds: remaining
                    ).hello()
                    let hello = try validateHello(
                        payload,
                        sessionID: sessionID,
                        manifest: manifest,
                        pid: identity.pid,
                        stdioLog: stdioLog
                    )
                    #if DEBUG && canImport(Darwin)
                    PlayCoverLaunchCrashCut.hit(.afterReadyGate)
                    #endif
                    launchPhaseTiming.readyGeometryNanoseconds =
                        PlayCoverMonotonicClock.elapsed(
                            since: readyGeometryStarted
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
                    if runtimeHelloFailureIsTerminal(error) {
                        launchPhaseTiming.readyGeometryNanoseconds =
                            PlayCoverMonotonicClock.elapsed(
                                since: readyGeometryStarted
                            )
                        throw error
                    }
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
            launchPhaseTiming.readyGeometryNanoseconds =
                PlayCoverMonotonicClock.elapsed(
                    since: readyGeometryStarted
                )
            throw PlayCoverBackendError.launchTimedOut(
                "no verified Runtime hello within \(timeout) seconds"
                    + (lastError.map { "; last error: \($0)" } ?? "")
            )
        } catch {
            var shouldRetryDurableOwnership = false
            if let ownedLaunchError =
                    error as? PendingOwnedLaunchError {
                launched = ownedLaunchError.identity
                shouldRetryDurableOwnership =
                    ownedLaunchError.shouldRetryDurableOwnership
            }
            var cleanupProof:
                PlayCoverPendingLaunchStore.CleanupProof?
            if let launched {
                do {
                    try terminateFailedLaunch(
                        identity: launched,
                        manifest: manifest
                    )
                    cleanupProof = .stoppedExactOwner
                } catch let rollbackError {
                    var rollbackDescription =
                        String(describing: rollbackError)
                    if shouldRetryDurableOwnership,
                       let pendingLaunchPaths,
                       let durableOwner =
                            pendingLaunchOwner(launched) {
                        do {
                            _ = try PlayCoverPendingLaunchStore
                                .markOwned(
                                    sessionID: sessionID,
                                    owner: durableOwner,
                                    callbackSucceeded:
                                        launched.source
                                            == .workspaceCallback,
                                    paths: pendingLaunchPaths
                                )
                        } catch {
                            rollbackDescription +=
                                "; durable ownership retry failed: "
                                + String(describing: error)
                        }
                    }
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
                        rollbackError: rollbackDescription
                    )
                }
            } else if !workspaceOpenSubmitted {
                cleanupProof = .neverSubmitted
            }
            var errorToThrow = error
            if let pendingLaunchPaths,
               let cleanupProof {
                do {
                    try completePendingLaunchCleanup(
                        sessionID: sessionID,
                        proof: cleanupProof,
                        owner: launched,
                        manifest: manifest,
                        paths: pendingLaunchPaths
                    )
                } catch let cleanupError {
                    errorToThrow = PlayCoverSessionCleanupError(
                        operation: .launch,
                        cleanupError: cleanupError,
                        originalError: error,
                        logPath: nil
                    )
                }
            } else if pendingLaunchPaths == nil,
                      cleanupProof != nil {
                do {
                    if keyCoverUnlocked {
                        try lockKeyCover(for: manifest)
                    }
                    if let launchAlias {
                        try removeSessionLaunchAlias(
                            launchAlias,
                            manifest: manifest
                        )
                    }
                } catch let cleanupError {
                    errorToThrow = PlayCoverSessionCleanupError(
                        operation: .launch,
                        cleanupError: cleanupError,
                        originalError: error,
                        logPath: nil
                    )
                }
            }
            throw errorToThrow
        }
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
             .alertRefreshUnsupportedByRuntime,
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
        prepareRevision: String,
        signerPublicKeySPKISHA256: String,
        signerCertificateSHA256: String,
        signingPolicyRevision: String
    ) -> String {
        generationKeyComputationObserverForTesting?()
        var hasher = SHA256()
        update(&hasher, sourceContentHash)
        update(&hasher, runtimeBuildHash)
        update(&hasher, prepareRevision)
        update(&hasher, signerPublicKeySPKISHA256)
        update(&hasher, signerCertificateSHA256)
        update(&hasher, signingPolicyRevision)
        return hex(hasher.finalize())
    }

    private static func resolveSigningIdentity(
        initializeIfMissing: Bool
    ) throws -> PlayCoverSigningIdentityEvidence {
        if let override =
                signingIdentityResolverOverrideForTesting {
            return try override(initializeIfMissing)
        }
        return try PlayCoverSigningIdentityService()
            .requireHealthy(
                initializeIfMissing: initializeIfMissing
            )
    }

    static func requireUnchangedSigningIdentityAfterPreparation(
        _ expected: PlayCoverSigningIdentityEvidence
    ) throws {
        let observed =
            try resolveSigningIdentity(initializeIfMissing: false)
        guard observed == expected else {
            throw PlayCoverBackendError.codeSigningFailed(
                "stable signing identity changed during preparation"
            )
        }
    }

    private static func inspectRootCodeSignature(
        appURL: URL,
        mainExecutableRelativePath: String,
        scratchRootURL: URL
    ) throws -> PlayCoverRootCodeSignatureEvidence {
        if let override =
                rootCodeSignatureInspectorOverrideForTesting {
            return try override(appURL)
        }
        #if canImport(Darwin)
        let descriptor = Darwin.open(
            appURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.codeSigningFailed(
                "cannot open prepared App root for signature inspection: "
                    + "errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        let stableURL =
            try PlayCoverManagedAppService.ownedDirectoryDescriptorPath(
                descriptor,
                label: "signature-inspection App root"
            )
        return try PlayCoverCodeSignatureInspector.inspectRoot(
            appURL: stableURL,
            mainExecutableRelativePath: mainExecutableRelativePath,
            scratchRootURL: scratchRootURL
        )
        #else
        return try PlayCoverCodeSignatureInspector.inspectRoot(
            appURL: appURL,
            mainExecutableRelativePath: mainExecutableRelativePath,
            scratchRootURL: scratchRootURL
        )
        #endif
    }

    private static func isValidSigningIdentity(
        _ evidence: PlayCoverSigningIdentityEvidence
    ) -> Bool {
        let now = signingIdentityNowOverrideForTesting?() ?? Date()
        let selectorIsValid =
            isUppercaseHex(
                evidence.codesignSelector,
                count: 40
            )
            || (
                signingIdentityResolverOverrideForTesting != nil
                    && evidence.codesignSelector == "-"
            )
        return evidence.policy.revision
                == PlayCoverSigningIdentityService.policyRevision
            && evidence.policy.source == .managedUserKeychain
            && evidence.policy.health == .healthy
            && isUppercaseHex(
                evidence.publicKeySPKISHA256,
                count: 64
            )
            && isUppercaseHex(
                evidence.certificateSHA256,
                count: 64
            )
            && selectorIsValid
            && evidence.notBefore < evidence.notAfter
            && now >= evidence.notBefore
            && now < evidence.notAfter
    }

    private static func isValidRootCodeSignature(
        _ evidence: PlayCoverRootCodeSignatureEvidence,
        signingIdentity: PlayCoverSigningIdentityEvidence,
        bundleIdentifier: String
    ) -> Bool {
        let cdHashLength = evidence.cdHash.count
        return evidence.certificateSHA256
                == signingIdentity.certificateSHA256
            && !evidence.designatedRequirement.isEmpty
            && evidence.designatedRequirementSHA256
                == sha256(evidence.designatedRequirement).uppercased()
            && isUppercaseHex(
                evidence.designatedRequirementSHA256,
                count: 64
            )
            && (cdHashLength == 40 || cdHashLength == 64)
            && isUppercaseHex(
                evidence.cdHash,
                count: cdHashLength
            )
            && evidence.signingIdentifier == bundleIdentifier
    }

    private static func verifyStableRootSignature(
        appURL: URL,
        scratchRootURL: URL,
        manifest: PlayCoverPrepareManifest
    ) throws {
        let currentIdentity =
            try resolveSigningIdentity(initializeIfMissing: false)
        guard currentIdentity == manifest.signingIdentity else {
            throw PlayCoverBackendError.cacheTampered(
                "stable signing identity no longer matches the prepared "
                    + "generation"
            )
        }
        let observed: PlayCoverRootCodeSignatureEvidence
        do {
            observed = try inspectRootCodeSignature(
                appURL: appURL,
                mainExecutableRelativePath: manifest.executableName,
                scratchRootURL: scratchRootURL
            )
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect the prepared root signature: \(error)"
            )
        }
        guard observed == manifest.rootCodeSignature else {
            throw PlayCoverBackendError.cacheTampered(
                "prepared root signer, designated requirement, identifier, "
                    + "or CDHash changed"
            )
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isUppercaseHex(
        _ value: String,
        count: Int
    ) -> Bool {
        value.utf8.count == count
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 65 && $0.value <= 70)
            }
    }

    private static func normalizedCDHash(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.uppercased()
        guard (normalized.utf8.count == 40
                || normalized.utf8.count == 64),
              normalized.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57)
                      || ($0.value >= 65 && $0.value <= 70)
              }) else {
            return nil
        }
        return normalized
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

    private static func runtimeEvidence(
        frameworkPath: String
    ) throws -> PlayCoverUpstreamRuntimeEvidence {
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
            return try PlayCoverUpstreamEngine.runtimeEvidence(
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
        managedHomePath: String? = nil,
        stdioLog: PlayCoverStdioLogIdentity? = nil
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
        if let stdioLog {
            result["IOS_USE_PLAY_STDIO_LOG"] = "1"
            result["IOS_USE_PLAY_STDIO_LOG_PATH"] = stdioLog.path
            result["IOS_USE_PLAY_STDIO_LOG_DEVICE"] =
                String(stdioLog.device)
            result["IOS_USE_PLAY_STDIO_LOG_INODE"] =
                String(stdioLog.inode)
        }
        return result
    }

    static func launchConfigurationEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment,
        sessionID: String,
        runtimeSocketPath: String,
        managedHomePath: String,
        stdioLog: PlayCoverStdioLogIdentity? = nil
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
                managedHomePath: managedHomePath,
                stdioLog: stdioLog
            )
        ) { _, allowed in allowed }
        return result
    }

    static func validateHello(
        _ payload: PlayCoverRuntimeHelloPayload,
        sessionID: String,
        manifest: PlayCoverPrepareManifest,
        pid: Int32,
        stdioLog: PlayCoverStdioLogIdentity?
    ) throws -> PlayCoverHello {
        try validateStdio(
            payload.stdio,
            expected: stdioLog
        )
        let geometry = payload.geometry
        let expectedLogicalWidth = Double(IOSUsePlayDeviceLogicalWidth)
        let expectedLogicalHeight = Double(IOSUsePlayDeviceLogicalHeight)
        let expectedScale = Double(IOSUsePlayDeviceScale)
        let expectedNativeWidth = Double(IOSUsePlayDeviceNativeWidth)
        let expectedNativeHeight = Double(IOSUsePlayDeviceNativeHeight)
        guard payload.pid == pid,
              payload.bundleIdentifier == manifest.bundleIdentifier,
              canonicalPath(payload.executablePath)
                == canonicalPath(manifest.executablePath) else {
            throw PlayCoverBackendError.verificationFailed(
                "authenticated Runtime hello identity does not match "
                    + "the launched prepared generation"
            )
        }
        guard runtimeGeometryApproximatelyEqual(
                  geometry.logical.width,
                  expectedLogicalWidth
              ),
              runtimeGeometryApproximatelyEqual(
                  geometry.logical.height,
                  expectedLogicalHeight
              ),
              runtimeGeometryApproximatelyEqual(
                  geometry.native.width,
                  expectedNativeWidth
              ),
              runtimeGeometryApproximatelyEqual(
                  geometry.native.height,
                  expectedNativeHeight
              ),
              runtimeGeometryApproximatelyEqual(
                  geometry.scale,
                  expectedScale
              ) else {
            throw PlayCoverBackendError.verificationFailed(
                "authenticated Runtime hello fixed-device geometry "
                    + "mismatch: logical=\(geometry.logical.width)x"
                    + "\(geometry.logical.height), native="
                    + "\(geometry.native.width)x"
                    + "\(geometry.native.height), scale="
                    + "\(geometry.scale); expected="
                    + "\(expectedLogicalWidth)x"
                    + "\(expectedLogicalHeight)@\(expectedScale)x "
                    + "(\(expectedNativeWidth)x"
                    + "\(expectedNativeHeight) native)"
            )
        }
        guard payload.stage == "ready",
              runtimeGeometryApproximatelyEqual(
                  geometry.window.width,
                  expectedLogicalWidth
              ),
              runtimeGeometryApproximatelyEqual(
                  geometry.window.height,
                  expectedLogicalHeight
              ) else {
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
                "Runtime hello stage/window is not ready for the fixed "
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

    private static func runtimeGeometryApproximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        abs(lhs - rhs) <= 0.01
    }

    static func validateStdio(
        _ state: PlayCoverRuntimeStdioState?,
        expected: PlayCoverStdioLogIdentity?
    ) throws {
        if let expected {
            guard let state else {
                throw PlayCoverBackendError.stdioLogFailed(
                    "Runtime hello omitted stdio initialization evidence"
                )
            }
            guard state.status == "redirected",
                  state.path.map(canonicalPath)
                    == canonicalPath(expected.path),
                  state.device == expected.device,
                  state.inode == expected.inode,
                  state.failureStage == nil,
                  state.errorNumber == nil else {
                throw PlayCoverBackendError.stdioLogFailed(
                    "Runtime stdio redirection did not match the "
                        + "requested per-session log: status="
                        + "\(state.status), stage="
                        + "\(state.failureStage ?? "none"), errno="
                        + "\(state.errorNumber.map(String.init) ?? "none")"
                )
            }
            return
        }
        // Schema-v3 Runtime generations prepared before --log do not carry
        // this optional field. Preserve bare-start reuse for an unlogged
        // session; a logged start still requires exact evidence above.
        guard let state else {
            return
        }
        guard state.status == "disabled",
              state.path == nil,
              state.device == nil,
              state.inode == nil,
              state.failureStage == nil,
              state.errorNumber == nil else {
            throw PlayCoverBackendError.stdioLogFailed(
                "Runtime stdio redirection was active without --log"
            )
        }
    }

    static func runtimeHelloFailureIsTerminal(
        _ error: Error
    ) -> Bool {
        if let runtimeError = error as? PlayCoverRuntimeClientError {
            switch runtimeError {
            case .socketCreateFailed,
                 .socketOptionFailed,
                 .connectFailed,
                 .writeFailed,
                 .readFailed,
                 .timeout,
                 .unexpectedEOF:
                // Runtime startup can transiently leave its endpoint absent
                // or interrupt the one in-flight hello. Retry only these
                // transport failures inside the existing launch deadline.
                return false
            case .remoteError(_, _, let details):
                // A Runtime owns the semantics of its typed failure. It must
                // explicitly mark the failure both retryable and non-fatal.
                return !(
                    details?.retryable == true
                        && details?.fatal == false
                )
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
                 .alertRefreshUnsupportedByRuntime,
                 .malformedResponse:
                return true
            }
        }
        guard let backendError = error as? PlayCoverBackendError else {
            // Do not silently turn an unclassified programming or system
            // failure into a retry loop.
            return true
        }
        switch backendError {
        case .launchFailed:
            // Hello stage/window readiness can still converge while the App
            // is entering its ready state. Authenticated fixed-device
            // geometry mismatches use verificationFailed and are terminal.
            return false
        case .stdioLogFailed:
            // Constructor stdio state is immutable. Repeating hello cannot
            // repair a missing, failed, or mismatched exact log identity.
            return true
        case .invalidApp,
             .unsupportedMachO,
             .malformedMachO,
             .encryptedMachO,
             .duplicateRuntimeLoad,
             .machOTransformFailed,
             .entitlementFailed,
             .codeSigningFailed,
             .outputExists,
             .missingRuntime,
             .prepareFailed,
             .verificationFailed,
             .cacheTampered,
             .launchTimedOut,
             .terminateFailed,
             .capabilityUnavailable:
            return true
        }
    }

    private static func writeGenerationSidecars(
        manifest: PlayCoverPrepareManifest,
        actualAppURL: URL
    ) throws {
        let generation = actualAppURL.deletingLastPathComponent()
        let sidecars = try generationSidecars(manifest: manifest)
        try writeAtomically(
            sidecars.manifestData,
            to: generation.appendingPathComponent(manifestFilename)
        )
        try writeAtomically(
            canonicalJSON(sidecars.completed),
            to: generation.appendingPathComponent(completedFilename)
        )
    }

    static func generationSidecars(
        manifest: PlayCoverPrepareManifest
    ) throws -> (
        manifestData: Data,
        completed: PlayCoverCompletedGeneration
    ) {
        let manifestData = try canonicalJSON(manifest)
        let executableSHA256 = try finalInspectionMachOHash(
            manifest: manifest,
            label: "main executable"
        ) {
            $0.relativePath == manifest.executableName
        }
        let runtimePrefix =
            "Frameworks/\(manifest.runtimeFrameworkName)/"
        let runtimeSHA256 = try finalInspectionMachOHash(
            manifest: manifest,
            label: "embedded Runtime executable"
        ) {
            $0.relativePath.hasPrefix(runtimePrefix)
                && $0.relativePath.split(separator: "/").last
                    == Substring(runtimeExecutableName)
        }
        let completed = PlayCoverCompletedGeneration(
            schemaVersion: 4,
            generationKey: manifest.generationKey,
            manifestSHA256: sha256(manifestData),
            executableSHA256: executableSHA256,
            runtimeSHA256: runtimeSHA256
        )
        return (manifestData, completed)
    }

    private static func finalInspectionMachOHash(
        manifest: PlayCoverPrepareManifest,
        label: String,
        matching: (PlayCoverMachOInspection) -> Bool
    ) throws -> String {
        let machOs = manifest.machOs.filter(matching)
        guard machOs.count == 1,
              let machO = machOs.first,
              isSHA256(machO.fileSHA256) else {
            throw PlayCoverBackendError.verificationFailed(
                "final prepared inspection does not uniquely seal \(label)"
            )
        }
        let inventory = manifest.inventory.filter {
            $0.relativePath == machO.relativePath
        }
        guard inventory.count == 1,
              let entry = inventory.first,
              entry.kind == "regularFile",
              entry.sha256 == machO.fileSHA256 else {
            throw PlayCoverBackendError.verificationFailed(
                "final prepared inventory does not seal \(label)"
            )
        }
        return machO.fileSHA256
    }

    @discardableResult
    static func validateManifest(
        _ manifest: PlayCoverPrepareManifest,
        appURL: URL,
        expectedGenerationIdentity:
            PlayCoverGenerationIdentity? = nil
    ) throws -> PlayCoverGenerationIdentity {
        manifestValidationObserverForTesting?()
        guard manifest.schemaVersion == 4,
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
              !manifest.sourceInventory.isEmpty,
              !manifest.sourceMachOs.isEmpty,
              Set(manifest.sourceInventory.map(\.relativePath)).count
                == manifest.sourceInventory.count,
              Set(manifest.sourceMachOs.map(\.relativePath)).count
                == manifest.sourceMachOs.count,
              isValidSigningIdentity(manifest.signingIdentity),
              isValidRootCodeSignature(
                manifest.rootCodeSignature,
                signingIdentity: manifest.signingIdentity,
                bundleIdentifier: manifest.bundleIdentifier
              ) else {
            throw PlayCoverBackendError.verificationFailed(
                "manifest schema or identity is invalid"
            )
        }
        let observedGeneration =
            PlayCoverGenerationIdentity(manifest: manifest)
        if let expectedGenerationIdentity {
            guard expectedGenerationIdentity == observedGeneration else {
                throw PlayCoverBackendError.verificationFailed(
                    "manifest generation does not match trusted "
                        + "preparation evidence"
                )
            }
            return expectedGenerationIdentity
        }
        guard manifest.generationKey == makeGenerationKey(
                sourceContentHash: manifest.sourceContentHash,
                runtimeBuildHash: manifest.runtimeBuildHash,
                prepareRevision: manifest.prepareRevision,
                signerPublicKeySPKISHA256:
                    manifest.signingIdentity.publicKeySPKISHA256,
                signerCertificateSHA256:
                    manifest.signingIdentity.certificateSHA256,
                signingPolicyRevision:
                    manifest.signingIdentity.policy.revision
              ) else {
            throw PlayCoverBackendError.verificationFailed(
                "manifest generation key is invalid"
            )
        }
        return observedGeneration
    }

    private struct RecordedCodeVerification {
        let fileSHA256: [String: String]
        let executablePaths: Set<String>
    }

    private final class RecordedHashesResultBox:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var storage: Result<[String: String], Error>?

        func set(_ result: Result<[String: String], Error>) {
            lock.lock()
            storage = result
            lock.unlock()
        }

        func get() throws -> [String: String] {
            lock.lock()
            let result = storage
            lock.unlock()
            guard let result else {
                throw PlayCoverBackendError.cacheTampered(
                    "concurrent executable hash verification did not finish"
                )
            }
            return try result.get()
        }
    }

    private final class RecordedSignaturesResultBox:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var nextIndex = 0
        private var storage: [Result<Void, Error>?]

        init(count: Int) {
            storage = Array(repeating: nil, count: count)
        }

        func takeNextIndex() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard nextIndex < storage.count else {
                return nil
            }
            defer { nextIndex += 1 }
            return nextIndex
        }

        func set(_ result: Result<Void, Error>, at index: Int) {
            lock.lock()
            storage[index] = result
            lock.unlock()
        }

        func getInOriginalOrder() throws {
            lock.lock()
            let results = storage
            lock.unlock()
            for (index, result) in results.enumerated() {
                guard let result else {
                    throw PlayCoverBackendError.cacheTampered(
                        "concurrent nested signature verification did not "
                            + "finish at signing-order index \(index)"
                    )
                }
                try result.get()
            }
        }
    }

    private static func withStableGenerationDescriptor<T>(
        for app: URL,
        _ body: (Int32, URL) throws -> T
    ) throws -> T {
        let generationURL = app.deletingLastPathComponent()
        let generationDescriptor = Darwin.open(
            generationURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard generationDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open generation directory without following links: "
                    + "\(generationURL.path), errno \(errno)"
            )
        }
        defer { Darwin.close(generationDescriptor) }
        var openedStatus = stat()
        guard fstat(generationDescriptor, &openedStatus) == 0,
              openedStatus.st_mode & S_IFMT == S_IFDIR,
              openedStatus.st_uid == geteuid(),
              openedStatus.st_mode & 0o077 == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "generation metadata directory is not owner-only"
            )
        }
        try emitFastVerifyEvent(.afterGenerationOpen)
        let result = try body(generationDescriptor, generationURL)
        var finalStatus = stat()
        var pathStatus = stat()
        guard fstat(generationDescriptor, &finalStatus) == 0,
              lstat(generationURL.path, &pathStatus) == 0,
              sameRecordedIdentity(openedStatus, finalStatus),
              sameRecordedIdentity(openedStatus, pathStatus) else {
            throw PlayCoverBackendError.cacheTampered(
                "generation directory changed during verification"
            )
        }
        return result
    }

    private static func withPreparedAppDescriptor<T>(
        generationDescriptor: Int32,
        generationURL: URL,
        app: URL,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let appName = app.lastPathComponent
        guard !appName.isEmpty,
              appName != ".",
              appName != "..",
              app.deletingLastPathComponent().standardizedFileURL.path
                == generationURL.standardizedFileURL.path else {
            throw PlayCoverBackendError.cacheTampered(
                "prepared App is not a direct generation child"
            )
        }
        let appDescriptor = Darwin.openat(
            generationDescriptor,
            appName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard appDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open the prepared App root from its generation: "
                    + "errno \(errno)"
            )
        }
        defer { Darwin.close(appDescriptor) }
        var openedStatus = stat()
        guard fstat(appDescriptor, &openedStatus) == 0,
              openedStatus.st_mode & S_IFMT == S_IFDIR else {
            throw PlayCoverBackendError.cacheTampered(
                "prepared App root is not a stable directory"
            )
        }
        try emitFastVerifyEvent(.afterPreparedAppOpen)
        let result = try body(appDescriptor)
        var finalStatus = stat()
        var pathStatus = stat()
        guard fstat(appDescriptor, &finalStatus) == 0,
              fstatat(
                generationDescriptor,
                appName,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameRecordedIdentity(openedStatus, finalStatus),
              sameRecordedIdentity(openedStatus, pathStatus) else {
            throw PlayCoverBackendError.cacheTampered(
                "prepared App root changed during verification"
            )
        }
        return result
    }

    @discardableResult
    private static func verifyRecordedCodeObjects(
        app: URL,
        manifest: PlayCoverPrepareManifest,
        fast: Bool,
        requiredHashes: Set<String> = []
    ) throws -> RecordedCodeVerification {
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
        return try verifyRecordedCodeObjects(
            app: app,
            borrowedAppDescriptor: appDescriptor,
            manifest: manifest,
            fast: fast,
            requiredHashes: requiredHashes
        )
    }

    @discardableResult
    private static func verifyRecordedCodeObjects(
        app: URL,
        borrowedAppDescriptor appDescriptor: Int32,
        manifest: PlayCoverPrepareManifest,
        fast: Bool,
        requiredHashes: Set<String> = []
    ) throws -> RecordedCodeVerification {
        var codePaths = Set(manifest.inventory.compactMap {
            $0.codeObjectKind == nil ? nil : $0.relativePath
        })
        codePaths.insert(".")
        let orderedCodePaths = manifest.signingOrder
        let signaturePaths = Set(orderedCodePaths)
        let requiredBundlePaths = Set(manifest.inventory.compactMap {
            entry -> String? in
            guard entry.kind == "directory",
                  entry.codeObjectKind?.hasSuffix("Bundle") == true else {
                return nil
            }
            return entry.relativePath
        }).union(["."])
        let requiredIndependentPaths = Set(manifest.inventory.compactMap {
            entry -> String? in
            guard let codeObjectKind = entry.codeObjectKind,
                  entry.relativePath != manifest.executableName else {
                return nil
            }
            if codeObjectKind.hasSuffix("Executable"),
               requiredBundlePaths.contains(where: {
                   $0 != "."
                       && entry.relativePath.hasPrefix($0 + "/")
               }) {
                return nil
            }
            return entry.relativePath
        }).union(["."])
        guard orderedCodePaths.last == ".",
              signaturePaths.count == orderedCodePaths.count,
              signaturePaths.isSubset(of: codePaths),
              requiredBundlePaths.isSubset(of: signaturePaths),
              requiredIndependentPaths.isSubset(of: signaturePaths),
              !signaturePaths.contains(manifest.executableName) else {
            throw PlayCoverBackendError.cacheTampered(
                "manifest signing order is not a valid inside-out plan"
            )
        }
        let relevantEntries = manifest.inventory.filter { entry in
            if !fast { return true }
            return entry.relativePath == "Info.plist"
                || requiredHashes.contains(entry.relativePath)
                || entry.codeObjectKind != nil
        }
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
        let requiredHashEntries = relevantEntries.filter {
            requiredHashes.contains($0.relativePath)
        }
        guard requiredHashes.isSubset(
                of: Set(requiredHashEntries.map(\.relativePath))
              ),
              fast || requiredHashes.isSubset(of: Set(hashes.keys)) else {
            throw PlayCoverBackendError.cacheTampered(
                "manifest is missing a required executable hash entry"
            )
        }
        let stableAppURL =
            try PlayCoverManagedAppService.ownedDirectoryDescriptorPath(
                appDescriptor,
                label: "prepared App root"
            )
        if fast, !requiredHashEntries.isEmpty {
            hashes.merge(
                try verifyNestedCodeSignaturesWhileHashing(
                    entries: requiredHashEntries,
                    nestedCodePaths: Array(orderedCodePaths.dropLast()),
                    app: app,
                    appDescriptor: appDescriptor,
                    expectedStatuses: verifiedStatuses,
                    stableAppURL: stableAppURL
                ),
                uniquingKeysWith: { _, verified in verified }
            )
            try verifyRecordedCodeSignature(
                ".",
                appDescriptor: appDescriptor,
                expectedStatuses: verifiedStatuses,
                stableAppURL: stableAppURL
            )
        } else {
            try verifyRecordedCodeSignatures(
                orderedCodePaths,
                app: app,
                appDescriptor: appDescriptor,
                expectedStatuses: verifiedStatuses,
                stableAppURL: stableAppURL
            )
        }
        try verifyStableRootSignature(
            appURL: stableAppURL,
            scratchRootURL: app
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            manifest: manifest
        )
        guard requiredHashes.isSubset(of: Set(hashes.keys)) else {
            throw PlayCoverBackendError.cacheTampered(
                "manifest is missing a required executable hash entry"
            )
        }
        for relative in codePaths.subtracting(signaturePaths).sorted() {
            guard
                let expected = verifiedStatuses[relative],
                try recordedPathStillHasIdentity(
                    relative,
                    appDescriptor: appDescriptor,
                    expected: expected
                )
            else {
                throw PlayCoverBackendError.cacheTampered(
                    "recorded code object changed during signature plan: "
                        + relative
                )
            }
        }
        return RecordedCodeVerification(
            fileSHA256: hashes,
            executablePaths: executablePaths
        )
    }

    private static func verifyNestedCodeSignaturesWhileHashing(
        entries: [PlayCoverInventoryEntry],
        nestedCodePaths: [String],
        app: URL,
        appDescriptor: Int32,
        expectedStatuses: [String: stat],
        stableAppURL: URL
    ) throws -> [String: String] {
        let hashes = RecordedHashesResultBox()
        let work = DispatchGroup()
        work.enter()
        fastVerifyHashQueue.async {
            defer { work.leave() }
            hashes.set(
                Result {
                    try verifyRecordedHashes(
                        entries,
                        appDescriptor: appDescriptor,
                        expectedStatuses: expectedStatuses
                    )
                }
            )
        }
        let signature = Result {
            try verifyRecordedCodeSignaturesConcurrently(
                nestedCodePaths,
                app: app,
                appDescriptor: appDescriptor,
                expectedStatuses: expectedStatuses,
                stableAppURL: stableAppURL
            )
        }
        work.wait()

        // Hashes ran before every signature in the former sequential
        // implementation. Preserve their failure precedence while
        // overlapping only read-only nested checks. The root signature still
        // runs after this join as the final temporal seal for the whole App.
        let result = try hashes.get()
        try signature.get()
        return result
    }

    private static func verifyRecordedCodeSignaturesConcurrently(
        _ relativePaths: [String],
        app: URL,
        appDescriptor: Int32,
        expectedStatuses: [String: stat],
        stableAppURL: URL
    ) throws {
        guard !relativePaths.isEmpty else {
            return
        }
        let results = RecordedSignaturesResultBox(
            count: relativePaths.count
        )
        let work = DispatchGroup()
        let workerCount = min(
            fastVerifyNestedSignatureWorkerLimit,
            relativePaths.count
        )
        for _ in 0..<workerCount {
            work.enter()
            fastVerifyNestedSignatureQueue.async {
                defer { work.leave() }
                while let index = results.takeNextIndex() {
                    let relative = relativePaths[index]
                    results.set(
                        Result {
                            try verifyRecordedCodeSignatures(
                                [relative],
                                app: app,
                                appDescriptor: appDescriptor,
                                expectedStatuses: expectedStatuses,
                                stableAppURL: stableAppURL
                            )
                        },
                        at: index
                    )
                }
            }
        }
        work.wait()
        try results.getInOriginalOrder()
    }

    private static func verifyRecordedHashes(
        _ entries: [PlayCoverInventoryEntry],
        appDescriptor: Int32,
        expectedStatuses: [String: stat]
    ) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for entry in entries {
            let result = try verifyRecordedEntry(
                entry,
                appDescriptor: appDescriptor,
                hashContents: true
            )
            guard let expected = expectedStatuses[entry.relativePath],
                  sameRecordedIdentity(expected, result.status),
                  let hash = result.sha256 else {
                throw PlayCoverBackendError.cacheTampered(
                    "recorded file changed before concurrent hashing: "
                        + entry.relativePath
                )
            }
            hashes[entry.relativePath] = hash
        }
        return hashes
    }

    private static func verifyRecordedCodeSignatures(
        _ relativePaths: [String],
        app: URL,
        appDescriptor: Int32,
        expectedStatuses: [String: stat],
        stableAppURL: URL
    ) throws {
        for relative in relativePaths {
            if relative != "." {
                _ = try recordedURL(
                    app: app,
                    relativePath: relative
                )
            }
            try verifyRecordedCodeSignature(
                relative,
                appDescriptor: appDescriptor,
                expectedStatuses: expectedStatuses,
                stableAppURL: stableAppURL
            )
        }
    }

    private static func verifyRecordedCodeSignature(
        _ relative: String,
        appDescriptor: Int32,
        expectedStatuses: [String: stat],
        stableAppURL: URL
    ) throws {
        try emitFastVerifyEvent(.beforeCodeSignature(relative))
        let result = try Shell.runWithResult(
            "/usr/bin/codesign",
            arguments: ["--verify", "--strict", relative],
            cwd: stableAppURL.path
        )
        guard result.exitCode == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "recorded code object signature is invalid "
                    + "(\(relative)): \(result.stderr)"
            )
        }
        try emitFastVerifyEvent(.afterCodeSignature(relative))
        guard
            let expected = expectedStatuses[relative],
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

    private static func sameDirectoryAuthorityIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
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

    private static func readJSONMetadata<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        maximumBytes: Int
    ) throws -> DecodedMetadata<T> {
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
        return try readJSONMetadata(
            type,
            generationDescriptor: parentDescriptor,
            generationURL: parent,
            filename: url.lastPathComponent,
            maximumBytes: maximumBytes
        )
    }

    private static func readJSONMetadata<T: Decodable>(
        _ type: T.Type,
        generationDescriptor: Int32,
        generationURL: URL,
        filename: String,
        maximumBytes: Int
    ) throws -> DecodedMetadata<T> {
        try emitFastVerifyEvent(.beforeMetadataOpen(filename))
        do {
            let data = try PlayCoverManagedAppService.readOwnedRegularFile(
                parentDescriptor: generationDescriptor,
                name: filename,
                maximumBytes: maximumBytes,
                afterOpen: {
                    try emitFastVerifyEvent(
                        .afterMetadataOpen(filename)
                    )
                }
            )
            guard !data.isEmpty else {
                throw PlayCoverBackendError.cacheTampered(
                    "\(filename) is empty"
                )
            }
            try emitFastVerifyEvent(.afterMetadataRead(filename))
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
                "cannot decode "
                    + "\(generationURL.appendingPathComponent(filename).path): "
                    + "\(error)"
            )
        }
    }

    private static func emitFastVerifyEvent(
        _ event: FastVerifyEvent
    ) throws {
        try fastVerifyEventOverrideForTesting?(event)
    }

    private static func emitLaunchIntegrityEvent(
        _ event: LaunchIntegrityEvent
    ) throws {
        try launchIntegrityEventOverrideForTesting?(event)
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

    private static func pendingLaunchOwner(
        _ identity: LaunchedApplicationIdentity
    ) -> PlayCoverPendingLaunchStore.Owner? {
        guard let processBirthMicroseconds =
                identity.processStartTimeMicroseconds,
              processBirthMicroseconds > 0 else {
            return nil
        }
        let source:
            PlayCoverPendingLaunchStore.OwnerSource
        switch identity.source {
        case .workspaceCallback:
            source = .workspaceCallback
        case .authenticatedRuntime:
            source = .authenticatedRuntime
        case .observedCandidate:
            return nil
        }
        return PlayCoverPendingLaunchStore.Owner(
            pid: identity.pid,
            processBirthMicroseconds:
                processBirthMicroseconds,
            source: source
        )
    }

    private static func persistPendingLaunchOwner(
        _ owner: PlayCoverPendingLaunchStore.Owner,
        identity: LaunchedApplicationIdentity,
        sessionID: String,
        callbackSucceeded: Bool,
        paths: IOSUsePaths
    ) throws {
        do {
            try revalidatePendingLaunchIdentity(identity)
        } catch {
            throw PendingOwnedLaunchError(
                identity: identity,
                underlying: error,
                shouldRetryDurableOwnership: false
            )
        }
        #if DEBUG && canImport(Darwin)
        PlayCoverLaunchCrashCut.hit(.beforeOwnerDurable)
        switch identity.source {
        case .workspaceCallback:
            PlayCoverLaunchCrashCut.hit(
                .beforeCallbackOwnerDurable
            )
        case .authenticatedRuntime:
            PlayCoverLaunchCrashCut.hit(
                .beforeRuntimeOwnerDurable
            )
        case .observedCandidate:
            break
        }
        #endif
        do {
            _ = try PlayCoverPendingLaunchStore.markOwned(
                sessionID: sessionID,
                owner: owner,
                callbackSucceeded: callbackSucceeded,
                paths: paths
            )
        } catch {
            throw PendingOwnedLaunchError(
                identity: identity,
                underlying: error,
                shouldRetryDurableOwnership: true
            )
        }
        #if DEBUG && canImport(Darwin)
        PlayCoverLaunchCrashCut.hit(.afterOwnerDurable)
        switch identity.source {
        case .workspaceCallback:
            PlayCoverLaunchCrashCut.hit(
                .afterCallbackOwnerDurable
            )
        case .authenticatedRuntime:
            PlayCoverLaunchCrashCut.hit(
                .afterRuntimeOwnerDurable
            )
        case .observedCandidate:
            break
        }
        #endif
        do {
            try revalidatePendingLaunchIdentity(identity)
        } catch {
            throw PendingOwnedLaunchError(
                identity: identity,
                underlying: error,
                shouldRetryDurableOwnership: false
            )
        }
    }

    private static func boundedPendingLaunchError(
        _ error: Error
    ) -> String {
        let description = String(describing: error)
        if description.utf8.count <= 4_096 {
            return description
        }
        return String(
            decoding: description.utf8.prefix(4_000),
            as: UTF8.self
        )
    }

    struct SessionLaunchAlias: Equatable {
        let rootURL: URL
        let bundleURL: URL
    }

    final class FastVerifiedLaunchCapability {
        fileprivate var generationDescriptor: Int32
        fileprivate let generationURL: URL
        fileprivate let generationStatus: stat
        fileprivate var appDescriptor: Int32
        fileprivate let appURL: URL
        fileprivate let appStatus: stat
        fileprivate let entries: [AnchoredLaunchAliasEntry]

        fileprivate init(
            generationDescriptor: Int32,
            generationURL: URL,
            generationStatus: stat,
            appDescriptor: Int32,
            appURL: URL,
            appStatus: stat,
            entries: [AnchoredLaunchAliasEntry]
        ) {
            self.generationDescriptor = generationDescriptor
            self.generationURL = generationURL
            self.generationStatus = generationStatus
            self.appDescriptor = appDescriptor
            self.appURL = appURL
            self.appStatus = appStatus
            self.entries = entries
        }

        func close() {
            if appDescriptor >= 0 {
                Darwin.close(appDescriptor)
                appDescriptor = -1
            }
            if generationDescriptor >= 0 {
                Darwin.close(generationDescriptor)
                generationDescriptor = -1
            }
        }

        deinit {
            close()
        }
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

    private struct PendingOwnedLaunchError:
        Error,
        CustomStringConvertible
    {
        let identity: LaunchedApplicationIdentity
        let underlying: Error
        let shouldRetryDurableOwnership: Bool

        var description: String {
            "the exact PlayCover process was identified, but "
                + "pending-launch ownership could not be safely "
                + "committed: \(underlying)"
        }
    }

    private struct LaunchAliasEntry {
        let name: String
        let destination: String
    }

    fileprivate struct AnchoredLaunchAliasEntry {
        let name: String
        let destination: String
        let sourceStatus: stat
    }

    private final class SessionLaunchAliasCapability {
        let alias: SessionLaunchAlias
        let aliasName: String
        var rootDescriptor: Int32
        let rootStatus: stat
        var aliasDescriptor: Int32
        let aliasStatus: stat

        init(
            alias: SessionLaunchAlias,
            aliasName: String,
            rootDescriptor: Int32,
            rootStatus: stat,
            aliasDescriptor: Int32,
            aliasStatus: stat
        ) {
            self.alias = alias
            self.aliasName = aliasName
            self.rootDescriptor = rootDescriptor
            self.rootStatus = rootStatus
            self.aliasDescriptor = aliasDescriptor
            self.aliasStatus = aliasStatus
        }

        func close() {
            if aliasDescriptor >= 0 {
                Darwin.close(aliasDescriptor)
                aliasDescriptor = -1
            }
            if rootDescriptor >= 0 {
                Darwin.close(rootDescriptor)
                rootDescriptor = -1
            }
        }

        deinit {
            close()
        }
    }

    private static func anchoredLaunchAliasEntries(
        app: URL,
        appDescriptor: Int32
    ) throws -> [AnchoredLaunchAliasEntry] {
        let names = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: appDescriptor,
                label: "prepared App launch inventory"
            ).sorted()
        guard !names.isEmpty,
              names.allSatisfy(isSafeLaunchAliasName) else {
            throw PlayCoverBackendError.cacheTampered(
                "the prepared App has no safe top-level launch inventory"
            )
        }
        return try names.map { name in
            var status = stat()
            guard fstatat(
                    appDescriptor,
                    name,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  status.st_uid == geteuid() else {
                throw PlayCoverBackendError.cacheTampered(
                    "cannot capture prepared App launch entry: \(name)"
                )
            }
            return AnchoredLaunchAliasEntry(
                name: name,
                destination: app.appendingPathComponent(name).path,
                sourceStatus: status
            )
        }
    }

    private static func validateFastVerifiedLaunchCapability(
        _ capability: FastVerifiedLaunchCapability
    ) throws {
        guard capability.generationDescriptor >= 0,
              capability.appDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "fast-verified launch capability was already consumed"
            )
        }
        var generationDescriptorStatus = stat()
        var generationPathStatus = stat()
        var appDescriptorStatus = stat()
        var appPathStatus = stat()
        guard fstat(
                capability.generationDescriptor,
                &generationDescriptorStatus
              ) == 0,
              lstat(
                capability.generationURL.path,
                &generationPathStatus
              ) == 0,
              sameRecordedIdentity(
                capability.generationStatus,
                generationDescriptorStatus
              ),
              sameRecordedIdentity(
                capability.generationStatus,
                generationPathStatus
              ),
              fstat(capability.appDescriptor, &appDescriptorStatus) == 0,
              fstatat(
                capability.generationDescriptor,
                capability.appURL.lastPathComponent,
                &appPathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameRecordedIdentity(
                capability.appStatus,
                appDescriptorStatus
              ),
              sameRecordedIdentity(
                capability.appStatus,
                appPathStatus
              ) else {
            throw PlayCoverBackendError.cacheTampered(
                "fast-verified generation/App changed before launch "
                    + "submission completed"
            )
        }
        try validateAnchoredLaunchAliasEntries(
            capability.entries,
            appDescriptor: capability.appDescriptor
        )
    }

    private static func validateAnchoredLaunchAliasEntries(
        _ entries: [AnchoredLaunchAliasEntry],
        appDescriptor: Int32
    ) throws {
        let actualNames = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: appDescriptor,
                label: "fast-verified prepared App"
            )
        let expectedNames = Set(entries.map(\.name))
        guard actualNames.count == expectedNames.count,
              Set(actualNames) == expectedNames else {
            throw PlayCoverBackendError.cacheTampered(
                "prepared App top-level inventory changed before launch"
            )
        }
        for entry in entries {
            var current = stat()
            guard fstatat(
                    appDescriptor,
                    entry.name,
                    &current,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  sameRecordedIdentity(entry.sourceStatus, current) else {
                throw PlayCoverBackendError.cacheTampered(
                    "prepared App top-level entry changed before launch: "
                        + entry.name
                )
            }
        }
    }

    private static func openSessionLaunchAliasCapability(
        alias: SessionLaunchAlias
    ) throws -> SessionLaunchAliasCapability {
        let aliasName = alias.bundleURL.lastPathComponent
        guard isSafeLaunchAliasName(aliasName),
              alias.bundleURL.deletingLastPathComponent()
                .standardizedFileURL.path
                == alias.rootURL.standardizedFileURL.path else {
            throw PlayCoverBackendError.cacheTampered(
                "the session launch alias is not a direct safe child"
            )
        }
        let rootDescriptor = Darwin.open(
            alias.rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot anchor the launch alias root: errno \(errno)"
            )
        }
        var rootStatus = stat()
        var rootPathStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              lstat(alias.rootURL.path, &rootPathStatus) == 0,
              sameDirectoryAuthorityIdentity(
                rootStatus,
                rootPathStatus
              ) else {
            Darwin.close(rootDescriptor)
            throw PlayCoverBackendError.cacheTampered(
                "the launch alias root changed while it was opened"
            )
        }
        do {
            try validateLaunchAliasRootStatus(rootStatus)
        } catch {
            Darwin.close(rootDescriptor)
            throw error
        }
        let aliasDescriptor = Darwin.openat(
            rootDescriptor,
            aliasName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard aliasDescriptor >= 0 else {
            Darwin.close(rootDescriptor)
            throw PlayCoverBackendError.cacheTampered(
                "cannot anchor the session launch alias: errno \(errno)"
            )
        }
        var aliasStatus = stat()
        var aliasPathStatus = stat()
        guard fstat(aliasDescriptor, &aliasStatus) == 0,
              fstatat(
                rootDescriptor,
                aliasName,
                &aliasPathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameRecordedIdentity(aliasStatus, aliasPathStatus),
              aliasStatus.st_mode & S_IFMT == S_IFDIR,
              aliasStatus.st_uid == geteuid(),
              aliasStatus.st_mode & 0o022 == 0 else {
            Darwin.close(aliasDescriptor)
            Darwin.close(rootDescriptor)
            throw PlayCoverBackendError.cacheTampered(
                "the session launch alias is not an owned real directory"
            )
        }
        return SessionLaunchAliasCapability(
            alias: alias,
            aliasName: aliasName,
            rootDescriptor: rootDescriptor,
            rootStatus: rootStatus,
            aliasDescriptor: aliasDescriptor,
            aliasStatus: aliasStatus
        )
    }

    private static func validateSessionLaunchAliasCapability(
        _ aliasCapability: SessionLaunchAliasCapability,
        expectedEntries: [LaunchAliasEntry]
    ) throws {
        try validateSessionLaunchAliasAuthority(
            aliasCapability
        )
        let expectedNames = Set(expectedEntries.map(\.name))
        let actualNames = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: aliasCapability.aliasDescriptor,
                label: "session launch alias"
            )
        guard actualNames.count == expectedNames.count,
              Set(actualNames) == expectedNames else {
            throw PlayCoverBackendError.cacheTampered(
                "the session launch alias top-level inventory changed"
            )
        }
        try validateSessionLaunchAliasEntries(
            actualNames,
            capability: aliasCapability,
            expectedEntries: expectedEntries
        )
    }

    private static func validateSessionLaunchAliasAuthority(
        _ aliasCapability: SessionLaunchAliasCapability
    ) throws {
        guard aliasCapability.rootDescriptor >= 0,
              aliasCapability.aliasDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "session launch alias capability was already consumed"
            )
        }
        var rootDescriptorStatus = stat()
        var rootPathStatus = stat()
        var aliasDescriptorStatus = stat()
        var aliasPathStatus = stat()
        guard fstat(
                aliasCapability.rootDescriptor,
                &rootDescriptorStatus
              ) == 0,
              lstat(
                aliasCapability.alias.rootURL.path,
                &rootPathStatus
              ) == 0,
              sameDirectoryAuthorityIdentity(
                aliasCapability.rootStatus,
                rootDescriptorStatus
              ),
              sameDirectoryAuthorityIdentity(
                aliasCapability.rootStatus,
                rootPathStatus
              ),
              fstat(
                aliasCapability.aliasDescriptor,
                &aliasDescriptorStatus
              ) == 0,
              fstatat(
                aliasCapability.rootDescriptor,
                aliasCapability.aliasName,
                &aliasPathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameRecordedIdentity(
                aliasCapability.aliasStatus,
                aliasDescriptorStatus
              ),
              sameRecordedIdentity(
                aliasCapability.aliasStatus,
                aliasPathStatus
              ) else {
            throw PlayCoverBackendError.cacheTampered(
                "the launch alias root/facade changed during submission"
            )
        }
    }

    private static func validateSessionLaunchAliasEntries(
        _ actualNames: [String],
        capability aliasCapability:
            SessionLaunchAliasCapability,
        expectedEntries: [LaunchAliasEntry]
    ) throws {
        let expected = Dictionary(
            uniqueKeysWithValues: expectedEntries.map {
                ($0.name, $0.destination)
            }
        )
        for name in actualNames {
            var linkStatus = stat()
            guard let destination = expected[name],
                  fstatat(
                    aliasCapability.aliasDescriptor,
                    name,
                    &linkStatus,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  linkStatus.st_mode & S_IFMT == S_IFLNK,
                  linkStatus.st_uid == geteuid(),
                  try anchoredSymbolicLinkDestination(
                    descriptor: aliasCapability.aliasDescriptor,
                    name: name
                  ) == destination else {
                throw PlayCoverBackendError.cacheTampered(
                    "the session launch alias entry changed: \(name)"
                )
            }
        }
    }

    private static func anchoredSymbolicLinkDestination(
        descriptor: Int32,
        name: String
    ) throws -> String {
        var buffer = [CChar](
            repeating: 0,
            count: Int(PATH_MAX) + 1
        )
        let count = Darwin.readlinkat(
            descriptor,
            name,
            &buffer,
            buffer.count - 1
        )
        guard count >= 0, count < buffer.count - 1 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot read anchored launch alias entry \(name)"
            )
        }
        buffer[Int(count)] = 0
        return String(cString: buffer)
    }

    private static func isSafeLaunchAliasName(
        _ name: String
    ) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }

    static func sessionLaunchAlias(
        sessionID: String
    ) -> SessionLaunchAlias {
        let root: URL
        if let launchAliasRootOverrideForTesting {
            root = launchAliasRootOverrideForTesting.standardizedFileURL
        } else {
            #if DEBUG && canImport(Darwin)
            if let crashAliasRoot =
                    PlayCoverLaunchCrashCut.launchAliasRoot {
                root = crashAliasRoot
            } else {
                root = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Applications/PlayCover",
                        isDirectory: true
                    )
            }
            #else
            root = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Applications/PlayCover",
                        isDirectory: true
                    )
            #endif
        }
        return SessionLaunchAlias(
            rootURL: root,
            bundleURL: root.appendingPathComponent(
                "a-\(sha256(Data(sessionID.utf8))).app",
                isDirectory: true
            )
        )
    }

    /// Pinned PlayCover launches a real `.app` directory whose top-level
    /// children are symlinks to the prepared App. Keep that exact facade
    /// shape, but give every ios-use session a private random identity and
    /// retain the prepared generation as the only session authority.
    static func createSessionLaunchAlias(
        manifest: PlayCoverPrepareManifest,
        sessionID: String
    ) throws -> SessionLaunchAlias {
        let entries = try launchAliasEntries(manifest: manifest)
        return try createSessionLaunchAlias(
            entries: entries,
            sessionID: sessionID,
            pendingLaunchPaths: nil
        )
    }

    private static func createSessionLaunchAlias(
        entries: [LaunchAliasEntry],
        sessionID: String,
        pendingLaunchPaths: IOSUsePaths?
    ) throws -> SessionLaunchAlias {
        let alias = sessionLaunchAlias(sessionID: sessionID)
        try ensureLaunchAliasRoot(alias.rootURL)
        var status = stat()
        guard lstat(alias.bundleURL.path, &status) != 0,
              errno == ENOENT else {
            throw PlayCoverBackendError.launchFailed(
                "the random session launch alias already exists"
            )
        }
        var createdAliasDirectory = false
        do {
            try FileManager.default.createDirectory(
                at: alias.bundleURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
            createdAliasDirectory = true
            for entry in entries {
                try FileManager.default.createSymbolicLink(
                    atPath: alias.bundleURL
                        .appendingPathComponent(entry.name).path,
                    withDestinationPath: entry.destination
                )
            }
            try syncSessionLaunchAlias(
                alias,
                expectedEntries: entries
            ) { capability in
                if let pendingLaunchPaths {
                    try recordPendingLaunchAlias(
                        capability,
                        entries: entries,
                        sessionID: sessionID,
                        paths: pendingLaunchPaths
                    )
                }
            }
            return alias
        } catch {
            if createdAliasDirectory {
                try? removePartialSessionLaunchAlias(alias)
            }
            if let backendError = error as? PlayCoverBackendError {
                throw backendError
            }
            throw PlayCoverBackendError.launchFailed(
                "cannot create the pinned PlayCover session launch "
                    + "alias: \(error)"
            )
        }
    }

    static func removeSessionLaunchAlias(
        sessionID: String,
        manifest: PlayCoverPrepareManifest
    ) throws {
        try removeSessionLaunchAlias(
            sessionLaunchAlias(sessionID: sessionID),
            manifest: manifest
        )
    }

    static func removeSessionLaunchAlias(
        _ alias: SessionLaunchAlias,
        manifest: PlayCoverPrepareManifest
    ) throws {
        var rootStatus = stat()
        if lstat(alias.rootURL.path, &rootStatus) != 0 {
            if errno == ENOENT {
                return
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect the launch alias root: errno \(errno)"
            )
        }
        try validateLaunchAliasRootStatus(rootStatus)
        var aliasStatus = stat()
        if lstat(alias.bundleURL.path, &aliasStatus) != 0 {
            if errno == ENOENT {
                return
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect the session launch alias: errno \(errno)"
            )
        }
        let expectedEntries = try launchAliasEntries(
            manifest: manifest
        )
        let capability = try openSessionLaunchAliasCapability(
            alias: alias
        )
        defer { capability.close() }
        try validateSessionLaunchAliasCapability(
            capability,
            expectedEntries: expectedEntries
        )
        try removeSessionLaunchAliasCapability(
            capability,
            expectedEntries: expectedEntries
        )
    }

    static func removeSessionLaunchAlias(
        pendingLaunch record:
            PlayCoverPendingLaunchStore.Record,
        manifest: PlayCoverPrepareManifest
    ) throws {
        guard record.phase == .confirmedStopped,
              record.appPath == manifest.preparedAppPath,
              record.bundleIdentifier
                == manifest.bundleIdentifier,
              record.executablePath == manifest.executablePath,
              record.generationKey == manifest.generationKey else {
            throw PlayCoverBackendError.cacheTampered(
                "pending launch does not match the prepared "
                    + "generation being cleaned"
            )
        }
        let alias = sessionLaunchAlias(
            sessionID: record.sessionID
        )
        guard alias.bundleURL.path == record.aliasPath else {
            throw PlayCoverBackendError.cacheTampered(
                "pending launch facade path changed"
            )
        }
        var rootStatus = stat()
        if lstat(alias.rootURL.path, &rootStatus) != 0 {
            if errno == ENOENT {
                return
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect the launch alias root: errno \(errno)"
            )
        }
        try validateLaunchAliasRootStatus(rootStatus)
        var aliasStatus = stat()
        if lstat(alias.bundleURL.path, &aliasStatus) != 0 {
            if errno == ENOENT {
                return
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect the session launch alias: errno \(errno)"
            )
        }
        guard let recordedDevice = record.aliasDevice,
              let recordedInode = record.aliasInode,
              let recordedInventory =
                record.aliasInventory else {
            // `intent` is durable before facade creation, including before
            // all symlinks exist. Since submission was never armed, a
            // current subset of immutable manifest entries can be removed
            // without inventing historical vnode evidence.
            let expectedEntries = try launchAliasEntries(
                manifest: manifest
            )
            let capability =
                try openSessionLaunchAliasCapability(
                    alias: alias
                )
            defer { capability.close() }
            try validateSessionLaunchAliasAuthority(capability)
            let actualNames = try PlayCoverManagedAppService
                .anchoredDirectoryNames(
                    descriptor: capability.aliasDescriptor,
                    label: "unsubmitted session launch alias"
                )
            guard Set(actualNames).isSubset(
                of: Set(expectedEntries.map(\.name))
            ) else {
                throw PlayCoverBackendError.cacheTampered(
                    "unsubmitted launch facade contains an "
                        + "unexpected entry"
                )
            }
            try validateSessionLaunchAliasEntries(
                actualNames,
                capability: capability,
                expectedEntries: expectedEntries
            )
            return try removeSessionLaunchAliasNames(
                actualNames,
                capability: capability
            )
        }
        let manifestEntries = try launchAliasEntries(
            manifest: manifest
        ).sorted { $0.name < $1.name }
        let recordedEntries = recordedInventory.map {
            LaunchAliasEntry(
                name: $0.name,
                destination: $0.destination
            )
        }
        guard manifestEntries.map(\.name)
                == recordedEntries.map(\.name),
              manifestEntries.map(\.destination)
                == recordedEntries.map(\.destination) else {
            throw PlayCoverBackendError.cacheTampered(
                "pending launch facade inventory no longer "
                    + "matches the immutable generation"
            )
        }
        let capability = try openSessionLaunchAliasCapability(
            alias: alias
        )
        defer { capability.close() }
        guard UInt64(capability.aliasStatus.st_dev)
                == recordedDevice,
              UInt64(capability.aliasStatus.st_ino)
                == recordedInode else {
            throw PlayCoverBackendError.cacheTampered(
                "pending launch facade directory identity changed"
            )
        }
        try validateSessionLaunchAliasAuthority(capability)
        let actualNames = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: capability.aliasDescriptor,
                label: "pending session launch alias"
            )
        let recordedNames = Set(recordedEntries.map(\.name))
        guard Set(actualNames).isSubset(of: recordedNames) else {
            throw PlayCoverBackendError.cacheTampered(
                "pending launch facade contains an unexpected entry"
            )
        }
        try validateSessionLaunchAliasEntries(
            actualNames,
            capability: capability,
            expectedEntries: recordedEntries
        )
        try removeSessionLaunchAliasNames(
            actualNames,
            capability: capability
        )
    }

    private static func completePendingLaunchCleanup(
        sessionID: String,
        proof: PlayCoverPendingLaunchStore.CleanupProof,
        owner: LaunchedApplicationIdentity?,
        manifest: PlayCoverPrepareManifest,
        paths: IOSUsePaths
    ) throws {
        if proof == .stoppedExactOwner,
           let owner,
           let durableOwner = pendingLaunchOwner(owner) {
            _ = try PlayCoverPendingLaunchStore.markOwned(
                sessionID: sessionID,
                owner: durableOwner,
                callbackSucceeded:
                    owner.source == .workspaceCallback,
                paths: paths
            )
        }
        let confirmed = try PlayCoverPendingLaunchStore
            .markConfirmedStopped(
                sessionID: sessionID,
                cleanupProof: proof,
                paths: paths
            )
        try lockKeyCover(for: manifest)
        try removeSessionLaunchAlias(
            pendingLaunch: confirmed,
            manifest: manifest
        )
        try PlayCoverPendingLaunchStore.removeConfirmed(
            sessionID: sessionID,
            paths: paths
        )
    }

    static func lockKeyCover(
        for manifest: PlayCoverPrepareManifest
    ) throws {
        let managedHome = URL(
            fileURLWithPath: managedHomePath(for: manifest),
            isDirectory: true
        )
        if let keyCoverLockOverrideForTesting {
            try keyCoverLockOverrideForTesting(
                manifest.bundleIdentifier,
                managedHome
            )
            return
        }
        try PlayCoverHeadlessKeyCover.lock(
            bundleIdentifier: manifest.bundleIdentifier,
            managedHome: managedHome
        )
    }

    private static func ensureLaunchAliasRoot(
        _ root: URL
    ) throws {
        var status = stat()
        if lstat(root.path, &status) != 0 {
            guard errno == ENOENT else {
                throw PlayCoverBackendError.cacheTampered(
                    "cannot inspect the launch alias root: errno \(errno)"
                )
            }
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw PlayCoverBackendError.launchFailed(
                    "cannot create the owner-only launch alias root: "
                        + "\(error)"
                )
            }
            guard lstat(root.path, &status) == 0 else {
                throw PlayCoverBackendError.launchFailed(
                    "the launch alias root disappeared after creation"
                )
            }
            try syncLaunchAliasDirectory(
                root.deletingLastPathComponent()
            )
        }
        try validateLaunchAliasRootStatus(status)
    }

    private static func validateLaunchAliasRootStatus(
        _ status: stat
    ) throws {
        #if canImport(Darwin)
        let expectedUserID = geteuid()
        #else
        let expectedUserID: UInt32 = status.st_uid
        #endif
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == expectedUserID,
              status.st_mode & 0o700 == 0o700,
              status.st_mode & 0o022 == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "the PlayCover launch alias root is not an owned, "
                    + "non-writable real directory"
            )
        }
    }

    private static func syncSessionLaunchAlias(
        _ alias: SessionLaunchAlias,
        expectedEntries: [LaunchAliasEntry],
        afterSync:
            ((SessionLaunchAliasCapability) throws -> Void)? = nil
    ) throws {
        let capability = try openSessionLaunchAliasCapability(
            alias: alias
        )
        defer { capability.close() }
        try validateSessionLaunchAliasCapability(
            capability,
            expectedEntries: expectedEntries
        )
        guard Darwin.fsync(capability.aliasDescriptor) == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot fsync the session launch alias: errno \(errno)"
            )
        }
        guard Darwin.fsync(capability.rootDescriptor) == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot fsync the launch alias parent: errno \(errno)"
            )
        }
        try afterSync?(capability)
    }

    private static func recordPendingLaunchAlias(
        _ capability: SessionLaunchAliasCapability,
        entries: [LaunchAliasEntry],
        sessionID: String,
        paths: IOSUsePaths
    ) throws {
        _ = try PlayCoverPendingLaunchStore.markAliasReady(
            sessionID: sessionID,
            device: UInt64(capability.aliasStatus.st_dev),
            inode: UInt64(capability.aliasStatus.st_ino),
            inventory: entries.map {
                PlayCoverPendingLaunchStore.AliasEntry(
                    name: $0.name,
                    destination: $0.destination
                )
            }.sorted { $0.name < $1.name },
            paths: paths
        )
    }

    private static func removeSessionLaunchAliasCapability(
        _ capability: SessionLaunchAliasCapability,
        expectedEntries: [LaunchAliasEntry]
    ) throws {
        let actualNames = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: capability.aliasDescriptor,
                label: "session launch alias"
            )
        guard Set(actualNames)
                == Set(expectedEntries.map(\.name)) else {
            throw PlayCoverBackendError.cacheTampered(
                "the session launch alias changed before removal"
            )
        }
        try removeSessionLaunchAliasNames(
            actualNames,
            capability: capability
        )
    }

    private static func removeSessionLaunchAliasNames(
        _ names: [String],
        capability: SessionLaunchAliasCapability
    ) throws {
        for name in names.sorted() {
            guard Darwin.unlinkat(
                    capability.aliasDescriptor,
                    name,
                    0
                  ) == 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "cannot unlink anchored session launch alias entry "
                        + "\(name): errno \(errno)"
                )
            }
        }
        guard Darwin.fsync(capability.aliasDescriptor) == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot fsync the emptied session launch alias: "
                    + "errno \(errno)"
            )
        }
        var namedStatus = stat()
        guard fstatat(
                capability.rootDescriptor,
                capability.aliasName,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameDirectoryAuthorityIdentity(
                capability.aliasStatus,
                namedStatus
              ) else {
            throw PlayCoverBackendError.cacheTampered(
                "the emptied session launch alias changed before removal"
            )
        }
        guard Darwin.unlinkat(
                capability.rootDescriptor,
                capability.aliasName,
                AT_REMOVEDIR
              ) == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot remove the anchored session launch alias: "
                    + "errno \(errno)"
            )
        }
        guard Darwin.fsync(capability.rootDescriptor) == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot fsync the launch alias parent after removal: "
                    + "errno \(errno)"
            )
        }
    }

    private static func removePartialSessionLaunchAlias(
        _ alias: SessionLaunchAlias
    ) throws {
        var aliasStatus = stat()
        guard lstat(alias.bundleURL.path, &aliasStatus) == 0 else {
            return
        }
        #if canImport(Darwin)
        let expectedUserID = geteuid()
        #else
        let expectedUserID: UInt32 = aliasStatus.st_uid
        #endif
        guard aliasStatus.st_mode & S_IFMT == S_IFDIR,
              aliasStatus.st_uid == expectedUserID else {
            return
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: alias.bundleURL.path
        )
        for name in names {
            var childStatus = stat()
            guard lstat(
                alias.bundleURL.appendingPathComponent(name).path,
                &childStatus
            ) == 0,
            childStatus.st_mode & S_IFMT == S_IFLNK,
            childStatus.st_uid == expectedUserID else {
                return
            }
        }
        try FileManager.default.removeItem(at: alias.bundleURL)
        try syncLaunchAliasDirectory(alias.rootURL)
    }

    private static func syncLaunchAliasDirectory(
        _ directory: URL
    ) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open the launch alias parent for fsync: "
                    + "errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot fsync the launch alias parent: errno \(errno)"
            )
        }
    }

    private static func launchAliasEntries(
        manifest: PlayCoverPrepareManifest
    ) throws -> [LaunchAliasEntry] {
        let app = URL(
            fileURLWithPath: manifest.preparedAppPath,
            isDirectory: true
        ).standardizedFileURL
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(
                atPath: app.path
            ).sorted()
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "cannot enumerate the prepared App for its launch alias: "
                    + "\(error)"
            )
        }
        guard !names.isEmpty,
              names.allSatisfy(isSafeLaunchAliasName) else {
            throw PlayCoverBackendError.cacheTampered(
                "the prepared App has no safe top-level launch inventory"
            )
        }
        return names.map {
            LaunchAliasEntry(
                name: $0,
                destination: app.appendingPathComponent($0).path
            )
        }
    }

    static func acceptsOwnedLaunchIdentity(
        pid: Int32,
        bundleIdentifier: String,
        bundleURLPath: String,
        executablePath: String,
        existingPIDs: Set<Int32>,
        manifest: PlayCoverPrepareManifest,
        launchAliasPath: String
    ) -> Bool {
        pid > 0
            && !existingPIDs.contains(pid)
            && bundleIdentifier == manifest.bundleIdentifier
            && canonicalPath(bundleURLPath)
                == canonicalPath(launchAliasPath)
            && canonicalPath(executablePath)
                == canonicalPath(manifest.executablePath)
    }

    /// Returns whether a newly observed process is safe to challenge with the
    /// random Runtime session. This does not grant process ownership.
    ///
    /// LaunchServices can canonicalize pinned PlayCover's top-level symlink
    /// facade and report the immutable prepared App as `bundleURL`. The exact
    /// facade remains accepted, but the prepared path is only a Runtime
    /// authentication candidate; it cannot be claimed from polling alone.
    static func acceptsRuntimeLaunchCandidateIdentity(
        pid: Int32,
        bundleIdentifier: String,
        bundleURLPath: String,
        executablePath: String,
        existingPIDs: Set<Int32>,
        manifest: PlayCoverPrepareManifest,
        launchAliasPath: String
    ) -> Bool {
        guard pid > 0,
              !existingPIDs.contains(pid),
              bundleIdentifier == manifest.bundleIdentifier,
              canonicalPath(executablePath)
                == canonicalPath(manifest.executablePath) else {
            return false
        }
        let bundlePath = canonicalPath(bundleURLPath)
        return bundlePath == canonicalPath(launchAliasPath)
            || bundlePath == canonicalPath(manifest.preparedAppPath)
    }

    /// Revalidates the source-specific bundle identity before the caller gains
    /// rollback authority. A prepared-App bundle path is valid only after the
    /// exact process authenticated the current Runtime session.
    static func acceptsClaimedLaunchIdentity(
        _ identity: LaunchedApplicationIdentity,
        manifest: PlayCoverPrepareManifest,
        launchAliasPath: String
    ) -> Bool {
        guard identity.pid > 0,
              identity.bundleIdentifier == manifest.bundleIdentifier,
              canonicalPath(identity.executablePath)
                == canonicalPath(manifest.executablePath) else {
            return false
        }
        let bundlePath = canonicalPath(identity.bundleURLPath)
        switch identity.source {
        case .workspaceCallback:
            return bundlePath == canonicalPath(launchAliasPath)
        case .authenticatedRuntime:
            return bundlePath == canonicalPath(launchAliasPath)
                || bundlePath == canonicalPath(manifest.preparedAppPath)
        case .observedCandidate:
            return false
        }
    }

    static func runtimeCandidateAllowsLegacyHelloFallback(
        bundleURLPath: String,
        launchAliasPath: String
    ) -> Bool {
        canonicalPath(bundleURLPath) == canonicalPath(launchAliasPath)
    }

    static func authenticateRuntimeLaunchCandidate(
        _ identity: LaunchedApplicationIdentity,
        runtimeSocketPath: String,
        sessionID: String,
        manifest: PlayCoverPrepareManifest,
        launchAliasPath: String,
        deadline: TimeInterval,
        legacyHelloAttempted: inout Bool,
        pingOverride: ((TimeInterval) throws
            -> PlayCoverRuntimePingPayload)? = nil,
        helloOverride: ((TimeInterval) throws -> Void)? = nil,
        now: () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) -> Bool {
        func client(timeout: TimeInterval) -> PlayCoverRuntimeClient {
            PlayCoverRuntimeClient(
                socketPath: runtimeSocketPath,
                sessionID: sessionID,
                expectedPID: identity.pid,
                expectedBundleIdentifier:
                    manifest.bundleIdentifier,
                expectedExecutablePath:
                    manifest.executablePath,
                timeoutSeconds: timeout
            )
        }

        do {
            let pingRemaining = deadline - now()
            guard pingRemaining > 0 else {
                return false
            }
            let pingTimeout = min(0.05, pingRemaining)
            let ping: PlayCoverRuntimePingPayload
            if let pingOverride {
                ping = try pingOverride(pingTimeout)
            } else {
                ping = try client(timeout: pingTimeout).ping()
            }
            guard !ping.hasCompleteIdentity else {
                return true
            }
            guard !ping.hasAnyIdentity,
                runtimeCandidateAllowsLegacyHelloFallback(
                    bundleURLPath: identity.bundleURLPath,
                    launchAliasPath: launchAliasPath
                ),
                !legacyHelloAttempted else {
                return false
            }

            // A pre-identified-ping Runtime reads requests on its serialized
            // socket/FIFO worker, then waits synchronously for the App main
            // queue to compute hello. Send exactly one fallback with the
            // launch deadline's full remaining budget. Repeated 50 ms hello
            // requests would keep executing after their clients timed out and
            // starve the final ready hello behind stale FIFO work.
            let helloRemaining = deadline - now()
            guard helloRemaining > 0 else {
                return false
            }
            legacyHelloAttempted = true
            if let helloOverride {
                try helloOverride(helloRemaining)
            } else {
                _ = try client(timeout: helloRemaining).hello()
            }
            return true
        } catch {
            return false
        }
    }

    static func authenticatedRuntimeClaim(
        from candidates: [LaunchedApplicationIdentity]
    ) throws -> LaunchedApplicationIdentity? {
        guard candidates.count <= 1 else {
            throw PlayCoverBackendError.launchFailed(
                "multiple App processes authenticated the same "
                    + "launch session"
            )
        }
        guard let identity = candidates.first else {
            return nil
        }
        guard identity.source == .observedCandidate else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime-authenticated launch claim did not originate "
                    + "from an observed candidate"
            )
        }
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

    static func launchPreparedApplication(
        manifest: PlayCoverPrepareManifest,
        launchCapability: FastVerifiedLaunchCapability,
        sessionID: String,
        runtimeSocketPath: String,
        stdioLog: PlayCoverStdioLogIdentity? = nil,
        pendingLaunchPaths: IOSUsePaths? = nil,
        deadline: TimeInterval,
        launchAlias: inout SessionLaunchAlias?,
        workspaceOpenSubmitted: inout Bool,
        postSubmissionIntegrityError: inout Error?,
        launchPhaseTiming: inout PlayCoverLaunchPhaseTiming
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
            managedHomePath: managedHomePath(for: manifest),
            stdioLog: stdioLog
        )
        let existingApplications =
            NSRunningApplication.runningApplications(
                withBundleIdentifier: manifest.bundleIdentifier
            )
        let existingPIDs = Set(
            existingApplications.map(\.processIdentifier)
        )
        guard !existingApplications.contains(where: { application in
            guard let executablePath = application.executableURL?
                    .standardizedFileURL.path else {
                return false
            }
            return canonicalPath(executablePath)
                    == canonicalPath(manifest.executablePath)
        }) else {
            throw PlayCoverBackendError.launchFailed(
                "the exact prepared App is already running outside "
                    + "this start invocation"
            )
        }
        try validateFastVerifiedLaunchCapability(launchCapability)
        let launchEntries = launchCapability.entries.map {
            LaunchAliasEntry(
                name: $0.name,
                destination: $0.destination
            )
        }
        let aliasStarted = PlayCoverMonotonicClock.now()
        let alias: SessionLaunchAlias
        do {
            alias = try createSessionLaunchAlias(
                entries: launchEntries,
                sessionID: sessionID,
                pendingLaunchPaths: pendingLaunchPaths
            )
        } catch {
            launchPhaseTiming.aliasNanoseconds =
                PlayCoverMonotonicClock.elapsed(
                    since: aliasStarted
                )
            throw error
        }
        launchAlias = alias
        let aliasCapability: SessionLaunchAliasCapability
        do {
            aliasCapability = try openSessionLaunchAliasCapability(
                alias: alias
            )
            try emitLaunchIntegrityEvent(
                .afterAliasBuiltBeforePreSubmitValidation
            )
        } catch {
            launchPhaseTiming.aliasNanoseconds =
                PlayCoverMonotonicClock.elapsed(since: aliasStarted)
            throw error
        }
        defer { aliasCapability.close() }
        launchPhaseTiming.aliasNanoseconds =
            PlayCoverMonotonicClock.elapsed(since: aliasStarted)
        let box = LaunchBox()
        let semaphore = DispatchSemaphore(value: 0)
        let completion:
            (NSRunningApplication?, Error?) -> Void = {
                application, error in
            if let application,
               !application.isTerminated,
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
                    manifest: manifest,
                    launchAliasPath: alias.bundleURL.path
               ) {
                let identity = LaunchedApplicationIdentity(
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
                if let pendingLaunchPaths {
                    guard let owner = pendingLaunchOwner(
                        identity
                    ) else {
                        box.set(
                            .failure(
                                PlayCoverBackendError.launchFailed(
                                    "NSWorkspace callback owner "
                                        + "has no stable process "
                                        + "birth identity"
                                )
                            )
                        )
                        semaphore.signal()
                        return
                    }
                    do {
                        try persistPendingLaunchOwner(
                            owner,
                            identity: identity,
                            sessionID: sessionID,
                            callbackSucceeded: true,
                            paths: pendingLaunchPaths
                        )
                    } catch {
                        box.set(.failure(error))
                        semaphore.signal()
                        return
                    }
                }
                box.set(.success(identity))
            } else {
                let callbackError =
                    error ?? PlayCoverBackendError.launchFailed(
                        "NSWorkspace returned a pre-existing, "
                            + "incomplete, or mismatched App identity"
                    )
                do {
                    if let pendingLaunchPaths {
                        #if DEBUG && canImport(Darwin)
                        PlayCoverLaunchCrashCut.hit(
                            .beforeTerminalCallbackDurable
                        )
                        #endif
                        _ = try PlayCoverPendingLaunchStore
                            .markTerminalCallbackFailure(
                                sessionID: sessionID,
                                errorDescription:
                                    boundedPendingLaunchError(
                                        callbackError
                                    ),
                                paths: pendingLaunchPaths
                            )
                        #if DEBUG && canImport(Darwin)
                        PlayCoverLaunchCrashCut.hit(
                            .afterTerminalCallbackDurable
                        )
                        #endif
                    }
                    box.set(.failure(callbackError))
                } catch {
                    box.set(.failure(error))
                }
            }
            semaphore.signal()
        }
        try validateFastVerifiedLaunchCapability(launchCapability)
        try validateSessionLaunchAliasCapability(
            aliasCapability,
            expectedEntries: launchEntries
        )
        // NSWorkspace accepts a path, not an fd. These checks only sample the
        // lexical identities immediately before and after the synchronous
        // API call. Descriptor retention neither closes namespace ABA nor
        // proves when LaunchServices consumes the asynchronous request.
        if let pendingLaunchPaths {
            _ = try PlayCoverPendingLaunchStore
                .markSubmissionArmed(
                    sessionID: sessionID,
                    bootSessionUUID:
                        PlayCoverPendingLaunchRecovery
                            .currentBootSessionUUID(),
                    paths: pendingLaunchPaths
                )
            #if DEBUG && canImport(Darwin)
            PlayCoverLaunchCrashCut.hit(.afterSubmissionArmed)
            #endif
        }
        workspaceOpenSubmitted = true
        if let workspaceOpenOverrideForTesting {
            let openDispatchStarted =
                PlayCoverMonotonicClock.now()
            workspaceOpenOverrideForTesting(
                alias.bundleURL,
                configuration,
                completion
            )
            launchPhaseTiming.openDispatchNanoseconds =
                PlayCoverMonotonicClock.elapsed(
                    since: openDispatchStarted
                )
        } else {
            let openDispatchStarted =
                PlayCoverMonotonicClock.now()
            NSWorkspace.shared.openApplication(
                at: alias.bundleURL,
                configuration: configuration,
                completionHandler: completion
            )
            launchPhaseTiming.openDispatchNanoseconds =
                PlayCoverMonotonicClock.elapsed(
                    since: openDispatchStarted
                )
        }
        #if DEBUG && canImport(Darwin)
        PlayCoverLaunchCrashCut.hit(.afterOpenReturned)
        #endif
        do {
            try emitLaunchIntegrityEvent(
                .afterWorkspaceOpenReturnedBeforePostSubmitValidation
            )
            try validateFastVerifiedLaunchCapability(launchCapability)
            try validateSessionLaunchAliasCapability(
                aliasCapability,
                expectedEntries: launchEntries
            )
        } catch {
            // Submission may still create the App after this method returns
            // from NSWorkspace. Keep the existing ownership loop alive so an
            // exact process can be handed to the caller for rollback.
            postSubmissionIntegrityError = error
        }
        aliasCapability.close()
        launchCapability.close()
        // The caller supplies the one monotonic `start --timeout` deadline
        // shared by launch discovery and the subsequent ready Runtime hello.
        // Large Apps may exceed LaunchServices' historical ten-second window,
        // but discovery must not restart the public timeout.
        let exactOwnershipStarted =
            PlayCoverMonotonicClock.now()
        var runtimeTransportPingNanoseconds: UInt64 = 0
        var attemptedRuntimeTransportPing = false
        defer {
            let ownershipAndPingNanoseconds =
                PlayCoverMonotonicClock.elapsed(
                    since: exactOwnershipStarted
                )
            launchPhaseTiming.runtimeTransportPingNanoseconds =
                attemptedRuntimeTransportPing
                    ? runtimeTransportPingNanoseconds
                    : nil
            launchPhaseTiming.exactOwnershipNanoseconds =
                ownershipAndPingNanoseconds
        }
        var callbackError: Error?
        var legacyHelloAttempted = false
        func authenticatesCurrentLaunch(
            _ identity: LaunchedApplicationIdentity
        ) -> Bool {
            attemptedRuntimeTransportPing = true
            let runtimeTransportPingStarted =
                PlayCoverMonotonicClock.now()
            defer {
                let elapsed =
                    PlayCoverMonotonicClock.elapsed(
                        since: runtimeTransportPingStarted
                    )
                let (sum, overflow) =
                    runtimeTransportPingNanoseconds
                        .addingReportingOverflow(elapsed)
                runtimeTransportPingNanoseconds =
                    overflow ? UInt64.max : sum
            }
            return authenticateRuntimeLaunchCandidate(
                identity,
                runtimeSocketPath: runtimeSocketPath,
                sessionID: sessionID,
                manifest: manifest,
                launchAliasPath: alias.bundleURL.path,
                deadline: deadline,
                legacyHelloAttempted: &legacyHelloAttempted
            )
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            // A successful callback is published only after any required
            // exact-owner durability. Consume it before the bounded candidate
            // ping; a callback failure must still allow Runtime rescue.
            if case .success(let identity)? = box.get(),
               mayClaimLaunchIdentity(
                   identity,
                   callbackIdentity: identity,
                   runtimeAuthenticated: false
               ) {
                return identity
            }

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
                      acceptsRuntimeLaunchCandidateIdentity(
                        pid: application.processIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        bundleURLPath: bundlePath,
                        executablePath: executablePath,
                        existingPIDs: existingPIDs,
                        manifest: manifest,
                        launchAliasPath: alias.bundleURL.path
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
            if let identity = try authenticatedRuntimeClaim(
                from: provenCandidates
            ) {
                if let pendingLaunchPaths {
                    guard let owner = pendingLaunchOwner(
                        identity
                    ) else {
                        throw PlayCoverBackendError.launchFailed(
                            "authenticated Runtime owner has no "
                                + "stable process birth identity"
                        )
                    }
                    try persistPendingLaunchOwner(
                        owner,
                        identity: identity,
                        sessionID: sessionID,
                        callbackSucceeded: false,
                        paths: pendingLaunchPaths
                    )
                }
                return identity
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
                    if let ownershipError =
                            error as? PendingOwnedLaunchError {
                        throw ownershipError
                    }
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
        if let postSubmissionIntegrityError {
            throw postSubmissionIntegrityError
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

    static func revalidatePendingLaunchIdentity(
        _ identity: LaunchedApplicationIdentity
    ) throws {
        guard identity.source == .workspaceCallback
                || identity.source == .authenticatedRuntime,
              let expectedProcessBirth =
                identity.processStartTimeMicroseconds,
              expectedProcessBirth > 0 else {
            throw PlayCoverBackendError.launchFailed(
                "pending launch owner has no stable process birth "
                    + "identity"
            )
        }
        switch failedLaunchProcessState(identity.pid) {
        case .missing:
            throw PlayCoverBackendError.launchFailed(
                "pending launch owner exited before durable "
                    + "ownership commit"
            )
        case .unverifiable(let errorNumber):
            throw PlayCoverBackendError.launchFailed(
                "pending launch owner cannot be revalidated: "
                    + "errno \(errorNumber)"
            )
        case .running(
            let executablePath,
            let processBirthMicroseconds
        ):
            guard canonicalPath(executablePath)
                    == canonicalPath(identity.executablePath) else {
                throw PlayCoverBackendError.launchFailed(
                    "pending launch PID was reused by a different "
                        + "executable before ownership commit"
                )
            }
            guard let processBirthMicroseconds,
                  processBirthMicroseconds > 0 else {
                throw PlayCoverBackendError.launchFailed(
                    "pending launch owner lost its stable process "
                        + "birth identity before ownership commit"
                )
            }
            guard processBirthMicroseconds
                    == expectedProcessBirth else {
                throw PlayCoverBackendError.launchFailed(
                    "pending launch PID was reused before ownership "
                        + "commit"
                )
            }
        }
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
                    == canonicalPath(manifest.executablePath) else {
                // The owned App exited and the PID was reused by a different
                // executable.
                return
            }
            guard let currentProcessStart else {
                throw PlayCoverBackendError.launchFailed(
                    "rollback cannot verify pid \(pid): the live "
                        + "executable has no stable process birth token"
                )
            }
            guard currentProcessStart == expectedProcessStart else {
                // The owned App exited and the PID was reused by the same
                // executable; the stable birth token proves the replacement.
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
                    != canonicalPath(expectedExecutablePath) {
                    // The exact process exited and its PID was reused by a
                    // different executable.
                    return true
                }
                guard let processStartTimeMicroseconds else {
                    throw PlayCoverBackendError.launchFailed(
                        "rollback cannot verify pid \(pid): the live "
                            + "executable has no stable process birth token"
                    )
                }
                if processStartTimeMicroseconds
                    != expectedProcessStartTimeMicroseconds {
                    // The exact process exited and its PID was reused by the
                    // same executable.
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
