import CryptoKit
import Foundation
import IOSUseProtocol
import Security
#if canImport(Darwin)
import Darwin
#endif

/// The policy-owned lifecycle state of the stable PlayCover signer.
public enum PlayCoverSigningIdentityHealth: String, Codable, Sendable {
    case healthy
    case missing
    case replaced
    case expired
    case trustRequired = "trust_required"
    case inaccessible
    case unavailable
}

/// Policy evidence is carried with every signer observation so downstream
/// manifests do not have to infer which signer contract produced it.
public struct PlayCoverSigningIdentityPolicyEvidence:
    Codable,
    Equatable,
    Sendable
{
    public enum Source: String, Codable, Sendable {
        case managedUserKeychain = "ios-use-managed-user-keychain"
    }

    public let revision: String
    public let source: Source
    public let health: PlayCoverSigningIdentityHealth

    public init(
        revision: String,
        source: Source,
        health: PlayCoverSigningIdentityHealth
    ) {
        self.revision = revision
        self.source = source
        self.health = health
    }
}

/// Immutable, non-secret evidence for exactly one code-signing identity.
///
/// `codesignSelector` is the full SHA-1 digest of the certificate, which is an
/// exact selector accepted by `/usr/bin/codesign`. It is deliberately not a
/// common name or another ambiguous display string.
public struct PlayCoverSigningIdentityEvidence:
    Codable,
    Equatable,
    Sendable
{
    public let publicKeySPKISHA256: String
    public let certificateSHA256: String
    public let codesignSelector: String
    public let notBefore: Date
    public let notAfter: Date
    public let policy: PlayCoverSigningIdentityPolicyEvidence

    public init(
        publicKeySPKISHA256: String,
        certificateSHA256: String,
        codesignSelector: String,
        notBefore: Date,
        notAfter: Date,
        policy: PlayCoverSigningIdentityPolicyEvidence
    ) {
        self.publicKeySPKISHA256 = publicKeySPKISHA256
        self.certificateSHA256 = certificateSHA256
        self.codesignSelector = codesignSelector
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.policy = policy
    }
}

public struct PlayCoverSigningIdentityResolution:
    Equatable,
    Sendable
{
    public let health: PlayCoverSigningIdentityHealth
    public let evidence: PlayCoverSigningIdentityEvidence?

    public init(
        health: PlayCoverSigningIdentityHealth,
        evidence: PlayCoverSigningIdentityEvidence?
    ) {
        self.health = health
        self.evidence = evidence
    }
}

public enum PlayCoverSigningIdentityServiceError:
    Error,
    Equatable,
    CustomStringConvertible,
    MachineErrorConvertible,
    Sendable
{
    case identityCreationUnavailable
    case invalidCreatedIdentity
    case bindingUnavailable
    case trustConfigurationFailed(OSStatus)
    case signingProbeFailed(String)
    case unhealthy(PlayCoverSigningIdentityHealth)

    public var description: String {
        switch self {
        case .identityCreationUnavailable:
            return "the dedicated PlayCover code-signing identity could "
                + "not be created"
        case .invalidCreatedIdentity:
            return "the created PlayCover code-signing identity did not "
                + "produce valid immutable evidence"
        case .bindingUnavailable:
            return "the PlayCover code-signing identity binding is "
                + "unavailable"
        case .trustConfigurationFailed(let status):
            return "the dedicated PlayCover code-signing identity could "
                + "not be trusted for code signing (Security status "
                + "\(status)); retry `ios-use config --playcover` and "
                + "approve the macOS authentication dialog"
        case .signingProbeFailed(let detail):
            return "the dedicated PlayCover code-signing identity failed "
                + "its signing probe: \(detail)"
        case .unhealthy(let health):
            if health == .missing {
                return "the dedicated PlayCover code-signing identity is "
                    + "not initialized; run `ios-use config --playcover`"
            }
            if health == .trustRequired {
                return "the dedicated PlayCover code-signing identity "
                    + "requires trust; run `ios-use config --playcover`"
            }
            return "the dedicated PlayCover code-signing identity is "
                + health.rawValue
        }
    }

    var machineError: MachineError {
        let code: String
        let retryable: Bool
        switch self {
        case .identityCreationUnavailable:
            code = "playcover_signing_identity_creation_unavailable"
            retryable = false
        case .invalidCreatedIdentity:
            code = "playcover_signing_identity_invalid"
            retryable = false
        case .bindingUnavailable:
            code = "playcover_signing_identity_binding_unavailable"
            retryable = true
        case .trustConfigurationFailed:
            code = "playcover_signing_identity_trust_required"
            retryable = true
        case .signingProbeFailed:
            code = "playcover_signing_identity_inaccessible"
            retryable = true
        case .unhealthy(let health):
            code = "playcover_signing_identity_\(health.rawValue)"
            retryable = health == .missing
                || health == .trustRequired
                || health == .inaccessible
                || health == .unavailable
        }
        return MachineError(
            message: description,
            category: IOSUseErrorCategory.authorization,
            code: code,
            phase: "playcover_signing_identity",
            retryable: retryable,
            fatal: false,
            mutationMayHaveApplied: false
        )
    }
}

