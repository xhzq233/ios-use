import Foundation
import PlayCoverUpstream

public struct PlayCoverSignatureEvidence: Codable, Equatable, Sendable {
    public let isSigned: Bool
    public let entitlementsPlist: Data?
    public let entitlementsSHA256: String?

    init(_ upstream: PlayCoverUpstreamSignature) {
        isSigned = upstream.isSigned
        entitlementsPlist = upstream.entitlementsPlist
        entitlementsSHA256 = upstream.entitlementsSHA256
    }
}

public struct PlayCoverProvisioningEvidence: Codable, Equatable, Sendable {
    public let present: Bool
    public let size: UInt64?
    public let sha256: String?

    init(_ upstream: PlayCoverUpstreamProvisioningEvidence) {
        present = upstream.present
        size = upstream.size
        sha256 = upstream.sha256
    }
}

public struct PlayCoverInventoryEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    public let kind: String
    public let size: UInt64?
    public let posixPermissions: UInt16?
    public let sha256: String?
    public let symbolicLinkDestination: String?
    public let codeObjectKind: String?

    init(_ upstream: PlayCoverUpstreamInventoryEntry) {
        relativePath = upstream.relativePath
        kind = upstream.kind.rawValue
        size = upstream.size
        posixPermissions = upstream.posixPermissions
        sha256 = upstream.sha256
        symbolicLinkDestination = upstream.symbolicLinkDestination
        codeObjectKind = upstream.codeObjectKind
    }
}

public struct PlayCoverMachOInspection: Codable, Equatable, Sendable {
    public let path: String
    public let relativePath: String
    public let fileSHA256: String
    public let container: String
    public let arm64SliceOffset: UInt64
    public let arm64SliceSize: UInt64
    public let byteSwapped: Bool
    public let cpuType: Int32
    public let fileType: UInt32
    public let commandCount: UInt32
    public let commandBytes: UInt32
    public let firstSectionOffset: UInt64?
    public let availableCommandPadding: UInt64
    public let platform: UInt32?
    public let minimumOS: UInt32?
    public let sdk: UInt32?
    public let encrypted: Bool
    public let dependencies: [String]
    public let rpaths: [String]
    public let signature: PlayCoverSignatureEvidence

    public var runtimeInjected: Bool {
        dependencies.contains(PlayCoverMachO.runtimeLoadPath)
    }

    public var isMacCatalyst: Bool {
        platform == PlayCoverMachO.platformMacCatalyst
    }

    init(
        _ upstream: PlayCoverUpstreamMachOInspection,
        appPath: String
    ) {
        relativePath = upstream.relativePath
        path = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).appendingPathComponent(upstream.relativePath).path
        fileSHA256 = upstream.fileSHA256
        container = upstream.container.rawValue
        arm64SliceOffset = upstream.arm64SliceOffset
        arm64SliceSize = upstream.arm64SliceSize
        byteSwapped = upstream.byteSwapped
        cpuType = upstream.cpuType
        fileType = upstream.fileType
        commandCount = upstream.commandCount
        commandBytes = upstream.commandBytes
        firstSectionOffset = upstream.firstSectionOffset
        if let firstSectionOffset,
           firstSectionOffset >= 32 + UInt64(upstream.commandBytes) {
            availableCommandPadding =
                firstSectionOffset - 32 - UInt64(upstream.commandBytes)
        } else {
            availableCommandPadding = 0
        }
        platform = upstream.platform
        minimumOS = upstream.minimumOS
        sdk = upstream.sdk
        encrypted = upstream.encrypted
        dependencies = upstream.dependencies
        rpaths = upstream.rpaths
        signature = PlayCoverSignatureEvidence(upstream.signature)
    }
}

public struct PlayCoverAppInspection: Codable, Equatable, Sendable {
    public let appPath: String
    public let sourceContentHash: String
    public let infoPlistSHA256: String
    public let bundleIdentifier: String
    public let executableName: String
    public let executablePath: String
    public let mainExecutableRelativePath: String
    public let signature: PlayCoverSignatureEvidence
    public let provisioning: PlayCoverProvisioningEvidence
    public let inventory: [PlayCoverInventoryEntry]
    public let machOs: [PlayCoverMachOInspection]

