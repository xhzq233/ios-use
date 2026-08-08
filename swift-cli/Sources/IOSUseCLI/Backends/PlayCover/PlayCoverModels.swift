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

    init(_ upstream: PlayCoverUpstreamMachOInspection, appPath: String) {
        relativePath = upstream.relativePath
        path = URL(fileURLWithPath: appPath, isDirectory: true)
            .appendingPathComponent(upstream.relativePath).path
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
            availableCommandPadding = firstSectionOffset
                - 32 - UInt64(upstream.commandBytes)
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

/// Immutable evidence for one always-Frida prepare attempt. It is transient;
/// the installed slot persists only its compact `slot.json` contract.
struct PlayCoverPreparationPlan: Equatable, Sendable {
    let source: PlayCoverPreparationSource
    let runtimeFrameworkPath: String
    let runtimeEvidence: PlayCoverUpstreamRuntimeEvidence
    let signingIdentity: PlayCoverSigningIdentityEvidence
    let runtimeBuildHash: String
    let prepareRevision: String
    let accountNamespacePolicyHash: String
    let fridaEngineFrameworkPath: String
    let fridaEngineSHA256: String
}

/// Detailed result for the current prepare call. This is never persisted in
/// the App slot and is not a cache identity.
public struct PlayCoverPreparedApp: Equatable, Sendable {
    public let appPath: String
    public let bundleIdentifier: String
    public let executableName: String
    public let executableRelativePath: String
    public let executablePath: String
    public let sourceContentHash: String
    public let sourceHashAfterPreparation: String
    public let runtimeBuildHash: String
    public let prepareRevision: String
    public let fridaEngineSHA256: String
    public let signingIdentity: PlayCoverSigningIdentityEvidence
    public let rootCodeSignature: PlayCoverRootCodeSignatureEvidence
    public let inspection: PlayCoverAppInspection
    public let completedAt: String
}

public struct PlayCoverVerification: Equatable, Sendable {
    public let inspection: PlayCoverAppInspection
    public let mainExecutable: PlayCoverMachOInspection
    public let signatureValid: Bool
}

public struct PlayCoverHello: Codable, Equatable, Sendable {
    public let sessionID: String
    public let pid: Int32
    public let bundleIdentifier: String
    public let executablePath: String
    public let installRevision: String
    public let controlStage: String
    public let uiState: String
    public let uiStage: String
    public let uiFailure: String?
    public let capabilities: [String]

    init(
        sessionID: String,
        pid: Int32,
        bundleIdentifier: String,
        executablePath: String,
        installRevision: String,
        controlStage: String,
        uiState: String,
        uiStage: String,
        uiFailure: String?,
        capabilities: [String]
    ) {
        self.sessionID = sessionID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.installRevision = installRevision
        self.controlStage = controlStage
        self.uiState = uiState
        self.uiStage = uiStage
        self.uiFailure = uiFailure
        self.capabilities = capabilities
    }
}

public enum PlayCoverBackendError:
    Error, Equatable, CustomStringConvertible, Sendable
{
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
    case bundleAlreadyRunning(bundleIdentifier: String, pid: Int32)
    case launchRecoveryUnresolved(String)

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
            return "Mac App slot failed integrity checks: \(message)"
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
        case .bundleAlreadyRunning(let bundleIdentifier, let pid):
            return "Mac bundle is already running: \(bundleIdentifier) "
                + "(pid \(pid))"
        case .launchRecoveryUnresolved(let message):
            return "Mac launch is unresolved: \(message)"
        }
    }
}