struct PlayCoverSigningIdentitySnapshot: Equatable, Sendable {
    let publicKeySPKISHA256: String
    let certificateSHA256: String
    let codesignSelector: String
    let notBefore: Date
    let notAfter: Date
    let trustedForCodeSigning: Bool

    init(
        publicKeySPKISHA256: String,
        certificateSHA256: String,
        codesignSelector: String,
        notBefore: Date,
        notAfter: Date,
        trustedForCodeSigning: Bool = true
    ) {
        self.publicKeySPKISHA256 = publicKeySPKISHA256
        self.certificateSHA256 = certificateSHA256
        self.codesignSelector = codesignSelector
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.trustedForCodeSigning = trustedForCodeSigning
    }
}

struct PlayCoverSigningIdentityBinding: Codable, Equatable, Sendable {
    let publicKeySPKISHA256: String
    let certificateSHA256: String
    let codesignSelector: String
    let notBefore: Date
    let notAfter: Date
    let policyRevision: String
    let policySource: PlayCoverSigningIdentityPolicyEvidence.Source

    init(
        snapshot: PlayCoverSigningIdentitySnapshot,
        policy: PlayCoverSigningIdentityPolicyEvidence
    ) {
        publicKeySPKISHA256 = snapshot.publicKeySPKISHA256
        certificateSHA256 = snapshot.certificateSHA256
        codesignSelector = snapshot.codesignSelector
        notBefore = snapshot.notBefore
        notAfter = snapshot.notAfter
        policyRevision = policy.revision
        policySource = policy.source
    }
}

enum PlayCoverSigningIdentityObservationError: Error {
    case inaccessible
}

enum PlayCoverSigningACLMatcher {
    static func containsRequiredTrustedApplication(
        _ required: Data,
        candidates: [Data]
    ) -> Bool {
        candidates.contains(required)
    }
}

/// Backend boundary for the explicit initialization ceremony and read-only
/// identity resolution used by ordinary starts.
protocol PlayCoverSigningIdentityBackend: AnyObject {
    func readBinding() throws -> PlayCoverSigningIdentityBinding?
    func claimInitialBinding(
        _ binding: PlayCoverSigningIdentityBinding
    ) throws -> Bool
    func identitySnapshots(
        matching binding: PlayCoverSigningIdentityBinding
    ) throws -> [PlayCoverSigningIdentitySnapshot]
    func createIdentity() throws -> PlayCoverSigningIdentitySnapshot
    func configureCodeSigningTrust(
        certificateSHA256: String
    ) throws
    func probeCodeSigning(codesignSelector: String) throws
}

public final class PlayCoverSigningIdentityService {
    public static let policyRevision = "playcover-stable-signer-v1"

    /// Fixed public-evidence namespace. It never depends on HOME or
    /// IOS_USE_HOME. The private key and certificate remain in Keychain; this
    /// owner-only file avoids binding access control being tied to one ad-hoc
    /// CLI build's changing CDHash.
    static let bindingDirectoryName = "dev.ios-use"
    static let bindingFilename =
        "playcover-stable-signing-binding-v1.json"

    private let backend: PlayCoverSigningIdentityBackend
    private let now: () -> Date
    private let initializationLockURL: URL?

    public convenience init() {
        self.init(
            backend: SecurityPlayCoverSigningIdentityBackend(),
            initializationLockURL: nil
        )
    }

    init(
        backend: PlayCoverSigningIdentityBackend,
        now: @escaping () -> Date = Date.init,
        initializationLockURL: URL?
    ) {
        self.backend = backend
        self.now = now
        self.initializationLockURL = initializationLockURL
    }

    /// Resolves only the bound identity. It never creates or rotates a signer.
    public func resolve() -> PlayCoverSigningIdentityResolution {
        do {
            guard let binding = try backend.readBinding() else {
                return resolution(.missing)
            }
            let identities = try backend.identitySnapshots(
                matching: binding
            )
            return resolve(
                binding: binding,
                identities: identities,
                at: now()
            )
        } catch PlayCoverSigningIdentityObservationError.inaccessible {
            return resolution(.inaccessible)
        } catch {
            return resolution(.unavailable)
        }
    }

    /// Performs the one-time initialization. The owner-only binding claim is
    /// atomic, so concurrent initializers converge on one winning binding.
    ///
    /// An existing binding is never replaced or repaired by this method.
    public func initializeIfNeeded()
        throws -> PlayCoverSigningIdentityResolution
    {
        do {
            if try backend.readBinding() != nil {
                return resolve()
            }

            let created = try createIdentitySnapshot()
            guard isStructurallyValid(created) else {
                throw PlayCoverSigningIdentityServiceError
                    .invalidCreatedIdentity
            }
            let binding = PlayCoverSigningIdentityBinding(
                snapshot: created,
                policy: healthyPolicy()
            )
            _ = try backend.claimInitialBinding(binding)
            return resolve()
        } catch let error as PlayCoverSigningIdentityServiceError {
            throw error
        } catch {
            throw PlayCoverSigningIdentityServiceError.bindingUnavailable
        }
    }