    public var mainExecutable: PlayCoverMachOInspection {
        guard let value = machOs.first(where: {
            $0.relativePath == mainExecutableRelativePath
        }) else {
            preconditionFailure(
                "validated Mac inspection is missing its main executable"
            )
        }
        return value
    }

    init(
        _ upstream: PlayCoverUpstreamAppInspection,
        appPath overrideAppPath: String? = nil
    ) {
        let resolvedAppPath = overrideAppPath ?? upstream.appPath
        appPath = resolvedAppPath
        sourceContentHash = upstream.sourceContentHash
        infoPlistSHA256 = upstream.infoPlistSHA256
        bundleIdentifier = upstream.bundleIdentifier
        executableName = upstream.executableName
        executablePath = URL(
            fileURLWithPath: resolvedAppPath,
            isDirectory: true
        ).appendingPathComponent(upstream.mainExecutableRelativePath).path
        mainExecutableRelativePath = upstream.mainExecutableRelativePath
        signature = PlayCoverSignatureEvidence(upstream.signature)
        provisioning = PlayCoverProvisioningEvidence(upstream.provisioning)
        inventory = upstream.inventory.map(PlayCoverInventoryEntry.init)
        machOs = upstream.machOs.map {
            PlayCoverMachOInspection($0, appPath: resolvedAppPath)
        }
    }
}

struct PlayCoverPreparationSource: Equatable, Sendable {
    let inspection: PlayCoverAppInspection
    let upstreamInspection: PlayCoverUpstreamAppInspection

    init(_ upstreamInspection: PlayCoverUpstreamAppInspection) {
        self.upstreamInspection = upstreamInspection
        inspection = PlayCoverAppInspection(upstreamInspection)
    }
}

/// Immutable evidence and content identity for one prepare attempt.
///
/// The original upstream inspection is retained alongside the public facade so
/// the managed cache resolver, service facade, and upstream prepare engine all
/// consume the same source snapshot without reconstructing or re-inspecting it.
struct PlayCoverPreparationPlan: Equatable, Sendable {
    let source: PlayCoverPreparationSource
    let runtimeFrameworkPath: String
    let runtimeEvidence: PlayCoverUpstreamRuntimeEvidence
    let signingIdentity: PlayCoverSigningIdentityEvidence
    let generationIdentity: PlayCoverGenerationIdentity

    var runtimeBuildHash: String {
        generationIdentity.runtimeBuildHash
    }

    var prepareRevision: String {
        generationIdentity.prepareRevision
    }

    var accountNamespacePolicyHash: String {
        generationIdentity.accountNamespacePolicyHash
    }

    var generationKey: String {
        generationIdentity.generationKey
    }
}

public struct PlayCoverEntitlementDiff: Codable, Equatable, Sendable {
    public let original: [String: String]
    public let playCoverBaseline: [String: String]
    public let final: [String: String]
    public let addedByPlayCover: [String]
    public let addedByIOSUse: [String]
    public let changedFromOriginal: [String]
    public let removedFromOriginal: [String]

    init(_ upstream: PlayCoverUpstreamEntitlementDiff) {
        original = upstream.original
        playCoverBaseline = upstream.playCoverBaseline
        final = upstream.final
        addedByPlayCover = upstream.addedByPlayCover
        addedByIOSUse = upstream.addedByIOSUse
        changedFromOriginal = upstream.changedFromOriginal
        removedFromOriginal = upstream.removedFromOriginal
    }

