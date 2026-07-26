/*
 * Headless integration of PlayCover at
 * 7190cc9ce57c8dee0e222918468f2579acc95e1b.
 *
 * PlayCover is GPL-3.0. See ../../../LICENSE and ../../../PROVENANCE.md.
 * Conversion is performed by the pinned Macho.swift implementation and
 * injection by paradiseduo/inject through Inject.injectMachO.
 */

import CryptoKit
import Darwin
import Dispatch
import Foundation

public enum PlayCoverUpstreamError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidApp(String)
    case malformedMachO(String)
    case unsupportedMachO(String)
    case encryptedMachO(String)
    case duplicateRuntimeLoad(String)
    case insufficientMachOPadding(String)
    case injectionFailed(String)
    case entitlementFailed(String)
    case signingFailed(String)
    case verificationFailed(String)
    case sourceMutated(expected: String, actual: String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .invalidApp(let value):
            return "invalid App: \(value)"
        case .malformedMachO(let value):
            return "malformed Mach-O: \(value)"
        case .unsupportedMachO(let value):
            return "unsupported Mach-O: \(value)"
        case .encryptedMachO(let value):
            return "encrypted Mach-O is not supported: \(value)"
        case .duplicateRuntimeLoad(let value):
            return "Runtime load command already exists by exact path or basename: \(value)"
        case .insufficientMachOPadding(let value):
            return "Mach-O has insufficient load-command padding: \(value)"
        case .injectionFailed(let value):
            return "Runtime injection failed: \(value)"
        case .entitlementFailed(let value):
            return "entitlement composition failed: \(value)"
        case .signingFailed(let value):
            return "code signing failed: \(value)"
        case .verificationFailed(let value):
            return "verification failed: \(value)"
        case .sourceMutated(let expected, let actual):
            return "source App changed during prepare: expected \(expected), got \(actual)"
        case .commandFailed(let value):
            return "command failed: \(value)"
        }
    }
}

public enum PlayCoverUpstreamFileKind: String, Codable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other
}

public enum PlayCoverUpstreamMachOContainer: String, Codable, Sendable {
    case thin
    case fat
    case fat64
}

public struct PlayCoverUpstreamCodeDirectoryEvidence:
    Codable, Equatable, Sendable
{
    public let structureSHA256: String
    public let cdHash: String
    public let hashType: UInt8
    public let hashSize: UInt8
    public let specialSlotHashes: [String: String]
    public let codeSlotHashes: [String]

    public init(
        structureSHA256: String,
        cdHash: String,
        hashType: UInt8,
        hashSize: UInt8,
        specialSlotHashes: [String: String],
        codeSlotHashes: [String]
    ) {
        self.structureSHA256 = structureSHA256
        self.cdHash = cdHash
        self.hashType = hashType
        self.hashSize = hashSize
        self.specialSlotHashes = specialSlotHashes
        self.codeSlotHashes = codeSlotHashes
    }
}

public struct PlayCoverUpstreamSignatureSlot:
    Codable, Equatable, Sendable
{
    public let index: UInt32
    public let type: UInt32
    public let offset: UInt32
    public let magic: UInt32
    public let length: UInt32
    public let bytesSHA256: String
    public let bytes: Data
    public let codeDirectory: PlayCoverUpstreamCodeDirectoryEvidence?

    public init(
        index: UInt32,
        type: UInt32,
        offset: UInt32,
        magic: UInt32,
        length: UInt32,
        bytesSHA256: String,
        bytes: Data,
        codeDirectory: PlayCoverUpstreamCodeDirectoryEvidence? = nil
    ) {
        self.index = index
        self.type = type
        self.offset = offset
        self.magic = magic
        self.length = length
        self.bytesSHA256 = bytesSHA256
        self.bytes = bytes
        self.codeDirectory = codeDirectory
    }
}

public struct PlayCoverUpstreamSignature: Codable, Equatable, Sendable {
    public let isSigned: Bool
    public let isValid: Bool
    public let cdHash: String?
    public let identifier: String?
    public let teamIdentifier: String?
    public let signatureType: String?
    public let flags: String?
    public let codeDirectoryVersion: String?
    public let codeDirectoryHashes: String?
    public let hashChoices: String?
    public let hashType: String?
    public let pageSize: String?
    public let superBlobLength: UInt32?
    public let superBlobPaddingSize: UInt32?
    public let superBlobStructureSHA256: String?
    public let superBlobPaddingSHA256: String?
    public let embeddedSlots: [PlayCoverUpstreamSignatureSlot]
    public let entitlementsPlist: Data?
    public let derEntitlementsPlist: Data?
    public let entitlementsSHA256: String?
    public let derEntitlementsSHA256: String?

    public init(
        isSigned: Bool,
        isValid: Bool,
        cdHash: String? = nil,
        identifier: String? = nil,
        teamIdentifier: String? = nil,
        signatureType: String? = nil,
        flags: String? = nil,
        codeDirectoryVersion: String? = nil,
        codeDirectoryHashes: String? = nil,
        hashChoices: String? = nil,
        hashType: String? = nil,
        pageSize: String? = nil,
        superBlobLength: UInt32? = nil,
        superBlobPaddingSize: UInt32? = nil,
        superBlobStructureSHA256: String? = nil,
        superBlobPaddingSHA256: String? = nil,
        embeddedSlots: [PlayCoverUpstreamSignatureSlot] = [],
        entitlementsPlist: Data?,
        derEntitlementsPlist: Data? = nil
    ) {
        self.isSigned = isSigned
        self.isValid = isValid
        self.cdHash = cdHash
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.signatureType = signatureType
        self.flags = flags
        self.codeDirectoryVersion = codeDirectoryVersion
        self.codeDirectoryHashes = codeDirectoryHashes
        self.hashChoices = hashChoices
        self.hashType = hashType
        self.pageSize = pageSize
        self.superBlobLength = superBlobLength
        self.superBlobPaddingSize = superBlobPaddingSize
        self.superBlobStructureSHA256 = superBlobStructureSHA256
        self.superBlobPaddingSHA256 = superBlobPaddingSHA256
        self.embeddedSlots = embeddedSlots
        self.entitlementsPlist = entitlementsPlist
        self.derEntitlementsPlist = derEntitlementsPlist
        self.entitlementsSHA256 = entitlementsPlist.map(Self.sha256)
        self.derEntitlementsSHA256 = derEntitlementsPlist.map(Self.sha256)
    }