    /// Explicit, user-approved one-time configuration. This is the only
    /// default path that may create an identity or modify per-user Trust
    /// Settings. A cancelled authentication leaves the same bound identity in
    /// place so the command can resume safely without generating a new one.
    public func initializeForConfiguration()
        throws -> PlayCoverSigningIdentityEvidence
    {
        try withInitializationLock {
            var resolution = try initializeIfNeeded()
            if resolution.health == .missing
                || resolution.health == .replaced
            {
                resolution = try repairDeterministicBoundIdentity()
            }
            if resolution.health == .trustRequired,
               let evidence = resolution.evidence {
                try configureCodeSigningTrust(
                    certificateSHA256: evidence.certificateSHA256
                )
                resolution = resolve()
            }
            guard resolution.health == .healthy,
                  let evidence = resolution.evidence else {
                throw PlayCoverSigningIdentityServiceError.unhealthy(
                    resolution.health
                )
            }
            try backend.probeCodeSigning(
                codesignSelector: evidence.codesignSelector
            )
            let final = resolve()
            guard final.health == .healthy,
                  final.evidence == evidence else {
                throw PlayCoverSigningIdentityServiceError.unhealthy(
                    final.health
                )
            }
            return evidence
        }
    }

    private func configureCodeSigningTrust(
        certificateSHA256: String
    ) throws {
        do {
            try backend.configureCodeSigningTrust(
                certificateSHA256: certificateSHA256
            )
        } catch let error as PlayCoverSigningIdentityServiceError {
            throw error
        } catch {
            throw PlayCoverSigningIdentityServiceError
                .unhealthy(.unavailable)
        }
    }

    /// Explicit configuration may reinstall the deterministic certificate for
    /// an existing binding. It must reproduce every immutable bound field; this
    /// is repair, never implicit rotation.
    private func repairDeterministicBoundIdentity()
        throws -> PlayCoverSigningIdentityResolution
    {
        let binding: PlayCoverSigningIdentityBinding?
        do {
            binding = try backend.readBinding()
        } catch {
            throw PlayCoverSigningIdentityServiceError.bindingUnavailable
        }
        guard let binding else {
            return try initializeIfNeeded()
        }
        let recreated = try createIdentitySnapshot()
        guard isStructurallyValid(recreated),
              snapshot(recreated, matches: binding)
        else {
            throw PlayCoverSigningIdentityServiceError
                .invalidCreatedIdentity
        }
        return resolve()
    }

    private func createIdentitySnapshot()
        throws -> PlayCoverSigningIdentitySnapshot
    {
        do {
            return try backend.createIdentity()
        } catch let error as PlayCoverSigningIdentityServiceError {
            throw error
        } catch let error as SecurityPlayCoverSigningIdentityBackendError {
            switch error {
            case .invalidCertificate, .unsupportedPublicKey:
                throw PlayCoverSigningIdentityServiceError
                    .invalidCreatedIdentity
            case .unavailable,
                 .malformedBinding,
                 .keyCreation,
                 .certificateInstall,
                 .identityAssociation:
                throw PlayCoverSigningIdentityServiceError
                    .identityCreationUnavailable
            }
        } catch let error as PlayCoverSigningCertificateBuilderError {
            switch error {
            case .signatureFailed:
                throw PlayCoverSigningIdentityServiceError
                    .identityCreationUnavailable
            case .invalidValidity,
                 .invalidSerialNumber,
                 .unsupportedPrivateKey,
                 .publicKeyUnavailable,
                 .publicKeyExportFailed:
                throw PlayCoverSigningIdentityServiceError
                    .invalidCreatedIdentity
            }
        } catch {
            throw PlayCoverSigningIdentityServiceError
                .identityCreationUnavailable
        }
    }

    public func requireHealthy(
        initializeIfMissing: Bool
    ) throws -> PlayCoverSigningIdentityEvidence {
        var resolution = resolve()
        if resolution.health == .missing, initializeIfMissing {
            resolution = try initializeIfNeeded()
        }
        guard resolution.health == .healthy,
              let evidence = resolution.evidence else {
            throw PlayCoverSigningIdentityServiceError.unhealthy(
                resolution.health
            )
        }
        return evidence
    }

    private func resolve(
        binding: PlayCoverSigningIdentityBinding,
        identities: [PlayCoverSigningIdentitySnapshot],
        at date: Date
    ) -> PlayCoverSigningIdentityResolution {
        guard binding.policyRevision == Self.policyRevision,
              binding.policySource == .managedUserKeychain
        else {
            return resolution(.replaced)
        }

        if let identity = identities.first(where: {
            $0.certificateSHA256 == binding.certificateSHA256
        }) {
            guard snapshot(identity, matches: binding) else {
                return resolution(
                    .replaced,
                    snapshot: identity,
                    binding: binding
                )
            }
            if date >= identity.notAfter {
                return resolution(
                    .expired,
                    snapshot: identity,
                    binding: binding
                )
            }
            guard date >= identity.notBefore else {
                return resolution(
                    .unavailable,
                    snapshot: identity,
                    binding: binding
                )
            }
            guard identity.trustedForCodeSigning else {
                return resolution(
                    .trustRequired,
                    snapshot: identity,
                    binding: binding
                )
            }
            return resolution(
                .healthy,
                snapshot: identity,
                binding: binding
            )
        }

        if let replacement = identities.first(where: {
            $0.publicKeySPKISHA256 == binding.publicKeySPKISHA256
        }) {
            return resolution(
                .replaced,
                snapshot: replacement,
                binding: binding
            )
        }
        return resolution(.missing)
    }

