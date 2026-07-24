import CryptoKit
import Foundation

/// Immutable device geometry used by the headless PlayCover backend.
///
/// The default intentionally matches vPhone's current 1290 x 2796, 3x setup.
public struct PlayCoverDeviceProfile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let identifier: String
    public let productType: String
    public let hardwareTarget: String
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let scale: Double
    public let pixelsPerInch: Int
    public let orientation: String

    public init(
        schemaVersion: Int = 1,
        identifier: String,
        productType: String,
        hardwareTarget: String,
        logicalWidth: Int,
        logicalHeight: Int,
        nativeWidth: Int,
        nativeHeight: Int,
        scale: Double,
        pixelsPerInch: Int,
        orientation: String
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.productType = productType
        self.hardwareTarget = hardwareTarget
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.scale = scale
        self.pixelsPerInch = pixelsPerInch
        self.orientation = orientation
    }

    public static let vphoneDefault = PlayCoverDeviceProfile(
        identifier: "iphone-15-pro-max-vphone",
        productType: "iPhone16,2",
        hardwareTarget: "A2849",
        logicalWidth: 430,
        logicalHeight: 932,
        nativeWidth: 1290,
        nativeHeight: 2796,
        scale: 3,
        pixelsPerInch: 460,
        orientation: "portrait"
    )

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw PlayCoverBackendError.invalidProfile("unsupported schemaVersion \(schemaVersion)")
        }
        guard !identifier.isEmpty, !productType.isEmpty, !hardwareTarget.isEmpty else {
            throw PlayCoverBackendError.invalidProfile("identifier, productType, and hardwareTarget must be non-empty")
        }
        guard logicalWidth > 0, logicalHeight > 0,
              nativeWidth > 0, nativeHeight > 0,
              scale > 0, scale.isFinite,
              pixelsPerInch > 0 else {
            throw PlayCoverBackendError.invalidProfile("geometry, scale, and pixelsPerInch must be positive")
        }
        guard orientation == "portrait" else {
            throw PlayCoverBackendError.invalidProfile("the first backend slice only supports portrait orientation")
        }
        let expectedNativeWidth = Double(logicalWidth) * scale
        let expectedNativeHeight = Double(logicalHeight) * scale
        guard abs(expectedNativeWidth - Double(nativeWidth)) < 0.000_001,
              abs(expectedNativeHeight - Double(nativeHeight)) < 0.000_001 else {
            throw PlayCoverBackendError.invalidProfile(
                "native size must equal logical size multiplied by scale"
            )
        }
    }

    public func stableHash() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(self))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct PlayCoverMachOInspection: Codable, Equatable, Sendable {
    public let path: String
    public let cpuType: Int32
    public let fileType: UInt32
    public let commandCount: UInt32
    public let commandBytes: UInt32
    public let firstSectionOffset: UInt64
    public let availableCommandPadding: UInt64
    public let platform: UInt32?
    public let minimumOS: UInt32?
    public let sdk: UInt32?
    public let encrypted: Bool
    public let runtimeInjected: Bool

    public var isMacCatalyst: Bool {
        platform == PlayCoverMachO.platformMacCatalyst
    }
}

public struct PlayCoverAppInspection: Codable, Equatable, Sendable {
    public let appPath: String
    public let bundleIdentifier: String
    public let executableName: String
    public let executablePath: String
    public let profile: PlayCoverDeviceProfile
    public let profileHash: String
    public let mainExecutable: PlayCoverMachOInspection
}

public struct PlayCoverPrepareManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let backend: String
    public let sourceAppPath: String
    public let preparedAppPath: String
    public let bundleIdentifier: String
    public let executableName: String
    public let profileHash: String
    public let runtimeLoadPath: String
    public let runtimeFrameworkName: String
    public let convertedMachOs: [String]
    public let preparedAt: String
    public let helloPath: String
}

public struct PlayCoverVerification: Codable, Equatable, Sendable {
    public let manifest: PlayCoverPrepareManifest
    public let profile: PlayCoverDeviceProfile
    public let mainExecutable: PlayCoverMachOInspection
    public let signatureValid: Bool
}

public struct PlayCoverHello: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let pid: Int32
    public let bundleIdentifier: String
    public let profileHash: String
    public let logicalWidth: Double
    public let logicalHeight: Double
    public let nativeWidth: Double
    public let nativeHeight: Double
    public let scale: Double
    public let windowWidth: Double?
    public let windowHeight: Double?
    public let stage: String
}

public enum PlayCoverBackendError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidProfile(String)
    case invalidApp(String)
    case unsupportedMachO(String)
    case malformedMachO(String)
    case encryptedMachO(String)
    case insufficientLoadCommandSpace(required: Int, available: Int)
    case nonZeroLoadCommandPadding(String)
    case outputExists(String)
    case missingRuntime(String)
    case prepareFailed(String)
    case verificationFailed(String)
    case launchFailed(String)
    case launchTimedOut(String)
    case terminateFailed(String)
    case capabilityUnavailable(String)

    public var description: String {
        switch self {
        case .invalidProfile(let message):
            return "invalid PlayCover device profile: \(message)"
        case .invalidApp(let message):
            return "invalid iOS app: \(message)"
        case .unsupportedMachO(let message):
            return "unsupported Mach-O: \(message)"
        case .malformedMachO(let message):
            return "malformed Mach-O: \(message)"
        case .encryptedMachO(let path):
            return "encrypted Mach-O is not supported: \(path)"
        case .insufficientLoadCommandSpace(let required, let available):
            return "insufficient Mach-O load-command space: need \(required) bytes, have \(available)"
        case .nonZeroLoadCommandPadding(let path):
            return "refusing to overwrite non-zero bytes after Mach-O load commands: \(path)"
        case .outputExists(let path):
            return "prepared output already exists: \(path)"
        case .missingRuntime(let path):
            return "IOSUsePlayRuntime.framework is missing or invalid: \(path)"
        case .prepareFailed(let message):
            return "PlayCover prepare failed: \(message)"
        case .verificationFailed(let message):
            return "PlayCover verification failed: \(message)"
        case .launchFailed(let message):
            return "PlayCover launch failed: \(message)"
        case .launchTimedOut(let message):
            return "PlayCover launch timed out: \(message)"
        case .terminateFailed(let message):
            return "PlayCover terminate failed: \(message)"
        case .capabilityUnavailable(let command):
            return "PlayCover active session does not support `\(command)` yet; IOSUsePlayRuntime automation transport is not connected"
        }
    }
}