    static let empty = PlayCoverEntitlementDiff(
        PlayCoverUpstreamEntitlementDiff(
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

public struct PlayCoverPrepareManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let backend: String
    public let appBundleName: String
    public let mainExecutableRelativePath: String
    public let runtimeExecutableRelativePath: String
    public let infoPlistSHA256: String
    public let mainExecutableSHA256: String
    public let runtimeExecutableSHA256: String
    public let rootEntitlementsSHA256: String
    public let codeObjects: [PlayCoverInventoryEntry]
    /// Runtime-only resolution. These paths are never encoded.
    public let sourceAppPath: String
    public let preparedAppPath: String
    public let bundleIdentifier: String
    public let executableName: String
    public let executablePath: String
    public let sourceContentHash: String
    public let sourceHashAfterPreparation: String
    public let runtimeBuildHash: String
    public let prepareRevision: String
    public let accountNamespacePolicyHash: String
    public let generationKey: String
    public let signingIdentity: PlayCoverSigningIdentityEvidence
    public let rootCodeSignature:
        PlayCoverRootCodeSignatureEvidence
    public let runtimeLoadPath: String
    public let runtimeFrameworkName: String
    public let convertedMachOs: [String]
    public let signingOrder: [String]
    public let sourceInventory: [PlayCoverInventoryEntry]
    public let sourceMachOs: [PlayCoverMachOInspection]
    public let inventory: [PlayCoverInventoryEntry]
    public let machOs: [PlayCoverMachOInspection]
    public let entitlementDiff: PlayCoverEntitlementDiff
    public let completedAt: String

    public init(
        schemaVersion: Int = 5,
        backend: String = "mac",
        sourceAppPath: String,
        preparedAppPath: String,
        bundleIdentifier: String,
        executableName: String,
        executablePath: String,
        sourceContentHash: String,
        sourceHashAfterPreparation: String,
        runtimeBuildHash: String,
        prepareRevision: String,
        accountNamespacePolicyHash: String,
        generationKey: String,
        signingIdentity: PlayCoverSigningIdentityEvidence,
        rootCodeSignature: PlayCoverRootCodeSignatureEvidence,
        runtimeLoadPath: String,
        runtimeFrameworkName: String,
        convertedMachOs: [String],
        signingOrder: [String],
        sourceInventory: [PlayCoverInventoryEntry],
        sourceMachOs: [PlayCoverMachOInspection],
        inventory: [PlayCoverInventoryEntry],
        machOs: [PlayCoverMachOInspection],
        entitlementDiff: PlayCoverEntitlementDiff,
        completedAt: String,
        appBundleName: String? = nil,
        mainExecutableRelativePath: String? = nil,
        runtimeExecutableRelativePath: String? = nil,
        infoPlistSHA256: String? = nil,
        mainExecutableSHA256: String? = nil,
        runtimeExecutableSHA256: String? = nil,
        rootEntitlementsSHA256: String = "",
        codeObjects: [PlayCoverInventoryEntry]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.backend = backend
        let mainRelative =
            mainExecutableRelativePath ?? executableName
        let runtimeRelative = runtimeExecutableRelativePath
            ?? "Frameworks/\(runtimeFrameworkName)/IOSUsePlayRuntime"
        self.appBundleName = appBundleName
            ?? URL(fileURLWithPath: preparedAppPath).lastPathComponent
        self.mainExecutableRelativePath = mainRelative
        self.runtimeExecutableRelativePath = runtimeRelative
        self.infoPlistSHA256 = infoPlistSHA256
            ?? inventory.first(where: {
                $0.relativePath == "Info.plist"
            })?.sha256
            ?? ""
        self.mainExecutableSHA256 = mainExecutableSHA256
            ?? machOs.first(where: {
                $0.relativePath == mainRelative
            })?.fileSHA256
            ?? ""
        self.runtimeExecutableSHA256 = runtimeExecutableSHA256
            ?? machOs.first(where: {
                $0.relativePath == runtimeRelative
            })?.fileSHA256
            ?? ""
        self.rootEntitlementsSHA256 =
            rootEntitlementsSHA256
        let criticalPaths: Set<String> = [
            "Info.plist",
            mainRelative,
            runtimeRelative,
        ]
        self.codeObjects = codeObjects
            ?? inventory.filter {
                $0.codeObjectKind != nil
                    || criticalPaths.contains($0.relativePath)
            }
        self.sourceAppPath = sourceAppPath
        self.preparedAppPath = preparedAppPath
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.executablePath = executablePath
        self.sourceContentHash = sourceContentHash
        self.sourceHashAfterPreparation = sourceHashAfterPreparation
        self.runtimeBuildHash = runtimeBuildHash
        self.prepareRevision = prepareRevision
        self.accountNamespacePolicyHash =
            accountNamespacePolicyHash
        self.generationKey = generationKey
        self.signingIdentity = signingIdentity
        self.rootCodeSignature = rootCodeSignature
        self.runtimeLoadPath = runtimeLoadPath
        self.runtimeFrameworkName = runtimeFrameworkName
        self.convertedMachOs = convertedMachOs
        self.signingOrder = signingOrder
        self.sourceInventory = sourceInventory
        self.sourceMachOs = sourceMachOs
        self.inventory = inventory
        self.machOs = machOs
        self.entitlementDiff = entitlementDiff
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case backend
        case appBundleName
        case mainExecutableRelativePath
        case runtimeExecutableRelativePath
        case infoPlistSHA256
        case mainExecutableSHA256
        case runtimeExecutableSHA256
        case rootEntitlementsSHA256
        case codeObjects
        case bundleIdentifier
        case executableName
        case sourceContentHash
        case runtimeBuildHash
        case prepareRevision
        case accountNamespacePolicyHash
        case generationKey
        case signingIdentity
        case rootCodeSignature
        case runtimeLoadPath
        case runtimeFrameworkName
        case signingOrder
        case completedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(backend, forKey: .backend)
        try container.encode(appBundleName, forKey: .appBundleName)
        try container.encode(
            mainExecutableRelativePath,
            forKey: .mainExecutableRelativePath
        )
        try container.encode(
            runtimeExecutableRelativePath,
            forKey: .runtimeExecutableRelativePath
        )
        try container.encode(
            infoPlistSHA256,
            forKey: .infoPlistSHA256
        )
        try container.encode(
            mainExecutableSHA256,
            forKey: .mainExecutableSHA256
        )
        try container.encode(
            runtimeExecutableSHA256,
            forKey: .runtimeExecutableSHA256
        )
        try container.encode(
            rootEntitlementsSHA256,
            forKey: .rootEntitlementsSHA256
        )
        try container.encode(codeObjects, forKey: .codeObjects)
        try container.encode(
            bundleIdentifier,
            forKey: .bundleIdentifier
        )
        try container.encode(executableName, forKey: .executableName)
        try container.encode(
            sourceContentHash,
            forKey: .sourceContentHash
        )
        try container.encode(
            runtimeBuildHash,
            forKey: .runtimeBuildHash
        )
        try container.encode(prepareRevision, forKey: .prepareRevision)
        try container.encode(
            accountNamespacePolicyHash,
            forKey: .accountNamespacePolicyHash
        )
        try container.encode(generationKey, forKey: .generationKey)
        try container.encode(signingIdentity, forKey: .signingIdentity)
        try container.encode(
            rootCodeSignature,
            forKey: .rootCodeSignature
        )
        try container.encode(runtimeLoadPath, forKey: .runtimeLoadPath)
        try container.encode(
            runtimeFrameworkName,
            forKey: .runtimeFrameworkName
        )
        try container.encode(signingOrder, forKey: .signingOrder)
        try container.encode(completedAt, forKey: .completedAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        backend = try container.decode(String.self, forKey: .backend)
        appBundleName = try container.decode(
            String.self,
            forKey: .appBundleName
        )
        mainExecutableRelativePath = try container.decode(
            String.self,
            forKey: .mainExecutableRelativePath
        )
        runtimeExecutableRelativePath = try container.decode(
            String.self,
            forKey: .runtimeExecutableRelativePath
        )
        infoPlistSHA256 = try container.decode(
            String.self,
            forKey: .infoPlistSHA256
        )
        mainExecutableSHA256 = try container.decode(
            String.self,
            forKey: .mainExecutableSHA256
        )
        runtimeExecutableSHA256 = try container.decode(
            String.self,
            forKey: .runtimeExecutableSHA256
        )
        rootEntitlementsSHA256 = try container.decode(
            String.self,
            forKey: .rootEntitlementsSHA256
        )
        codeObjects = try container.decode(
            [PlayCoverInventoryEntry].self,
            forKey: .codeObjects
        )
        bundleIdentifier = try container.decode(
            String.self,
            forKey: .bundleIdentifier
        )
        executableName = try container.decode(
            String.self,
            forKey: .executableName
        )
        sourceContentHash = try container.decode(
            String.self,
            forKey: .sourceContentHash
        )
        sourceHashAfterPreparation = sourceContentHash
        runtimeBuildHash = try container.decode(
            String.self,
            forKey: .runtimeBuildHash
        )
        prepareRevision = try container.decode(
            String.self,
            forKey: .prepareRevision
        )
        accountNamespacePolicyHash = try container.decode(
            String.self,
            forKey: .accountNamespacePolicyHash
        )
        generationKey = try container.decode(
            String.self,
            forKey: .generationKey
        )
        signingIdentity = try container.decode(
            PlayCoverSigningIdentityEvidence.self,
            forKey: .signingIdentity
        )
        rootCodeSignature = try container.decode(
            PlayCoverRootCodeSignatureEvidence.self,
            forKey: .rootCodeSignature
        )
        runtimeLoadPath = try container.decode(
            String.self,
            forKey: .runtimeLoadPath
        )
        runtimeFrameworkName = try container.decode(
            String.self,
            forKey: .runtimeFrameworkName
        )
        signingOrder = try container.decode(
            [String].self,
            forKey: .signingOrder
        )
        entitlementDiff = .empty
        completedAt = try container.decode(
            String.self,
            forKey: .completedAt
        )
        sourceAppPath = ""
        preparedAppPath = ""
        executablePath = ""
        convertedMachOs = []
        sourceInventory = []
        sourceMachOs = []
        inventory = codeObjects
        machOs = []
    }

    func resolving(appURL: URL) -> PlayCoverPrepareManifest {
        let app = URL(
            fileURLWithPath: appURL.path,
            isDirectory: true
        )
        return PlayCoverPrepareManifest(
            schemaVersion: schemaVersion,
            backend: backend,
            sourceAppPath: "",
            preparedAppPath: app.path,
            bundleIdentifier: bundleIdentifier,
            executableName: executableName,
            executablePath: app.appendingPathComponent(
                mainExecutableRelativePath
            ).path,
            sourceContentHash: sourceContentHash,
            sourceHashAfterPreparation: sourceContentHash,
            runtimeBuildHash: runtimeBuildHash,
            prepareRevision: prepareRevision,
            accountNamespacePolicyHash:
                accountNamespacePolicyHash,
            generationKey: generationKey,
            signingIdentity: signingIdentity,
            rootCodeSignature: rootCodeSignature,
            runtimeLoadPath: runtimeLoadPath,
            runtimeFrameworkName: runtimeFrameworkName,
            convertedMachOs: [],
            signingOrder: signingOrder,
            sourceInventory: [],
            sourceMachOs: [],
            inventory: codeObjects,
            machOs: [],
            entitlementDiff: entitlementDiff,
            completedAt: completedAt,
            appBundleName: appBundleName,
            mainExecutableRelativePath:
                mainExecutableRelativePath,
            runtimeExecutableRelativePath:
                runtimeExecutableRelativePath,
            infoPlistSHA256: infoPlistSHA256,
            mainExecutableSHA256: mainExecutableSHA256,
            runtimeExecutableSHA256:
                runtimeExecutableSHA256,
            rootEntitlementsSHA256:
                rootEntitlementsSHA256,
            codeObjects: codeObjects
        )
    }

    func hasSamePersistedSeal(
        as other: PlayCoverPrepareManifest
    ) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(self)
            == encoder.encode(other)
    }
}

struct PlayCoverValidatedPreparedManifest: Equatable, Sendable {
    let manifest: PlayCoverPrepareManifest
    let generationIdentity: PlayCoverGenerationIdentity
}

struct PlayCoverCompletedGeneration: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generationKey: String
    let manifestSHA256: String
    let executableSHA256: String
    let runtimeSHA256: String
}

public struct PlayCoverVerification: Codable, Equatable, Sendable {
    public let manifest: PlayCoverPrepareManifest
    public let mainExecutable: PlayCoverMachOInspection
    public let signatureValid: Bool