    private func snapshot(
        _ snapshot: PlayCoverSigningIdentitySnapshot,
        matches binding: PlayCoverSigningIdentityBinding
    ) -> Bool {
        snapshot.publicKeySPKISHA256 == binding.publicKeySPKISHA256
            && snapshot.certificateSHA256 == binding.certificateSHA256
            && snapshot.codesignSelector == binding.codesignSelector
            && snapshot.notBefore == binding.notBefore
            && snapshot.notAfter == binding.notAfter
    }

    private func isStructurallyValid(
        _ snapshot: PlayCoverSigningIdentitySnapshot
    ) -> Bool {
        isUppercaseHex(snapshot.publicKeySPKISHA256, count: 64)
            && isUppercaseHex(snapshot.certificateSHA256, count: 64)
            && isUppercaseHex(snapshot.codesignSelector, count: 40)
            && snapshot.notBefore < snapshot.notAfter
    }

    private func isUppercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 65 && $0.value <= 70)
            }
    }

    private func healthyPolicy()
        -> PlayCoverSigningIdentityPolicyEvidence
    {
        PlayCoverSigningIdentityPolicyEvidence(
            revision: Self.policyRevision,
            source: .managedUserKeychain,
            health: .healthy
        )
    }

    private func resolution(
        _ health: PlayCoverSigningIdentityHealth,
        snapshot: PlayCoverSigningIdentitySnapshot? = nil,
        binding: PlayCoverSigningIdentityBinding? = nil
    ) -> PlayCoverSigningIdentityResolution {
        let evidence = snapshot.map {
            PlayCoverSigningIdentityEvidence(
                publicKeySPKISHA256: $0.publicKeySPKISHA256,
                certificateSHA256: $0.certificateSHA256,
                codesignSelector: $0.codesignSelector,
                notBefore: $0.notBefore,
                notAfter: $0.notAfter,
                policy: PlayCoverSigningIdentityPolicyEvidence(
                    revision:
                        binding?.policyRevision ?? Self.policyRevision,
                    source:
                        binding?.policySource ?? .managedUserKeychain,
                    health: health
                )
            )
        }
        return PlayCoverSigningIdentityResolution(
            health: health,
            evidence: evidence
        )
    }

    private func withInitializationLock<T>(
        _ body: () throws -> T
    ) throws -> T {
        #if canImport(Darwin)
        let path = try initializationLockPath()
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw PlayCoverSigningIdentityServiceError.bindingUnavailable
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            throw PlayCoverSigningIdentityServiceError.bindingUnavailable
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
        #else
        return try body()
        #endif
    }

    private func initializationLockPath() throws -> String {
        if let initializationLockURL {
            return initializationLockURL.path
        }
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(
            _CS_DARWIN_USER_TEMP_DIR,
            &buffer,
            buffer.count
        ) > 0 else {
            throw PlayCoverSigningIdentityServiceError.bindingUnavailable
        }
        return URL(
            fileURLWithPath: String(cString: buffer),
            isDirectory: true
        ).appendingPathComponent(
            "dev.ios-use.playcover-signer.lock"
        ).path
        #else
        throw PlayCoverSigningIdentityServiceError.bindingUnavailable
        #endif
    }
}

private enum SecurityPlayCoverSigningIdentityBackendError: Error {
    case unavailable
    case malformedBinding
    case unsupportedPublicKey
    case invalidCertificate
    case keyCreation(OSStatus)
    case certificateInstall(OSStatus)
    case identityAssociation(OSStatus)
}