    public init(
        isSigned: Bool,
        isValid: Bool,
        cdHash: String? = nil,
        identifier: String? = nil,
        teamIdentifier: String? = nil,
        signatureType: String? = nil,
        flags: String? = nil,
        codeDirectoryVersion: String? = nil,
        codeDirectoryHashes: String? = nil,
        hashChoices: String? = nil,
        hashType: String? = nil,
        pageSize: String? = nil,
        entitlementsPlist: Data?
    ) {
        self.init(
            isSigned: isSigned,
            isValid: isValid,
            cdHash: cdHash,
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            signatureType: signatureType,
            flags: flags,
            codeDirectoryVersion: codeDirectoryVersion,
            codeDirectoryHashes: codeDirectoryHashes,
            hashChoices: hashChoices,
            hashType: hashType,
            pageSize: pageSize,
            superBlobLength: nil,
            superBlobPaddingSize: nil,
            superBlobStructureSHA256: nil,
            superBlobPaddingSHA256: nil,
            embeddedSlots: [],
            entitlementsPlist: entitlementsPlist,
            derEntitlementsPlist: nil
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PlayCoverUpstreamLoadCommandInspection:
    Codable, Equatable, Sendable
{
    public let index: UInt32
    public let command: UInt32
    public let commandSize: UInt32
    public let semanticValue: String?
    public let bytesSHA256: String

    public init(
        index: UInt32,
        command: UInt32,
        commandSize: UInt32,
        semanticValue: String?,
        bytesSHA256: String
    ) {
        self.index = index
        self.command = command
        self.commandSize = commandSize
        self.semanticValue = semanticValue
        self.bytesSHA256 = bytesSHA256
    }
}

public struct PlayCoverUpstreamMachOSliceInspection:
    Codable, Equatable, Sendable
{
    public let fatIndex: UInt32
    public let cpuType: Int32
    public let cpuSubtype: Int32
    public let offset: UInt64
    public let size: UInt64
    public let alignment: UInt32?
    public let byteSwapped: Bool
    public let fileType: UInt32
    public let headerFlags: UInt32?
    public let headerReserved: UInt32?
    public let commandCount: UInt32
    public let commandBytes: UInt32
    public let firstSectionOffset: UInt64?
    public let platform: UInt32?
    public let minimumOS: UInt32?
    public let sdk: UInt32?
    public let encrypted: Bool
    public let dependencies: [String]
    public let rpaths: [String]
    public let loadCommands: [PlayCoverUpstreamLoadCommandInspection]
    public let signature: PlayCoverUpstreamSignature
    public let sliceSHA256: String
    public let immutableContentSHA256: String?

    public init(
        fatIndex: UInt32,
        cpuType: Int32,
        cpuSubtype: Int32,
        offset: UInt64,
        size: UInt64,
        alignment: UInt32?,
        byteSwapped: Bool,
        fileType: UInt32,
        headerFlags: UInt32? = nil,
        headerReserved: UInt32? = nil,
        commandCount: UInt32,
        commandBytes: UInt32,
        firstSectionOffset: UInt64?,
        platform: UInt32?,
        minimumOS: UInt32?,
        sdk: UInt32?,
        encrypted: Bool,
        dependencies: [String],
        rpaths: [String],
        loadCommands: [PlayCoverUpstreamLoadCommandInspection],
        signature: PlayCoverUpstreamSignature,
        sliceSHA256: String,
        immutableContentSHA256: String? = nil
    ) {
        self.fatIndex = fatIndex
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.offset = offset
        self.size = size
        self.alignment = alignment
        self.byteSwapped = byteSwapped
        self.fileType = fileType
        self.headerFlags = headerFlags
        self.headerReserved = headerReserved
        self.commandCount = commandCount
        self.commandBytes = commandBytes
        self.firstSectionOffset = firstSectionOffset
        self.platform = platform
        self.minimumOS = minimumOS
        self.sdk = sdk
        self.encrypted = encrypted
        self.dependencies = dependencies
        self.rpaths = rpaths
        self.loadCommands = loadCommands
        self.signature = signature
        self.sliceSHA256 = sliceSHA256
        self.immutableContentSHA256 = immutableContentSHA256
    }
}

public struct PlayCoverUpstreamMachOInspection: Codable, Equatable, Sendable {
    public let relativePath: String
    public let fileSHA256: String
    public let container: PlayCoverUpstreamMachOContainer
    public let fatHeaderBigEndian: Bool?
    public let arm64SliceOffset: UInt64
    public let arm64SliceSize: UInt64
    public let byteSwapped: Bool
    public let cpuType: Int32
    public let fileType: UInt32
    public let commandCount: UInt32
    public let commandBytes: UInt32
    public let firstSectionOffset: UInt64?
    public let platform: UInt32?
    public let minimumOS: UInt32?
    public let sdk: UInt32?
    public let encrypted: Bool
    public let dependencies: [String]
    public let rpaths: [String]
    public let loadCommands: [PlayCoverUpstreamLoadCommandInspection]
    public let signature: PlayCoverUpstreamSignature
    public let sliceInspections: [PlayCoverUpstreamMachOSliceInspection]?

    public init(
        relativePath: String,
        fileSHA256: String,
        container: PlayCoverUpstreamMachOContainer,
        fatHeaderBigEndian: Bool? = nil,
        arm64SliceOffset: UInt64,
        arm64SliceSize: UInt64,
        byteSwapped: Bool,
        cpuType: Int32,
        fileType: UInt32,
        commandCount: UInt32,
        commandBytes: UInt32,
        firstSectionOffset: UInt64?,
        platform: UInt32?,
        minimumOS: UInt32?,
        sdk: UInt32?,
        encrypted: Bool,
        dependencies: [String],
        rpaths: [String],
        loadCommands: [PlayCoverUpstreamLoadCommandInspection],
        signature: PlayCoverUpstreamSignature,
        sliceInspections: [PlayCoverUpstreamMachOSliceInspection]? = nil
    ) {
        self.relativePath = relativePath
        self.fileSHA256 = fileSHA256
        self.container = container
        self.fatHeaderBigEndian = fatHeaderBigEndian
        self.arm64SliceOffset = arm64SliceOffset
        self.arm64SliceSize = arm64SliceSize
        self.byteSwapped = byteSwapped
        self.cpuType = cpuType
        self.fileType = fileType
        self.commandCount = commandCount
        self.commandBytes = commandBytes
        self.firstSectionOffset = firstSectionOffset
        self.platform = platform
        self.minimumOS = minimumOS
        self.sdk = sdk
        self.encrypted = encrypted
        self.dependencies = dependencies
        self.rpaths = rpaths
        self.loadCommands = loadCommands
        self.signature = signature
        self.sliceInspections = sliceInspections
    }

    public var allSlices: [PlayCoverUpstreamMachOSliceInspection] {
        guard let sliceInspections, !sliceInspections.isEmpty else {
            return [
            PlayCoverUpstreamMachOSliceInspection(
                fatIndex: 0,
                cpuType: cpuType,
                cpuSubtype: 0,
                offset: arm64SliceOffset,
                size: arm64SliceSize,
                alignment: nil,
                byteSwapped: byteSwapped,
                fileType: fileType,
                headerFlags: nil,
                headerReserved: nil,
                commandCount: commandCount,
                commandBytes: commandBytes,
                firstSectionOffset: firstSectionOffset,
                platform: platform,
                minimumOS: minimumOS,
                sdk: sdk,
                encrypted: encrypted,
                dependencies: dependencies,
                rpaths: rpaths,
                loadCommands: loadCommands,
                signature: signature,
                sliceSHA256: fileSHA256,
                immutableContentSHA256: nil
            ),
            ]
        }
        return sliceInspections
    }
}

public struct PlayCoverUpstreamInventoryEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    public let kind: PlayCoverUpstreamFileKind
    public let size: UInt64?
    public let posixPermissions: UInt16?
    public let sha256: String?
    public let symbolicLinkDestination: String?
    public let codeObjectKind: String?

    public init(
        relativePath: String,
        kind: PlayCoverUpstreamFileKind,
        size: UInt64?,
        posixPermissions: UInt16?,
        sha256: String?,
        symbolicLinkDestination: String?,
        codeObjectKind: String?
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.posixPermissions = posixPermissions
        self.sha256 = sha256
        self.symbolicLinkDestination = symbolicLinkDestination
        self.codeObjectKind = codeObjectKind
    }
}

public struct PlayCoverUpstreamProvisioningEvidence: Codable, Equatable, Sendable {
    public let present: Bool
    public let size: UInt64?
    public let sha256: String?

    public init(present: Bool, size: UInt64?, sha256: String?) {
        self.present = present
        self.size = size
        self.sha256 = sha256
    }
}

public struct PlayCoverUpstreamAppInspection: Codable, Equatable, Sendable {
    public let appPath: String
    public let sourceContentHash: String
    public let infoPlistSHA256: String
    public let bundleIdentifier: String
    public let executableName: String
    public let executablePath: String
    public let mainExecutableRelativePath: String
    public let signature: PlayCoverUpstreamSignature
    public let provisioning: PlayCoverUpstreamProvisioningEvidence
    public let inventory: [PlayCoverUpstreamInventoryEntry]
    public let machOs: [PlayCoverUpstreamMachOInspection]

    public init(
        appPath: String,
        sourceContentHash: String,
        infoPlistSHA256: String,
        bundleIdentifier: String,
        executableName: String,
        executablePath: String,
        mainExecutableRelativePath: String,
        signature: PlayCoverUpstreamSignature,
        provisioning: PlayCoverUpstreamProvisioningEvidence,
        inventory: [PlayCoverUpstreamInventoryEntry],
        machOs: [PlayCoverUpstreamMachOInspection]
    ) {
        self.appPath = appPath
        self.sourceContentHash = sourceContentHash
        self.infoPlistSHA256 = infoPlistSHA256
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.executablePath = executablePath
        self.mainExecutableRelativePath = mainExecutableRelativePath
        self.signature = signature
        self.provisioning = provisioning
        self.inventory = inventory
        self.machOs = machOs
    }
}

public struct PlayCoverUpstreamEntitlementDiff: Codable, Equatable, Sendable {
    public let original: [String: String]
    public let playCoverBaseline: [String: String]
    public let final: [String: String]
    public let addedByPlayCover: [String]
    public let addedByIOSUse: [String]
    public let changedFromOriginal: [String]
    public let removedFromOriginal: [String]

    public init(
        original: [String: String],
        playCoverBaseline: [String: String],
        final: [String: String],
        addedByPlayCover: [String],
        addedByIOSUse: [String],
        changedFromOriginal: [String],
        removedFromOriginal: [String]
    ) {
        self.original = original
        self.playCoverBaseline = playCoverBaseline
        self.final = final
        self.addedByPlayCover = addedByPlayCover
        self.addedByIOSUse = addedByIOSUse
        self.changedFromOriginal = changedFromOriginal
        self.removedFromOriginal = removedFromOriginal
    }
}

public struct PlayCoverUpstreamPrepareOptions: Sendable {
    public let sourceApp: URL
    public let stagingApp: URL
    public let managedStagingApp: URL?
    public let runtimeFramework: URL
    public let managedHome: URL
    public let runtimeSocketPath: String
    public let runtimeLoadPath: String
    public let playSignActive: Bool
    public let expectedRuntimeBuildHash: String?

    public init(
        sourceApp: URL,
        stagingApp: URL,
        managedStagingApp: URL? = nil,
        runtimeFramework: URL,
        managedHome: URL,
        runtimeSocketPath: String,
        runtimeLoadPath: String,
        playSignActive: Bool = false,
        expectedRuntimeBuildHash: String? = nil
    ) {
        self.sourceApp = sourceApp
        self.stagingApp = stagingApp
        self.managedStagingApp = managedStagingApp
        self.runtimeFramework = runtimeFramework
        self.managedHome = managedHome
        self.runtimeSocketPath = runtimeSocketPath
        self.runtimeLoadPath = runtimeLoadPath
        self.playSignActive = playSignActive
        self.expectedRuntimeBuildHash = expectedRuntimeBuildHash
    }
}

public struct PlayCoverUpstreamPrepareResult: Codable, Equatable, Sendable {
    public let sourceBefore: PlayCoverUpstreamAppInspection
    public let sourceHashAfterPrepare: String
    public let prepared: PlayCoverUpstreamAppInspection
    public let convertedMachOs: [String]
    public let signingOrder: [String]
    public let entitlementDiff: PlayCoverUpstreamEntitlementDiff
    public let phaseTimings: PlayCoverUpstreamPreparePhaseTimings?

    public init(
        sourceBefore: PlayCoverUpstreamAppInspection,
        sourceHashAfterPrepare: String,
        prepared: PlayCoverUpstreamAppInspection,
        convertedMachOs: [String],
        signingOrder: [String],
        entitlementDiff: PlayCoverUpstreamEntitlementDiff,
        phaseTimings: PlayCoverUpstreamPreparePhaseTimings? = nil
    ) {
        self.sourceBefore = sourceBefore
        self.sourceHashAfterPrepare = sourceHashAfterPrepare
        self.prepared = prepared
        self.convertedMachOs = convertedMachOs
        self.signingOrder = signingOrder
        self.entitlementDiff = entitlementDiff
        self.phaseTimings = phaseTimings
    }
}

public struct PlayCoverUpstreamPreparePhaseTimings:
    Codable, Equatable, Sendable
{
    public let cloneNanoseconds: UInt64
    public let convertNanoseconds: UInt64
    public let signNanoseconds: UInt64
    public let verifyNanoseconds: UInt64

    public init(
        cloneNanoseconds: UInt64,
        convertNanoseconds: UInt64,
        signNanoseconds: UInt64,
        verifyNanoseconds: UInt64
    ) {
        self.cloneNanoseconds = cloneNanoseconds
        self.convertNanoseconds = convertNanoseconds
        self.signNanoseconds = signNanoseconds
        self.verifyNanoseconds = verifyNanoseconds
    }
}

public enum PlayCoverUpstreamEngine {
    public static let playCoverRevision =
        "7190cc9ce57c8dee0e222918468f2579acc95e1b"
    public static let injectRevision =
        "e6d3aa4abe106f90fd8c5a1ca04db15c19d324eb"
    /// SHA-256 of the vendored `Rules/default.yaml`. Headless prepare never
    /// reads mutable rules from the caller's HOME.
    public static let defaultRulesRevision =
        "0a544ec2c294dd9ed5e2d9fd323fe07be30b7d31b3ec7b71a078c6222b37583e"

    private static let cpuTypeArm64: Int32 = 0x0100_000c
    private static let platformIPhoneOS: UInt32 = 2
    public static let platformMacCatalyst: UInt32 = 6
    private static let maximumLoadCommands = 1_000_000
    public static func inspect(appURL: URL) throws -> PlayCoverUpstreamAppInspection {
        let app = appURL.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard app.pathExtension == "app",
              fileManager.fileExists(atPath: app.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PlayCoverUpstreamError.invalidApp(
                "path is not an existing .app directory: \(app.path)"
            )
        }
        try validateTreeContainment(
            root: app,
            label: "source App",
            rejectRootSymlink: true
        )

        let infoURL = app.appendingPathComponent("Info.plist")
        guard let infoData = try? Data(
                  contentsOf: infoURL,
                  options: .mappedIfSafe
              ),
              let info = try? PropertyListSerialization.propertyList(
                  from: infoData,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty,
              let executableName = info["CFBundleExecutable"] as? String,
              !executableName.isEmpty else {
            throw PlayCoverUpstreamError.invalidApp(
                "Info.plist has no non-empty CFBundleIdentifier/CFBundleExecutable"
            )
        }
        let executable = app.appendingPathComponent(executableName)
        guard fileManager.isRegularFile(atPath: executable.path) else {
            throw PlayCoverUpstreamError.invalidApp(
                "main executable does not exist: \(executable.path)"
            )
        }

        let snapshot = try treeSnapshot(
            appURL: app,
            preloadedRegularFileData: ["Info.plist": infoData],
            inspectMachOs: true
        )
        let inventory = snapshot.inventory
        let machOs = snapshot.machOs
        let mainRelative = try relativePath(executable, in: app)
        guard let mainMachO = machOs.first(where: {
            $0.relativePath == mainRelative
        }) else {
            throw PlayCoverUpstreamError.invalidApp(
                "main executable is not a supported arm64 Mach-O"
            )
        }

        let provisionURL = app.appendingPathComponent("embedded.mobileprovision")
        let provisionAttributes = try? fileManager.attributesOfItem(
            atPath: provisionURL.path
        )
        let provisioning = PlayCoverUpstreamProvisioningEvidence(
            present: provisionAttributes != nil,
            size: (provisionAttributes?[.size] as? NSNumber)?.uint64Value,
            sha256: try provisioningSHA256(
                attributes: provisionAttributes,
                relativePath: "embedded.mobileprovision",
                url: provisionURL,
                snapshot: snapshot
            )
        )
        return PlayCoverUpstreamAppInspection(
            appPath: app.path,
            sourceContentHash: snapshot.contentHash,
            infoPlistSHA256: hex(SHA256.hash(data: infoData)),
            bundleIdentifier: bundleIdentifier,
            executableName: executableName,
            executablePath: executable.path,
            mainExecutableRelativePath: mainRelative,
            signature: mainMachO.signature,
            provisioning: provisioning,
            inventory: inventory,
            machOs: machOs
        )
    }

    @discardableResult
    public static func convertMachO(
        at url: URL,
        relativePath: String,
        injectRuntime: Bool,
        runtimeLoadPath: String
    ) throws -> PlayCoverUpstreamMachOInspection {
        let before = try inspectMachO(
            at: url,
            relativePath: relativePath
        )
        guard !before.encrypted else {
            throw PlayCoverUpstreamError.encryptedMachO(relativePath)
        }
        if before.platform != platformMacCatalyst {
            do {
                try Macho.convertMacho(url)
            } catch {
                throw PlayCoverUpstreamError.unsupportedMachO(
                    "\(relativePath): \(error)"
                )
            }
        }
        if injectRuntime {
            let converted = try inspectMachO(
                at: url,
                relativePath: relativePath
            )
            try rejectRuntimeDuplicate(
                in: converted,
                runtimeLoadPath: runtimeLoadPath
            )
            try PlayTools.injectRuntime(url, loadPath: runtimeLoadPath)
        }
        return try inspectMachO(at: url, relativePath: relativePath)
    }

    /// Pinned Installer order, adapted to an already-extracted source .app:
    /// entitlement evidence -> enumerate/encryption -> clone -> per-Mach-O
    /// conversion/sign -> main injection -> provision/Info -> entitlement
    /// composition -> inside-out sign -> outer sign -> quarantine -> verify.
    public static func prepare(
        _ options: PlayCoverUpstreamPrepareOptions
    ) throws -> PlayCoverUpstreamPrepareResult {
        let source = try inspect(appURL: options.sourceApp)
        return try prepare(options, sourceInspection: source)
    }

    public static func prepare(
        _ options: PlayCoverUpstreamPrepareOptions,
        sourceInspection source: PlayCoverUpstreamAppInspection
    ) throws -> PlayCoverUpstreamPrepareResult {
        let optionsSourcePath = options.sourceApp.standardizedFileURL
            .resolvingSymlinksInPath().path
        let inspectedSourcePath = URL(
            fileURLWithPath: source.appPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath().path
        guard optionsSourcePath == inspectedSourcePath else {
            throw PlayCoverUpstreamError.invalidApp(
                "source inspection path \(source.appPath) does not match "
                    + options.sourceApp.standardizedFileURL.path
            )
        }
        var phaseTimings = PrepareTimingAccumulator()
        try validateManagedStaging(options, source: source)

        try validateRuntimeFramework(options.runtimeFramework)
        let managedPlayCover = options.managedHome
            .appendingPathComponent("playcover", isDirectory: true)
        try PlayTools.configureManagedContainer(managedPlayCover)
        _ = KeyCover.playChainPath
        let sourceBaseApp = BaseApp(appUrl: options.sourceApp)
        try Installer.saveEntitlements(sourceBaseApp)
        let installerMachOs = try Installer.resolveValidMachOs(sourceBaseApp)
        let sourceByPath = Dictionary(
            uniqueKeysWithValues: source.machOs.map {
                ($0.relativePath, $0)
            }
        )
        let installerRelativePaths = try installerMachOs.map {
            try relativePath($0, in: options.sourceApp)
        }
        guard Set(installerRelativePaths) == Set(sourceByPath.keys) else {
            throw PlayCoverUpstreamError.verificationFailed(
                "Installer enumeration and inspection inventory disagree"
            )
        }
        for relative in installerRelativePaths {
            guard let macho = sourceByPath[relative] else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "Installer Mach-O disappeared from source inventory: "
                        + relative
                )
            }
            let sourceURL = options.sourceApp.appendingPathComponent(relative)
            let installerEncrypted = try Macho.isMachoEncrypted(
                atURL: sourceURL
            )
            guard installerEncrypted == macho.encrypted else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "pinned encryption check and bounded inspection "
                        + "disagree for \(relative)"
                )
            }
            if installerEncrypted {
                throw PlayCoverUpstreamError.encryptedMachO(relative)
            }
            guard macho.platform == platformIPhoneOS
                    || macho.platform == platformMacCatalyst else {
                throw PlayCoverUpstreamError.unsupportedMachO(
                    "\(relative) has platform "
                        + "\(macho.platform.map(String.init) ?? "unknown")"
                )
            }
            try preflightMachOMutations(
                macho,
                runtimeLoadPath: relative
                    == source.mainExecutableRelativePath
                    ? options.runtimeLoadPath
                    : nil
            )
        }
        let cloneStarted = monotonicTimestamp()
        try cloneSource(options.sourceApp, to: options.stagingApp)
        var rollback = true
        defer {
            if rollback {
                try? FileManager.default.removeItem(at: options.stagingApp)
            }
        }

        let stagingFrameworks = options.stagingApp
            .appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingFrameworks,
            withIntermediateDirectories: true
        )
        let embeddedRuntime = stagingFrameworks
            .appendingPathComponent(
                options.runtimeFramework.lastPathComponent,
                isDirectory: true
            )
        guard !FileManager.default.fileExists(atPath: embeddedRuntime.path) else {
            throw PlayCoverUpstreamError.invalidApp(
                "source already contains \(embeddedRuntime.lastPathComponent)"
            )
        }
        try FileManager.default.copyItem(
            at: options.runtimeFramework,
            to: embeddedRuntime
        )
        if let expected = options.expectedRuntimeBuildHash {
            let actual = try runtimeBuildHash(frameworkURL: embeddedRuntime)
            guard actual == expected else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "Runtime framework changed while staging: expected "
                        + "\(expected), got \(actual)"
                )
            }
        }
        accumulateMonotonicDuration(
            &phaseTimings.cloneNanoseconds,
            since: cloneStarted
        )

        var converted: [String] = []
        for relative in installerRelativePaths {
            guard let sourceMacho = sourceByPath[relative] else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "Installer Mach-O disappeared from evidence: \(relative)"
                )
            }
            let target = options.stagingApp
                .appendingPathComponent(relative)
            if sourceMacho.platform != platformMacCatalyst {
                let convertStarted = monotonicTimestamp()
                do {
                    try Macho.convertMacho(target)
                } catch {
                    throw PlayCoverUpstreamError.unsupportedMachO(
                        "\(relative): \(error)"
                    )
                }
                accumulateMonotonicDuration(
                    &phaseTimings.convertNanoseconds,
                    since: convertStarted
                )
                converted.append(relative)
            }
            let signStarted = monotonicTimestamp()
            do {
                try Shell.signMacho(target)
            } catch {
                throw PlayCoverUpstreamError.signingFailed(
                    "\(relative): \(error)"
                )
            }
            accumulateMonotonicDuration(
                &phaseTimings.signNanoseconds,
                since: signStarted
            )
        }

        let mainExecutable = options.stagingApp
            .appendingPathComponent(source.mainExecutableRelativePath)
        let preInjection = try inspectMachO(
            at: mainExecutable,
            relativePath: source.mainExecutableRelativePath
        )
        try rejectRuntimeDuplicate(
            in: preInjection,
            runtimeLoadPath: options.runtimeLoadPath
        )
        let injectionStarted = monotonicTimestamp()
        try PlayTools.injectRuntime(
            mainExecutable,
            loadPath: options.runtimeLoadPath
        )
        accumulateMonotonicDuration(
            &phaseTimings.convertNanoseconds,
            since: injectionStarted
        )
        let postInjection = try inspectMachO(
            at: mainExecutable,
            relativePath: source.mainExecutableRelativePath
        )
        guard postInjection.dependencies.filter({
            $0 == options.runtimeLoadPath
        }).count == 1 else {
            throw PlayCoverUpstreamError.verificationFailed(
                "main executable does not have exactly one Runtime load command"
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: mainExecutable.path
        )

        let stagedBaseApp = BaseApp(appUrl: options.stagingApp)
        stagedBaseApp.info.applicationCategoryType = .none
        try Installer.removeMobileProvision(stagedBaseApp)
        try updateInfoPlist(
            options.stagingApp.appendingPathComponent("Info.plist")
        )

        let composition = try composeEntitlements(
            appURL: options.stagingApp,
            originalPlist: source.signature.entitlementsPlist,
            runtimeSocketPath: options.runtimeSocketPath,
            managedHome: options.managedHome,
            playSignActive: options.playSignActive
        )
        let signingStarted = monotonicTimestamp()
        let signing = try signInsideOut(
            appURL: options.stagingApp,
            source: source,
            finalEntitlements: composition.finalPlist
        )
        accumulateMonotonicDuration(
            &phaseTimings.signNanoseconds,
            since: signingStarted
        )
        do {
            _ = try Shell.run(
                print: false,
                "/usr/bin/xattr",
                "-dr",
                "com.apple.quarantine",
                options.stagingApp.path
            )
        } catch {
            throw PlayCoverUpstreamError.commandFailed(
                "remove quarantine from \(options.stagingApp.path): \(error)"
            )
        }

        let verifyStarted = monotonicTimestamp()
        let prepared = try verify(
            appURL: options.stagingApp,
            runtimeLoadPath: options.runtimeLoadPath
        )
        let sourceAfter = try contentHash(appURL: options.sourceApp)
        guard sourceAfter == source.sourceContentHash else {
            throw PlayCoverUpstreamError.sourceMutated(
                expected: source.sourceContentHash,
                actual: sourceAfter
            )
        }
        accumulateMonotonicDuration(
            &phaseTimings.verifyNanoseconds,
            since: verifyStarted
        )
        rollback = false
        return PlayCoverUpstreamPrepareResult(
            sourceBefore: source,
            sourceHashAfterPrepare: sourceAfter,
            prepared: prepared,
            convertedMachOs: converted,
            signingOrder: signing,
            entitlementDiff: composition.diff,
            phaseTimings: phaseTimings.evidence
        )
    }

    public static func verify(
        appURL: URL,
        runtimeLoadPath: String
    ) throws -> PlayCoverUpstreamAppInspection {
        let inspection = try inspect(appURL: appURL)
        for macho in inspection.machOs {
            guard !macho.encrypted else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "encrypted Mach-O remains: \(macho.relativePath)"
                )
            }
            guard macho.platform == platformMacCatalyst else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "non-Catalyst Mach-O remains: \(macho.relativePath)"
                )
            }
            try verifyCodeSignature(
                appURL.appendingPathComponent(macho.relativePath),
                label: macho.relativePath
            )
        }
        guard let main = inspection.machOs.first(where: {
            $0.relativePath == inspection.mainExecutableRelativePath
        }) else {
            throw PlayCoverUpstreamError.verificationFailed(
                "main executable is absent"
            )
        }
        let runtimeName = URL(fileURLWithPath: runtimeLoadPath).lastPathComponent
        let runtimeMatches = main.dependencies.filter {
            $0 == runtimeLoadPath || URL(fileURLWithPath: $0).lastPathComponent == runtimeName
        }
        guard runtimeMatches == [runtimeLoadPath] else {
            throw PlayCoverUpstreamError.verificationFailed(
                "Runtime load command is missing, duplicated, or shadowed by basename"
            )
        }
        for macho in inspection.machOs
            where macho.relativePath != inspection.mainExecutableRelativePath {
            guard !macho.dependencies.contains(where: {
                $0 == runtimeLoadPath
                    || URL(fileURLWithPath: $0).lastPathComponent == runtimeName
            }) else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "Runtime was injected outside the main executable: \(macho.relativePath)"
                )
            }
        }
        try verifyCodeSignature(appURL, label: appURL.lastPathComponent)
        return inspection
    }

    public static func contentHash(appURL: URL) throws -> String {
        let app = appURL.standardizedFileURL
        try validateTreeContainment(
            root: app,
            label: "App content hash",
            rejectRootSymlink: true
        )
        return try treeSnapshot(
            appURL: app,
            preloadedRegularFileData: [:],
            inspectMachOs: false
        ).contentHash
    }

    public static func runtimeBuildHash(frameworkURL: URL) throws -> String {
        // FileManager may enumerate `/tmp` and `/var` through their canonical
        // `/private/...` aliases. Anchor enumeration and relative paths to the
        // canonical framework root so an unchanged copy has the same build
        // identity regardless of which lexical alias the caller supplied.
        let root = frameworkURL.standardizedFileURL
            .resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(
                  atPath: root.path,
                  isDirectory: &directory
              ),
              directory.boolValue else {
            throw PlayCoverUpstreamError.invalidApp(
                "Runtime is not a framework directory: \(root.path)"
            )
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw PlayCoverUpstreamError.invalidApp(
                "cannot enumerate Runtime framework \(root.path)"
            )
        }
        var entries: [(String, URL, String, UInt16, UInt64)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
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
                    try relativePath(url, in: root),
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

    private struct Slice {
        let data: Data
        let container: PlayCoverUpstreamMachOContainer
        let fatIndex: UInt32
        let cpuType: Int32
        let cpuSubtype: Int32
        let offset: UInt64
        let size: UInt64
        let alignment: UInt32?
        let byteSwapped: Bool
    }

    private struct InventoryMetadata {
        let url: URL
        let relativePath: String
        let kind: PlayCoverUpstreamFileKind
        let size: UInt64?
        let posixPermissions: UInt16?
        let symbolicLinkDestination: String?
    }

    private struct RegularFileSnapshot {
        let sha256: String
        let isMachO: Bool
        let retainedData: Data?
    }

    private struct TreeSnapshot {
        let contentHash: String
        let inventory: [PlayCoverUpstreamInventoryEntry]
        let machOs: [PlayCoverUpstreamMachOInspection]
    }

    private struct PrepareTimingAccumulator {
        var cloneNanoseconds: UInt64 = 0
        var convertNanoseconds: UInt64 = 0
        var signNanoseconds: UInt64 = 0
        var verifyNanoseconds: UInt64 = 0

        var evidence: PlayCoverUpstreamPreparePhaseTimings {
            PlayCoverUpstreamPreparePhaseTimings(
                cloneNanoseconds: cloneNanoseconds,
                convertNanoseconds: convertNanoseconds,
                signNanoseconds: signNanoseconds,
                verifyNanoseconds: verifyNanoseconds
            )
        }
    }

    private struct EmbeddedSignatureEvidence {
        let superBlobLength: UInt32
        let paddingSize: UInt32
        let structureSHA256: String
        let paddingSHA256: String
        let slots: [PlayCoverUpstreamSignatureSlot]
    }

    struct EntitlementComposition {
        let finalPlist: Data
        let diff: PlayCoverUpstreamEntitlementDiff
    }

    public static func inspectMachO(
        at url: URL,
        relativePath: String
    ) throws -> PlayCoverUpstreamMachOInspection {
        let fullData = try Data(contentsOf: url, options: .alwaysMapped)
        return try inspectMachO(
            fullData,
            fileSHA256: hex(SHA256.hash(data: fullData)),
            at: url,
            relativePath: relativePath
        )
    }

    private static func inspectMachO(
        _ fullData: Data,
        fileSHA256: String,
        at url: URL,
        relativePath: String
    ) throws -> PlayCoverUpstreamMachOInspection {
        let rawSlices = try machoSlices(fullData, path: relativePath)
        guard let slice = rawSlices.first(where: {
            $0.cpuType == cpuTypeArm64
        }) else {
            throw PlayCoverUpstreamError.unsupportedMachO(
                "\(relativePath) has no arm64 slice"
            )
        }
        let data = slice.data
        guard data.count >= 32 else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(relativePath) has an incomplete mach_header_64"
            )
        }
        let magicBytes = Array(data.prefix(4))
        let swapped: Bool
        if magicBytes == [0xcf, 0xfa, 0xed, 0xfe] {
            swapped = false
        } else if magicBytes == [0xfe, 0xed, 0xfa, 0xcf] {
            swapped = true
        } else {
            throw PlayCoverUpstreamError.unsupportedMachO(
                "\(relativePath) is not a 64-bit Mach-O"
            )
        }
        let cpu = Int32(bitPattern: try u32(data, 4, bigEndian: swapped))
        guard cpu == cpuTypeArm64 else {
            throw PlayCoverUpstreamError.unsupportedMachO(
                "\(relativePath) has no arm64 slice"
            )
        }
        let fileType = try u32(data, 12, bigEndian: swapped)
        let count = try u32(data, 16, bigEndian: swapped)
        let bytes = try u32(data, 20, bigEndian: swapped)
        guard count > 0, count <= maximumLoadCommands,
              bytes >= 8, UInt64(32) + UInt64(bytes) <= UInt64(data.count) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(relativePath) has invalid load-command bounds"
            )
        }

        var cursor = 32
        var platform: UInt32?
        var minimumOS: UInt32?
        var sdk: UInt32?
        var encrypted = false
        var dependencies: [String] = []
        var rpaths: [String] = []
        var loadCommands: [PlayCoverUpstreamLoadCommandInspection] = []
        var firstSectionOffset: UInt64?
        for index in 0..<Int(count) {
            guard cursor + 8 <= 32 + Int(bytes) else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(relativePath) command \(index) header is truncated"
                )
            }
            let command = try u32(data, cursor, bigEndian: swapped)
            let commandSize = Int(
                try u32(data, cursor + 4, bigEndian: swapped)
            )
            guard commandSize >= 8,
                  cursor + commandSize <= 32 + Int(bytes),
                  cursor + commandSize <= data.count else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(relativePath) command \(index) has invalid size"
                )
            }
            let baseCommand = command & 0x7fff_ffff
            var semanticValue: String?
            switch baseCommand {
            case 0x32:
                guard commandSize >= 24 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short LC_BUILD_VERSION"
                    )
                }
                platform = try u32(data, cursor + 8, bigEndian: swapped)
                minimumOS = try u32(data, cursor + 12, bigEndian: swapped)
                sdk = try u32(data, cursor + 16, bigEndian: swapped)
                semanticValue =
                    "platform=\(platform!);minimumOS=\(minimumOS!);"
                    + "sdk=\(sdk!);tools="
                    + "\(try u32(data, cursor + 20, bigEndian: swapped))"
            case 0x24:
                guard commandSize >= 16 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short LC_VERSION_MIN_MACOSX"
                    )
                }
                platform = 1
                minimumOS = try u32(data, cursor + 8, bigEndian: swapped)
                sdk = try u32(data, cursor + 12, bigEndian: swapped)
                semanticValue =
                    "platform=1;minimumOS=\(minimumOS!);sdk=\(sdk!)"
            case 0x25:
                guard commandSize >= 16 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short LC_VERSION_MIN_IPHONEOS"
                    )
                }
                platform = platformIPhoneOS
                minimumOS = try u32(data, cursor + 8, bigEndian: swapped)
                sdk = try u32(data, cursor + 12, bigEndian: swapped)
                semanticValue =
                    "platform=\(platformIPhoneOS);minimumOS="
                    + "\(minimumOS!);sdk=\(sdk!)"
            case 0x2f, 0x30:
                guard commandSize >= 16 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short legacy platform command"
                    )
                }
                platform = baseCommand == 0x2f ? 3 : 4
                minimumOS = try u32(data, cursor + 8, bigEndian: swapped)
                sdk = try u32(data, cursor + 12, bigEndian: swapped)
                semanticValue =
                    "platform=\(platform!);minimumOS=\(minimumOS!);"
                    + "sdk=\(sdk!)"
            case 0x21, 0x2c:
                guard commandSize >= 20 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short encryption command"
                    )
                }
                encrypted = try u32(
                    data,
                    cursor + 16,
                    bigEndian: swapped
                ) != 0
                semanticValue =
                    "cryptoff="
                    + "\(try u32(data, cursor + 8, bigEndian: swapped));"
                    + "cryptsize="
                    + "\(try u32(data, cursor + 12, bigEndian: swapped));"
                    + "cryptid="
                    + "\(try u32(data, cursor + 16, bigEndian: swapped))"
            case 0x0c, 0x18, 0x1f, 0x20, 0x23:
                guard commandSize >= 24 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short dylib command"
                    )
                }
                let value = try loadCommandString(
                    data,
                    commandOffset: cursor,
                    commandSize: commandSize,
                    fieldOffset: 8,
                    minimumStringOffset: 24,
                    bigEndian: swapped,
                    label: relativePath
                )
                dependencies.append(value)
                semanticValue = value
            case 0x1c:
                guard commandSize >= 12 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short LC_RPATH"
                    )
                }
                let value = try loadCommandString(
                    data,
                    commandOffset: cursor,
                    commandSize: commandSize,
                    fieldOffset: 8,
                    minimumStringOffset: 12,
                    bigEndian: swapped,
                    label: relativePath
                )
                rpaths.append(value)
                semanticValue = value
            case 0x19:
                guard commandSize >= 72 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short LC_SEGMENT_64"
                    )
                }
                let sections = Int(
                    try u32(data, cursor + 64, bigEndian: swapped)
                )
                guard sections >= 0,
                      72 + sections * 80 <= commandSize else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has invalid section bounds"
                    )
                }
                semanticValue =
                    "segment=\(fixedString(data, cursor + 8, length: 16));"
                    + "vmaddr="
                    + "\(try u64(data, cursor + 24, bigEndian: swapped));"
                    + "vmsize="
                    + "\(try u64(data, cursor + 32, bigEndian: swapped));"
                    + "fileoff="
                    + "\(try u64(data, cursor + 40, bigEndian: swapped));"
                    + "filesize="
                    + "\(try u64(data, cursor + 48, bigEndian: swapped));"
                    + "sections=\(sections)"
                for section in 0..<sections {
                    let sectionOffset = cursor + 72 + section * 80
                    let fileOffset = UInt64(
                        try u32(
                            data,
                            sectionOffset + 48,
                            bigEndian: swapped
                        )
                    )
                    if fileOffset > 0 {
                        firstSectionOffset = min(
                            firstSectionOffset ?? fileOffset,
                            fileOffset
                        )
                    }
                }
            case 0x1b:
                guard commandSize >= 24 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short LC_UUID"
                    )
                }
                semanticValue = "uuid=" + relativeData(
                    data,
                    (cursor + 8)..<(cursor + 24)
                ).map { String(format: "%02x", $0) }.joined()
            case 0x1d:
                guard commandSize >= 16 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(relativePath) has a short LC_CODE_SIGNATURE"
                    )
                }
                semanticValue =
                    "dataoff="
                    + "\(try u32(data, cursor + 8, bigEndian: swapped));"
                    + "datasize="
                    + "\(try u32(data, cursor + 12, bigEndian: swapped))"
            default:
                break
            }
            let commandData = relativeData(
                data,
                cursor..<(cursor + commandSize)
            )
            loadCommands.append(
                PlayCoverUpstreamLoadCommandInspection(
                    index: UInt32(index),
                    command: command,
                    commandSize: UInt32(commandSize),
                    semanticValue: semanticValue,
                    bytesSHA256: hex(SHA256.hash(data: commandData))
                )
            )
            cursor += commandSize
        }
        guard cursor == 32 + Int(bytes) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(relativePath) load-command byte count is inconsistent"
            )
        }
        return PlayCoverUpstreamMachOInspection(
            relativePath: relativePath,
            fileSHA256: fileSHA256,
            container: slice.container,
            fatHeaderBigEndian: slice.container == .thin
                ? nil
                : [
                    [0xca, 0xfe, 0xba, 0xbe],
                    [0xca, 0xfe, 0xba, 0xbf],
                ].contains(Array(fullData.prefix(4))),
            arm64SliceOffset: slice.offset,
            arm64SliceSize: slice.size,
            byteSwapped: swapped,
            cpuType: cpu,
            fileType: fileType,
            commandCount: count,
            commandBytes: bytes,
            firstSectionOffset: firstSectionOffset,
            platform: platform,
            minimumOS: minimumOS,
            sdk: sdk,
            encrypted: encrypted,
            dependencies: dependencies,
            rpaths: rpaths,
            loadCommands: loadCommands,
            signature: try signatureEvidence(url),
            sliceInspections: try rawSlices.map {
                try inspectSlice($0, path: relativePath)
            }
        )
    }

    private static func machoSlices(
        _ data: Data,
        path: String
    ) throws -> [Slice] {
        guard data.count >= 4 else {
            throw PlayCoverUpstreamError.unsupportedMachO(
                "\(path) is too short"
            )
        }
        let magic = Array(data.prefix(4))
        if magic == [0xcf, 0xfa, 0xed, 0xfe]
            || magic == [0xfe, 0xed, 0xfa, 0xcf] {
            let swapped = magic[0] == 0xfe
            return [
                Slice(
                    data: data,
                    container: .thin,
                    fatIndex: 0,
                    cpuType: Int32(
                        bitPattern: try u32(data, 4, bigEndian: swapped)
                    ),
                    cpuSubtype: Int32(
                        bitPattern: try u32(data, 8, bigEndian: swapped)
                    ),
                    offset: 0,
                    size: UInt64(data.count),
                    alignment: nil,
                    byteSwapped: swapped
                ),
            ]
        }
        let isFat64: Bool
        let bigEndian: Bool
        switch magic {
        case [0xca, 0xfe, 0xba, 0xbe]:
            isFat64 = false
            bigEndian = true
        case [0xbe, 0xba, 0xfe, 0xca]:
            isFat64 = false
            bigEndian = false
        case [0xca, 0xfe, 0xba, 0xbf]:
            isFat64 = true
            bigEndian = true
        case [0xbf, 0xba, 0xfe, 0xca]:
            isFat64 = true
            bigEndian = false
        default:
            throw PlayCoverUpstreamError.unsupportedMachO(
                "\(path) has unsupported magic"
            )
        }
        guard data.count >= 8 else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has a short fat header"
            )
        }
        let count = Int(try u32(data, 4, bigEndian: bigEndian))
        let entrySize = isFat64 ? 32 : 20
        guard count > 0,
              count <= 4_096,
              8 + count * entrySize <= data.count else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has invalid fat architecture bounds"
            )
        }
        let tableEnd = 8 + count * entrySize
        var slices: [Slice] = []
        var occupiedRanges: [Range<UInt64>] = []
        for index in 0..<count {
            let entry = 8 + index * entrySize
            let cpu = Int32(
                bitPattern: try u32(data, entry, bigEndian: bigEndian)
            )
            let subtype = Int32(
                bitPattern: try u32(data, entry + 4, bigEndian: bigEndian)
            )
            let offset: UInt64
            let size: UInt64
            let alignment: UInt32
            if isFat64 {
                offset = try u64(data, entry + 8, bigEndian: bigEndian)
                size = try u64(data, entry + 16, bigEndian: bigEndian)
                alignment = try u32(data, entry + 24, bigEndian: bigEndian)
                guard try u32(
                    data,
                    entry + 28,
                    bigEndian: bigEndian
                ) == 0 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) fat64 slice \(index) has nonzero reserved data"
                    )
                }
            } else {
                offset = UInt64(
                    try u32(data, entry + 8, bigEndian: bigEndian)
                )
                size = UInt64(
                    try u32(data, entry + 12, bigEndian: bigEndian)
                )
                alignment = try u32(
                    data,
                    entry + 16,
                    bigEndian: bigEndian
                )
            }
            guard size >= 32,
                  offset >= UInt64(tableEnd),
                  offset <= UInt64(data.count),
                  size <= UInt64(data.count) - offset,
                  offset <= UInt64(Int.max),
                  size <= UInt64(Int.max),
                  alignment < 64,
                  offset % (UInt64(1) << alignment) == 0 else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) fat slice \(index) is out of bounds or misaligned"
                )
            }
            let range = offset..<(offset + size)
            guard !occupiedRanges.contains(where: { $0.overlaps(range) }) else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) fat slice \(index) overlaps another slice"
                )
            }
            occupiedRanges.append(range)
            let start = Int(offset)
            let end = start + Int(size)
            // `Data` slicing shares the file-backed storage and keeps the
            // original indices. Do not use `subdata(in:)` here: that eagerly
            // copies every fat slice and makes inspection proportional to the
            // sum of all slice sizes in heap memory.
            let sliceData = data[start..<end]
            let sliceMagic = Array(sliceData.prefix(4))
            guard sliceMagic == [0xcf, 0xfa, 0xed, 0xfe]
                    || sliceMagic == [0xfe, 0xed, 0xfa, 0xcf] else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) fat slice \(index) is not mach_header_64"
                )
            }
            let sliceSwapped = sliceMagic[0] == 0xfe
            let headerCPU = Int32(
                bitPattern: try u32(
                    sliceData,
                    4,
                    bigEndian: sliceSwapped
                )
            )
            let headerSubtype = Int32(
                bitPattern: try u32(
                    sliceData,
                    8,
                    bigEndian: sliceSwapped
                )
            )
            guard headerCPU == cpu, headerSubtype == subtype else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) fat slice \(index) table/header architecture "
                        + "mismatch"
                )
            }
            slices.append(
                Slice(
                    data: sliceData,
                    container: isFat64 ? .fat64 : .fat,
                    fatIndex: UInt32(index),
                    cpuType: cpu,
                    cpuSubtype: subtype,
                    offset: offset,
                    size: size,
                    alignment: alignment,
                    byteSwapped: sliceSwapped
                )
            )
        }
        let sortedRanges = occupiedRanges.sorted {
            $0.lowerBound < $1.lowerBound
        }
        var previousEnd = UInt64(tableEnd)
        for range in sortedRanges {
            guard relativeData(
                data,
                Int(previousEnd)..<Int(range.lowerBound)
            ).allSatisfy({ $0 == 0 }) else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) has nonzero fat-container padding"
                )
            }
            previousEnd = range.upperBound
        }
        guard relativeData(
            data,
            Int(previousEnd)..<data.count
        ).allSatisfy({ $0 == 0 }) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has nonzero fat-container trailing data"
            )
        }
        return slices
    }

    private static func inspectSlice(
        _ slice: Slice,
        path: String
    ) throws -> PlayCoverUpstreamMachOSliceInspection {
        let data = slice.data
        let swapped = slice.byteSwapped
        guard data.count >= 32 else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) slice \(slice.fatIndex) has an incomplete header"
            )
        }
        let cpu = Int32(bitPattern: try u32(data, 4, bigEndian: swapped))
        let subtype = Int32(
            bitPattern: try u32(data, 8, bigEndian: swapped)
        )
        guard cpu == slice.cpuType, subtype == slice.cpuSubtype else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) slice \(slice.fatIndex) architecture changed"
            )
        }
        let fileType = try u32(data, 12, bigEndian: swapped)
        let count = try u32(data, 16, bigEndian: swapped)
        let bytes = try u32(data, 20, bigEndian: swapped)
        let headerFlags = try u32(data, 24, bigEndian: swapped)
        let headerReserved = try u32(data, 28, bigEndian: swapped)
        guard count > 0, count <= maximumLoadCommands,
              bytes >= 8,
              UInt64(32) + UInt64(bytes) <= UInt64(data.count) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) slice \(slice.fatIndex) has invalid command bounds"
            )
        }

        var cursor = 32
        var platform: UInt32?
        var minimumOS: UInt32?
        var sdk: UInt32?
        var encrypted = false
        var dependencies: [String] = []
        var rpaths: [String] = []
        var commands: [PlayCoverUpstreamLoadCommandInspection] = []
        var firstSectionOffset: UInt64?
        var codeSignatureOffset: UInt64?
        var codeSignatureSize: UInt64?
        for index in 0..<Int(count) {
            guard cursor + 8 <= 32 + Int(bytes) else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) slice \(slice.fatIndex) command \(index) "
                        + "header is truncated"
                )
            }
            let command = try u32(data, cursor, bigEndian: swapped)
            let commandSize = Int(
                try u32(data, cursor + 4, bigEndian: swapped)
            )
            guard commandSize >= 8,
                  cursor + commandSize <= 32 + Int(bytes),
                  cursor + commandSize <= data.count else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) slice \(slice.fatIndex) command \(index) "
                        + "has invalid size"
                )
            }
            let baseCommand = command & 0x7fff_ffff
            var semanticValue: String?
            switch baseCommand {
            case 0x32:
                guard commandSize >= 24 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short LC_BUILD_VERSION"
                    )
                }
                platform = try u32(data, cursor + 8, bigEndian: swapped)
                minimumOS = try u32(data, cursor + 12, bigEndian: swapped)
                sdk = try u32(data, cursor + 16, bigEndian: swapped)
                semanticValue =
                    "platform=\(platform!);minimumOS=\(minimumOS!);"
                    + "sdk=\(sdk!);tools="
                    + "\(try u32(data, cursor + 20, bigEndian: swapped))"
            case 0x24:
                guard commandSize >= 16 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short LC_VERSION_MIN_MACOSX"
                    )
                }
                platform = 1
                minimumOS = try u32(data, cursor + 8, bigEndian: swapped)
                sdk = try u32(data, cursor + 12, bigEndian: swapped)
                semanticValue =
                    "platform=1;minimumOS=\(minimumOS!);sdk=\(sdk!)"
            case 0x25:
                guard commandSize >= 16 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short LC_VERSION_MIN_IPHONEOS"
                    )
                }
                platform = platformIPhoneOS
                minimumOS = try u32(data, cursor + 8, bigEndian: swapped)
                sdk = try u32(data, cursor + 12, bigEndian: swapped)
                semanticValue =
                    "platform=\(platformIPhoneOS);minimumOS="
                    + "\(minimumOS!);sdk=\(sdk!)"
            case 0x2f, 0x30:
                guard commandSize >= 16 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short legacy platform command"
                    )
                }
                platform = baseCommand == 0x2f ? 3 : 4
                minimumOS = try u32(data, cursor + 8, bigEndian: swapped)
                sdk = try u32(data, cursor + 12, bigEndian: swapped)
                semanticValue =
                    "platform=\(platform!);minimumOS=\(minimumOS!);"
                    + "sdk=\(sdk!)"
            case 0x21, 0x2c:
                guard commandSize >= 20 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short encryption command"
                    )
                }
                encrypted = try u32(
                    data,
                    cursor + 16,
                    bigEndian: swapped
                ) != 0
                semanticValue =
                    "cryptoff="
                    + "\(try u32(data, cursor + 8, bigEndian: swapped));"
                    + "cryptsize="
                    + "\(try u32(data, cursor + 12, bigEndian: swapped));"
                    + "cryptid="
                    + "\(try u32(data, cursor + 16, bigEndian: swapped))"
            case 0x0c, 0x18, 0x1f, 0x20, 0x23:
                guard commandSize >= 24 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short dylib command"
                    )
                }
                let value = try loadCommandString(
                    data,
                    commandOffset: cursor,
                    commandSize: commandSize,
                    fieldOffset: 8,
                    minimumStringOffset: 24,
                    bigEndian: swapped,
                    label: path
                )
                dependencies.append(value)
                semanticValue =
                    "path=\(value);pathOffset="
                    + "\(try u32(data, cursor + 8, bigEndian: swapped));"
                    + "timestamp="
                    + "\(try u32(data, cursor + 12, bigEndian: swapped));"
                    + "current="
                    + "\(try u32(data, cursor + 16, bigEndian: swapped));"
                    + "compatibility="
                    + "\(try u32(data, cursor + 20, bigEndian: swapped))"
            case 0x1c:
                guard commandSize >= 12 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short LC_RPATH"
                    )
                }
                let value = try loadCommandString(
                    data,
                    commandOffset: cursor,
                    commandSize: commandSize,
                    fieldOffset: 8,
                    minimumStringOffset: 12,
                    bigEndian: swapped,
                    label: path
                )
                rpaths.append(value)
                semanticValue =
                    "path=\(value);pathOffset="
                    + "\(try u32(data, cursor + 8, bigEndian: swapped))"
            case 0x19:
                guard commandSize >= 72 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short LC_SEGMENT_64"
                    )
                }
                let sections = Int(
                    try u32(data, cursor + 64, bigEndian: swapped)
                )
                guard 72 + sections * 80 <= commandSize else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has invalid section bounds"
                    )
                }
                semanticValue =
                    "segment=\(fixedString(data, cursor + 8, length: 16));"
                    + "vmaddr="
                    + "\(try u64(data, cursor + 24, bigEndian: swapped));"
                    + "vmsize="
                    + "\(try u64(data, cursor + 32, bigEndian: swapped));"
                    + "fileoff="
                    + "\(try u64(data, cursor + 40, bigEndian: swapped));"
                    + "filesize="
                    + "\(try u64(data, cursor + 48, bigEndian: swapped));"
                    + "maxprot="
                    + "\(try u32(data, cursor + 56, bigEndian: swapped));"
                    + "initprot="
                    + "\(try u32(data, cursor + 60, bigEndian: swapped));"
                    + "sections=\(sections);flags="
                    + "\(try u32(data, cursor + 68, bigEndian: swapped))"
                for section in 0..<sections {
                    let sectionOffset = cursor + 72 + section * 80
                    let fileOffset = UInt64(
                        try u32(
                            data,
                            sectionOffset + 48,
                            bigEndian: swapped
                        )
                    )
                    if fileOffset > 0 {
                        firstSectionOffset = min(
                            firstSectionOffset ?? fileOffset,
                            fileOffset
                        )
                    }
                }
            case 0x1b:
                guard commandSize >= 24 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short LC_UUID"
                    )
                }
                semanticValue = "uuid=" + relativeData(
                    data,
                    (cursor + 8)..<(cursor + 24)
                ).map { String(format: "%02x", $0) }.joined()
            case 0x1d:
                guard commandSize >= 16 else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has a short LC_CODE_SIGNATURE"
                    )
                }
                let dataOffset = try u32(
                    data,
                    cursor + 8,
                    bigEndian: swapped
                )
                let dataSize = try u32(
                    data,
                    cursor + 12,
                    bigEndian: swapped
                )
                guard UInt64(dataOffset) <= UInt64(data.count),
                      UInt64(dataSize)
                        <= UInt64(data.count) - UInt64(dataOffset) else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has an out-of-bounds LC_CODE_SIGNATURE"
                    )
                }
                guard codeSignatureOffset == nil else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has duplicate LC_CODE_SIGNATURE commands"
                    )
                }
                codeSignatureOffset = UInt64(dataOffset)
                codeSignatureSize = UInt64(dataSize)
                semanticValue =
                    "dataoff=\(dataOffset);datasize=\(dataSize)"
            default:
                break
            }
            let commandData = relativeData(
                data,
                cursor..<(cursor + commandSize)
            )
            commands.append(
                PlayCoverUpstreamLoadCommandInspection(
                    index: UInt32(index),
                    command: command,
                    commandSize: UInt32(commandSize),
                    semanticValue: semanticValue,
                    bytesSHA256: hex(SHA256.hash(data: commandData))
                )
            )
            cursor += commandSize
        }
        guard cursor == 32 + Int(bytes) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) slice \(slice.fatIndex) command bytes disagree"
            )
        }
        let immutableStart = firstSectionOffset
            ?? UInt64(32) + UInt64(bytes)
        let immutableEnd = codeSignatureOffset ?? UInt64(data.count)
        guard immutableStart <= immutableEnd,
              immutableStart >= UInt64(cursor),
              immutableEnd <= UInt64(data.count),
              immutableStart <= UInt64(Int.max),
              immutableEnd <= UInt64(Int.max) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) slice \(slice.fatIndex) immutable content bounds "
                    + "are invalid"
            )
        }
        let headerPadding = relativeData(
            data,
            cursor..<Int(immutableStart)
        )
        guard headerPadding.allSatisfy({ $0 == 0 }) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) slice \(slice.fatIndex) has nonzero bytes between "
                    + "load commands and its first section"
            )
        }
        if let codeSignatureOffset, let codeSignatureSize {
            guard codeSignatureOffset + codeSignatureSize
                    == UInt64(data.count) else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) slice \(slice.fatIndex) has trailing bytes "
                        + "outside LC_CODE_SIGNATURE"
                )
            }
        }
        let immutableContent = relativeData(
            data,
            Int(immutableStart)..<Int(immutableEnd)
        )
        return PlayCoverUpstreamMachOSliceInspection(
            fatIndex: slice.fatIndex,
            cpuType: cpu,
            cpuSubtype: subtype,
            offset: slice.offset,
            size: slice.size,
            alignment: slice.alignment,
            byteSwapped: swapped,
            fileType: fileType,
            headerFlags: headerFlags,
            headerReserved: headerReserved,
            commandCount: count,
            commandBytes: bytes,
            firstSectionOffset: firstSectionOffset,
            platform: platform,
            minimumOS: minimumOS,
            sdk: sdk,
            encrypted: encrypted,
            dependencies: dependencies,
            rpaths: rpaths,
            loadCommands: commands,
            signature: try signatureEvidence(
                forThinSlice: data,
                codeSignatureOffset: codeSignatureOffset,
                codeSignatureSize: codeSignatureSize,
                path: "\(path) slice \(slice.fatIndex)"
            ),
            sliceSHA256: hex(SHA256.hash(data: data)),
            immutableContentSHA256: hex(
                SHA256.hash(data: immutableContent)
            )
        )
    }

    private static func embeddedSignatureEvidence(
        _ data: Data,
        codeSignatureOffset: UInt64?,
        codeSignatureSize: UInt64?,
        path: String
    ) throws -> EmbeddedSignatureEvidence? {
        guard let codeSignatureOffset, let codeSignatureSize else {
            guard codeSignatureOffset == nil, codeSignatureSize == nil else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) has incomplete code-signature bounds"
                )
            }
            return nil
        }
        guard codeSignatureOffset <= UInt64(Int.max),
              codeSignatureSize <= UInt64(Int.max),
              codeSignatureOffset <= UInt64(data.count),
              codeSignatureSize
                <= UInt64(data.count) - codeSignatureOffset else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has invalid embedded-signature bounds"
            )
        }
        let start = Int(codeSignatureOffset)
        let end = start + Int(codeSignatureSize)
        let signatureData = relativeData(data, start..<end)
        guard signatureData.count >= 12,
              try u32(signatureData, 0, bigEndian: true)
                == 0xfade_0cc0 else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) lacks an embedded-signature SuperBlob"
            )
        }
        let declaredLength = try u32(
            signatureData,
            4,
            bigEndian: true
        )
        let count = try u32(signatureData, 8, bigEndian: true)
        guard declaredLength >= 12,
              declaredLength <= UInt32(signatureData.count),
              count <= 4_096,
              UInt64(12) + UInt64(count) * 8
                <= UInt64(declaredLength) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has invalid SuperBlob bounds"
            )
        }
        let declaredEnd = Int(declaredLength)

        let tableEnd = 12 + Int(count) * 8
        var occupiedRanges: [Range<Int>] = []
        var slots: [PlayCoverUpstreamSignatureSlot] = []
        for index in 0..<Int(count) {
            let entry = 12 + index * 8
            let type = try u32(
                signatureData,
                entry,
                bigEndian: true
            )
            let rawBlobOffset = try u32(
                signatureData,
                entry + 4,
                bigEndian: true
            )
            let blobOffset = Int(rawBlobOffset)
            guard blobOffset >= tableEnd,
                  blobOffset + 8 <= declaredEnd else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) signature slot \(index) has invalid bounds"
                )
            }
            let magic = try u32(
                signatureData,
                blobOffset,
                bigEndian: true
            )
            let blobLength = try u32(
                signatureData,
                blobOffset + 4,
                bigEndian: true
            )
            guard blobLength >= 8,
                  UInt64(blobOffset) + UInt64(blobLength)
                    <= UInt64(declaredEnd) else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) signature slot \(index) is truncated"
                )
            }
            let range = blobOffset..<(blobOffset + Int(blobLength))
            guard !occupiedRanges.contains(where: {
                $0.overlaps(range)
            }) else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(path) signature slot \(index) overlaps another slot"
                )
            }
            occupiedRanges.append(range)
            let blob = Data(relativeData(signatureData, range))
            let codeDirectory = magic == 0xfade_0c02
                ? try codeDirectoryEvidence(
                    blob,
                    path: "\(path) signature slot \(index)"
                )
                : nil
            slots.append(
                PlayCoverUpstreamSignatureSlot(
                    index: UInt32(index),
                    type: type,
                    offset: rawBlobOffset,
                    magic: magic,
                    length: blobLength,
                    bytesSHA256: hex(SHA256.hash(data: blob)),
                    bytes: blob,
                    codeDirectory: codeDirectory
                )
            )
        }
        let codeDirectorySlots = slots.filter {
            isCodeDirectorySlotType($0.type)
        }
        let primaryCodeDirectories = codeDirectorySlots.filter {
            $0.type == 0
        }
        guard primaryCodeDirectories.count == 1,
              codeDirectorySlots.allSatisfy({
                  $0.magic == 0xfade_0c02 && $0.codeDirectory != nil
              }),
              Set(codeDirectorySlots.map(\.type)).count
                == codeDirectorySlots.count,
              !slots.contains(where: {
                  $0.codeDirectory != nil
                      && !isCodeDirectorySlotType($0.type)
              }) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) must contain one primary and unique legal "
                    + "alternate CodeDirectories"
            )
        }
        for codeDirectorySlot in codeDirectorySlots {
            guard let codeDirectory = codeDirectorySlot.codeDirectory else {
                preconditionFailure(
                    "legal CodeDirectory slot lost parsed evidence"
                )
            }
            for slot in slots where slot.type > 0
                    && slot.type < 0x1_000 {
                guard let signedHash =
                    codeDirectory.specialSlotHashes["-\(slot.type)"] else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) signature slot \(slot.index) is not bound "
                            + "by CodeDirectory type "
                            + "\(codeDirectorySlot.type)"
                    )
                }
                let fullHash: String
                switch codeDirectory.hashType {
                case 1:
                    fullHash = hex(Insecure.SHA1.hash(data: slot.bytes))
                case 2, 3:
                    fullHash = slot.bytesSHA256
                case 4:
                    fullHash = hex(SHA384.hash(data: slot.bytes))
                default:
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) has unsupported special-slot hash type "
                            + "\(codeDirectory.hashType)"
                    )
                }
                let expectedCharacters =
                    Int(codeDirectory.hashSize) * 2
                guard expectedCharacters <= fullHash.count else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) special-slot hash size exceeds its algorithm"
                    )
                }
                let actualHash = String(
                    fullHash.prefix(expectedCharacters)
                )
                guard signedHash == actualHash else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(path) signature slot \(slot.index) hash is not "
                            + "bound by CodeDirectory type "
                            + "\(codeDirectorySlot.type)"
                    )
                }
            }
        }
        var structure = Data(
            relativeData(signatureData, 0..<declaredEnd)
        )
        for range in occupiedRanges {
            structure.replaceSubrange(
                range,
                with: repeatElement(UInt8(0), count: range.count)
            )
        }
        let padding = Data(relativeData(
            signatureData,
            declaredEnd..<signatureData.count
        ))
        return EmbeddedSignatureEvidence(
            superBlobLength: declaredLength,
            paddingSize: UInt32(signatureData.count - declaredEnd),
            structureSHA256: hex(SHA256.hash(data: structure)),
            paddingSHA256: hex(SHA256.hash(data: padding)),
            slots: slots
        )
    }

    private static func isCodeDirectorySlotType(_ type: UInt32) -> Bool {
        type == 0 || (type >= 0x1_000 && type < 0x1_005)
    }

    private static func codeDirectoryEvidence(
        _ blob: Data,
        path: String
    ) throws -> PlayCoverUpstreamCodeDirectoryEvidence {
        guard blob.count >= 44,
              try u32(blob, 0, bigEndian: true) == 0xfade_0c02,
              try u32(blob, 4, bigEndian: true) == UInt32(blob.count) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has an invalid CodeDirectory"
            )
        }
        let hashOffset = Int(try u32(blob, 16, bigEndian: true))
        let specialCount = Int(try u32(blob, 24, bigEndian: true))
        let codeCount = Int(try u32(blob, 28, bigEndian: true))
        let hashSize = Int(blob[36])
        let hashType = blob[37]
        guard hashSize > 0,
              hashSize <= 64,
              specialCount <= blob.count / hashSize,
              codeCount <= blob.count / hashSize else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has invalid CodeDirectory hash counts"
            )
        }
        let specialBytes = specialCount * hashSize
        let codeBytes = codeCount * hashSize
        guard hashOffset >= specialBytes,
              hashOffset <= blob.count,
              codeBytes <= blob.count - hashOffset else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has out-of-bounds CodeDirectory hashes"
            )
        }
        let hashStart = hashOffset - specialBytes
        let hashEnd = hashOffset + codeBytes
        var specialSlotHashes: [String: String] = [:]
        if specialCount > 0 {
            for slot in 1...specialCount {
                let start = hashOffset - slot * hashSize
                let bytes = blob[start..<(start + hashSize)]
                specialSlotHashes["-\(slot)"] = bytes.map {
                    String(format: "%02x", $0)
                }.joined()
            }
        }
        var codeSlotHashes: [String] = []
        for slot in 0..<codeCount {
            let start = hashOffset + slot * hashSize
            let bytes = blob[start..<(start + hashSize)]
            codeSlotHashes.append(
                bytes.map { String(format: "%02x", $0) }.joined()
            )
        }
        var normalized = blob
        normalized.replaceSubrange(
            hashStart..<hashEnd,
            with: repeatElement(UInt8(0), count: hashEnd - hashStart)
        )
        let cdHash: String
        switch hashType {
        case 1:
            cdHash = String(
                hex(Insecure.SHA1.hash(data: blob)).prefix(40)
            )
        case 2, 3:
            cdHash = String(
                hex(SHA256.hash(data: blob)).prefix(40)
            )
        case 4:
            cdHash = String(
                hex(SHA384.hash(data: blob)).prefix(40)
            )
        default:
            throw PlayCoverUpstreamError.malformedMachO(
                "\(path) has unsupported CodeDirectory hash type \(hashType)"
            )
        }
        return PlayCoverUpstreamCodeDirectoryEvidence(
            structureSHA256: hex(SHA256.hash(data: normalized)),
            cdHash: cdHash,
            hashType: hashType,
            hashSize: UInt8(hashSize),
            specialSlotHashes: specialSlotHashes,
            codeSlotHashes: codeSlotHashes
        )
    }

    private static func signatureEvidence(
        forThinSlice data: Data,
        codeSignatureOffset: UInt64?,
        codeSignatureSize: UInt64?,
        path: String
    ) throws -> PlayCoverUpstreamSignature {
        let embedded = try embeddedSignatureEvidence(
            data,
            codeSignatureOffset: codeSignatureOffset,
            codeSignatureSize: codeSignatureSize,
            path: path
        )
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-slice-\(UUID().uuidString)"
            )
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporary.path
        )
        return try signatureEvidence(
            temporary,
            embeddedSignature: embedded,
            diagnosticPath: path
        )
    }

    private static func treeSnapshot(
        appURL: URL,
        preloadedRegularFileData: [String: Data],
        inspectMachOs: Bool
    ) throws -> TreeSnapshot {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw PlayCoverUpstreamError.invalidApp(
                "cannot enumerate \(appURL.path)"
            )
        }
        var metadata: [InventoryMetadata] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let kind: PlayCoverUpstreamFileKind
            if values.isSymbolicLink == true {
                kind = .symbolicLink
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .regularFile
            } else {
                kind = .other
            }
            let attrs = try? FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let permissions = (attrs?[.posixPermissions] as? NSNumber)
                .map { UInt16(truncating: $0) }
            let relative = try relativePath(url, in: appURL)
            metadata.append(
                InventoryMetadata(
                    url: url,
                    relativePath: relative,
                    kind: kind,
                    size: values.fileSize.map { UInt64($0) },
                    posixPermissions: permissions,
                    symbolicLinkDestination: kind == .symbolicLink
                        ? try FileManager.default.destinationOfSymbolicLink(
                            atPath: url.path
                        )
                        : nil
                )
            )
        }

        var hasher = SHA256()
        var inventory = Array<PlayCoverUpstreamInventoryEntry?>(
            repeating: nil,
            count: metadata.count
        )
        var machOs = Array<PlayCoverUpstreamMachOInspection?>(
            repeating: nil,
            count: metadata.count
        )
        let sortedIndices = metadata.indices.sorted {
            metadata[$0].relativePath.utf8.lexicographicallyPrecedes(
                metadata[$1].relativePath.utf8
            )
        }
        for index in sortedIndices {
            let entry = metadata[index]
            update(&hasher, entry.relativePath)
            update(&hasher, entry.kind.rawValue)
            update(&hasher, entry.posixPermissions.map(String.init) ?? "-")
            update(&hasher, entry.size.map(String.init) ?? "-")
            let fileSHA256: String?
            let codeKind: String?
            switch entry.kind {
            case .regularFile:
                updateLength(&hasher, entry.size ?? 0)
                let file = try readRegularFile(
                    entry.url,
                    preloadedData:
                        preloadedRegularFileData[entry.relativePath],
                    retainMachOData: inspectMachOs,
                    contentHasher: &hasher
                )
                fileSHA256 = file.sha256
                codeKind = file.isMachO
                    ? codeObjectKind(
                        forMachO: entry.relativePath,
                        appURL: appURL
                    )
                    : nil
                if inspectMachOs, file.isMachO {
                    guard let data = file.retainedData else {
                        preconditionFailure(
                            "Mach-O bytes were not retained for inspection"
                        )
                    }
                    machOs[index] = try inspectMachO(
                        data,
                        fileSHA256: file.sha256,
                        at: entry.url,
                        relativePath: entry.relativePath
                    )
                }
            case .symbolicLink:
                update(&hasher, entry.symbolicLinkDestination ?? "")
                fileSHA256 = nil
                codeKind = nil
            case .directory, .other:
                fileSHA256 = nil
                codeKind = entry.kind == .directory
                    ? codeObjectKind(forDirectory: entry.relativePath)
                    : nil
            }
            inventory[index] = PlayCoverUpstreamInventoryEntry(
                relativePath: entry.relativePath,
                kind: entry.kind,
                size: entry.size,
                posixPermissions: entry.posixPermissions,
                sha256: fileSHA256,
                symbolicLinkDestination: entry.symbolicLinkDestination,
                codeObjectKind: codeKind
            )
        }
        return TreeSnapshot(
            contentHash: hex(hasher.finalize()),
            inventory: inventory.map {
                guard let entry = $0 else {
                    preconditionFailure("inventory entry was not materialized")
                }
                return entry
            },
            machOs: machOs.compactMap { $0 }
        )
    }

    private static func readRegularFile(
        _ url: URL,
        preloadedData: Data?,
        retainMachOData: Bool,
        contentHasher: inout SHA256
    ) throws -> RegularFileSnapshot {
        if let data = preloadedData {
            let macho = isMachO(data)
            contentHasher.update(data: data)
            return RegularFileSnapshot(
                sha256: hex(SHA256.hash(data: data)),
                isMachO: macho,
                retainedData: retainMachOData && macho ? data : nil
            )
        }

        // Hash and inspect through one file-backed mapping. Only the current
        // file is mapped, and Mach-O slices below share this storage instead
        // of accumulating a second heap copy.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let macho = isMachO(data)
        let fileSHA256 = hex(SHA256.hash(data: data))
        contentHasher.update(data: data)
        return RegularFileSnapshot(
            sha256: fileSHA256,
            isMachO: macho,
            retainedData: retainMachOData && macho ? data : nil
        )
    }

    private static func provisioningSHA256(
        attributes: [FileAttributeKey: Any]?,
        relativePath: String,
        url: URL,
        snapshot: TreeSnapshot
    ) throws -> String? {
        guard attributes != nil else {
            return nil
        }
        if let sha256 = snapshot.inventory.first(where: {
            $0.relativePath == relativePath && $0.kind == .regularFile
        })?.sha256 {
            return sha256
        }
        return try fileSHA256(url)
    }

    static func composeEntitlements(
        appURL: URL,
        originalPlist: Data?,
        runtimeSocketPath: String,
        managedHome: URL? = nil,
        playSignActive: Bool
    ) throws -> EntitlementComposition {
        let original = try entitlementDictionary(originalPlist)
        let app = BaseApp(appUrl: appURL)
        if let originalPlist {
            try originalPlist.write(to: app.entitlements, options: .atomic)
        }
        let baseline: [String: Any]
        do {
            baseline = try Entitlements.composeEntitlements(
                app,
                discordActivityEnabled: false,
                bypass: false,
                playSignActive: playSignActive,
                homeDirectory: managedHome
                    ?? FileManager.default.homeDirectoryForCurrentUser
            )
        } catch {
            throw PlayCoverUpstreamError.entitlementFailed(
                "PlayCover composition: \(error)"
            )
        }

        // Keep pinned composition semantics: source entitlements are overlaid
        // only when PlaySign is active. The local patch below extends only the
        // sandbox profile needed by the injected Runtime.
        var final = baseline
        var finalSandbox =
            final["com.apple.security.temporary-exception.sbpl"] as? [String]
                ?? []
        // Sandbox path matching uses canonical filesystem paths.  In
        // particular, macOS presents `/tmp` to callers but resolves it to
        // `/private/tmp`; emitting the lexical alias makes the otherwise
        // valid Runtime socket open fail with EPERM inside the injected App.
        let socketParent = URL(fileURLWithPath: runtimeSocketPath)
            .deletingLastPathComponent()
            .standardizedFileURL.path
        let canonicalSocketParent =
            canonicalizingExistingPrefix(socketParent)
        finalSandbox.append(
            "(allow file-read* file-write* file-read-metadata "
                + "(subpath \""
                + "\(sandboxEscape(canonicalSocketParent))\"))"
        )
        // The App Sandbox classifies AF_UNIX bind separately from the vnode
        // creation above.  Keep this exception scoped to the owner-only
        // per-IOS_USE_HOME run directory; the session socket filename is
        // generated later and cannot be embedded in the prepared signature.
        finalSandbox.append(
            "(allow network-bind "
                + "(subpath \""
                + "\(sandboxEscape(canonicalSocketParent))\"))"
        )
        if let managedHome {
            let managed = canonicalizingExistingPrefix(
                managedHome.standardizedFileURL.path
            )
            let playChain = (managed as NSString)
                .appendingPathComponent("playcover/PlayChain")
            finalSandbox.append(
                "(allow file-read* file-write* file-read-metadata "
                    + "(subpath \"\(sandboxEscape(managed))\"))"
            )
            finalSandbox.append(
                "(allow file-read* file-write* file-read-metadata "
                    + "(subpath \"\(sandboxEscape(playChain))\"))"
            )
        }
        final["com.apple.security.temporary-exception.sbpl"] = finalSandbox

        let originalNormalized = normalizeEntitlements(original)
        let baselineNormalized = normalizeEntitlements(baseline)
        let finalNormalized = normalizeEntitlements(final)
        let removed = originalNormalized.keys.filter {
            finalNormalized[$0] == nil
        }.sorted()
        let baselineAdded = baselineNormalized.keys.filter {
            originalNormalized[$0] == nil
        }.sorted()
        let iosUseAdded = finalNormalized.keys.filter {
            baselineNormalized[$0] == nil
        }.sorted()
        let changed = originalNormalized.keys.filter {
            finalNormalized[$0] != originalNormalized[$0]
        }.sorted()
        let plist: Data
        do {
            plist = try PropertyListSerialization.data(
                fromPropertyList: final,
                format: .xml,
                options: 0
            )
        } catch {
            throw PlayCoverUpstreamError.entitlementFailed(
                "cannot serialize final entitlements: \(error)"
            )
        }
        return EntitlementComposition(
            finalPlist: plist,
            diff: PlayCoverUpstreamEntitlementDiff(
                original: originalNormalized,
                playCoverBaseline: baselineNormalized,
                final: finalNormalized,
                addedByPlayCover: baselineAdded,
                addedByIOSUse: iosUseAdded,
                changedFromOriginal: changed,
                removedFromOriginal: removed
            )
        )
    }

    static func signInsideOut(
        appURL: URL,
        source _: PlayCoverUpstreamAppInspection,
        finalEntitlements: Data
    ) throws -> [String] {
        let prepared = try inspect(appURL: appURL)
        let preparedMachOPaths = Set(prepared.machOs.map(\.relativePath))
        let nestedBundles = prepared.inventory.compactMap {
            entry -> String? in
            guard entry.kind == .directory,
                  let codeKind = entry.codeObjectKind,
                  codeKind.hasSuffix("Bundle") else {
                return nil
            }
            return entry.relativePath
        }.sorted {
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            if lhsDepth != rhsDepth {
                return lhsDepth > rhsDepth
            }
            return $0 < $1
        }

        // A bundle's executable is signed by signing the bundle code object.
        // Pinned Installer's per-Mach-O signing drops source entitlements
        // before its final `codesign --deep` pass, which does not restore
        // them. Keep nested executables in their containing bundle pass and
        // sign that bundle without source entitlements.
        let nestedMainExecutables = Set(
            nestedBundles.compactMap {
                nestedBundleExecutableRelativePath(
                    bundleRelativePath: $0,
                    appURL: appURL,
                    knownMachOs: preparedMachOPaths
                )
            }
        )
        var order: [String] = []
        let dependencies = prepared.machOs.filter {
            $0.relativePath != prepared.mainExecutableRelativePath
                && !nestedMainExecutables.contains($0.relativePath)
        }.sorted {
            let lhsDepth = $0.relativePath.split(separator: "/").count
            let rhsDepth = $1.relativePath.split(separator: "/").count
            if lhsDepth != rhsDepth {
                return lhsDepth > rhsDepth
            }
            return $0.relativePath < $1.relativePath
        }
        for macho in dependencies {
            try sign(
                appURL.appendingPathComponent(macho.relativePath),
                entitlements: nil
            )
            order.append(macho.relativePath)
            try verifyCodeSignature(
                appURL.appendingPathComponent(macho.relativePath),
                label: macho.relativePath
            )
        }

        for relative in nestedBundles {
            try sign(
                appURL.appendingPathComponent(relative),
                entitlements: nil
            )
            order.append(relative)
            try verifyCodeSignature(
                appURL.appendingPathComponent(relative),
                label: relative
            )
        }
        try sign(appURL, entitlements: finalEntitlements)
        order.append(".")
        try verifyCodeSignature(appURL, label: ".")

        // The outer seal must leave every child code object valid.
        for relative in order {
            let url = relative == "."
                ? appURL
                : appURL.appendingPathComponent(relative)
            try verifyCodeSignature(url, label: relative)
        }
        return order
    }

    private static func nestedBundleExecutableRelativePath(
        bundleRelativePath: String,
        appURL: URL,
        knownMachOs: Set<String>
    ) -> String? {
        let bundleURL = appURL.appendingPathComponent(
            bundleRelativePath,
            isDirectory: true
        )
        let infoCandidates = [
            bundleURL.appendingPathComponent("Info.plist"),
            bundleURL
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Info.plist"),
            bundleURL
                .appendingPathComponent("Versions/Current/Resources",
                                        isDirectory: true)
                .appendingPathComponent("Info.plist"),
        ]
        guard let infoURL = infoCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }), let info = NSDictionary(contentsOf: infoURL),
           let executableName = info["CFBundleExecutable"] as? String,
           !executableName.isEmpty else {
            return nil
        }
        let direct = bundleRelativePath + "/" + executableName
        if knownMachOs.contains(direct) {
            return direct
        }
        let prefix = bundleRelativePath + "/"
        return knownMachOs.first {
            $0.hasPrefix(prefix)
                && URL(fileURLWithPath: $0).lastPathComponent
                    == executableName
        }
    }

    private static func sign(_ url: URL, entitlements: Data?) throws {
        do {
            if let entitlements {
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ios-use-playcover-entitlements-\(UUID().uuidString).plist"
                    )
                try entitlements.write(to: temporary, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: temporary.path
                )
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Shell.signAppWith(url, entitlements: temporary)
            } else {
                try Shell.signMacho(url)
            }
        } catch {
            throw PlayCoverUpstreamError.signingFailed(
                "\(url.path): \(error)"
            )
        }
    }

    private static func signatureEvidence(
        _ url: URL,
        embeddedSignature: EmbeddedSignatureEvidence? = nil,
        diagnosticPath: String? = nil
    ) throws -> PlayCoverUpstreamSignature {
        let evidencePath = diagnosticPath ?? url.path
        let metadata = codeSignatureMetadata(url)
        let hasDEREntitlements = embeddedSignature?.slots.contains {
            $0.type == 7
        } == true
        let derEntitlementsPlist: Data?
        if hasDEREntitlements {
            derEntitlementsPlist = try decodedDEREntitlements(url)
        } else {
            derEntitlementsPlist = nil
        }

        func result(
            signed: Bool,
            entitlementsPlist: Data?
        ) throws -> PlayCoverUpstreamSignature {
            if let embeddedSignature {
                let displayed = metadata?.cdHash?.lowercased()
                let candidates = embeddedSignature.slots.filter {
                    isCodeDirectorySlotType($0.type)
                }.compactMap(\.codeDirectory)
                guard let displayed,
                      candidates.contains(where: {
                          $0.cdHash == displayed
                      }) else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(evidencePath) displayed CDHash "
                            + "\(displayed ?? "missing") does not match any "
                            + "embedded CodeDirectory"
                    )
                }
            }
            if let entitlementsPlist, let derEntitlementsPlist {
                let xmlValue = try signatureEntitlementsCanonicalValue(
                    entitlementsPlist
                )
                let derValue = try signatureEntitlementsCanonicalValue(
                    derEntitlementsPlist
                )
                guard xmlValue == derValue else {
                    throw PlayCoverUpstreamError.malformedMachO(
                        "\(url.path) XML and DER entitlements disagree"
                    )
                }
            }
            return PlayCoverUpstreamSignature(
                isSigned: signed,
                isValid: signed && codeSignatureIsValid(url),
                cdHash: metadata?.cdHash,
                identifier: metadata?.identifier,
                teamIdentifier: metadata?.teamIdentifier,
                signatureType: metadata?.signatureType,
                flags: metadata?.flags,
                codeDirectoryVersion: metadata?.codeDirectoryVersion,
                codeDirectoryHashes: metadata?.codeDirectoryHashes,
                hashChoices: metadata?.hashChoices,
                hashType: metadata?.hashType,
                pageSize: metadata?.pageSize,
                superBlobLength: embeddedSignature?.superBlobLength,
                superBlobPaddingSize: embeddedSignature?.paddingSize,
                superBlobStructureSHA256:
                    embeddedSignature?.structureSHA256,
                superBlobPaddingSHA256:
                    embeddedSignature?.paddingSHA256,
                embeddedSlots: embeddedSignature?.slots ?? [],
                entitlementsPlist: entitlementsPlist,
                derEntitlementsPlist: derEntitlementsPlist
            )
        }

        let output: String
        do {
            output = try Shell.run(
                print: false,
                "/usr/bin/codesign",
                "-d",
                "--entitlements",
                "-",
                "--xml",
                url.path
            )
        } catch {
            let description = String(describing: error)
            if description.contains("code object is not signed at all")
                || description.contains("does not have any entitlements")
                || description.contains("Document is empty") {
                let signed = metadata != nil || embeddedSignature != nil
                return try result(signed: signed, entitlementsPlist: nil)
            }
            throw PlayCoverUpstreamError.commandFailed(
                "extract entitlements from \(evidencePath): \(description)"
            )
        }
        guard let xml = extractPlist(from: output),
              !xml.isEmpty else {
            return try result(signed: true, entitlementsPlist: nil)
        }
        return try result(
            signed: true,
            entitlementsPlist: Data(xml.utf8)
        )
    }

    private static func decodedDEREntitlements(
        _ url: URL
    ) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/derq")
        process.arguments = [
            "macho",
            "--input",
            url.path,
            "-x",
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw String(
                    data: output,
                    encoding: .utf8
                ) ?? "derq failed"
            }
            let startMarker = Data("<?xml".utf8)
            let endMarker = Data("</plist>".utf8)
            guard let start = output.range(of: startMarker)?.lowerBound,
                  let end = output.range(
                    of: endMarker,
                    options: .backwards,
                    in: start..<output.endIndex
                  )?.upperBound else {
                throw PlayCoverUpstreamError.malformedMachO(
                    "\(url.path) DER entitlements cannot be decoded"
                )
            }
            return Data(output[start..<end])
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw PlayCoverUpstreamError.commandFailed(
                "extract DER entitlements from \(url.path): \(error)"
            )
        }
    }

    private static func signatureEntitlementsCanonicalValue(
        _ data: Data
    ) throws -> String {
        do {
            let value = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            return canonicalValue(value)
        } catch {
            throw PlayCoverUpstreamError.malformedMachO(
                "cannot parse signature entitlements: \(error)"
            )
        }
    }

    private struct CodeSignatureMetadata {
        let cdHash: String?
        let identifier: String?
        let teamIdentifier: String?
        let signatureType: String?
        let flags: String?
        let codeDirectoryVersion: String?
        let codeDirectoryHashes: String?
        let hashChoices: String?
        let hashType: String?
        let pageSize: String?
    }

    private static func codeSignatureMetadata(
        _ url: URL
    ) -> CodeSignatureMetadata? {
        guard let output = try? Shell.run(
            print: false,
            "/usr/bin/codesign",
            "-d",
            "--verbose=4",
            url.path
        ) else {
            return nil
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var values: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            values[String(line[..<separator])] =
                String(line[line.index(after: separator)...])
        }
        let codeDirectory = lines.first {
            $0.hasPrefix("CodeDirectory ")
        }
        func codeDirectoryToken(_ name: String) -> String? {
            codeDirectory?
                .split(separator: " ")
                .first { $0.hasPrefix(name + "=") }
                .map { String($0.dropFirst(name.count + 1)) }
        }
        return CodeSignatureMetadata(
            cdHash: values["CDHash"],
            identifier: values["Identifier"],
            teamIdentifier: values["TeamIdentifier"],
            signatureType: values["Signature"],
            flags: codeDirectoryToken("flags") ?? values["Flags"],
            codeDirectoryVersion: codeDirectoryToken("v"),
            codeDirectoryHashes: codeDirectoryToken("hashes"),
            hashChoices: values["Hash choices"],
            hashType: values["Hash type"],
            pageSize: values["Page size"]
        )
    }

    private static func codeSignatureIsValid(_ url: URL) -> Bool {
        (try? Shell.run(
            print: false,
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            url.path
        )) != nil
    }

    private static func verifyCodeSignature(
        _ url: URL,
        label: String
    ) throws {
        do {
            _ = try Shell.run(
                print: false,
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                url.path
            )
        } catch {
            throw PlayCoverUpstreamError.verificationFailed(
                "\(label) code signature: \(error)"
            )
        }
    }

    private static func validateManagedStaging(
        _ options: PlayCoverUpstreamPrepareOptions,
        source: PlayCoverUpstreamAppInspection
    ) throws {
        let sourcePath = URL(fileURLWithPath: source.appPath)
            .standardizedFileURL.path
        let home = options.managedHome.standardizedFileURL.path
        let managedStaging =
            options.managedStagingApp ?? options.stagingApp
        let staging = managedStaging.standardizedFileURL.path
        guard options.stagingApp.pathExtension == "app",
              managedStaging.pathExtension == "app",
              options.stagingApp.lastPathComponent
                == managedStaging.lastPathComponent else {
            throw PlayCoverUpstreamError.invalidApp(
                "staging output identity must use one matching .app name"
            )
        }
        try requireNoSymlinkComponents(
            options.managedHome,
            label: "managed IOS_USE_HOME",
            allowMissingLeaf: false
        )
        try requireNoSymlinkComponents(
            managedStaging.deletingLastPathComponent(),
            label: "staging parent",
            allowMissingLeaf: false
        )
        if options.managedStagingApp != nil {
            try requireSameDirectoryIdentity(
                options.stagingApp.deletingLastPathComponent(),
                managedStaging.deletingLastPathComponent(),
                label: "staging I/O vnode"
            )
        }
        guard staging != sourcePath,
              !staging.hasPrefix(sourcePath + "/") else {
            throw PlayCoverUpstreamError.invalidApp(
                "staging output must be outside the source App"
            )
        }
        guard staging.hasPrefix(home + "/") else {
            throw PlayCoverUpstreamError.invalidApp(
                "staging output must be under managed IOS_USE_HOME: \(home)"
            )
        }
        guard !FileManager.default.fileExists(atPath: staging) else {
            throw PlayCoverUpstreamError.invalidApp(
                "staging output already exists: \(staging)"
            )
        }
        let socket = URL(fileURLWithPath: options.runtimeSocketPath)
            .standardizedFileURL.path
        guard socket.hasPrefix(home + "/") else {
            throw PlayCoverUpstreamError.invalidApp(
                "Runtime socket must be under managed IOS_USE_HOME"
            )
        }
        guard !options.runtimeLoadPath.isEmpty,
              options.runtimeLoadPath.utf8.count < 1_024 else {
            throw PlayCoverUpstreamError.invalidApp(
                "Runtime load path is empty or unreasonably long"
            )
        }
    }

    private static func validateRuntimeFramework(_ url: URL) throws {
        try requireNoSymlinkComponents(
            url,
            label: "Runtime framework",
            allowMissingLeaf: false
        )
        try validateTreeContainment(
            root: url,
            label: "Runtime framework",
            rejectRootSymlink: true
        )
        var directory: ObjCBool = false
        guard url.pathExtension == "framework",
              FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &directory
              ),
              directory.boolValue else {
            throw PlayCoverUpstreamError.invalidApp(
                "Runtime is not a framework directory: \(url.path)"
            )
        }
        let name = url.deletingPathExtension().lastPathComponent
        let executable = url.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PlayCoverUpstreamError.invalidApp(
                "Runtime framework executable is missing: \(executable.path)"
            )
        }
        let inspection = try inspectMachO(
            at: executable,
            relativePath: executable.lastPathComponent
        )
        guard inspection.platform == platformMacCatalyst,
              !inspection.encrypted else {
            throw PlayCoverUpstreamError.invalidApp(
                "Runtime must be an unencrypted arm64 Mac Catalyst binary"
            )
        }
    }

    private static func requireSameDirectoryIdentity(
        _ first: URL,
        _ second: URL,
        label: String
    ) throws {
        var firstStatus = stat()
        var secondStatus = stat()
        guard lstat(first.path, &firstStatus) == 0,
              lstat(second.path, &secondStatus) == 0,
              firstStatus.st_mode & S_IFMT == S_IFDIR,
              secondStatus.st_mode & S_IFMT == S_IFDIR,
              firstStatus.st_dev == secondStatus.st_dev,
              firstStatus.st_ino == secondStatus.st_ino else {
            throw PlayCoverUpstreamError.invalidApp(
                "\(label) no longer matches its managed lexical path"
            )
        }
    }

    private static func cloneSource(_ source: URL, to staging: URL) throws {
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            _ = try Shell.run(
                print: false,
                "/bin/cp",
                "-cR",
                source.standardizedFileURL.path,
                staging.standardizedFileURL.path
            )
        } catch {
            throw PlayCoverUpstreamError.commandFailed(
                "APFS clone \(source.path) -> \(staging.path): \(error)"
            )
        }
    }

    static func preflightMachOMutations(
        _ inspection: PlayCoverUpstreamMachOInspection,
        runtimeLoadPath: String?
    ) throws {
        let commandsEnd = UInt64(32) + UInt64(inspection.commandBytes)
        let available = inspection.firstSectionOffset.map {
            $0 >= commandsEnd ? $0 - commandsEnd : 0
        } ?? 0
        var required: UInt64 = 0
        if let runtimeLoadPath {
            let raw = runtimeLoadPath.utf8.count + 24
            required += UInt64((raw + 7) & ~7)
        }
        if inspection.dependencies.contains("@rpath/libswiftUIKit.dylib") {
            let old = (24 + "@rpath/libswiftUIKit.dylib".utf8.count + 1 + 7)
                & ~7
            let new = (
                24
                    + "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib"
                        .utf8.count
                    + 1 + 7
            ) & ~7
            required += UInt64(max(0, new - old))
        }
        guard available >= required else {
            throw PlayCoverUpstreamError.insufficientMachOPadding(
                "\(inspection.relativePath) requires \(required) bytes, "
                    + "has \(available)"
            )
        }
    }

    private static func validateTreeContainment(
        root: URL,
        label: String,
        rejectRootSymlink: Bool
    ) throws {
        if rejectRootSymlink {
            try requireNoSymlinkComponents(
                root,
                label: label,
                allowMissingLeaf: false
            )
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw PlayCoverUpstreamError.invalidApp(
                "cannot enumerate \(label): \(root.path)"
            )
        }
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let destination = try FileManager.default
                .destinationOfSymbolicLink(atPath: entry.path)
            guard !destination.hasPrefix("/") else {
                throw PlayCoverUpstreamError.invalidApp(
                    "\(label) absolute symbolic link is not clone-safe: "
                        + entry.path
                )
            }
            let resolved = entry.resolvingSymlinksInPath()
                .standardizedFileURL.path
            guard resolved == canonicalRoot
                    || resolved.hasPrefix(canonicalRoot + "/") else {
                throw PlayCoverUpstreamError.invalidApp(
                    "\(label) symbolic-link escape: \(entry.path)"
                )
            }
        }
    }

    private static func requireNoSymlinkComponents(
        _ url: URL,
        label: String,
        allowMissingLeaf: Bool
    ) throws {
        var value = stat()
        if lstat(url.standardizedFileURL.path, &value) != 0 {
            if errno == ENOENT, allowMissingLeaf { return }
            throw PlayCoverUpstreamError.invalidApp(
                "\(label) is missing: \(url.path)"
            )
        }
        guard value.st_mode & S_IFMT != S_IFLNK else {
            throw PlayCoverUpstreamError.invalidApp(
                "\(label) is a symbolic link: \(url.path)"
            )
        }
    }

    private static func rejectRuntimeDuplicate(
        in inspection: PlayCoverUpstreamMachOInspection,
        runtimeLoadPath: String
    ) throws {
        let basename = URL(fileURLWithPath: runtimeLoadPath).lastPathComponent
        if let duplicate = inspection.dependencies.first(where: {
            $0 == runtimeLoadPath
                || URL(fileURLWithPath: $0).lastPathComponent == basename
        }) {
            throw PlayCoverUpstreamError.duplicateRuntimeLoad(duplicate)
        }
    }

    static func updateInfoPlist(_ url: URL) throws {
        let appInfo = AppInfo(contentsOf: url)
        appInfo.assert(minimumVersion: 11)
        try appInfo.write()
        guard let raw = NSMutableDictionary(contentsOf: url) else {
            throw PlayCoverUpstreamError.invalidApp(
                "cannot decode \(url.path)"
            )
        }
        // Catalyst otherwise applies the legacy 320 x 480 compatibility canvas
        // to iOS Apps that have no launch-screen declaration. Preserve every
        // existing launch/scene key; only add the modern empty declaration
        // when neither supported launch-screen form exists.
        let modernValue = raw["UILaunchScreen"]
        let hasModernLaunchScreen = modernValue is NSDictionary
        if modernValue != nil, !hasModernLaunchScreen {
            throw PlayCoverUpstreamError.invalidApp(
                "UILaunchScreen exists but is not a dictionary"
            )
        }
        let hasLaunchStoryboard =
            (raw["UILaunchStoryboardName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        if !hasModernLaunchScreen, !hasLaunchStoryboard {
            raw["UILaunchScreen"] = NSDictionary()
        }
        do {
            try raw.write(to: url)
        } catch {
            throw PlayCoverUpstreamError.invalidApp(
                "cannot update Info.plist: \(error)"
            )
        }
    }

    private static func entitlementDictionary(
        _ data: Data?
    ) throws -> [String: Any] {
        guard let data, !data.isEmpty else {
            return [:]
        }
        do {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] ?? [:]
        } catch {
            throw PlayCoverUpstreamError.entitlementFailed(
                "cannot parse original entitlements: \(error)"
            )
        }
    }

    private static func normalizeEntitlements(
        _ values: [String: Any]
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: values.map {
                ($0.key, canonicalValue($0.value))
            }
        )
    }

    private static func canonicalValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return "\"\(string)\""
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let data as Data:
            return "data:sha256:\(hex(SHA256.hash(data: data)))"
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let array as [Any]:
            return "[" + array.map(canonicalValue).joined(separator: ",") + "]"
        case let dictionary as [String: Any]:
            return "{" + dictionary.keys.sorted().map {
                "\($0):\(canonicalValue(dictionary[$0] as Any))"
            }.joined(separator: ",") + "}"
        default:
            return String(describing: value)
        }
    }

    private static func sandboxEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func canonicalizingExistingPrefix(
        _ path: String
    ) -> String {
        var existing = URL(
            fileURLWithPath: path
        ).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var buffer = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        let resolved = existing.path.withCString {
            Darwin.realpath($0, &buffer)
        }
        var result = resolved == nil
            ? existing.path
            : String(cString: buffer)
        for component in suffix {
            result = (result as NSString)
                .appendingPathComponent(component)
        }
        return result
    }

    private static func extractPlist(from output: String) -> String? {
        guard let start = output.range(of: "<?xml")?.lowerBound,
              let endRange = output.range(
                of: "</plist>",
                options: .backwards,
                range: start..<output.endIndex
              ) else {
            return nil
        }
        return String(output[start..<endRange.upperBound])
    }

    private static func codeObjectKind(
        forDirectory path: String
    ) -> String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "framework": return "frameworkBundle"
        case "appex": return "appExtensionBundle"
        case "xpc": return "xpcBundle"
        case "plugin": return "pluginBundle"
        default: return nil
        }
    }

    private static func codeObjectKind(
        forMachO path: String,
        appURL: URL
    ) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "dylib" {
            return "dylib"
        }
        if path.contains(".framework/") {
            return "frameworkExecutable"
        }
        if path.contains(".appex/") {
            return "appExtensionExecutable"
        }
        if path.contains(".xpc/") {
            return "xpcExecutable"
        }
        if path.contains(".plugin/") {
            return "pluginExecutable"
        }
        return "machO"
    }

    private static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else {
            return false
        }
        let magic = Array(data.prefix(4))
        return [
            [0xcf, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf],
            [0xca, 0xfe, 0xba, 0xbe],
            [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf],
            [0xbf, 0xba, 0xfe, 0xca],
        ].contains(magic)
    }

    private static func loadCommandString(
        _ data: Data,
        commandOffset: Int,
        commandSize: Int,
        fieldOffset: Int,
        minimumStringOffset: Int,
        bigEndian: Bool,
        label: String
    ) throws -> String {
        let relative = Int(
            try u32(
                data,
                commandOffset + fieldOffset,
                bigEndian: bigEndian
            )
        )
        guard relative >= minimumStringOffset, relative < commandSize else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(label) has an invalid load-command string offset"
            )
        }
        let start = data.startIndex + commandOffset + relative
        let end = data.startIndex + commandOffset + commandSize
        guard let terminator = data[start..<end].firstIndex(of: 0) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(label) load-command string is not NUL terminated"
            )
        }
        guard data[
            (data.startIndex + commandOffset + minimumStringOffset)..<start
        ].allSatisfy({ $0 == 0 }),
        data[data.index(after: terminator)..<end].allSatisfy({ $0 == 0 }) else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(label) has nonzero load-command string padding"
            )
        }
        guard let value = String(
            data: data[start..<terminator],
            encoding: .utf8
        ), !value.isEmpty else {
            throw PlayCoverUpstreamError.malformedMachO(
                "\(label) has an empty/non-UTF8 load-command string"
            )
        }
        return value
    }

    private static func fixedString(
        _ data: Data,
        _ offset: Int,
        length: Int
    ) -> String {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            return ""
        }
        let start = data.startIndex + offset
        let field = data[start..<(start + length)]
        let bytes = field.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func u32(
        _ data: Data,
        _ offset: Int,
        bigEndian: Bool
    ) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw PlayCoverUpstreamError.malformedMachO(
                "32-bit read is out of bounds"
            )
        }
        let start = data.startIndex + offset
        let bytes = Array(data[start..<(start + 4)])
        if bigEndian {
            return UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
        }
        return UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }

    private static func u64(
        _ data: Data,
        _ offset: Int,
        bigEndian: Bool
    ) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else {
            throw PlayCoverUpstreamError.malformedMachO(
                "64-bit read is out of bounds"
            )
        }
        var value: UInt64 = 0
        let start = data.startIndex + offset
        if bigEndian {
            for byte in data[start..<(start + 8)] {
                value = value << 8 | UInt64(byte)
            }
        } else {
            for index in 0..<8 {
                value |= UInt64(data[start + index]) << UInt64(index * 8)
            }
        }
        return value
    }

    /// Returns a zero-copy view addressed relative to the beginning of
    /// `data`. Foundation `Data` slices preserve their original indices, so
    /// all Mach-O offsets must be translated through `startIndex`.
    private static func relativeData(
        _ data: Data,
        _ range: Range<Int>
    ) -> Data {
        precondition(
            range.lowerBound >= 0
                && range.upperBound >= range.lowerBound
                && range.upperBound <= data.count
        )
        let start = data.startIndex + range.lowerBound
        let end = data.startIndex + range.upperBound
        return data[start..<end]
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

    private static func relativePath(
        _ url: URL,
        in root: URL
    ) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if let relative = relativePath(
            path: path,
            rootPath: rootPath
        ) {
            return relative
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
            .standardizedFileURL.path
        var status = stat()
        let resolvedURL: URL
        if lstat(path, &status) == 0,
           status.st_mode & S_IFMT == S_IFLNK {
            resolvedURL = url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent)
        } else {
            resolvedURL = url.resolvingSymlinksInPath()
        }
        if let relative = relativePath(
            path: resolvedURL.standardizedFileURL.path,
            rootPath: resolvedRoot
        ) {
            return relative
        }
        throw PlayCoverUpstreamError.invalidApp(
            "enumerated path escaped its root: \(path) outside \(rootPath)"
        )
    }

    private static func relativePath(
        path: String,
        rootPath: String
    ) -> String? {
        if path == rootPath {
            return "."
        }
        guard path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func monotonicTimestamp() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func accumulateMonotonicDuration(
        _ total: inout UInt64,
        since start: UInt64
    ) {
        let end = monotonicTimestamp()
        let elapsed = end >= start ? end - start : 0
        total = total > UInt64.max - elapsed
            ? UInt64.max
            : total + elapsed
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
}

private extension FileManager {
    func isRegularFile(atPath path: String) -> Bool {
        var directory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue
    }
}