    public init(
        manifest: PlayCoverPrepareManifest,
        mainExecutable: PlayCoverMachOInspection,
        signatureValid: Bool
    ) {
        self.manifest = manifest
        self.mainExecutable = mainExecutable
        self.signatureValid = signatureValid
    }
}

public struct PlayCoverHello: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: String
    public let pid: Int32
    public let bundleIdentifier: String
    public let executablePath: String
    public let logicalWidth: Double
    public let logicalHeight: Double
    public let nativeWidth: Double
    public let nativeHeight: Double
    public let scale: Double
    public let windowWidth: Double
    public let windowHeight: Double
    public let stage: String
    public let capabilities: [String]
}

public struct PlayCoverLaunchIdentity: Codable, Equatable, Sendable {
    public let sessionID: String
    public let pid: Int32
    public let bundleIdentifier: String
    public let executablePath: String
    public let appPath: String
    public let generationKey: String
    public let runtimeSocketPath: String
    public let hello: PlayCoverHello
}

public enum PlayCoverBackendError:
    Error, Equatable, CustomStringConvertible, Sendable {
    case invalidApp(String)
    case unsupportedMachO(String)
    case malformedMachO(String)
    case encryptedMachO(String)
    case duplicateRuntimeLoad(String)
    case machOTransformFailed(String)
    case entitlementFailed(String)
    case codeSigningFailed(String)
    case outputExists(String)
    case missingRuntime(String)
    case prepareFailed(String)
    case verificationFailed(String)
    case cacheTampered(String)
    case stdioLogFailed(String)
    case launchFailed(String)
    case launchTimedOut(String)
    case terminateFailed(String)
    case capabilityUnavailable(String)

    public var description: String {
        switch self {
        case .invalidApp(let message):
            return "invalid iOS App: \(message)"
        case .unsupportedMachO(let message):
            return "unsupported Mach-O: \(message)"
        case .malformedMachO(let message):
            return "malformed Mach-O: \(message)"
        case .encryptedMachO(let path):
            return "encrypted Mach-O is not supported: \(path)"
        case .duplicateRuntimeLoad(let path):
            return "Runtime load command is duplicated: \(path)"
        case .machOTransformFailed(let message):
            return "Mac Mach-O transform failed: \(message)"
        case .entitlementFailed(let message):
            return "Mac entitlement composition failed: \(message)"
        case .codeSigningFailed(let message):
            return "Mac code signing failed: \(message)"
        case .outputExists(let path):
            return "prepared output already exists: \(path)"
        case .missingRuntime(let path):
            return "IOSUsePlayRuntime.framework is missing or invalid: \(path)"
        case .prepareFailed(let message):
            return "Mac prepare failed: \(message)"
        case .verificationFailed(let message):
            return "Mac verification failed: \(message)"
        case .cacheTampered(let message):
            return "Mac prepared cache failed integrity checks: \(message)"
        case .stdioLogFailed(let message):
            return "Mac stdio log setup failed: \(message)"
        case .launchFailed(let message):
            return "Mac launch failed: \(message)"
        case .launchTimedOut(let message):
            return "Mac launch timed out: \(message)"
        case .terminateFailed(let message):
            return "Mac terminate failed: \(message)"
        case .capabilityUnavailable(let command):
            return "Mac active session does not support `\(command)`"
        }
    }
}