final class SecurityPlayCoverSigningIdentityBackend:
    PlayCoverSigningIdentityBackend
{
    private static let keyApplicationTag = Data(
        "dev.ios-use.playcover.stable-signing-key-v1".utf8
    )
    private static let keyLabel =
        "ios-use PlayCover Stable Code Signing Key"
    private static let certificateLabel =
        "ios-use PlayCover Stable Code Signing"
    private static let certificateNotBefore =
        Date(timeIntervalSince1970: 1_735_689_600)
    private static let certificateNotAfter =
        Date(timeIntervalSince1970: 2_366_841_600)
    private let bindingDirectoryOverride: URL?
    private let afterTemporaryBindingSyncForTesting:
        (() throws -> Void)?

    init(
        bindingDirectoryOverride: URL? = nil,
        afterTemporaryBindingSyncForTesting:
            (() throws -> Void)? = nil
    ) {
        self.bindingDirectoryOverride = bindingDirectoryOverride
        self.afterTemporaryBindingSyncForTesting =
            afterTemporaryBindingSyncForTesting
    }

    func readBinding() throws -> PlayCoverSigningIdentityBinding? {
        let directory = bindingURL().deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryDescriptor < 0, errno == ENOENT {
            return nil
        }
        guard directoryDescriptor >= 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        defer { Darwin.close(directoryDescriptor) }
        try validateBindingDirectory(descriptor: directoryDescriptor)
        let descriptor = Darwin.openat(
            directoryDescriptor,
            PlayCoverSigningIdentityService.bindingFilename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        defer { Darwin.close(descriptor) }
        return try decodeBindingData(
            try readBindingData(descriptor: descriptor)
        )
    }

    func claimInitialBinding(
        _ binding: PlayCoverSigningIdentityBinding
    ) throws -> Bool {
        let directory = try ensureBindingDirectory()
        let data = try JSONEncoder().encode(binding)
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        defer { Darwin.close(directoryDescriptor) }
        try validateBindingDirectory(
            descriptor: directoryDescriptor
        )

        let finalName =
            PlayCoverSigningIdentityService.bindingFilename
        let temporaryName =
            ".\(finalName).\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        var temporaryExists = true
        defer {
            Darwin.close(descriptor)
            if temporaryExists {
                _ = Darwin.unlinkat(
                    directoryDescriptor,
                    temporaryName,
                    0
                )
                _ = Darwin.fsync(directoryDescriptor)
            }
        }
        guard Darwin.fchmod(
            descriptor,
            S_IRUSR | S_IWUSR
        ) == 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        try writeBindingData(data, descriptor: descriptor)
        try afterTemporaryBindingSyncForTesting?()

        let publishStatus = Darwin.renameatx_np(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            finalName,
            UInt32(RENAME_EXCL)
        )
        if publishStatus != 0, errno == EEXIST {
            guard Darwin.unlinkat(
                directoryDescriptor,
                temporaryName,
                0
            ) == 0,
                  Darwin.fsync(directoryDescriptor) == 0 else {
                throw SecurityPlayCoverSigningIdentityBackendError
                    .unavailable
            }
            temporaryExists = false
            _ = try readPublishedBinding(
                directoryDescriptor: directoryDescriptor
            )
            return false
        }
        guard publishStatus == 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        temporaryExists = false
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        guard try readPublishedBinding(
            directoryDescriptor: directoryDescriptor
        ) == binding else {
            throw SecurityPlayCoverSigningIdentityBackendError
                .malformedBinding
        }
        return true
    }

    func identitySnapshots(
        matching binding: PlayCoverSigningIdentityBinding
    )
        throws -> [PlayCoverSigningIdentitySnapshot]
    {
        var matches: [PlayCoverSigningIdentitySnapshot] = []
        for identity in try keychainIdentities() {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(
                identity,
                &certificate
            ) == errSecSuccess,
                  let certificate else {
                continue
            }
            let certificateSHA256 = sha256(
                SecCertificateCopyData(certificate) as Data
            )
            if certificateSHA256 == binding.certificateSHA256 {
                try requireAccessiblePrivateKey(identity)
                matches.append(try snapshot(identity))
                continue
            }
            // A same-key reissue is useful replacement evidence. Unrelated
            // identities are deliberately best-effort so an unsupported or
            // malformed certificate elsewhere in the user's Keychain cannot
            // make the bound ios-use identity unavailable.
            if let candidate = try? snapshot(identity),
               candidate.publicKeySPKISHA256
                    == binding.publicKeySPKISHA256 {
                matches.append(candidate)
            }
        }
        return matches
    }

    private func requireAccessiblePrivateKey(
        _ identity: SecIdentity
    ) throws {
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(
            identity,
            &privateKey
        ) == errSecSuccess,
              let privateKey,
              signingACLContainsCodesign(privateKey) else {
            throw PlayCoverSigningIdentityObservationError.inaccessible
        }
    }

    private func signingACLContainsCodesign(
        _ privateKey: SecKey
    ) -> Bool {
        guard let required = trustedApplicationData(
            path: "/usr/bin/codesign"
        ) else {
            return false
        }
        let keychainItem = unsafeBitCast(
            privateKey,
            to: SecKeychainItem.self
        )
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(
            keychainItem,
            &access
        ) == errSecSuccess,
              let access,
              let aclValues = SecAccessCopyMatchingACLList(
                  access,
                  kSecACLAuthorizationSign
              )
        else {
            return false
        }

        var candidates: [Data] = []
        for rawValue in aclValues as NSArray {
            let value = rawValue as AnyObject
            guard CFGetTypeID(value) == SecACLGetTypeID() else {
                return false
            }
            let acl = unsafeBitCast(value, to: SecACL.self)
            var applications: CFArray?
            var description: CFString?
            var promptSelector = SecKeychainPromptSelector()
            guard SecACLCopyContents(
                acl,
                &applications,
                &description,
                &promptSelector
            ) == errSecSuccess else {
                return false
            }
            guard let applications else {
                continue
            }
            for rawApplicationValue in applications as NSArray {
                let applicationValue =
                    rawApplicationValue as AnyObject
                guard CFGetTypeID(applicationValue)
                        == SecTrustedApplicationGetTypeID()
                else {
                    return false
                }
                let application = unsafeBitCast(
                    applicationValue,
                    to: SecTrustedApplication.self
                )
                guard let data = trustedApplicationData(
                    application
                ) else {
                    return false
                }
                candidates.append(data)
            }
        }
        return PlayCoverSigningACLMatcher
            .containsRequiredTrustedApplication(
                required,
                candidates: candidates
            )
    }

    private func trustedApplicationData(
        path: UnsafePointer<CChar>?
    ) -> Data? {
        var application: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(
            path,
            &application
        ) == errSecSuccess,
              let application else {
            return nil
        }
        return trustedApplicationData(application)
    }

    private func trustedApplicationData(
        _ application: SecTrustedApplication
    ) -> Data? {
        var data: CFData?
        guard SecTrustedApplicationCopyData(
            application,
            &data
        ) == errSecSuccess,
              let data else {
            return nil
        }
        return data as Data
    }

    private func keychainIdentities() throws -> [SecIdentity] {
        var result: CFTypeRef?
        // Enumerate identities without a validity policy so an expired bound
        // certificate remains observable and can be classified as expired.
        // The binding is still resolved only by its exact cryptographic
        // evidence; unrelated identities are never selected by display name.
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        let identities: [SecIdentity]
        if let values = result as? [SecIdentity] {
            identities = values
        } else if let value = result,
                  CFGetTypeID(value) == SecIdentityGetTypeID()
        {
            identities = [unsafeBitCast(value, to: SecIdentity.self)]
        } else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        return identities
    }

    func createIdentity() throws -> PlayCoverSigningIdentitySnapshot {
        let privateKey: SecKey
        if let existing = try managedPrivateKey() {
            privateKey = existing
        } else {
            let access = try managedKeyAccess()
            var error: Unmanaged<CFError>?
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 3072,
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.keyApplicationTag,
                kSecAttrLabel as String: Self.keyLabel,
                kSecAttrAccess as String: access,
            ]
            guard let created = SecKeyCreateRandomKey(
                attributes as CFDictionary,
                &error
            ) else {
                if let existing = try managedPrivateKey() {
                    privateKey = existing
                } else {
                    let status = error.map {
                        OSStatus(
                            CFErrorGetCode($0.takeRetainedValue())
                        )
                    } ?? errSecInternalError
                    throw SecurityPlayCoverSigningIdentityBackendError
                        .keyCreation(status)
                }
                return try installIdentity(privateKey: privateKey)
            }
            privateKey = created
        }
        return try installIdentity(privateKey: privateKey)
    }

    func configureCodeSigningTrust(
        certificateSHA256: String
    ) throws {
        let (_, certificate) = try identityAndCertificate(
            certificateSHA256: certificateSHA256
        )
        guard let policy = SecPolicyCreateWithProperties(
            kSecPolicyAppleCodeSigning,
            nil
        ) else {
            throw PlayCoverSigningIdentityServiceError
                .trustConfigurationFailed(errSecParam)
        }
        let settings: NSDictionary = [
            kSecTrustSettingsPolicy as String: policy,
            kSecTrustSettingsResult as String:
                NSNumber(
                    value:
                        SecTrustSettingsResult.trustRoot.rawValue
                ),
        ]
        let status = SecTrustSettingsSetTrustSettings(
            certificate,
            .user,
            settings
        )
        guard status == errSecSuccess else {
            throw PlayCoverSigningIdentityServiceError
                .trustConfigurationFailed(status)
        }
    }

    func probeCodeSigning(codesignSelector: String) throws {
        let root = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "ios-use-playcover-signer-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("probe")
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: executable
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let signed = try Shell.runWithResult(
                "/usr/bin/codesign",
                arguments: [
                    "--force",
                    "--sign",
                    codesignSelector,
                    "--timestamp=none",
                    executable.path,
                ]
            )
            guard signed.exitCode == 0 else {
                throw PlayCoverSigningIdentityServiceError
                    .signingProbeFailed(signed.stderr)
            }
            let verified = try Shell.runWithResult(
                "/usr/bin/codesign",
                arguments: [
                    "--verify",
                    "--strict",
                    executable.path,
                ]
            )
            guard verified.exitCode == 0 else {
                throw PlayCoverSigningIdentityServiceError
                    .signingProbeFailed(verified.stderr)
            }
        } catch let error as PlayCoverSigningIdentityServiceError {
            throw error
        } catch {
            throw PlayCoverSigningIdentityServiceError
                .signingProbeFailed(String(describing: error))
        }
    }

    private func installIdentity(
        privateKey: SecKey
    ) throws -> PlayCoverSigningIdentitySnapshot {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecurityPlayCoverSigningIdentityBackendError
                .unsupportedPublicKey
        }
        var exportError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(
            publicKey,
            &exportError
        ) as Data? else {
            throw SecurityPlayCoverSigningIdentityBackendError
                .unsupportedPublicKey
        }
        var serial = Data(SHA256.hash(data: publicKeyData).prefix(20))
        serial[serial.startIndex] &= 0x7F
        if serial.allSatisfy({ $0 == 0 }) {
            serial[serial.index(before: serial.endIndex)] = 1
        }
        let certificateData = try PlayCoverSigningCertificateBuilder.build(
            privateKey: privateKey,
            serialNumber: serial,
            notBefore: Self.certificateNotBefore,
            notAfter: Self.certificateNotAfter
        )
        guard let certificate = SecCertificateCreateWithData(
            nil,
            certificateData as CFData
        ) else {
            throw SecurityPlayCoverSigningIdentityBackendError
                .invalidCertificate
        }
        let addStatus = SecItemAdd(
            [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrLabel as String: Self.certificateLabel,
                kSecAttrSynchronizable as String:
                    kCFBooleanFalse as Any,
            ] as CFDictionary,
            nil
        )
        guard addStatus == errSecSuccess
                || addStatus == errSecDuplicateItem else {
            throw SecurityPlayCoverSigningIdentityBackendError
                .certificateInstall(addStatus)
        }
        guard let identity = SecIdentityCreate(
            nil,
            certificate,
            privateKey
        ) else {
            throw SecurityPlayCoverSigningIdentityBackendError
                .identityAssociation(errSecInternalError)
        }
        do {
            return try snapshot(identity)
        } catch SecurityPlayCoverSigningIdentityBackendError
            .unsupportedPublicKey {
            throw SecurityPlayCoverSigningIdentityBackendError
                .unsupportedPublicKey
        } catch {
            throw SecurityPlayCoverSigningIdentityBackendError
                .invalidCertificate
        }
    }

    private func managedPrivateKey() throws -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassKey,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrApplicationTag as String:
                    Self.keyApplicationTag,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnRef as String: true,
            ] as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let result,
              CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        return unsafeBitCast(result, to: SecKey.self)
    }

    private func managedKeyAccess() throws -> SecAccess {
        var codesign: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(
            "/usr/bin/codesign",
            &codesign
        ) == errSecSuccess,
              let codesign else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        var current: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(
            nil,
            &current
        ) == errSecSuccess,
              let current else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        var access: SecAccess?
        let status = SecAccessCreate(
            Self.keyLabel as NSString,
            [codesign, current] as NSArray,
            &access
        )
        guard status == errSecSuccess, let access else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        return access
    }

    private func identityAndCertificate(
        certificateSHA256: String
    ) throws -> (SecIdentity, SecCertificate) {
        for identity in try keychainIdentities() {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(
                identity,
                &certificate
            ) == errSecSuccess,
                  let certificate else {
                continue
            }
            if sha256(
                SecCertificateCopyData(certificate) as Data
            ) == certificateSHA256 {
                return (identity, certificate)
            }
        }
        throw PlayCoverSigningIdentityServiceError.unhealthy(.missing)
    }

    private func bindingURL() -> URL {
        let directory: URL
        if let bindingDirectoryOverride {
            directory = bindingDirectoryOverride
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent(
                    "Application Support",
                    isDirectory: true
                )
                .appendingPathComponent(
                    PlayCoverSigningIdentityService.bindingDirectoryName,
                    isDirectory: true
                )
        }
        return directory.appendingPathComponent(
            PlayCoverSigningIdentityService.bindingFilename
        )
    }

    private func ensureBindingDirectory() throws -> URL {
        let directory = bindingURL().deletingLastPathComponent()
        if Darwin.mkdir(directory.path, 0o700) != 0,
           errno != EEXIST {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        defer { Darwin.close(descriptor) }
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              initialStatus.st_mode & S_IFMT == S_IFDIR,
              initialStatus.st_uid == geteuid() else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        guard Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        try validateBindingDirectory(descriptor: descriptor)
        return directory
    }

    private func validateBindingDirectory(
        descriptor: Int32
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o700 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
    }

    private func readPublishedBinding(
        directoryDescriptor: Int32
    ) throws -> PlayCoverSigningIdentityBinding {
        let descriptor = Darwin.openat(
            directoryDescriptor,
            PlayCoverSigningIdentityService.bindingFilename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        defer { Darwin.close(descriptor) }
        return try decodeBindingData(
            try readBindingData(descriptor: descriptor)
        )
    }

    private func decodeBindingData(
        _ data: Data
    ) throws -> PlayCoverSigningIdentityBinding {
        do {
            return try JSONDecoder().decode(
                PlayCoverSigningIdentityBinding.self,
                from: data
            )
        } catch {
            throw SecurityPlayCoverSigningIdentityBackendError
                .malformedBinding
        }
    }

    private func readBindingData(
        descriptor: Int32
    ) throws -> Data {
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              isSafeBindingFile(initialStatus) else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        var data = Data(count: Int(initialStatus.st_size))
        let count = try data.withUnsafeMutableBytes {
            buffer -> Int in
            guard let base = buffer.baseAddress else {
                return 0
            }
            var offset = 0
            while offset < buffer.count {
                let readCount = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if readCount < 0, errno == EINTR {
                    continue
                }
                guard readCount > 0 else {
                    throw SecurityPlayCoverSigningIdentityBackendError
                        .unavailable
                }
                offset += readCount
            }
            return offset
        }
        guard count == data.count else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              isSafeBindingFile(finalStatus),
              finalStatus.st_dev == initialStatus.st_dev,
              finalStatus.st_ino == initialStatus.st_ino,
              finalStatus.st_size == initialStatus.st_size else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        return data
    }

    private func isSafeBindingFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_mode & 0o777 == 0o600
            && status.st_size > 0
            && status.st_size <= 1_048_576
            && status.st_nlink == 1
    }

    private func writeBindingData(
        _ data: Data,
        descriptor: Int32
    ) throws {
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw SecurityPlayCoverSigningIdentityBackendError
                    .unavailable
            }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw SecurityPlayCoverSigningIdentityBackendError
                        .unavailable
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
    }

    private func snapshot(
        _ identity: SecIdentity
    ) throws -> PlayCoverSigningIdentitySnapshot {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate)
                == errSecSuccess,
              let certificate
        else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        guard let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(
                  publicKey,
                  nil
              ) as Data?,
              let notBefore = certificateDate(
                  certificate,
                  oid: kSecOIDX509V1ValidityNotBefore
              ),
              let notAfter = certificateDate(
                  certificate,
                  oid: kSecOIDX509V1ValidityNotAfter
              )
        else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }
        let spki = try subjectPublicKeyInfo(
            key: publicKey,
            externalRepresentation: publicKeyData
        )
        return PlayCoverSigningIdentitySnapshot(
            publicKeySPKISHA256: sha256(spki),
            certificateSHA256: sha256(certificateData),
            codesignSelector: sha1(certificateData),
            notBefore: notBefore,
            notAfter: notAfter,
            trustedForCodeSigning:
                isTrustedForCodeSigning(certificate)
        )
    }

    private func certificateDate(
        _ certificate: SecCertificate,
        oid: CFString
    ) -> Date? {
        guard let values = SecCertificateCopyValues(
            certificate,
            [oid] as CFArray,
            nil
        ) as NSDictionary?,
              let property = values.object(forKey: oid) as? NSDictionary
        else {
            return nil
        }
        let value = property.object(forKey: kSecPropertyKeyValue)
        if let date = value as? Date {
            return date
        }
        if let seconds = value as? NSNumber {
            return Date(
                timeIntervalSinceReferenceDate:
                    seconds.doubleValue
            )
        }
        return nil
    }

    private func isTrustedForCodeSigning(
        _ certificate: SecCertificate
    ) -> Bool {
        guard let policy = SecPolicyCreateWithProperties(
            kSecPolicyAppleCodeSigning,
            nil
        ) else {
            return false
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(
            certificate,
            policy,
            &trust
        ) == errSecSuccess,
              let trust else {
            return false
        }
        _ = SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    private func subjectPublicKeyInfo(
        key: SecKey,
        externalRepresentation: Data
    ) throws -> Data {
        guard let attributes = SecKeyCopyAttributes(key) as NSDictionary?,
              let keyType = attributes.object(
                  forKey: kSecAttrKeyType
              ) as? String,
              let bits = attributes.object(
                  forKey: kSecAttrKeySizeInBits
              ) as? NSNumber
        else {
            throw SecurityPlayCoverSigningIdentityBackendError.unavailable
        }

        let algorithm: Data
        switch keyType as CFString {
        case kSecAttrKeyTypeRSA:
            algorithm = derSequence(
                derOID([1, 2, 840, 113549, 1, 1, 1]) + Data([0x05, 0x00])
            )
        case kSecAttrKeyTypeECSECPrimeRandom:
            let curveOID: [UInt64]
            switch bits.intValue {
            case 256:
                curveOID = [1, 2, 840, 10045, 3, 1, 7]
            case 384:
                curveOID = [1, 3, 132, 0, 34]
            case 521:
                curveOID = [1, 3, 132, 0, 35]
            default:
                throw SecurityPlayCoverSigningIdentityBackendError
                    .unsupportedPublicKey
            }
            algorithm = derSequence(
                derOID([1, 2, 840, 10045, 2, 1]) + derOID(curveOID)
            )
        default:
            throw SecurityPlayCoverSigningIdentityBackendError
                .unsupportedPublicKey
        }
        return derSequence(
            algorithm
                + derValue(
                    tag: 0x03,
                    content: Data([0]) + externalRepresentation
                )
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }
            .joined()
    }

    private func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map {
            String(format: "%02X", $0)
        }.joined()
    }

    private func derSequence(_ content: Data) -> Data {
        derValue(tag: 0x30, content: content)
    }

    private func derValue(tag: UInt8, content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    private func derLength(_ count: Int) -> Data {
        if count < 128 {
            return Data([UInt8(count)])
        }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private func derOID(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        var content = Data([
            UInt8(components[0] * 40 + components[1]),
        ])
        for component in components.dropFirst(2) {
            var value = component
            var encoded = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            content.append(contentsOf: encoded)
        }
        return derValue(tag: 0x06, content: content)
    }
}
