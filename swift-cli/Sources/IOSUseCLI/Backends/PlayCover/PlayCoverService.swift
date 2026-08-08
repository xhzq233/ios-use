import CryptoKit
import Foundation
import PlayCoverUpstream
#if canImport(Darwin)
import Darwin
#endif

public enum PlayCoverService {
    private static let upstreamStandardOutputLock = NSLock()

    public static let runtimeFrameworkName = "IOSUsePlayRuntime.framework"
    public static let runtimeExecutableName = "IOSUsePlayRuntime"
    static let prepareImplementationRevision =
        "ios-use-headless-v19+single-bundle-slot+playcover-"
        + PlayCoverUpstreamEngine.playCoverRevision
        + "+inject-"
        + PlayCoverUpstreamEngine.injectRevision
        + "+rules-"
        + PlayCoverUpstreamEngine.defaultRulesRevision
        + "+always-frida"
    private static let accountNamespacePolicyRevision =
        "account-runtime-namespace-v1"

    static var signingIdentityResolverOverrideForTesting:
        ((Bool) throws -> PlayCoverSigningIdentityEvidence)?
    static var rootCodeSignatureInspectorOverrideForTesting:
        ((URL) throws -> PlayCoverRootCodeSignatureEvidence)?
    static var upstreamPrepareOverrideForTesting: ((
        PlayCoverUpstreamPrepareOptions,
        PlayCoverUpstreamAppInspection
    ) throws -> PlayCoverUpstreamPrepareResult)?
    static var signingIdentityNowOverrideForTesting: (() -> Date)?

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
        paths: IOSUsePaths,
        signingIdentity suppliedSigningIdentity:
            PlayCoverSigningIdentityEvidence? = nil,
        fridaEngine: PlayCoverFridaEngineService.Resolved
    ) throws -> PlayCoverPreparationPlan {
        let runtimePath = URL(
            fileURLWithPath: runtimeFrameworkPath,
            isDirectory: true
        ).standardizedFileURL.path
        let runtimeEvidence = try runtimeEvidence(
            frameworkPath: runtimePath
        )
        let signingIdentity = try suppliedSigningIdentity
            ?? resolveSigningIdentity(initializeIfMissing: false)
        let plan = PlayCoverPreparationPlan(
            source: source,
            runtimeFrameworkPath: runtimePath,
            runtimeEvidence: runtimeEvidence,
            signingIdentity: signingIdentity,
            runtimeBuildHash: runtimeEvidence.buildHash,
            prepareRevision: fridaPrepareRevision(
                engineSHA256: fridaEngine.sha256
            ),
            accountNamespacePolicyHash:
                accountNamespacePolicyHash(paths: paths),
            fridaEngineFrameworkPath: fridaEngine.path,
            fridaEngineSHA256: fridaEngine.sha256
        )
        try validatePreparationPlan(plan)
        return plan
    }

    public static func prepare(
        sourceAppPath: String,
        outputAppPath: String,
        runtimeFrameworkPath: String,
        paths: IOSUsePaths,
        publishedAppPath: String? = nil
    ) throws -> PlayCoverPreparedApp {
        let source = try inspectPreparationSource(appPath: sourceAppPath)
        let engine = try PlayCoverFridaEngineService.ensureAvailable()
        let plan = try makePreparationPlan(
            source: source,
            runtimeFrameworkPath: runtimeFrameworkPath,
            paths: paths,
            fridaEngine: engine
        )
        return try prepareArtifact(
            plan: plan,
            outputAppPath: outputAppPath,
            paths: paths,
            publishedAppPath: publishedAppPath
        ).preparedApp
    }

    static func prepareArtifact(
        plan: PlayCoverPreparationPlan,
        outputAppPath: String,
        stagingIOAppPath: String? = nil,
        paths: IOSUsePaths,
        publishedAppPath: String? = nil
    ) throws -> PlayCoverPreparedArtifact {
        try validatePreparationPlan(plan)
        let source = plan.source.inspection
        let stagingIdentityURL = lexicalURL(
            outputAppPath,
            isDirectory: true
        )
        let stagingURL = lexicalURL(
            stagingIOAppPath ?? outputAppPath,
            isDirectory: true
        )
        let publishedURL = lexicalURL(
            publishedAppPath ?? outputAppPath,
            isDirectory: true
        )
        try requireSlotPath(
            stagingIdentityURL,
            paths: paths,
            operation: "staging"
        )
        try requireSlotPath(
            publishedURL,
            paths: paths,
            operation: "published App"
        )
        if stagingIOAppPath != nil {
            guard stagingIdentityURL.lastPathComponent
                    == stagingURL.lastPathComponent else {
                throw PlayCoverBackendError.prepareFailed(
                    "staging identity and I/O paths disagree"
                )
            }
        }

        let runtimeURL = URL(
            fileURLWithPath: plan.runtimeFrameworkPath,
            isDirectory: true
        ).standardizedFileURL
        let sandboxSocket = URL(
            fileURLWithPath: paths.playcoverSocketRoot,
            isDirectory: true
        ).appendingPathComponent("s-runtime.sock").path
        let options = PlayCoverUpstreamPrepareOptions(
            sourceApp: URL(
                fileURLWithPath: source.appPath,
                isDirectory: true
            ),
            stagingApp: stagingURL,
            managedStagingApp: stagingIdentityURL,
            managedStagingRoot: URL(
                fileURLWithPath: paths.playcoverApps,
                isDirectory: true
            ),
            runtimeFramework: runtimeURL,
            managedHome: URL(
                fileURLWithPath: paths.playcoverPlayChain,
                isDirectory: true
            ),
            runtimeSocketRoot: URL(
                fileURLWithPath: paths.playcoverSocketRoot,
                isDirectory: true
            ),
            runtimeSocketPath: sandboxSocket,
            runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
            defaultRulesData: try PlayCoverRulesService.ensureAvailable(),
            codesignIdentity: plan.signingIdentity.codesignSelector,
            expectedRuntimeBuildHash: plan.runtimeBuildHash,
            expectedRuntimeEvidence: plan.runtimeEvidence,
            embeddedFrameworks: [
                PlayCoverUpstreamPrepareOptions.EmbeddedFramework(
                    source: URL(
                        fileURLWithPath: plan.fridaEngineFrameworkPath,
                        isDirectory: true
                    ),
                    relativePath:
                        "Frameworks/\(PlayCoverFridaEngineService.frameworkName)"
                ),
            ]
        )
        let upstream: PlayCoverUpstreamPrepareResult
        do {
            if let upstreamPrepareOverrideForTesting {
                upstream = try upstreamPrepareOverrideForTesting(
                    options,
                    plan.source.upstreamInspection
                )
            } else {
                upstream = try withSuppressedUpstreamStandardOutput {
                    try PlayCoverUpstreamEngine.prepare(
                        options,
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
        let rootSignature: PlayCoverRootCodeSignatureEvidence
        do {
            rootSignature = try inspectRootCodeSignature(
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
        guard upstream.sourceHashAfterPrepare == source.sourceContentHash,
              prepared.bundleIdentifier == source.bundleIdentifier,
              prepared.signature.isSigned,
              upstream.prepared.signature.isValid,
              rootSignature.certificateSHA256
                == plan.signingIdentity.certificateSHA256,
              rootSignature.signingIdentifier
                == prepared.bundleIdentifier,
              isValidRootCodeSignature(
                rootSignature,
                signingIdentity: plan.signingIdentity,
                bundleIdentifier: prepared.bundleIdentifier
              ),
              normalizedCDHash(rootSignature.cdHash)
                == normalizedCDHash(upstream.prepared.signature.cdHash),
              hasEmbeddedRuntime(prepared),
              hasEmbeddedFridaEngine(prepared) else {
            throw PlayCoverBackendError.verificationFailed(
                "prepared App failed Runtime, Frida, source, or signing checks"
            )
        }
        let result = PlayCoverPreparedApp(
            appPath: publishedURL.path,
            bundleIdentifier: prepared.bundleIdentifier,
            executableName: prepared.executableName,
            executableRelativePath:
                prepared.mainExecutableRelativePath,
            executablePath: prepared.executablePath,
            sourceContentHash: source.sourceContentHash,
            sourceHashAfterPreparation: upstream.sourceHashAfterPrepare,
            runtimeBuildHash: plan.runtimeBuildHash,
            prepareRevision: plan.prepareRevision,
            fridaEngineSHA256: plan.fridaEngineSHA256,
            signingIdentity: plan.signingIdentity,
            rootCodeSignature: rootSignature,
            inspection: prepared,
            completedAt: ISO8601DateFormatter().string(from: Date())
        )
        return PlayCoverPreparedArtifact(
            preparedApp: result,
            upstreamResult: upstream
        )
    }

    public static func verify(
        appPath: String
    ) throws -> PlayCoverVerification {
        let appURL = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).standardizedFileURL
        let upstream: PlayCoverUpstreamAppInspection
        do {
            upstream = try PlayCoverUpstreamEngine.verify(
                appURL: appURL,
                runtimeLoadPath: PlayCoverMachO.runtimeLoadPath
            )
        } catch let error as PlayCoverUpstreamError {
            throw PlayCoverMachO.map(error)
        }
        let inspection = PlayCoverAppInspection(upstream)
        guard hasEmbeddedRuntime(inspection),
              hasEmbeddedFridaEngine(inspection),
              upstream.signature.isSigned,
              upstream.signature.isValid else {
            throw PlayCoverBackendError.verificationFailed(
                "Mac App is missing its always-on Runtime or Frida Engine"
            )
        }
        return PlayCoverVerification(
            inspection: inspection,
            mainExecutable: inspection.mainExecutable,
            signatureValid: true
        )
    }

    static func validatePreparationPlan(
        _ plan: PlayCoverPreparationPlan
    ) throws {
        let sourceHash = plan.source.inspection.sourceContentHash
        guard sourceHash == plan.source.upstreamInspection.sourceContentHash,
              isSHA256(sourceHash),
              plan.runtimeEvidence.buildHash == plan.runtimeBuildHash,
              isSHA256(plan.runtimeBuildHash),
              isSHA256(plan.fridaEngineSHA256),
              plan.prepareRevision == fridaPrepareRevision(
                engineSHA256: plan.fridaEngineSHA256
              ),
              isSHA256(plan.accountNamespacePolicyHash),
              isValidSigningIdentity(plan.signingIdentity),
              FileManager.default.fileExists(
                atPath: plan.fridaEngineFrameworkPath
              ) else {
            throw PlayCoverBackendError.prepareFailed(
                "always-Frida preparation plan is invalid"
            )
        }
    }

    static func fridaPrepareRevision(
        engineSHA256: String
    ) -> String {
        prepareImplementationRevision
            + "+frida-engine-"
            + PlayCoverFridaEngineService.descriptorVersion
            + "-"
            + PlayCoverFridaEngineService.descriptorSourceCommit
            + "+abi-"
            + PlayCoverFridaEngineService.descriptorEngineABI
            + "+agent-"
            + PlayCoverFridaEngineService.descriptorAgentSHA256
            + "+source-"
            + PlayCoverFridaEngineService.descriptorSourceClosureSHA256
            + "+engine-"
            + engineSHA256
    }

    static func runtimeBuildHash(
        frameworkPath: String
    ) throws -> String {
        try runtimeEvidence(frameworkPath: frameworkPath).buildHash
    }

    static func accountNamespacePolicyHash(
        paths: IOSUsePaths
    ) -> String {
        var hasher = SHA256()
        for value in [
            accountNamespacePolicyRevision,
            canonicalizingExistingPrefix(paths.playcoverPlayChain),
            canonicalizingExistingPrefix(paths.playcoverSocketRoot),
        ] {
            update(&hasher, value)
        }
        return hex(hasher.finalize())
    }

    static func requireHealthySigningIdentityForStart()
        throws -> PlayCoverSigningIdentityEvidence
    {
        try resolveSigningIdentity(initializeIfMissing: false)
    }

    static func validateStdio(
        _ state: PlayCoverRuntimeStdioState,
        expected: PlayCoverStdioLogIdentity?
    ) throws {
        if let expected {
            guard state.status == "redirected",
                  state.path.map(PlayCoverRuntimeClient.canonicalPath)
                    == PlayCoverRuntimeClient.canonicalPath(expected.path),
                  state.device == expected.device,
                  state.inode == expected.inode,
                  state.failureStage == nil,
                  state.errorNumber == nil else {
                throw PlayCoverBackendError.stdioLogFailed(
                    "Runtime stdio redirection does not match the session log"
                )
            }
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

    static func runtimeHelloFailureIsTerminal(_ error: Error) -> Bool {
        guard let runtimeError = error as? PlayCoverRuntimeClientError else {
            return true
        }
        switch runtimeError {
        case .socketCreateFailed,
             .socketOptionFailed,
             .connectFailed,
             .writeFailed,
             .readFailed,
             .timeout,
             .unexpectedEOF:
            return false
        case .remoteError(_, _, let details):
            return !(details?.retryable == true && details?.fatal == false)
        default:
            return true
        }
    }

    static func permitsUnresponsiveRuntimeTermination(
        after error: Error
    ) -> Bool {
        guard let runtimeError = error as? PlayCoverRuntimeClientError else {
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
        default:
            return false
        }
    }

    static func processStartTimeMicroseconds(for pid: Int32) -> UInt64? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
                == size else {
            return nil
        }
        let seconds = UInt64(info.pbi_start_tvsec)
        let micros = UInt64(info.pbi_start_tvusec)
        guard micros < 1_000_000,
              seconds <= (UInt64.max - micros) / 1_000_000 else {
            return nil
        }
        return seconds * 1_000_000 + micros
        #else
        return nil
        #endif
    }

    static func validateFreshRuntimeSocketPath(_ path: String) throws {
        let socketURL = URL(fileURLWithPath: path)
        let directoryPath = socketURL.deletingLastPathComponent().path
        #if canImport(Darwin)
        let directory = Darwin.open(
            directoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot open Runtime socket directory: errno \(errno)"
            )
        }
        defer { Darwin.close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & 0o077 == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket directory is not owner-only"
            )
        }
        var existing = stat()
        let result = socketURL.lastPathComponent.withCString {
            fstatat(directory, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        guard result != 0, errno == ENOENT else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket path already exists or cannot be inspected"
            )
        }
        #else
        guard FileManager.default.fileExists(atPath: directoryPath),
              !FileManager.default.fileExists(atPath: path) else {
            throw PlayCoverBackendError.launchFailed(
                "Runtime socket path is not fresh"
            )
        }
        #endif
    }

    static func fileSHA256(descriptor: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            #if canImport(Darwin)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            #else
            let count = 0
            #endif
            if count > 0 {
                hasher.update(data: Data(buffer.prefix(count)))
            } else if count == 0 {
                return hex(hasher.finalize())
            } else if errno != EINTR {
                throw PlayCoverBackendError.cacheTampered(
                    "file could not be hashed: errno \(errno)"
                )
            }
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

    private static func hasEmbeddedRuntime(
        _ inspection: PlayCoverAppInspection
    ) -> Bool {
        inspection.machOs.contains {
            $0.relativePath.hasPrefix(
                "Frameworks/\(runtimeFrameworkName)/"
            ) && URL(fileURLWithPath: $0.relativePath).lastPathComponent
                == runtimeExecutableName
        }
    }

    private static func hasEmbeddedFridaEngine(
        _ inspection: PlayCoverAppInspection
    ) -> Bool {
        inspection.machOs.contains {
            $0.relativePath.hasPrefix(
                "Frameworks/\(PlayCoverFridaEngineService.frameworkName)/"
            ) && URL(fileURLWithPath: $0.relativePath).lastPathComponent
                == "IOSUseFridaEngine"
        }
    }

    private static func resolveSigningIdentity(
        initializeIfMissing: Bool
    ) throws -> PlayCoverSigningIdentityEvidence {
        if let signingIdentityResolverOverrideForTesting {
            return try signingIdentityResolverOverrideForTesting(
                initializeIfMissing
            )
        }
        return try PlayCoverSigningIdentityService().requireHealthy(
            initializeIfMissing: initializeIfMissing
        )
    }

    private static func inspectRootCodeSignature(
        appURL: URL,
        mainExecutableRelativePath: String,
        scratchRootURL: URL
    ) throws -> PlayCoverRootCodeSignatureEvidence {
        if let rootCodeSignatureInspectorOverrideForTesting {
            return try rootCodeSignatureInspectorOverrideForTesting(appURL)
        }
        return try PlayCoverCodeSignatureInspector.inspectRoot(
            appURL: appURL,
            mainExecutableRelativePath: mainExecutableRelativePath,
            scratchRootURL: scratchRootURL
        )
    }

    private static func isValidSigningIdentity(
        _ evidence: PlayCoverSigningIdentityEvidence
    ) -> Bool {
        let now = signingIdentityNowOverrideForTesting?() ?? Date()
        let selectorValid = isUppercaseHex(
            evidence.codesignSelector,
            count: 40
        ) || (
            signingIdentityResolverOverrideForTesting != nil
                && evidence.codesignSelector == "-"
        )
        return evidence.policy.revision
                == PlayCoverSigningIdentityService.policyRevision
            && evidence.policy.source == .managedUserKeychain
            && evidence.policy.health == .healthy
            && isUppercaseHex(evidence.publicKeySPKISHA256, count: 64)
            && isUppercaseHex(evidence.certificateSHA256, count: 64)
            && selectorValid
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
            && isUppercaseHex(evidence.cdHash, count: cdHashLength)
            && evidence.signingIdentifier == bundleIdentifier
    }

    private static func requireSlotPath(
        _ url: URL,
        paths: IOSUsePaths,
        operation: String
    ) throws {
        let root = lexicalURL(paths.playcoverApps, isDirectory: true).path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else {
            throw PlayCoverBackendError.prepareFailed(
                "\(operation) path must be below the Mac apps root"
            )
        }
    }

    private static func withSuppressedUpstreamStandardOutput<T>(
        _ body: () throws -> T
    ) throws -> T {
        #if canImport(Darwin)
        upstreamStandardOutputLock.lock()
        defer { upstreamStandardOutputLock.unlock() }
        guard fflush(stdout) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot flush prepare stdout"
            )
        }
        let saved = Darwin.fcntl(
            STDOUT_FILENO,
            F_DUPFD_CLOEXEC,
            STDERR_FILENO + 1
        )
        guard saved >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot preserve prepare stdout"
            )
        }
        defer { Darwin.close(saved) }
        let sink = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard sink >= 0, Darwin.dup2(sink, STDOUT_FILENO) >= 0 else {
            if sink >= 0 { Darwin.close(sink) }
            throw PlayCoverBackendError.prepareFailed(
                "cannot isolate prepare stdout"
            )
        }
        defer { Darwin.close(sink) }
        let result = Result<T, Error> { try body() }
        let flushStatus = fflush(stdout)
        let restoreStatus = Darwin.dup2(saved, STDOUT_FILENO)
        guard restoreStatus >= 0, flushStatus == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot restore prepare stdout"
            )
        }
        return try result.get()
        #else
        return try body()
        #endif
    }

    private static func normalizedCDHash(_ value: String?) -> String? {
        guard let value else { return nil }
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

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 70)
                || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func isUppercaseHex(
        _ value: String,
        count: Int
    ) -> Bool {
        value.utf8.count == count && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 70)
        }
    }

    private static func lexicalURL(
        _ path: String,
        isDirectory: Bool
    ) -> URL {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return URL(
            fileURLWithPath: "/" + components.joined(separator: "/"),
            isDirectory: isDirectory
        )
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
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = existing.path.withCString {
            Darwin.realpath($0, &buffer)
        }
        var result = resolved == nil
            ? existing.path
            : String(cString: buffer)
        #else
        var result = existing.resolvingSymlinksInPath().path
        #endif
        for component in suffix {
            result = (result as NSString).appendingPathComponent(component)
        }
        return result
    }

    private static func update(_ hasher: inout SHA256, _ value: String) {
        let data = Data(value.utf8)
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) {
            hasher.update(data: Data($0))
        }
        hasher.update(data: data)
    }

    private static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String
        where D.Element == UInt8
    {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
