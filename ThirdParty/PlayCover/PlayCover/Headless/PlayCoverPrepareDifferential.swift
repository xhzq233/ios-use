/*
 * Differential prepare support for PlayCover at
 * 7190cc9ce57c8dee0e222918468f2579acc95e1b.
 *
 * PlayCover is GPL-3.0. See ../../../LICENSE and ../../../PROVENANCE.md.
 */

import CryptoKit
import Darwin
import Foundation
import MachO
import injection

private let playCoverPrepareDifferentialEmbeddedSourceClosureSHA256 =
    "66513d73f83f3d1400c8160e3113846151ac50101dfdbcc4bd3270223eec0632"

private func playCoverCanonicalExistingURL(_ url: URL) -> URL? {
    guard let resolved = realpath(url.standardizedFileURL.path, nil) else {
        return nil
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}

public struct PlayCoverPinnedPrimitivePrepareOptions: Sendable {
    public let sourceApp: URL
    public let stagingApp: URL
    public let managedHome: URL
    public let playSignActive: Bool
    public let bundledPlayToolsFramework: URL?

    public init(
        sourceApp: URL,
        stagingApp: URL,
        managedHome: URL,
        playSignActive: Bool = false,
        bundledPlayToolsFramework: URL? = nil
    ) {
        self.sourceApp = sourceApp
        self.stagingApp = stagingApp
        self.managedHome = managedHome
        self.playSignActive = playSignActive
        self.bundledPlayToolsFramework = bundledPlayToolsFramework
    }
}

enum PlayCoverPinnedPrepareProducer: String, Sendable {
    case fullPlayToolsInstallerOracle
    case primitiveCharacterization
}

public struct PlayCoverPinnedPrimitivePrepareResult: Sendable {
    public let sourceBefore: PlayCoverUpstreamAppInspection
    public let sourceHashAfterPrepare: String
    public let prepared: PlayCoverUpstreamAppInspection
    public let convertedMachOs: [String]
    public let signingOrder: [String]
    public let executedPinnedSymbols: [String]
    let producer: PlayCoverPinnedPrepareProducer

    init(
        sourceBefore: PlayCoverUpstreamAppInspection,
        sourceHashAfterPrepare: String,
        prepared: PlayCoverUpstreamAppInspection,
        convertedMachOs: [String],
        signingOrder: [String],
        executedPinnedSymbols: [String],
        producer: PlayCoverPinnedPrepareProducer
    ) {
        self.sourceBefore = sourceBefore
        self.sourceHashAfterPrepare = sourceHashAfterPrepare
        self.prepared = prepared
        self.convertedMachOs = convertedMachOs
        self.signingOrder = signingOrder
        self.executedPinnedSymbols = executedPinnedSymbols
        self.producer = producer
    }
}

fileprivate enum PlayCoverPinnedInjectionMode {
    case primitiveCore
    case fullPlayTools(URL)
}

/// Headless adapter for the pinned PlayCover Installer mutation sequence.
///
/// UI choice/progress, IPA extraction, Finder-library placement, and the final
/// path-only wrapper move are transport concerns outside an unpacked `.app`
/// prepare comparison. All app mutations execute through the vendored pinned
/// symbols, including the complete `PlayTools.installInIPA` implementation
/// with a real fixture framework/plugin resource tree.
public enum PlayCoverPinnedHeadlessInstallerOracle {
    public static let playCoverRevision =
        "7190cc9ce57c8dee0e222918468f2579acc95e1b"

    public static let referenceLineage =
        "pinned-installer-headless-adapter;exact-playtools-install-in-ipa;"
            + "independent-of-ios-use-prepare"

    public static let adapterBoundaryEvidence = [
        "NSAlert and InstallVM select/report the pinned branch without app "
            + "mutations; omitted InstallPreferences are fixed to their pinned "
            + "defaults (install PlayTools and application category .none).",
        "IPA.allocateTempDir/unzip/checkOfficialMacOS are replaced by an "
            + "already-unpacked, signed source .app fixture.",
        "Installer.wrap's Finder-library move is replaced by an APFS clone to "
            + "the explicit output.",
        "PlayApp.sign is retained as exact corresponding source but its GUI "
            + "class closure is not linked. The adapter records its direct "
            + "Entitlements.composeEntitlements then Shell.signAppWith "
            + "sequence; the pinned side keeps --deep while ios-use "
            + "strengthens it to explicit inside-out children and root last.",
    ]

    public static func prepare(
        _ options: PlayCoverPinnedPrimitivePrepareOptions
    ) async throws -> PlayCoverPinnedPrimitivePrepareResult {
        guard let framework = options.bundledPlayToolsFramework else {
            throw PlayCoverUpstreamError.invalidApp(
                "authoritative pinned oracle requires a bundled "
                    + "PlayTools.framework fixture"
            )
        }
        return try await PlayCoverPinnedPrimitiveCharacterization.execute(
            options,
            injectionMode: .fullPlayTools(framework)
        )
    }
}

/// A fixture-only primitive characterization that is independent from
/// `PlayCoverUpstreamEngine.prepare`.
///
/// It invokes the vendored pinned mutation primitives in `Installer.install`
/// order. It is deliberately not described as a reference/oracle because it
/// cannot execute the pristine top-level installer or full
/// `PlayTools.installInIPA` resource path.
public enum PlayCoverPinnedPrimitiveCharacterization {
    public static let playCoverRevision =
        "7190cc9ce57c8dee0e222918468f2579acc95e1b"

    public static let referenceLineage =
        "characterization-only;vendored-pinned-primitives;"
            + "not-authoritative-installer-oracle"

    /// The load path used by pinned `PlayTools.installInIPA`.
    public static var playToolsLoadPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("PlayTools.framework")
            .appendingPathComponent("PlayTools")
            .path
    }

    /// Executes the pinned source mutation path without calling the ios-use
    /// prepare wrapper or `PlayCoverUpstreamEngine.prepare`.
    public static func prepare(
        _ options: PlayCoverPinnedPrimitivePrepareOptions
    ) async throws -> PlayCoverPinnedPrimitivePrepareResult {
        try await execute(options, injectionMode: .primitiveCore)
    }

    fileprivate static func execute(
        _ options: PlayCoverPinnedPrimitivePrepareOptions,
        injectionMode: PlayCoverPinnedInjectionMode
    ) async throws -> PlayCoverPinnedPrimitivePrepareResult {
        let source = try PlayCoverUpstreamEngine.inspect(
            appURL: options.sourceApp
        )
        try validate(options, source: source)
        var executedPinnedSymbols: [String] = []

        let referenceContainer = options.managedHome.appendingPathComponent(
            "pinned-playcover-container",
            isDirectory: true
        )
        try PlayTools.configureManagedContainer(referenceContainer)

        let sourceBaseApp = BaseApp(appUrl: options.sourceApp)
        try Installer.saveEntitlements(sourceBaseApp)
        executedPinnedSymbols.append("Installer.saveEntitlements")
        let installerMachOs = try Installer.resolveValidMachOs(sourceBaseApp)
        executedPinnedSymbols.append("Installer.resolveValidMachOs")
        let relativePaths = try installerMachOs.map {
            try relativePath($0, in: options.sourceApp)
        }
        let sourcePaths = Set(source.machOs.map(\.relativePath))
        guard Set(relativePaths) == sourcePaths else {
            let installerOnly = Set(relativePaths)
                .subtracting(sourcePaths)
                .sorted()
            let inspectionOnly = sourcePaths
                .subtracting(relativePaths)
                .sorted()
            throw PlayCoverUpstreamError.verificationFailed(
                "pinned Installer enumeration and neutral inspection "
                    + "disagree; installer-only=\(installerOnly); "
                    + "inspection-only=\(inspectionOnly)"
            )
        }
        for relative in relativePaths {
            let sourceURL = options.sourceApp.appendingPathComponent(relative)
            if try Macho.isMachoEncrypted(atURL: sourceURL) {
                throw PlayCoverUpstreamError.encryptedMachO(relative)
            }
            executedPinnedSymbols.append(
                "Macho.isMachoEncrypted[\(relative)]"
            )
        }

        try cloneSource(options.sourceApp, to: options.stagingApp)
        var rollback = true
        defer {
            if rollback {
                try? FileManager.default.removeItem(at: options.stagingApp)
            }
        }

        var converted: [String] = []
        var signingOrder: [String] = []
        for relative in relativePaths {
            let target = options.stagingApp.appendingPathComponent(relative)
            do {
                try Macho.convertMacho(target)
            } catch {
                throw PlayCoverUpstreamError.unsupportedMachO(
                    "\(relative): \(error)"
                )
            }
            converted.append(relative)
            executedPinnedSymbols.append("Macho.convertMacho[\(relative)]")
            do {
                try Shell.signMacho(target)
            } catch {
                throw PlayCoverUpstreamError.signingFailed(
                    "\(relative): \(error)"
                )
            }
            signingOrder.append(relative)
            executedPinnedSymbols.append("Shell.signMacho[\(relative)]")
        }

        let mainExecutable = options.stagingApp.appendingPathComponent(
            source.mainExecutableRelativePath
        )
        var addedMachOPaths = Set<String>()
        switch injectionMode {
        case .primitiveCore:
            var injectionSucceeded = false
            Inject.injectMachO(
                machoPath: mainExecutable.path,
                cmdType: .loadDylib,
                backup: false,
                injectPath: playToolsLoadPath,
                finishHandle: { injectionSucceeded = $0 }
            )
            guard injectionSucceeded else {
                throw PlayCoverUpstreamError.injectionFailed(
                    "pinned PlayTools.installInIPA core: "
                        + mainExecutable.path
                )
            }
            executedPinnedSymbols.append(contentsOf: [
                "Inject.injectMachO "
                    + "(PlayTools.installInIPA mutation core only)",
            ])
        case .fullPlayTools(let bundledFramework):
            let observedCalls =
                try await PlayTools.installInIPAForHeadlessOracle(
                mainExecutable,
                bundledFramework: bundledFramework
            )
            executedPinnedSymbols.append(contentsOf: observedCalls)
            let pluginExecutable =
                "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface"
            addedMachOPaths.insert(pluginExecutable)
        }
        let stagedBaseApp = BaseApp(appUrl: options.stagingApp)
        stagedBaseApp.info.applicationCategoryType = .none
        executedPinnedSymbols.append(
            "AppInfo.applicationCategoryType(default:.none)"
        )
        executedPinnedSymbols.append(
            "FileManager.setAttributes(mainExecutable,0755)"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: mainExecutable.path
        )
        try Installer.removeMobileProvision(stagedBaseApp)
        executedPinnedSymbols.append("Installer.removeMobileProvision")
        stagedBaseApp.info.assert(minimumVersion: 11)
        try stagedBaseApp.info.write()
        executedPinnedSymbols.append("AppInfo.assert(minimumVersion:)")

        let pinnedEntitlements = try Entitlements.composeEntitlements(
            stagedBaseApp,
            discordActivityEnabled: false,
            bypass: false,
            playSignActive: options.playSignActive,
            homeDirectory: options.managedHome
        )
        executedPinnedSymbols.append(
            "PlayApp.sign adapter -> Entitlements.composeEntitlements"
        )
        let entitlementsURL = options.managedHome.appendingPathComponent(
            "pinned-reference-entitlements.plist"
        )
        try PropertyListSerialization.data(
            fromPropertyList: pinnedEntitlements,
            format: .xml,
            options: 0
        ).write(to: entitlementsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: entitlementsURL.path
        )
        defer { try? FileManager.default.removeItem(at: entitlementsURL) }

        do {
            try Shell.signAppWithPinnedOracle(
                options.stagingApp,
                entitlements: entitlementsURL
            )
        } catch {
            throw PlayCoverUpstreamError.signingFailed(
                "pinned Shell.signAppWith --deep: \(error)"
            )
        }
        executedPinnedSymbols.append(
            "PlayApp.sign adapter -> Shell.signAppWith(--deep)"
        )
        signingOrder.append(".")
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
                "pinned quarantine removal: \(error)"
            )
        }
        executedPinnedSymbols.append(
            "IPA.removeQuarantine operation (/usr/bin/xattr)"
        )

        let prepared = try PlayCoverUpstreamEngine.inspect(
            appURL: options.stagingApp
        )
        try verifyReference(
            prepared,
            appURL: options.stagingApp,
            sourcePaths: sourcePaths,
            addedMachOPaths: addedMachOPaths
        )
        let sourceAfter = try PlayCoverUpstreamEngine.contentHash(
            appURL: options.sourceApp
        )
        guard sourceAfter == source.sourceContentHash else {
            throw PlayCoverUpstreamError.sourceMutated(
                expected: source.sourceContentHash,
                actual: sourceAfter
            )
        }

        rollback = false
        let producer: PlayCoverPinnedPrepareProducer
        switch injectionMode {
        case .fullPlayTools:
            producer = .fullPlayToolsInstallerOracle
        case .primitiveCore:
            producer = .primitiveCharacterization
        }
        return PlayCoverPinnedPrimitivePrepareResult(
            sourceBefore: source,
            sourceHashAfterPrepare: sourceAfter,
            prepared: prepared,
            convertedMachOs: converted,
            signingOrder: signingOrder,
            executedPinnedSymbols: executedPinnedSymbols,
            producer: producer
        )
    }

    private static func validate(
        _ options: PlayCoverPinnedPrimitivePrepareOptions,
        source: PlayCoverUpstreamAppInspection
    ) throws {
        let sourcePath = URL(fileURLWithPath: source.appPath)
            .standardizedFileURL.path
        let home = options.managedHome.standardizedFileURL.path
        let staging = options.stagingApp.standardizedFileURL.path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: home,
            isDirectory: &directory
        ), directory.boolValue else {
            throw PlayCoverUpstreamError.invalidApp(
                "pinned reference managed home is missing: \(home)"
            )
        }
        guard options.stagingApp.pathExtension == "app",
              staging != sourcePath,
              staging.hasPrefix(home + "/"),
              !FileManager.default.fileExists(atPath: staging) else {
            throw PlayCoverUpstreamError.invalidApp(
                "pinned reference output must be a new .app under managed home"
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
                "pinned APFS clone \(source.path) -> \(staging.path): \(error)"
            )
        }
    }

    private static func verifyReference(
        _ inspection: PlayCoverUpstreamAppInspection,
        appURL: URL,
        sourcePaths: Set<String>,
        addedMachOPaths: Set<String>
    ) throws {
        guard Set(inspection.machOs.map(\.relativePath))
                == sourcePaths.union(addedMachOPaths) else {
            throw PlayCoverUpstreamError.verificationFailed(
                "pinned reference unexpectedly added or removed a Mach-O"
            )
        }
        for macho in inspection.machOs {
            let expectedPlatform: UInt32 =
                addedMachOPaths.contains(macho.relativePath)
                    ? 1
                    : PlayCoverUpstreamEngine.platformMacCatalyst
            guard macho.platform == expectedPlatform else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "pinned reference platform mismatch "
                        + "\(macho.relativePath): "
                        + String(describing: macho.platform)
                )
            }
            guard macho.signature.isSigned, macho.signature.isValid else {
                throw PlayCoverUpstreamError.verificationFailed(
                    "pinned reference signature is invalid: "
                        + macho.relativePath
                )
            }
        }
        guard let main = inspection.machOs.first(where: {
            $0.relativePath == inspection.mainExecutableRelativePath
        }), main.dependencies.filter({
            $0 == playToolsLoadPath
        }).count == 1 else {
            throw PlayCoverUpstreamError.verificationFailed(
                "pinned reference does not have one PlayTools load command"
            )
        }
        do {
            _ = try Shell.run(
                print: false,
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                appURL.path
            )
        } catch {
            throw PlayCoverUpstreamError.verificationFailed(
                "pinned reference App signature: \(error)"
            )
        }
    }

    private static func relativePath(
        _ url: URL,
        in root: URL
    ) throws -> String {
        guard
            let canonicalRoot = playCoverCanonicalExistingURL(root)?.path,
            let canonicalURL = playCoverCanonicalExistingURL(url)?.path,
            canonicalURL.hasPrefix(canonicalRoot + "/")
        else {
            throw PlayCoverUpstreamError.verificationFailed(
                "pinned Installer Mach-O escaped its canonical source App: "
                    + url.path
            )
        }
        return String(
            canonicalURL.dropFirst(canonicalRoot.count + 1)
        )
    }
}

public struct PlayCoverDifferentialDifference: Equatable, Sendable {
    public let relativePath: String
    public let field: String
    public let pinnedValue: String?
    public let iosUseValue: String?

    public init(
        relativePath: String,
        field: String,
        pinnedValue: String?,
        iosUseValue: String?
    ) {
        self.relativePath = relativePath
        self.field = field
        self.pinnedValue = pinnedValue
        self.iosUseValue = iosUseValue
    }
}

public enum PlayCoverDifferentialExpectation: Equatable, Sendable {
    case any
    case absent
    case present
    case exact(String)
    case containing(String)
    case lowercaseHexDigest(length: Int)

    fileprivate func matches(_ value: String?) -> Bool {
        switch self {
        case .any:
            return true
        case .absent:
            return value == nil
        case .present:
            return value != nil
        case .exact(let expected):
            return value == expected
        case .containing(let fragment):
            return value?.contains(fragment) == true
        case .lowercaseHexDigest(let length):
            guard let value, value.count == length else {
                return false
            }
            return value.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
        }
    }
}

public struct PlayCoverDifferentialAllowance: Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let field: String
    public let pinnedValue: PlayCoverDifferentialExpectation
    public let iosUseValue: PlayCoverDifferentialExpectation
    public let reason: String
    public let pinnedSymbol: String
    public let iosUseSymbol: String

    public init(
        id: String,
        relativePath: String,
        field: String,
        pinnedValue: PlayCoverDifferentialExpectation,
        iosUseValue: PlayCoverDifferentialExpectation,
        reason: String,
        pinnedSymbol: String,
        iosUseSymbol: String
    ) {
        self.id = id
        self.relativePath = relativePath
        self.field = field
        self.pinnedValue = pinnedValue
        self.iosUseValue = iosUseValue
        self.reason = reason
        self.pinnedSymbol = pinnedSymbol
        self.iosUseSymbol = iosUseSymbol
    }
}

public struct PlayCoverDifferentialNormalization: Sendable {
    fileprivate struct ManagedHomePaths: Sendable {
        let lexical: String
        let canonical: String

        var aliases: [String] {
            Array(Set([lexical, canonical])).sorted()
        }
    }

    fileprivate let pinnedPathReplacements: [String: String]
    fileprivate let iosUsePathReplacements: [String: String]
    fileprivate let pinnedManagedHome: ManagedHomePaths?
    fileprivate let iosUseManagedHome: ManagedHomePaths?
    fileprivate let evidence:
        PlayCoverDifferentialNormalizationEvidence?

    public init() {
        pinnedPathReplacements = [:]
        iosUsePathReplacements = [:]
        pinnedManagedHome = nil
        iosUseManagedHome = nil
        evidence = nil
    }

    public static func hermeticFixture(
        pinnedManagedHome: URL,
        iosUseManagedHome: URL
    ) throws -> Self {
        try managedPaths(
            pinnedManagedHome: pinnedManagedHome,
            iosUseManagedHome: iosUseManagedHome,
            mode: .hermeticFixtureManagedPathsV1
        )
    }

    public static func externalApp(
        pinnedManagedHome: URL,
        iosUseManagedHome: URL
    ) throws -> Self {
        try managedPaths(
            pinnedManagedHome: pinnedManagedHome,
            iosUseManagedHome: iosUseManagedHome,
            mode: .externalAppManagedPathsV1
        )
    }

    private static func managedPaths(
        pinnedManagedHome: URL,
        iosUseManagedHome: URL,
        mode: PlayCoverDifferentialNormalizationMode
    ) throws -> Self {
        let pinnedPaths = try managedHomePaths(
            pinnedManagedHome,
            name: "pinned"
        )
        let iosUsePaths = try managedHomePaths(
            iosUseManagedHome,
            name: "ios-use"
        )
        let rootsOverlap = pinnedPaths.aliases.contains { pinnedPath in
            iosUsePaths.aliases.contains { iosUsePath in
                pathsOverlap(pinnedPath, iosUsePath)
            }
        }
        guard !rootsOverlap else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "pinned and ios-use managed homes must be canonical, "
                    + "non-overlapping directories",
            ])
        }
        let playToolsPath =
            PlayCoverPinnedPrimitiveCharacterization.playToolsLoadPath
        guard playToolsPath.hasPrefix("/"), playToolsPath != "/" else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "pinned PlayTools normalization path is not a safe absolute path",
            ])
        }
        var pinnedReplacements = replacements(for: pinnedPaths)
        pinnedReplacements[playToolsPath] = "<PLAYTOOLS>"
        return Self(
            pinnedPathReplacements: pinnedReplacements,
            iosUsePathReplacements: replacements(for: iosUsePaths),
            pinnedManagedHome: pinnedPaths,
            iosUseManagedHome: iosUsePaths,
            evidence: PlayCoverDifferentialNormalizationEvidence(
                mode: mode,
                pinnedManagedHomeLexicalSHA256:
                    sha256(pinnedPaths.lexical),
                pinnedManagedHomeCanonicalSHA256:
                    sha256(pinnedPaths.canonical),
                iosUseManagedHomeLexicalSHA256:
                    sha256(iosUsePaths.lexical),
                iosUseManagedHomeCanonicalSHA256:
                    sha256(iosUsePaths.canonical),
                pinnedPlayToolsLoadPathSHA256: sha256(playToolsPath),
                managedHomeReplacement: "<MANAGED_HOME>",
                playToolsReplacement: "<PLAYTOOLS>"
            )
        )
    }

    fileprivate init(
        pinnedPathReplacements: [String: String],
        iosUsePathReplacements: [String: String],
        pinnedManagedHome: ManagedHomePaths? = nil,
        iosUseManagedHome: ManagedHomePaths? = nil,
        evidence: PlayCoverDifferentialNormalizationEvidence? = nil
    ) {
        self.pinnedPathReplacements = pinnedPathReplacements
        self.iosUsePathReplacements = iosUsePathReplacements
        self.pinnedManagedHome = pinnedManagedHome
        self.iosUseManagedHome = iosUseManagedHome
        self.evidence = evidence
    }

    private static func managedHomePaths(
        _ url: URL,
        name: String
    ) throws -> ManagedHomePaths {
        guard url.path.hasPrefix("/") else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "\(name) managed home must be absolute",
            ])
        }
        let lexical = url.standardizedFileURL.path
        guard let canonical = playCoverCanonicalExistingURL(url)?.path else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "\(name) managed home cannot be canonicalized",
            ])
        }
        guard lexical != "/", canonical != "/" else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "\(name) managed home cannot be the filesystem root",
            ])
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonical,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "\(name) managed home must be an existing directory",
            ])
        }
        return ManagedHomePaths(
            lexical: lexical,
            canonical: canonical
        )
    }

    private static func replacements(
        for paths: ManagedHomePaths
    ) -> [String: String] {
        return Dictionary(
            uniqueKeysWithValues: paths.aliases.map {
                ($0, "<MANAGED_HOME>")
            }
        )
    }

    fileprivate static func isStrictDescendant(
        _ candidate: String,
        of root: String
    ) -> Bool {
        candidate.hasPrefix(root + "/")
    }

    private static func pathsOverlap(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        lhs == rhs
            || isStrictDescendant(lhs, of: rhs)
            || isStrictDescendant(rhs, of: lhs)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

public enum PlayCoverDifferentialNormalizationMode:
    String, Codable, Equatable, Sendable
{
    case hermeticFixtureManagedPathsV1 =
        "hermetic-fixture-managed-paths-v1"
    case externalAppManagedPathsV1 =
        "external-app-managed-paths-v1"
}

public struct PlayCoverDifferentialNormalizationEvidence:
    Codable, Equatable, Sendable
{
    public let mode: PlayCoverDifferentialNormalizationMode
    public let pinnedManagedHomeLexicalSHA256: String
    public let pinnedManagedHomeCanonicalSHA256: String
    public let iosUseManagedHomeLexicalSHA256: String
    public let iosUseManagedHomeCanonicalSHA256: String
    public let pinnedPlayToolsLoadPathSHA256: String
    public let managedHomeReplacement: String
    public let playToolsReplacement: String
}

public enum PlayCoverDifferentialSide:
    String, Codable, Equatable, Sendable
{
    case pinned
    case iosUse
}

public struct PlayCoverDifferentialObjectBaseline: Sendable {
    public let id: String
    public let side: PlayCoverDifferentialSide
    public let relativePath: String
    public let inspection: PlayCoverUpstreamMachOInspection
    public let sourceSHA256: String
    public let provenance: String

    public init(
        id: String,
        side: PlayCoverDifferentialSide,
        relativePath: String,
        inspection: PlayCoverUpstreamMachOInspection,
        sourceSHA256: String,
        provenance: String
    ) {
        self.id = id
        self.side = side
        self.relativePath = relativePath
        self.inspection = inspection
        self.sourceSHA256 = sourceSHA256
        self.provenance = provenance
    }
}

public enum PlayCoverDifferentialFieldFamily:
    String, Codable, CaseIterable, Equatable, Hashable, Sendable
{
    case container
    case sliceLayout = "slice-layout"
    case immutableContent = "immutable-content"
    case machHeader = "mach-header"
    case platform
    case encryption
    case loadCommands = "load-commands"
    case rpaths
    case dependencies
    case signatureMetadata = "signature-metadata"
    case signatureSuperBlob = "signature-superblob"
    case signatureCodeDirectory = "signature-code-directory"
    case xmlEntitlements = "xml-entitlements"
    case derEntitlements = "der-entitlements"
}

public enum PlayCoverDifferentialAppFieldFamily:
    String, Codable, CaseIterable, Equatable, Hashable, Sendable
{
    case infoPlist = "info-plist"
    case bundleIdentity = "bundle-identity"
    case executableIdentity = "executable-identity"
    case rootSignature = "root-signature"
    case provisioning
    case inventory
}

public enum PlayCoverDifferentialInventoryFieldFamily:
    String, Codable, CaseIterable, Equatable, Hashable, Sendable
{
    case presence
    case kind
    case size
    case permissions
    case content
    case symbolicLinkDestination = "symbolic-link-destination"
    case codeObjectKind = "code-object-kind"
}

public enum PlayCoverDifferentialSliceComparison:
    String, Codable, Equatable, Sendable
{
    case pinnedVersusIOSUse = "pinned-vs-ios-use"
    case pinnedVersusBaseline = "pinned-vs-baseline"
    case iosUseVersusBaseline = "ios-use-vs-baseline"
}

public struct PlayCoverDifferentialObjectCoverage:
    Codable, Equatable, Sendable
{
    public let selector: String
    public let comparison: PlayCoverDifferentialSliceComparison
    public let baselineID: String?

    public init(
        selector: String,
        comparison: PlayCoverDifferentialSliceComparison,
        baselineID: String?
    ) {
        self.selector = selector
        self.comparison = comparison
        self.baselineID = baselineID
    }
}

public struct PlayCoverDifferentialMatchedSliceCoverage:
    Codable, Equatable, Sendable
{
    public let selector: String
    public let comparison: PlayCoverDifferentialSliceComparison
    public let baselineID: String?
    public let checkedFieldFamilies: [PlayCoverDifferentialFieldFamily]

    public init(
        selector: String,
        comparison: PlayCoverDifferentialSliceComparison,
        baselineID: String?,
        checkedFieldFamilies: [PlayCoverDifferentialFieldFamily]
    ) {
        self.selector = selector
        self.comparison = comparison
        self.baselineID = baselineID
        self.checkedFieldFamilies = checkedFieldFamilies
    }
}

public enum PlayCoverDifferentialInventoryComparison:
    String, Codable, Equatable, Sendable
{
    case pinnedVersusIOSUse = "pinned-vs-ios-use"
    case pinnedOnly = "pinned-only"
    case iosUseOnly = "ios-use-only"
}

public struct PlayCoverDifferentialInventoryEntryCoverage:
    Codable, Equatable, Sendable
{
    public let selector: String
    public let comparison: PlayCoverDifferentialInventoryComparison
    public let checkedFieldFamilies:
        [PlayCoverDifferentialInventoryFieldFamily]

    public init(
        selector: String,
        comparison: PlayCoverDifferentialInventoryComparison,
        checkedFieldFamilies:
            [PlayCoverDifferentialInventoryFieldFamily]
    ) {
        self.selector = selector
        self.comparison = comparison
        self.checkedFieldFamilies = checkedFieldFamilies
    }
}

public struct PlayCoverDifferentialAppCoverage:
    Codable, Equatable, Sendable
{
    public let checkedFieldFamilies:
        [PlayCoverDifferentialAppFieldFamily]
    public let pinnedInventorySelectors: [String]
    public let iosUseInventorySelectors: [String]
    public let inventoryEntries:
        [PlayCoverDifferentialInventoryEntryCoverage]

    public init(
        checkedFieldFamilies:
            [PlayCoverDifferentialAppFieldFamily],
        pinnedInventorySelectors: [String],
        iosUseInventorySelectors: [String],
        inventoryEntries:
            [PlayCoverDifferentialInventoryEntryCoverage]
    ) {
        self.checkedFieldFamilies = checkedFieldFamilies
        self.pinnedInventorySelectors = pinnedInventorySelectors
        self.iosUseInventorySelectors = iosUseInventorySelectors
        self.inventoryEntries = inventoryEntries
    }
}

public struct PlayCoverDifferentialSelectorCoverage:
    Codable, Equatable, Sendable
{
    public let pinnedObjectSelectors: [String]
    public let iosUseObjectSelectors: [String]
    public let pinnedSliceSelectors: [String]
    public let iosUseSliceSelectors: [String]
    public let objects: [PlayCoverDifferentialObjectCoverage]
    public let matchedSlices: [PlayCoverDifferentialMatchedSliceCoverage]

    public init(
        pinnedObjectSelectors: [String],
        iosUseObjectSelectors: [String],
        pinnedSliceSelectors: [String],
        iosUseSliceSelectors: [String],
        objects: [PlayCoverDifferentialObjectCoverage],
        matchedSlices: [PlayCoverDifferentialMatchedSliceCoverage]
    ) {
        self.pinnedObjectSelectors = pinnedObjectSelectors
        self.iosUseObjectSelectors = iosUseObjectSelectors
        self.pinnedSliceSelectors = pinnedSliceSelectors
        self.iosUseSliceSelectors = iosUseSliceSelectors
        self.objects = objects
        self.matchedSlices = matchedSlices
    }
}

public enum PlayCoverDifferentialPreparationLineage:
    String, Codable, Equatable, Sendable
{
    case pinnedHeadlessInstallerOracle =
        "pinned-headless-installer-oracle"
    case iosUseServiceAndUpstreamEngine =
        "ios-use-service-and-upstream-engine"
}

public struct PlayCoverDifferentialImplementationEvidence:
    Codable, Equatable, Sendable
{
    public let algorithm: String
    public let relativeSourcePaths: [String]
    public let contentSHA256: String
    public let embeddedSourceClosureSHA256: String
    public let testExecutableSHA256: String
    public let testExecutableSize: UInt64
    public let testExecutableDevice: UInt64
    public let testExecutableInode: UInt64

    fileprivate init(
        algorithm: String,
        relativeSourcePaths: [String],
        contentSHA256: String,
        embeddedSourceClosureSHA256: String,
        testExecutableSHA256: String,
        testExecutableSize: UInt64,
        testExecutableDevice: UInt64,
        testExecutableInode: UInt64
    ) {
        self.algorithm = algorithm
        self.relativeSourcePaths = relativeSourcePaths
        self.contentSHA256 = contentSHA256
        self.embeddedSourceClosureSHA256 = embeddedSourceClosureSHA256
        self.testExecutableSHA256 = testExecutableSHA256
        self.testExecutableSize = testExecutableSize
        self.testExecutableDevice = testExecutableDevice
        self.testExecutableInode = testExecutableInode
    }
}

public enum PlayCoverDifferentialExpectationKind:
    String, Codable, Equatable, Sendable
{
    case any
    case absent
    case present
    case exact
    case containing
    case lowercaseHexDigest = "lowercase-hex-digest"
}

public struct PlayCoverDifferentialExpectationEvidence:
    Codable, Equatable, Sendable
{
    public let kind: PlayCoverDifferentialExpectationKind
    public let value: String?
    public let length: Int?

    fileprivate init(_ expectation: PlayCoverDifferentialExpectation) {
        switch expectation {
        case .any:
            kind = .any
            value = nil
            length = nil
        case .absent:
            kind = .absent
            value = nil
            length = nil
        case .present:
            kind = .present
            value = nil
            length = nil
        case .exact(let exact):
            kind = .exact
            value = exact
            length = nil
        case .containing(let fragment):
            kind = .containing
            value = fragment
            length = nil
        case .lowercaseHexDigest(let digestLength):
            kind = .lowercaseHexDigest
            value = nil
            length = digestLength
        }
    }
}

public struct PlayCoverDifferentialConsumedAllowanceEvidence:
    Codable, Equatable, Sendable
{
    public let id: String
    public let relativePath: String
    public let field: String
    public let pinnedExpectation: PlayCoverDifferentialExpectationEvidence
    public let iosUseExpectation: PlayCoverDifferentialExpectationEvidence
    public let observedPinnedValue: String?
    public let observedIOSUseValue: String?
    public let reason: String
    public let pinnedSymbol: String
    public let iosUseSymbol: String

    fileprivate init(
        allowance: PlayCoverDifferentialAllowance,
        difference: PlayCoverDifferentialDifference
    ) {
        id = allowance.id
        relativePath = allowance.relativePath
        field = allowance.field
        pinnedExpectation = .init(allowance.pinnedValue)
        iosUseExpectation = .init(allowance.iosUseValue)
        observedPinnedValue = difference.pinnedValue
        observedIOSUseValue = difference.iosUseValue
        reason = allowance.reason
        pinnedSymbol = allowance.pinnedSymbol
        iosUseSymbol = allowance.iosUseSymbol
    }
}

public struct PlayCoverDifferentialBaselineEvidence:
    Codable, Equatable, Sendable
{
    public let id: String
    public let side: PlayCoverDifferentialSide
    public let relativePath: String
    public let sourceSHA256: String
    public let provenance: String

    fileprivate init(_ baseline: PlayCoverDifferentialObjectBaseline) {
        id = baseline.id
        side = baseline.side
        relativePath = baseline.relativePath
        sourceSHA256 = baseline.sourceSHA256
        provenance = baseline.provenance
    }
}

public enum PlayCoverDifferentialAttestationScope:
    String, Codable, Equatable, Sendable
{
    case hermeticFixture = "hermetic-fixture"
    case externalApp = "external-app"
}

public struct PlayCoverDifferentialSourceEvidence:
    Codable, Equatable, Sendable
{
    public let inputContentSHA256: String
    public let pinnedHashAfterPrepare: String
    public let iosUseHashAfterPrepare: String
    public let recomputedAtAttestationSHA256: String
    public let unchanged: Bool

    public init(
        inputContentSHA256: String,
        pinnedHashAfterPrepare: String,
        iosUseHashAfterPrepare: String,
        recomputedAtAttestationSHA256: String,
        unchanged: Bool
    ) {
        self.inputContentSHA256 = inputContentSHA256
        self.pinnedHashAfterPrepare = pinnedHashAfterPrepare
        self.iosUseHashAfterPrepare = iosUseHashAfterPrepare
        self.recomputedAtAttestationSHA256 =
            recomputedAtAttestationSHA256
        self.unchanged = unchanged
    }
}

public struct PlayCoverDifferentialOutputEvidence:
    Codable, Equatable, Sendable
{
    public let contentSHA256: String
    public let playCoverRevision: String
    public let preparationLineage:
        PlayCoverDifferentialPreparationLineage
    public let consumedBaselineIDs: [String]

    public init(
        contentSHA256: String,
        playCoverRevision: String,
        preparationLineage: PlayCoverDifferentialPreparationLineage,
        consumedBaselineIDs: [String]
    ) {
        self.contentSHA256 = contentSHA256
        self.playCoverRevision = playCoverRevision
        self.preparationLineage = preparationLineage
        self.consumedBaselineIDs = consumedBaselineIDs
    }
}

public struct PlayCoverDifferentialAttestation:
    Codable, Equatable, Sendable
{
    public let schemaVersion: Int
    public let scope: PlayCoverDifferentialAttestationScope
    public let result: String
    public let implementation:
        PlayCoverDifferentialImplementationEvidence
    public let normalization:
        PlayCoverDifferentialNormalizationEvidence
    public let source: PlayCoverDifferentialSourceEvidence
    public let pinnedOutput: PlayCoverDifferentialOutputEvidence
    public let iosUseOutput: PlayCoverDifferentialOutputEvidence
    public let appCoverage: PlayCoverDifferentialAppCoverage
    public let selectorCoverage: PlayCoverDifferentialSelectorCoverage
    public let consumedAllowances:
        [PlayCoverDifferentialConsumedAllowanceEvidence]
    public let consumedBaselines: [PlayCoverDifferentialBaselineEvidence]
}

public struct PlayCoverDifferentialReport: Sendable {
    public let differences: [PlayCoverDifferentialDifference]
    public let consumedAllowanceIDs: [String]
    public let consumedBaselineIDs: [String]
    public let comparedSliceSelectors: [String]
    public let appCoverage: PlayCoverDifferentialAppCoverage
    public let selectorCoverage: PlayCoverDifferentialSelectorCoverage
    public let consumedAllowances:
        [PlayCoverDifferentialConsumedAllowanceEvidence]
    public let consumedBaselines: [PlayCoverDifferentialBaselineEvidence]

    public init(
        differences: [PlayCoverDifferentialDifference],
        consumedAllowanceIDs: [String],
        consumedBaselineIDs: [String] = [],
        comparedSliceSelectors: [String] = [],
        appCoverage: PlayCoverDifferentialAppCoverage = .init(
            checkedFieldFamilies: [],
            pinnedInventorySelectors: [],
            iosUseInventorySelectors: [],
            inventoryEntries: []
        ),
        selectorCoverage: PlayCoverDifferentialSelectorCoverage = .init(
            pinnedObjectSelectors: [],
            iosUseObjectSelectors: [],
            pinnedSliceSelectors: [],
            iosUseSliceSelectors: [],
            objects: [],
            matchedSlices: []
        ),
        consumedAllowances:
            [PlayCoverDifferentialConsumedAllowanceEvidence] = [],
        consumedBaselines: [PlayCoverDifferentialBaselineEvidence] = []
    ) {
        self.differences = differences
        self.consumedAllowanceIDs = consumedAllowanceIDs
        self.consumedBaselineIDs = consumedBaselineIDs
        self.comparedSliceSelectors = comparedSliceSelectors
        self.appCoverage = appCoverage
        self.selectorCoverage = selectorCoverage
        self.consumedAllowances = consumedAllowances
        self.consumedBaselines = consumedBaselines
    }
}

public enum PlayCoverDifferentialAttestationError:
    Error, Equatable, CustomStringConvertible, Sendable
{
    case invalidIdentity([String])

    public var description: String {
        switch self {
        case .invalidIdentity(let messages):
            return "invalid PlayCover differential attestation identity: "
                + messages.joined(separator: "; ")
        }
    }
}

public enum PlayCoverDifferentialGateError:
    Error, Equatable, CustomStringConvertible, Sendable
{
    case invalidAllowances([String])
    case unallowed([PlayCoverDifferentialDifference])
    case ambiguous(
        difference: PlayCoverDifferentialDifference,
        allowanceIDs: [String]
    )
    case staleAllowances([String])
    case duplicateDifferences([String])
    case invalidBaselines([String])
    case missingBaseline(side: PlayCoverDifferentialSide, path: String)
    case baselineMismatch(
        id: String,
        differences: [PlayCoverDifferentialDifference]
    )
    case staleBaselines([String])

    public var description: String {
        switch self {
        case .invalidAllowances(let messages):
            return "invalid differential allowances: "
                + messages.joined(separator: "; ")
        case .unallowed(let differences):
            return "unallowed PlayCover prepare differences:\n"
                + differences.map(Self.describe).joined(separator: "\n")
        case .ambiguous(let difference, let allowanceIDs):
            return "ambiguous PlayCover prepare difference "
                + Self.describe(difference)
                + " matched allowances \(allowanceIDs.joined(separator: ", "))"
        case .staleAllowances(let identifiers):
            return "stale PlayCover prepare allowances: "
                + identifiers.joined(separator: ", ")
        case .duplicateDifferences(let selectors):
            return "duplicate PlayCover prepare differences: "
                + selectors.joined(separator: ", ")
        case .invalidBaselines(let messages):
            return "invalid PlayCover object baselines: "
                + messages.joined(separator: "; ")
        case let .missingBaseline(side, path):
            return "missing \(side.rawValue) one-sided object baseline: \(path)"
        case let .baselineMismatch(id, differences):
            return "PlayCover object baseline \(id) changed:\n"
                + differences.map(Self.describe).joined(separator: "\n")
        case .staleBaselines(let identifiers):
            return "stale PlayCover object baselines: "
                + identifiers.joined(separator: ", ")
        }
    }

    private static func describe(
        _ difference: PlayCoverDifferentialDifference
    ) -> String {
        "\(difference.relativePath) \(difference.field): pinned="
            + "\(difference.pinnedValue ?? "<absent>") ios-use="
            + "\(difference.iosUseValue ?? "<absent>")"
    }
}

public enum PlayCoverPrepareDifferentialGate {
    static func attest(
        scope: PlayCoverDifferentialAttestationScope = .hermeticFixture,
        repositoryRoot: URL,
        sourceApp: URL,
        pinnedResult: PlayCoverPinnedPrimitivePrepareResult,
        iosUseResult: PlayCoverUpstreamPrepareResult,
        allowances: [PlayCoverDifferentialAllowance],
        oneSidedBaselines: [PlayCoverDifferentialObjectBaseline] = [],
        normalization: PlayCoverDifferentialNormalization = .init()
    ) throws -> PlayCoverDifferentialAttestation {
        guard pinnedResult.producer == .fullPlayToolsInstallerOracle else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "pinned prepare result was not produced by the full "
                    + "PlayTools Installer oracle",
            ])
        }
        let pinned = pinnedResult.prepared
        let iosUse = iosUseResult.prepared
        let report = try enforce(
            pinned: pinned,
            iosUse: iosUse,
            allowances: allowances,
            oneSidedBaselines: oneSidedBaselines,
            normalization: normalization
        )
        let implementation = try implementationEvidence(
            repositoryRoot: repositoryRoot
        )
        var identityErrors: [String] = []
        let sourceInputSHA256 =
            pinnedResult.sourceBefore.sourceContentHash
        let pinnedSourceHashAfterPrepare =
            pinnedResult.sourceHashAfterPrepare
        let iosUseSourceHashAfterPrepare =
            iosUseResult.sourceHashAfterPrepare
        let hashIdentities = [
            ("source input", sourceInputSHA256),
            ("pinned source after prepare", pinnedSourceHashAfterPrepare),
            ("ios-use source after prepare", iosUseSourceHashAfterPrepare),
            ("pinned output", pinned.sourceContentHash),
            ("ios-use output", iosUse.sourceContentHash),
        ]
        for (name, digest) in hashIdentities
            where !isLowercaseSHA256(digest) {
            identityErrors.append("\(name) hash is not lowercase SHA-256")
        }
        if sourceInputSHA256 != pinnedSourceHashAfterPrepare {
            identityErrors.append(
                "pinned prepare did not preserve the source input hash"
            )
        }
        if sourceInputSHA256 != iosUseSourceHashAfterPrepare {
            identityErrors.append(
                "ios-use prepare did not preserve the source input hash"
            )
        }
        if pinnedResult.sourceBefore != iosUseResult.sourceBefore {
            identityErrors.append(
                "pinned and ios-use prepare did not inspect the same source"
            )
        }
        guard let normalizationEvidence = normalization.evidence else {
            identityErrors.append(
                "differential attestation requires constrained normalization"
            )
            throw PlayCoverDifferentialAttestationError.invalidIdentity(
                identityErrors.sorted()
            )
        }
        let normalizationDigests = [
            normalizationEvidence.pinnedManagedHomeLexicalSHA256,
            normalizationEvidence.pinnedManagedHomeCanonicalSHA256,
            normalizationEvidence.iosUseManagedHomeLexicalSHA256,
            normalizationEvidence.iosUseManagedHomeCanonicalSHA256,
            normalizationEvidence.pinnedPlayToolsLoadPathSHA256,
        ]
        let expectedNormalizationMode:
            PlayCoverDifferentialNormalizationMode =
                scope == .hermeticFixture
                    ? .hermeticFixtureManagedPathsV1
                    : .externalAppManagedPathsV1
        if normalizationEvidence.mode != expectedNormalizationMode
            || normalizationEvidence.managedHomeReplacement
                != "<MANAGED_HOME>"
            || normalizationEvidence.playToolsReplacement != "<PLAYTOOLS>"
            || normalizationDigests.contains(where: {
                !isLowercaseSHA256($0)
            }) {
            identityErrors.append(
                "differential normalization evidence is invalid"
            )
        }
        guard
            let pinnedManagedHome = normalization.pinnedManagedHome,
            let iosUseManagedHome = normalization.iosUseManagedHome
        else {
            identityErrors.append(
                "differential normalization has no bound managed homes"
            )
            throw PlayCoverDifferentialAttestationError.invalidIdentity(
                identityErrors.sorted()
            )
        }
        let expectedPinnedObjects = pinned.machOs.map(\.relativePath).sorted()
        let expectedIOSUseObjects = iosUse.machOs
            .map(\.relativePath).sorted()
        let expectedPinnedSlices = sliceSelectors(in: pinned.machOs)
        let expectedIOSUseSlices = sliceSelectors(in: iosUse.machOs)
        let expectedObjects = Array(
            Set(expectedPinnedObjects).union(expectedIOSUseObjects)
        ).sorted()
        let coveredObjects = report.selectorCoverage.objects
            .map(\.selector)
        if coveredObjects != expectedObjects
            || Set(coveredObjects).count != coveredObjects.count {
            identityErrors.append(
                "object selector coverage is incomplete or duplicated"
            )
        }
        if report.selectorCoverage.pinnedObjectSelectors
            != expectedPinnedObjects {
            identityErrors.append(
                "pinned object selector coverage is incomplete"
            )
        }
        if report.selectorCoverage.iosUseObjectSelectors
            != expectedIOSUseObjects {
            identityErrors.append(
                "ios-use object selector coverage is incomplete"
            )
        }
        if report.selectorCoverage.pinnedSliceSelectors
            != expectedPinnedSlices {
            identityErrors.append(
                "pinned slice selector coverage is incomplete"
            )
        }
        if report.selectorCoverage.iosUseSliceSelectors
            != expectedIOSUseSlices {
            identityErrors.append(
                "ios-use slice selector coverage is incomplete"
            )
        }
        let matchedSelectors = report.selectorCoverage.matchedSlices
            .map(\.selector)
        if matchedSelectors != report.comparedSliceSelectors {
            identityErrors.append(
                "matched slice coverage does not match analyzer selectors"
            )
        }
        let expectedSlices = Array(
            Set(expectedPinnedSlices).union(expectedIOSUseSlices)
        ).sorted()
        if matchedSelectors != expectedSlices
            || Set(matchedSelectors).count != matchedSelectors.count {
            identityErrors.append(
                "slice selectors are not each covered exactly once"
            )
        }
        for matched in report.selectorCoverage.matchedSlices
            where matched.checkedFieldFamilies
                != PlayCoverDifferentialFieldFamily.allCases {
            identityErrors.append(
                "matched slice \(matched.selector) has incomplete field "
                    + "family coverage"
            )
        }
        if report.appCoverage.checkedFieldFamilies
            != PlayCoverDifferentialAppFieldFamily.allCases {
            identityErrors.append("app field family coverage is incomplete")
        }
        let expectedPinnedInventory = pinned.inventory
            .map(\.relativePath).sorted()
        let expectedIOSUseInventory = iosUse.inventory
            .map(\.relativePath).sorted()
        if report.appCoverage.pinnedInventorySelectors
            != expectedPinnedInventory {
            identityErrors.append(
                "pinned inventory selector coverage is incomplete"
            )
        }
        if report.appCoverage.iosUseInventorySelectors
            != expectedIOSUseInventory {
            identityErrors.append(
                "ios-use inventory selector coverage is incomplete"
            )
        }
        let expectedInventory = Array(
            Set(expectedPinnedInventory).union(expectedIOSUseInventory)
        ).sorted()
        let coveredInventory = report.appCoverage.inventoryEntries
            .map(\.selector)
        if coveredInventory != expectedInventory
            || Set(coveredInventory).count != coveredInventory.count {
            identityErrors.append(
                "inventory selectors are not each covered exactly once"
            )
        }
        for entry in report.appCoverage.inventoryEntries
            where entry.checkedFieldFamilies
                != PlayCoverDifferentialInventoryFieldFamily.allCases {
            identityErrors.append(
                "inventory entry \(entry.selector) has incomplete field "
                    + "family coverage"
            )
        }
        for (name, inspection) in [
            ("pinned", pinned),
            ("ios-use", iosUse),
        ] {
            let appPath = URL(fileURLWithPath: inspection.appPath)
                .standardizedFileURL.path
            let executablePath = URL(
                fileURLWithPath: inspection.executablePath
            ).standardizedFileURL.path
            let expectedExecutable = URL(fileURLWithPath: appPath)
                .appendingPathComponent(
                    inspection.mainExecutableRelativePath
                ).standardizedFileURL.path
            if executablePath != expectedExecutable
                || inspection.executableName
                    != URL(fileURLWithPath: executablePath)
                        .lastPathComponent {
                identityErrors.append(
                    "\(name) executable identity is internally inconsistent"
                )
            }
        }
        let sourceURL = sourceApp.standardizedFileURL
        let pinnedAppURL = URL(
            fileURLWithPath: pinned.appPath,
            isDirectory: true
        ).standardizedFileURL
        let iosUseAppURL = URL(
            fileURLWithPath: iosUse.appPath,
            isDirectory: true
        ).standardizedFileURL
        if !pathsIdentifySameItem(
            sourceURL.path,
            pinnedResult.sourceBefore.appPath
        ) || !pathsIdentifySameItem(
            sourceURL.path,
            iosUseResult.sourceBefore.appPath
        ) {
            identityErrors.append(
                "prepare results are not bound to the supplied source App"
            )
        }
        if !isBoundApp(
            pinnedAppURL,
            to: pinnedManagedHome
        ) {
            identityErrors.append(
                "pinned prepared App is outside its managed home"
            )
        }
        if !isBoundApp(
            iosUseAppURL,
            to: iosUseManagedHome
        ) {
            identityErrors.append(
                "ios-use prepared App is outside its managed home"
            )
        }
        if identityErrors.isEmpty {
            do {
                let currentSource = try PlayCoverUpstreamEngine.inspect(
                    appURL: sourceURL
                )
                let currentPinned = try PlayCoverUpstreamEngine.inspect(
                    appURL: pinnedAppURL
                )
                let currentIOSUse = try PlayCoverUpstreamEngine.inspect(
                    appURL: iosUseAppURL
                )
                if currentSource != pinnedResult.sourceBefore {
                    identityErrors.append(
                        "source App changed after the recorded input inspection"
                    )
                }
                if currentPinned != pinnedResult.prepared {
                    identityErrors.append(
                        "pinned prepared App changed after prepare"
                    )
                }
                if currentIOSUse != iosUseResult.prepared {
                    identityErrors.append(
                        "ios-use prepared App changed after prepare"
                    )
                }
            } catch {
                identityErrors.append(
                    "could not re-inspect attested source/output Apps: \(error)"
                )
            }
        }
        guard identityErrors.isEmpty else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity(
                identityErrors.sorted()
            )
        }
        let finalImplementation = try implementationEvidence(
            repositoryRoot: repositoryRoot
        )
        guard finalImplementation == implementation else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "implementation source closure or loaded XCTest image changed "
                    + "during attestation",
            ])
        }
        let pinnedBaselineIDs = report.consumedBaselines.filter {
            $0.side == .pinned
        }.map(\.id).sorted()
        let iosUseBaselineIDs = report.consumedBaselines.filter {
            $0.side == .iosUse
        }.map(\.id).sorted()
        return PlayCoverDifferentialAttestation(
            schemaVersion: 1,
            scope: scope,
            result: "pass",
            implementation: implementation,
            normalization: normalizationEvidence,
            source: PlayCoverDifferentialSourceEvidence(
                inputContentSHA256: sourceInputSHA256,
                pinnedHashAfterPrepare: pinnedSourceHashAfterPrepare,
                iosUseHashAfterPrepare: iosUseSourceHashAfterPrepare,
                recomputedAtAttestationSHA256: sourceInputSHA256,
                unchanged: true
            ),
            pinnedOutput: PlayCoverDifferentialOutputEvidence(
                contentSHA256: pinned.sourceContentHash,
                playCoverRevision:
                    PlayCoverPinnedHeadlessInstallerOracle
                        .playCoverRevision,
                preparationLineage: .pinnedHeadlessInstallerOracle,
                consumedBaselineIDs: pinnedBaselineIDs
            ),
            iosUseOutput: PlayCoverDifferentialOutputEvidence(
                contentSHA256: iosUse.sourceContentHash,
                playCoverRevision:
                    PlayCoverUpstreamEngine.playCoverRevision,
                preparationLineage: .iosUseServiceAndUpstreamEngine,
                consumedBaselineIDs: iosUseBaselineIDs
            ),
            appCoverage: report.appCoverage,
            selectorCoverage: report.selectorCoverage,
            consumedAllowances: report.consumedAllowances,
            consumedBaselines: report.consumedBaselines
        )
    }

    public static func differences(
        pinned: PlayCoverUpstreamAppInspection,
        iosUse: PlayCoverUpstreamAppInspection,
        oneSidedBaselines: [PlayCoverDifferentialObjectBaseline] = [],
        normalization: PlayCoverDifferentialNormalization = .init()
    ) throws -> [PlayCoverDifferentialDifference] {
        try analyze(
            pinned: pinned,
            iosUse: iosUse,
            oneSidedBaselines: oneSidedBaselines,
            normalization: normalization
        ).differences
    }

    @discardableResult
    public static func enforce(
        pinned: PlayCoverUpstreamAppInspection,
        iosUse: PlayCoverUpstreamAppInspection,
        allowances: [PlayCoverDifferentialAllowance],
        oneSidedBaselines: [PlayCoverDifferentialObjectBaseline] = [],
        normalization: PlayCoverDifferentialNormalization = .init()
    ) throws -> PlayCoverDifferentialReport {
        let allowanceErrors = validateAllowances(allowances)
        guard allowanceErrors.isEmpty else {
            throw PlayCoverDifferentialGateError.invalidAllowances(
                allowanceErrors
            )
        }
        let analysis = try analyze(
            pinned: pinned,
            iosUse: iosUse,
            oneSidedBaselines: oneSidedBaselines,
            normalization: normalization
        )
        let actual = analysis.differences
        let actualSelectors = actual.map {
            "\($0.relativePath)\u{0}\($0.field)"
        }
        let duplicateSelectors = Dictionary(
            grouping: actualSelectors,
            by: { $0 }
        ).filter {
            $0.value.count > 1
        }.keys.map {
            $0.replacingOccurrences(of: "\u{0}", with: " ")
        }.sorted()
        guard duplicateSelectors.isEmpty else {
            throw PlayCoverDifferentialGateError.duplicateDifferences(
                duplicateSelectors
            )
        }
        var consumed: Set<String> = []
        var consumedAllowances:
            [PlayCoverDifferentialConsumedAllowanceEvidence] = []
        var unallowed: [PlayCoverDifferentialDifference] = []
        for difference in actual {
            let matches = allowances.filter {
                $0.relativePath == difference.relativePath
                    && $0.field == difference.field
                    && $0.pinnedValue.matches(difference.pinnedValue)
                    && $0.iosUseValue.matches(difference.iosUseValue)
            }
            if matches.isEmpty {
                unallowed.append(difference)
            } else if matches.count > 1 {
                throw PlayCoverDifferentialGateError.ambiguous(
                    difference: difference,
                    allowanceIDs: matches.map(\.id).sorted()
                )
            } else {
                let allowance = matches[0]
                consumed.insert(allowance.id)
                consumedAllowances.append(
                    PlayCoverDifferentialConsumedAllowanceEvidence(
                        allowance: allowance,
                        difference: difference
                    )
                )
            }
        }
        guard unallowed.isEmpty else {
            throw PlayCoverDifferentialGateError.unallowed(unallowed)
        }
        let stale = allowances.map(\.id).filter {
            !consumed.contains($0)
        }.sorted()
        guard stale.isEmpty else {
            throw PlayCoverDifferentialGateError.staleAllowances(stale)
        }
        guard consumedAllowances.count == actual.count,
              consumed.count == allowances.count else {
            throw PlayCoverDifferentialGateError.invalidAllowances([
                "allowance consumption is not a one-to-one mapping",
            ])
        }
        let consumedBaselines = oneSidedBaselines.filter {
            analysis.consumedBaselineIDs.contains($0.id)
        }.map(PlayCoverDifferentialBaselineEvidence.init).sorted {
            $0.id < $1.id
        }
        return PlayCoverDifferentialReport(
            differences: actual,
            consumedAllowanceIDs: consumed.sorted(),
            consumedBaselineIDs: analysis.consumedBaselineIDs.sorted(),
            comparedSliceSelectors: analysis.comparedSliceSelectors.sorted(),
            appCoverage: analysis.appCoverage,
            selectorCoverage: PlayCoverDifferentialSelectorCoverage(
                pinnedObjectSelectors:
                    analysis.pinnedObjectSelectors,
                iosUseObjectSelectors:
                    analysis.iosUseObjectSelectors,
                pinnedSliceSelectors:
                    analysis.pinnedSliceSelectors,
                iosUseSliceSelectors:
                    analysis.iosUseSliceSelectors,
                objects: analysis.objectCoverage,
                matchedSlices: analysis.matchedSliceCoverage
            ),
            consumedAllowances: consumedAllowances.sorted {
                $0.id < $1.id
            },
            consumedBaselines: consumedBaselines
        )
    }

    private struct Analysis {
        let differences: [PlayCoverDifferentialDifference]
        let consumedBaselineIDs: Set<String>
        let comparedSliceSelectors: Set<String>
        let pinnedObjectSelectors: [String]
        let iosUseObjectSelectors: [String]
        let pinnedSliceSelectors: [String]
        let iosUseSliceSelectors: [String]
        let appCoverage: PlayCoverDifferentialAppCoverage
        let objectCoverage: [PlayCoverDifferentialObjectCoverage]
        let matchedSliceCoverage:
            [PlayCoverDifferentialMatchedSliceCoverage]
    }

    private static func analyze(
        pinned: PlayCoverUpstreamAppInspection,
        iosUse: PlayCoverUpstreamAppInspection,
        oneSidedBaselines: [PlayCoverDifferentialObjectBaseline],
        normalization: PlayCoverDifferentialNormalization
    ) throws -> Analysis {
        let baselineErrors = validateBaselines(oneSidedBaselines)
        guard baselineErrors.isEmpty else {
            throw PlayCoverDifferentialGateError.invalidBaselines(
                baselineErrors
            )
        }
        let baselineBySelector = Dictionary(
            uniqueKeysWithValues: oneSidedBaselines.map {
                (baselineSelector($0.side, $0.relativePath), $0)
            }
        )
        let pinnedByPath = Dictionary(
            uniqueKeysWithValues: pinned.machOs.map {
                ($0.relativePath, $0)
            }
        )
        let iosUseByPath = Dictionary(
            uniqueKeysWithValues: iosUse.machOs.map {
                ($0.relativePath, $0)
            }
        )
        let paths = Set(pinnedByPath.keys)
            .union(iosUseByPath.keys)
            .sorted()
        var result: [PlayCoverDifferentialDifference] = []
        let appCoverage = compareApp(
            pinned,
            iosUse,
            normalization: normalization,
            result: &result
        )
        var consumedBaselines: Set<String> = []
        var comparedSlices: Set<String> = []
        var objectCoverage: [PlayCoverDifferentialObjectCoverage] = []
        var matchedSliceCoverage:
            [String: PlayCoverDifferentialMatchedSliceCoverage] = [:]

        for path in paths {
            guard let pinnedMachO = pinnedByPath[path] else {
                let baseline = try requiredBaseline(
                    side: .iosUse,
                    path: path,
                    baselines: baselineBySelector
                )
                try verifyBaseline(
                    baseline,
                    actual: iosUseByPath[path]!,
                    replacements:
                        normalization.iosUsePathReplacements,
                    comparedSlices: &comparedSlices,
                    matchedSliceCoverage: &matchedSliceCoverage
                )
                consumedBaselines.insert(baseline.id)
                objectCoverage.append(
                    PlayCoverDifferentialObjectCoverage(
                        selector: path,
                        comparison: .iosUseVersusBaseline,
                        baselineID: baseline.id
                    )
                )
                appendDifference(
                    &result,
                    path: path,
                    field: "object.presence",
                    pinned: nil,
                    iosUse: presenceValue(
                        iosUseByPath[path]!,
                        baselineID: baseline.id
                    )
                )
                continue
            }
            guard let iosUseMachO = iosUseByPath[path] else {
                let baseline = try requiredBaseline(
                    side: .pinned,
                    path: path,
                    baselines: baselineBySelector
                )
                try verifyBaseline(
                    baseline,
                    actual: pinnedMachO,
                    replacements:
                        normalization.pinnedPathReplacements,
                    comparedSlices: &comparedSlices,
                    matchedSliceCoverage: &matchedSliceCoverage
                )
                consumedBaselines.insert(baseline.id)
                objectCoverage.append(
                    PlayCoverDifferentialObjectCoverage(
                        selector: path,
                        comparison: .pinnedVersusBaseline,
                        baselineID: baseline.id
                    )
                )
                appendDifference(
                    &result,
                    path: path,
                    field: "object.presence",
                    pinned: presenceValue(
                        pinnedMachO,
                        baselineID: baseline.id
                    ),
                    iosUse: nil
                )
                continue
            }
            objectCoverage.append(
                PlayCoverDifferentialObjectCoverage(
                    selector: path,
                    comparison: .pinnedVersusIOSUse,
                    baselineID: nil
                )
            )
            compareMachO(
                pinnedMachO,
                iosUseMachO,
                path: path,
                normalization: normalization,
                fieldPrefix: "",
                comparison: .pinnedVersusIOSUse,
                baselineID: nil,
                comparedSlices: &comparedSlices,
                matchedSliceCoverage: &matchedSliceCoverage,
                result: &result
            )
        }
        let staleBaselines = oneSidedBaselines.map(\.id).filter {
            !consumedBaselines.contains($0)
        }.sorted()
        guard staleBaselines.isEmpty else {
            throw PlayCoverDifferentialGateError.staleBaselines(
                staleBaselines
            )
        }
        return Analysis(
            differences: result,
            consumedBaselineIDs: consumedBaselines,
            comparedSliceSelectors: comparedSlices,
            pinnedObjectSelectors: pinned.machOs
                .map(\.relativePath).sorted(),
            iosUseObjectSelectors: iosUse.machOs
                .map(\.relativePath).sorted(),
            pinnedSliceSelectors: sliceSelectors(in: pinned.machOs),
            iosUseSliceSelectors: sliceSelectors(in: iosUse.machOs),
            appCoverage: appCoverage,
            objectCoverage: objectCoverage.sorted {
                $0.selector < $1.selector
            },
            matchedSliceCoverage: matchedSliceCoverage.values.sorted {
                $0.selector < $1.selector
            }
        )
    }

    private static func compareApp(
        _ pinned: PlayCoverUpstreamAppInspection,
        _ iosUse: PlayCoverUpstreamAppInspection,
        normalization: PlayCoverDifferentialNormalization,
        result: inout [PlayCoverDifferentialDifference]
    ) -> PlayCoverDifferentialAppCoverage {
        compare(
            &result,
            ".",
            "app.infoPlistSHA256",
            pinned.infoPlistSHA256,
            iosUse.infoPlistSHA256
        )
        compare(
            &result,
            ".",
            "app.bundleIdentifier",
            pinned.bundleIdentifier,
            iosUse.bundleIdentifier
        )
        compare(
            &result,
            ".",
            "app.executableName",
            pinned.executableName,
            iosUse.executableName
        )
        compare(
            &result,
            ".",
            "app.mainExecutableRelativePath",
            pinned.mainExecutableRelativePath,
            iosUse.mainExecutableRelativePath
        )
        var signatureCoverage: Set<PlayCoverDifferentialFieldFamily> = []
        compareSignature(
            pinned.signature,
            iosUse.signature,
            path: ".",
            fieldPrefix: "app.signature.",
            pinnedReplacements:
                normalization.pinnedPathReplacements,
            iosUseReplacements:
                normalization.iosUsePathReplacements,
            checkedFieldFamilies: &signatureCoverage,
            result: &result
        )
        compare(
            &result,
            ".",
            "app.provisioning.present",
            String(pinned.provisioning.present),
            String(iosUse.provisioning.present)
        )
        compareOptional(
            &result,
            ".",
            "app.provisioning.size",
            pinned.provisioning.size.map(String.init),
            iosUse.provisioning.size.map(String.init)
        )
        compareOptional(
            &result,
            ".",
            "app.provisioning.sha256",
            pinned.provisioning.sha256,
            iosUse.provisioning.sha256
        )

        let pinnedByPath = Dictionary(
            uniqueKeysWithValues: pinned.inventory.map {
                ($0.relativePath, $0)
            }
        )
        let iosUseByPath = Dictionary(
            uniqueKeysWithValues: iosUse.inventory.map {
                ($0.relativePath, $0)
            }
        )
        let pinnedMachOs = Set(pinned.machOs.map(\.relativePath))
        let iosUseMachOs = Set(iosUse.machOs.map(\.relativePath))
        let selectors = Set(pinnedByPath.keys)
            .union(iosUseByPath.keys)
            .sorted()
        var inventoryCoverage:
            [PlayCoverDifferentialInventoryEntryCoverage] = []
        for selector in selectors {
            let pinnedEntry = pinnedByPath[selector]
            let iosUseEntry = iosUseByPath[selector]
            let comparison: PlayCoverDifferentialInventoryComparison
            if let pinnedEntry, let iosUseEntry {
                comparison = .pinnedVersusIOSUse
                compare(
                    &result,
                    selector,
                    "inventory.kind",
                    pinnedEntry.kind.rawValue,
                    iosUseEntry.kind.rawValue
                )
                compareOptional(
                    &result,
                    selector,
                    "inventory.size",
                    pinnedEntry.size.map(String.init),
                    iosUseEntry.size.map(String.init)
                )
                compareOptional(
                    &result,
                    selector,
                    "inventory.permissions",
                    pinnedEntry.posixPermissions.map(String.init),
                    iosUseEntry.posixPermissions.map(String.init)
                )
                compareOptional(
                    &result,
                    selector,
                    "inventory.sha256",
                    inventoryContentIdentity(
                        pinnedEntry,
                        machOPaths: pinnedMachOs
                    ),
                    inventoryContentIdentity(
                        iosUseEntry,
                        machOPaths: iosUseMachOs
                    )
                )
                compareOptional(
                    &result,
                    selector,
                    "inventory.symbolicLinkDestination",
                    pinnedEntry.symbolicLinkDestination.map {
                        replacePaths(
                            $0,
                            replacements:
                                normalization.pinnedPathReplacements
                        )
                    },
                    iosUseEntry.symbolicLinkDestination.map {
                        replacePaths(
                            $0,
                            replacements:
                                normalization.iosUsePathReplacements
                        )
                    }
                )
                compareOptional(
                    &result,
                    selector,
                    "inventory.codeObjectKind",
                    pinnedEntry.codeObjectKind,
                    iosUseEntry.codeObjectKind
                )
            } else if let pinnedEntry {
                comparison = .pinnedOnly
                appendDifference(
                    &result,
                    path: selector,
                    field: "inventory.presence",
                    pinned: inventoryPresenceEvidence(
                        pinnedEntry,
                        machOPaths: pinnedMachOs,
                        replacements:
                            normalization.pinnedPathReplacements
                    ),
                    iosUse: nil
                )
            } else {
                comparison = .iosUseOnly
                let iosUseEntry = iosUseEntry!
                appendDifference(
                    &result,
                    path: selector,
                    field: "inventory.presence",
                    pinned: nil,
                    iosUse: inventoryPresenceEvidence(
                        iosUseEntry,
                        machOPaths: iosUseMachOs,
                        replacements:
                            normalization.iosUsePathReplacements
                    )
                )
            }
            inventoryCoverage.append(
                PlayCoverDifferentialInventoryEntryCoverage(
                    selector: selector,
                    comparison: comparison,
                    checkedFieldFamilies:
                        PlayCoverDifferentialInventoryFieldFamily.allCases
                )
            )
        }
        return PlayCoverDifferentialAppCoverage(
            checkedFieldFamilies:
                PlayCoverDifferentialAppFieldFamily.allCases,
            pinnedInventorySelectors:
                pinned.inventory.map(\.relativePath).sorted(),
            iosUseInventorySelectors:
                iosUse.inventory.map(\.relativePath).sorted(),
            inventoryEntries: inventoryCoverage
        )
    }

    private static func inventoryContentIdentity(
        _ entry: PlayCoverUpstreamInventoryEntry,
        machOPaths: Set<String>
    ) -> String? {
        guard entry.sha256 != nil else {
            return nil
        }
        if machOPaths.contains(entry.relativePath) {
            return "<MACHO-COMPARATOR>"
        }
        if entry.relativePath == "Info.plist" {
            return "<APP-INFO-COMPARATOR>"
        }
        if entry.relativePath == "_CodeSignature/CodeResources"
            || entry.relativePath.hasSuffix(
                "/_CodeSignature/CodeResources"
            ) {
            return "<SIGNATURE-COMPARATOR>"
        }
        return entry.sha256
    }

    private static func inventoryPresenceEvidence(
        _ entry: PlayCoverUpstreamInventoryEntry,
        machOPaths: Set<String>,
        replacements: [String: String]
    ) -> String {
        canonicalStrings(
            [
                "present",
                entry.kind.rawValue,
                entry.size.map(String.init) ?? "<absent>",
                entry.posixPermissions.map(String.init) ?? "<absent>",
                inventoryContentIdentity(
                    entry,
                    machOPaths: machOPaths
                ) ?? "<absent>",
                entry.symbolicLinkDestination.map {
                    replacePaths($0, replacements: replacements)
                } ?? "<absent>",
                entry.codeObjectKind ?? "<absent>",
            ],
            replacements: [:]
        )
    }

    private static func requiredBaseline(
        side: PlayCoverDifferentialSide,
        path: String,
        baselines: [String: PlayCoverDifferentialObjectBaseline]
    ) throws -> PlayCoverDifferentialObjectBaseline {
        guard let baseline = baselines[baselineSelector(side, path)] else {
            throw PlayCoverDifferentialGateError.missingBaseline(
                side: side,
                path: path
            )
        }
        return baseline
    }

    private static func verifyBaseline(
        _ baseline: PlayCoverDifferentialObjectBaseline,
        actual: PlayCoverUpstreamMachOInspection,
        replacements: [String: String],
        comparedSlices: inout Set<String>,
        matchedSliceCoverage:
            inout [String: PlayCoverDifferentialMatchedSliceCoverage]
    ) throws {
        let comparison: PlayCoverDifferentialSliceComparison =
            baseline.side == .pinned
                ? .pinnedVersusBaseline
                : .iosUseVersusBaseline
        guard baseline.inspection == actual else {
            var detailed: [PlayCoverDifferentialDifference] = []
            compareMachO(
                baseline.inspection,
                actual,
                path: actual.relativePath,
                normalization: PlayCoverDifferentialNormalization(
                    pinnedPathReplacements: replacements,
                    iosUsePathReplacements: replacements
                ),
                fieldPrefix: "baseline.\(baseline.id).",
                comparison: comparison,
                baselineID: baseline.id,
                comparedSlices: &comparedSlices,
                matchedSliceCoverage: &matchedSliceCoverage,
                result: &detailed
            )
            if detailed.isEmpty {
                detailed.append(
                    PlayCoverDifferentialDifference(
                        relativePath: actual.relativePath,
                        field: "baseline.\(baseline.id).rawInspection",
                        pinnedValue: baseline.inspection.fileSHA256,
                        iosUseValue: actual.fileSHA256
                    )
                )
            }
            throw PlayCoverDifferentialGateError.baselineMismatch(
                id: baseline.id,
                differences: detailed
            )
        }
        var mismatches: [PlayCoverDifferentialDifference] = []
        compareMachO(
            baseline.inspection,
            actual,
            path: actual.relativePath,
            normalization: PlayCoverDifferentialNormalization(
                pinnedPathReplacements: replacements,
                iosUsePathReplacements: replacements
            ),
            fieldPrefix: "baseline.\(baseline.id).",
            comparison: comparison,
            baselineID: baseline.id,
            comparedSlices: &comparedSlices,
            matchedSliceCoverage: &matchedSliceCoverage,
            result: &mismatches
        )
        guard mismatches.isEmpty else {
            throw PlayCoverDifferentialGateError.baselineMismatch(
                id: baseline.id,
                differences: mismatches
            )
        }
    }

    private static func presenceValue(
        _ inspection: PlayCoverUpstreamMachOInspection,
        baselineID: String
    ) -> String {
        "present;baseline=\(baselineID);fileSHA256=\(inspection.fileSHA256)"
    }

    private static func baselineSelector(
        _ side: PlayCoverDifferentialSide,
        _ path: String
    ) -> String {
        side.rawValue + "\u{0}" + path
    }

    private static func indexedSlices(
        _ slices: [PlayCoverUpstreamMachOSliceInspection]
    ) -> [String: PlayCoverUpstreamMachOSliceInspection] {
        var occurrences: [String: Int] = [:]
        var result: [String: PlayCoverUpstreamMachOSliceInspection] = [:]
        for slice in slices {
            let architecture = "cpu=\(slice.cpuType),"
                + "subtype=\(slice.cpuSubtype)"
            let occurrence = occurrences[architecture, default: 0]
            occurrences[architecture] = occurrence + 1
            result[architecture + ",occurrence=\(occurrence)"] = slice
        }
        return result
    }

    private static func sliceSelectors(
        in machOs: [PlayCoverUpstreamMachOInspection]
    ) -> [String] {
        machOs.flatMap { machO in
            indexedSlices(machO.allSlices).keys.map {
                "\(machO.relativePath)#\($0)"
            }
        }.sorted()
    }

    private static func compareMachO(
        _ pinned: PlayCoverUpstreamMachOInspection,
        _ iosUse: PlayCoverUpstreamMachOInspection,
        path: String,
        normalization: PlayCoverDifferentialNormalization,
        fieldPrefix: String,
        comparison: PlayCoverDifferentialSliceComparison,
        baselineID: String?,
        comparedSlices: inout Set<String>,
        matchedSliceCoverage:
            inout [String: PlayCoverDifferentialMatchedSliceCoverage],
        result: inout [PlayCoverDifferentialDifference]
    ) {
        compare(
            &result, path, fieldPrefix + "container",
            pinned.container.rawValue, iosUse.container.rawValue
        )
        compareOptional(
            &result, path, fieldPrefix + "fatHeader.bigEndian",
            pinned.fatHeaderBigEndian.map(String.init),
            iosUse.fatHeaderBigEndian.map(String.init)
        )
        let pinnedSlices = indexedSlices(pinned.allSlices)
        let iosUseSlices = indexedSlices(iosUse.allSlices)
        let selectors = Set(pinnedSlices.keys)
            .union(iosUseSlices.keys)
            .sorted()
        for selector in selectors {
            let prefix = fieldPrefix + "slices[\(selector)]."
            guard let pinnedSlice = pinnedSlices[selector] else {
                appendDifference(
                    &result,
                    path: path,
                    field: prefix + "presence",
                    pinned: nil,
                    iosUse: "present"
                )
                continue
            }
            guard let iosUseSlice = iosUseSlices[selector] else {
                appendDifference(
                    &result,
                    path: path,
                    field: prefix + "presence",
                    pinned: "present",
                    iosUse: nil
                )
                continue
            }
            let qualifiedSelector = "\(path)#\(selector)"
            comparedSlices.insert(qualifiedSelector)
            var checkedFieldFamilies:
                Set<PlayCoverDifferentialFieldFamily> = [.container]
            compareSlice(
                pinnedSlice,
                iosUseSlice,
                path: path,
                fieldPrefix: prefix,
                pinnedReplacements:
                    normalization.pinnedPathReplacements,
                iosUseReplacements:
                    normalization.iosUsePathReplacements,
                checkedFieldFamilies: &checkedFieldFamilies,
                result: &result
            )
            matchedSliceCoverage[qualifiedSelector] =
                PlayCoverDifferentialMatchedSliceCoverage(
                    selector: qualifiedSelector,
                    comparison: comparison,
                    baselineID: baselineID,
                    checkedFieldFamilies:
                        PlayCoverDifferentialFieldFamily.allCases.filter {
                            checkedFieldFamilies.contains($0)
                        }
                )
        }
    }

    private static func compareSlice(
        _ pinned: PlayCoverUpstreamMachOSliceInspection,
        _ iosUse: PlayCoverUpstreamMachOSliceInspection,
        path: String,
        fieldPrefix: String,
        pinnedReplacements: [String: String],
        iosUseReplacements: [String: String],
        checkedFieldFamilies:
            inout Set<PlayCoverDifferentialFieldFamily>,
        result: inout [PlayCoverDifferentialDifference]
    ) {
        compare(
            &result, path, fieldPrefix + "fatIndex",
            String(pinned.fatIndex), String(iosUse.fatIndex)
        )
        compare(
            &result, path, fieldPrefix + "offset",
            String(pinned.offset), String(iosUse.offset)
        )
        compare(
            &result, path, fieldPrefix + "size",
            String(pinned.size), String(iosUse.size)
        )
        compareOptional(
            &result, path, fieldPrefix + "alignment",
            pinned.alignment.map(String.init),
            iosUse.alignment.map(String.init)
        )
        checkedFieldFamilies.insert(.sliceLayout)
        compareOptional(
            &result, path, fieldPrefix + "immutableContentSHA256",
            pinned.immutableContentSHA256,
            iosUse.immutableContentSHA256
        )
        checkedFieldFamilies.insert(.immutableContent)
        compare(
            &result, path, fieldPrefix + "byteSwapped",
            String(pinned.byteSwapped), String(iosUse.byteSwapped)
        )
        compare(
            &result, path, fieldPrefix + "cpuType",
            String(pinned.cpuType), String(iosUse.cpuType)
        )
        compare(
            &result, path, fieldPrefix + "cpuSubtype",
            String(pinned.cpuSubtype), String(iosUse.cpuSubtype)
        )
        compare(
            &result, path, fieldPrefix + "fileType",
            String(pinned.fileType), String(iosUse.fileType)
        )
        compareOptional(
            &result, path, fieldPrefix + "header.flags",
            pinned.headerFlags.map(String.init),
            iosUse.headerFlags.map(String.init)
        )
        compareOptional(
            &result, path, fieldPrefix + "header.reserved",
            pinned.headerReserved.map(String.init),
            iosUse.headerReserved.map(String.init)
        )
        compareOptional(
            &result, path, fieldPrefix + "platform",
            pinned.platform.map(String.init),
            iosUse.platform.map(String.init)
        )
        compareOptional(
            &result, path, fieldPrefix + "platform.minimumOS",
            pinned.minimumOS.map(String.init),
            iosUse.minimumOS.map(String.init)
        )
        compareOptional(
            &result, path, fieldPrefix + "platform.sdk",
            pinned.sdk.map(String.init),
            iosUse.sdk.map(String.init)
        )
        checkedFieldFamilies.insert(.platform)
        compareOptional(
            &result, path, fieldPrefix + "firstSectionOffset",
            pinned.firstSectionOffset.map(String.init),
            iosUse.firstSectionOffset.map(String.init)
        )
        checkedFieldFamilies.insert(.machHeader)
        compare(
            &result, path, fieldPrefix + "encrypted",
            String(pinned.encrypted), String(iosUse.encrypted)
        )
        checkedFieldFamilies.insert(.encryption)
        compare(
            &result, path, fieldPrefix + "loadCommands.count",
            String(pinned.commandCount), String(iosUse.commandCount)
        )
        compare(
            &result, path, fieldPrefix + "loadCommands.bytes",
            String(pinned.commandBytes), String(iosUse.commandBytes)
        )
        let commandCount = max(
            pinned.loadCommands.count,
            iosUse.loadCommands.count
        )
        for index in 0..<commandCount {
            let pinnedValue = pinned.loadCommands[safe: index].map {
                canonicalLoadCommand(
                    $0,
                    replacements: pinnedReplacements
                )
            }
            let iosUseValue = iosUse.loadCommands[safe: index].map {
                canonicalLoadCommand(
                    $0,
                    replacements: iosUseReplacements
                )
            }
            compareOptional(
                &result,
                path,
                fieldPrefix + "loadCommands[\(index)]",
                pinnedValue,
                iosUseValue
            )
        }
        checkedFieldFamilies.insert(.loadCommands)
        compare(
            &result,
            path,
            fieldPrefix + "rpaths",
            canonicalStrings(
                pinned.rpaths,
                replacements: pinnedReplacements
            ),
            canonicalStrings(
                iosUse.rpaths,
                replacements: iosUseReplacements
            )
        )
        checkedFieldFamilies.insert(.rpaths)
        compare(
            &result,
            path,
            fieldPrefix + "dependencies",
            canonicalStrings(
                pinned.dependencies,
                replacements: pinnedReplacements
            ),
            canonicalStrings(
                iosUse.dependencies,
                replacements: iosUseReplacements
            )
        )
        checkedFieldFamilies.insert(.dependencies)
        compareSignature(
            pinned.signature,
            iosUse.signature,
            path: path,
            fieldPrefix: fieldPrefix + "signature.",
            pinnedReplacements: pinnedReplacements,
            iosUseReplacements: iosUseReplacements,
            checkedFieldFamilies: &checkedFieldFamilies,
            result: &result
        )
    }

    private static func compareSignature(
        _ pinned: PlayCoverUpstreamSignature,
        _ iosUse: PlayCoverUpstreamSignature,
        path: String,
        fieldPrefix: String,
        pinnedReplacements: [String: String],
        iosUseReplacements: [String: String],
        checkedFieldFamilies:
            inout Set<PlayCoverDifferentialFieldFamily>,
        result: inout [PlayCoverDifferentialDifference]
    ) {
        compare(
            &result,
            path,
            fieldPrefix + "isSigned",
            String(pinned.isSigned),
            String(iosUse.isSigned)
        )
        compare(
            &result,
            path,
            fieldPrefix + "isValid",
            String(pinned.isValid),
            String(iosUse.isValid)
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "cdHash",
            pinned.cdHash,
            iosUse.cdHash
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "identifier",
            pinned.identifier,
            iosUse.identifier
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "teamIdentifier",
            pinned.teamIdentifier,
            iosUse.teamIdentifier
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "type",
            pinned.signatureType,
            iosUse.signatureType
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "flags",
            pinned.flags,
            iosUse.flags
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "codeDirectory.version",
            pinned.codeDirectoryVersion,
            iosUse.codeDirectoryVersion
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "codeDirectory.hashes",
            pinned.codeDirectoryHashes,
            iosUse.codeDirectoryHashes
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "hashChoices",
            pinned.hashChoices,
            iosUse.hashChoices
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "hashType",
            pinned.hashType,
            iosUse.hashType
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "pageSize",
            pinned.pageSize,
            iosUse.pageSize
        )
        checkedFieldFamilies.insert(.signatureMetadata)
        compareOptional(
            &result,
            path,
            fieldPrefix + "superBlob.length",
            pinned.superBlobLength.map(String.init),
            iosUse.superBlobLength.map(String.init)
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "superBlob.paddingSize",
            pinned.superBlobPaddingSize.map(String.init),
            iosUse.superBlobPaddingSize.map(String.init)
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "superBlob.structureSHA256",
            pinned.superBlobStructureSHA256,
            iosUse.superBlobStructureSHA256
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "superBlob.paddingSHA256",
            pinned.superBlobPaddingSHA256,
            iosUse.superBlobPaddingSHA256
        )
        compareEmbeddedSignatureSlots(
            pinned,
            iosUse,
            path: path,
            fieldPrefix: fieldPrefix + "superBlob.",
            pinnedReplacements: pinnedReplacements,
            iosUseReplacements: iosUseReplacements,
            result: &result
        )
        checkedFieldFamilies.insert(.signatureSuperBlob)
        checkedFieldFamilies.insert(.signatureCodeDirectory)
        compareOptional(
            &result,
            path,
            fieldPrefix + "entitlementsCanonicalSHA256",
            canonicalEntitlementsSHA256(
                pinned.entitlementsPlist,
                replacements: pinnedReplacements
            ),
            canonicalEntitlementsSHA256(
                iosUse.entitlementsPlist,
                replacements: iosUseReplacements
            )
        )
        compareOptional(
            &result,
            path,
            fieldPrefix + "derEntitlementsCanonicalSHA256",
            canonicalEntitlementsSHA256(
                pinned.derEntitlementsPlist,
                replacements: pinnedReplacements
            ),
            canonicalEntitlementsSHA256(
                iosUse.derEntitlementsPlist,
                replacements: iosUseReplacements
            )
        )
        checkedFieldFamilies.insert(.derEntitlements)
        compareEntitlements(
            pinned.entitlementsPlist,
            iosUse.entitlementsPlist,
            path: path,
            fieldPrefix: fieldPrefix,
            pinnedReplacements: pinnedReplacements,
            iosUseReplacements: iosUseReplacements,
            result: &result
        )
        checkedFieldFamilies.insert(.xmlEntitlements)
    }

    private static func compareEmbeddedSignatureSlots(
        _ pinned: PlayCoverUpstreamSignature,
        _ iosUse: PlayCoverUpstreamSignature,
        path: String,
        fieldPrefix: String,
        pinnedReplacements: [String: String],
        iosUseReplacements: [String: String],
        result: inout [PlayCoverDifferentialDifference]
    ) {
        compare(
            &result,
            path,
            fieldPrefix + "slots.count",
            String(pinned.embeddedSlots.count),
            String(iosUse.embeddedSlots.count)
        )
        let pinnedSlots = indexedSignatureSlots(pinned.embeddedSlots)
        let iosUseSlots = indexedSignatureSlots(iosUse.embeddedSlots)
        let selectors = Set(pinnedSlots.keys)
            .union(iosUseSlots.keys)
            .sorted()
        for selector in selectors {
            let prefix = fieldPrefix + "slots[\(selector)]."
            guard let pinnedSlot = pinnedSlots[selector] else {
                appendDifference(
                    &result,
                    path: path,
                    field: prefix + "presence",
                    pinned: nil,
                    iosUse: signatureSlotPresenceEvidence(
                        iosUseSlots[selector]!,
                        replacements: iosUseReplacements
                    )
                )
                continue
            }
            guard let iosUseSlot = iosUseSlots[selector] else {
                appendDifference(
                    &result,
                    path: path,
                    field: prefix + "presence",
                    pinned: signatureSlotPresenceEvidence(
                        pinnedSlot,
                        replacements: pinnedReplacements
                    ),
                    iosUse: nil
                )
                continue
            }
            compare(
                &result,
                path,
                prefix + "index",
                String(pinnedSlot.index),
                String(iosUseSlot.index)
            )
            compare(
                &result,
                path,
                prefix + "type",
                String(pinnedSlot.type),
                String(iosUseSlot.type)
            )
            compare(
                &result,
                path,
                prefix + "offset",
                String(pinnedSlot.offset),
                String(iosUseSlot.offset)
            )
            compare(
                &result,
                path,
                prefix + "magic",
                String(format: "0x%08x", pinnedSlot.magic),
                String(format: "0x%08x", iosUseSlot.magic)
            )
            compare(
                &result,
                path,
                prefix + "length",
                String(pinnedSlot.length),
                String(iosUseSlot.length)
            )
            compareCodeDirectoryEvidence(
                pinnedSlot.codeDirectory,
                iosUseSlot.codeDirectory,
                path: path,
                fieldPrefix: prefix + "codeDirectory.",
                result: &result
            )
            if pinnedSlot.codeDirectory == nil,
               iosUseSlot.codeDirectory == nil {
                if pinnedSlot.type == 5 || pinnedSlot.type == 7 {
                    compare(
                        &result,
                        path,
                        prefix + "normalizedBytesSHA256",
                        normalizedSignatureSlotSHA256(
                            pinnedSlot,
                            replacements: pinnedReplacements
                        ),
                        normalizedSignatureSlotSHA256(
                            iosUseSlot,
                            replacements: iosUseReplacements
                        )
                    )
                } else {
                    compare(
                        &result,
                        path,
                        prefix + "bytesSHA256",
                        pinnedSlot.bytesSHA256,
                        iosUseSlot.bytesSHA256
                    )
                }
            }
        }
    }

    private static func indexedSignatureSlots(
        _ slots: [PlayCoverUpstreamSignatureSlot]
    ) -> [String: PlayCoverUpstreamSignatureSlot] {
        var result: [String: PlayCoverUpstreamSignatureSlot] = [:]
        var occurrences: [UInt32: Int] = [:]
        for slot in slots {
            let occurrence = occurrences[slot.type, default: 0]
            occurrences[slot.type] = occurrence + 1
            result[
                "type=\(slot.type),occurrence=\(occurrence)"
            ] = slot
        }
        return result
    }

    private static func signatureSlotPresenceEvidence(
        _ slot: PlayCoverUpstreamSignatureSlot,
        replacements: [String: String]
    ) -> String {
        "present;index=\(slot.index);offset=\(slot.offset);"
            + "type=\(slot.type);magic="
            + String(format: "0x%08x", slot.magic)
            + ";length=\(slot.length);normalizedBytesSHA256="
            + normalizedSignatureSlotSHA256(
                slot,
                replacements: replacements
            )
    }

    private static func normalizedSignatureSlotSHA256(
        _ slot: PlayCoverUpstreamSignatureSlot,
        replacements: [String: String]
    ) -> String {
        var normalized = slot.bytes
        let dynamicPaths = replacements.keys
            .filter { !$0.isEmpty }
            .sorted { $0.utf8.count > $1.utf8.count }
        for path in dynamicPaths {
            let needle = Data(path.utf8)
            while let range = normalized.range(of: needle) {
                normalized.replaceSubrange(
                    range,
                    with: repeatElement(UInt8(0), count: range.count)
                )
            }
        }
        return SHA256.hash(data: normalized).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func compareCodeDirectoryEvidence(
        _ pinned: PlayCoverUpstreamCodeDirectoryEvidence?,
        _ iosUse: PlayCoverUpstreamCodeDirectoryEvidence?,
        path: String,
        fieldPrefix: String,
        result: inout [PlayCoverDifferentialDifference]
    ) {
        compareOptional(
            &result,
            path,
            fieldPrefix + "presence",
            pinned.map { _ in "present" },
            iosUse.map { _ in "present" }
        )
        guard let pinned, let iosUse else {
            return
        }
        compare(
            &result,
            path,
            fieldPrefix + "structureSHA256",
            pinned.structureSHA256,
            iosUse.structureSHA256
        )
        compare(
            &result,
            path,
            fieldPrefix + "hashType",
            String(pinned.hashType),
            String(iosUse.hashType)
        )
        compare(
            &result,
            path,
            fieldPrefix + "hashSize",
            String(pinned.hashSize),
            String(iosUse.hashSize)
        )
        let specialSlots = Set(pinned.specialSlotHashes.keys)
            .union(iosUse.specialSlotHashes.keys)
            .sorted()
        for slot in specialSlots {
            switch slot {
            case "-5":
                compareOptional(
                    &result,
                    path,
                    fieldPrefix + "specialSlots[-5].binding",
                    specialSlotBinding(pinned.specialSlotHashes[slot]),
                    specialSlotBinding(iosUse.specialSlotHashes[slot])
                )
            case "-7":
                compareOptional(
                    &result,
                    path,
                    fieldPrefix + "specialSlots[-7].binding",
                    specialSlotBinding(pinned.specialSlotHashes[slot]),
                    specialSlotBinding(iosUse.specialSlotHashes[slot])
                )
            default:
                compareOptional(
                    &result,
                    path,
                    fieldPrefix + "specialSlots[\(slot)]",
                    pinned.specialSlotHashes[slot],
                    iosUse.specialSlotHashes[slot]
                )
            }
        }
        compare(
            &result,
            path,
            fieldPrefix + "codeSlots.count",
            String(pinned.codeSlotHashes.count),
            String(iosUse.codeSlotHashes.count)
        )
        let codeSlots = max(
            pinned.codeSlotHashes.count,
            iosUse.codeSlotHashes.count
        )
        for index in 0..<codeSlots {
            compareOptional(
                &result,
                path,
                fieldPrefix + "codeSlots[\(index)]",
                pinned.codeSlotHashes[safe: index],
                iosUse.codeSlotHashes[safe: index]
            )
        }
    }

    private static func specialSlotBinding(_ hash: String?) -> String? {
        guard let hash else {
            return nil
        }
        return hash.allSatisfy({ $0 == "0" }) ? "unbound" : "bound"
    }

    private static func compareEntitlements(
        _ pinned: Data?,
        _ iosUse: Data?,
        path: String,
        fieldPrefix: String,
        pinnedReplacements: [String: String],
        iosUseReplacements: [String: String],
        result: inout [PlayCoverDifferentialDifference]
    ) {
        let pinnedValues = entitlementValues(
            pinned,
            replacements: pinnedReplacements
        )
        let iosUseValues = entitlementValues(
            iosUse,
            replacements: iosUseReplacements
        )
        for key in Set(pinnedValues.keys).union(iosUseValues.keys).sorted() {
            compareOptional(
                &result,
                path,
                fieldPrefix + "entitlements.\(key)",
                pinnedValues[key],
                iosUseValues[key]
            )
        }
    }

    private static func entitlementValues(
        _ data: Data?,
        replacements: [String: String]
    ) -> [String: String] {
        guard let data,
              let values = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: values.map {
                (
                    $0.key,
                    canonicalEntitlementValue(
                        $0.value,
                        replacements: replacements
                    )
                )
            }
        )
    }

    private static func canonicalEntitlementsSHA256(
        _ data: Data?,
        replacements: [String: String]
    ) -> String? {
        guard data != nil else { return nil }
        let values = entitlementValues(data, replacements: replacements)
        let canonical = values.keys.sorted().map {
            "\($0)=\(values[$0]!)"
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func canonicalEntitlementValue(
        _ value: Any,
        replacements: [String: String]
    ) -> String {
        switch value {
        case let string as String:
            let normalized = replaceEntitlementPaths(
                string,
                replacements: replacements
            )
            return "\"" + normalized + "\""
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let data as Data:
            return "data:sha256:"
                + SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let array as [Any]:
            return "["
                + array.map {
                    canonicalEntitlementValue(
                        $0,
                        replacements: replacements
                    )
                }.joined(separator: ",")
                + "]"
        case let dictionary as [String: Any]:
            return "{"
                + dictionary.keys.sorted().map {
                    "\($0):"
                        + canonicalEntitlementValue(
                            dictionary[$0]!,
                            replacements: replacements
                        )
                }.joined(separator: ",")
                + "}"
        default:
            return replacePaths(
                String(describing: value),
                replacements: replacements
            )
        }
    }

    private static func canonicalLoadCommand(
        _ command: PlayCoverUpstreamLoadCommandInspection,
        replacements: [String: String]
    ) -> String {
        let originalSemantic = command.semanticValue
        let semantic = originalSemantic.map {
            replaceLoadCommandPath($0, replacements: replacements)
        } ?? "<none>"
        let baseCommand = command.command & 0x7fff_ffff
        let isPathBearingCommand = [
            UInt32(0x0c),
            UInt32(0x18),
            UInt32(0x1c),
            UInt32(0x1f),
            UInt32(0x20),
            UInt32(0x23),
        ].contains(baseCommand)
        let bytesHash = originalSemantic.map { value in
            isPathBearingCommand
                && replaceLoadCommandPath(
                    value,
                    replacements: replacements
                ) != value
                ? "<path-normalized-by-semantics>"
                : command.bytesSHA256
        } ?? command.bytesSHA256
        return String(format: "cmd=0x%08x", command.command)
            + ";size=\(command.commandSize)"
            + ";semantic=\(semantic)"
            + ";sha256=\(bytesHash)"
    }

    private static func canonicalStrings(
        _ values: [String],
        replacements: [String: String]
    ) -> String {
        let normalized = values.map {
            replacePaths($0, replacements: replacements)
        }
        let data = try? JSONEncoder().encode(normalized)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private static func replacePaths(
        _ value: String,
        replacements: [String: String]
    ) -> String {
        for source in replacements.keys.sorted(by: {
            $0.count > $1.count
        }) {
            guard !source.isEmpty,
                  let replacement = replacements[source] else {
                continue
            }
            if value == source {
                return replacement
            }
            if value.hasPrefix(source + "/") {
                return replacement + value.dropFirst(source.count)
            }
        }
        return value
    }

    private static func replaceLoadCommandPath(
        _ value: String,
        replacements: [String: String]
    ) -> String {
        guard value.hasPrefix("path="),
              let delimiter = value.range(
                  of: ";pathOffset=",
                  options: .backwards
              ) else {
            return value
        }
        let pathStart = value.index(
            value.startIndex,
            offsetBy: "path=".count
        )
        let path = String(value[pathStart..<delimiter.lowerBound])
        let normalized = replacePaths(path, replacements: replacements)
        guard normalized != path else {
            return value
        }
        return "path=" + normalized
            + String(value[delimiter.lowerBound...])
    }

    private static func replaceEntitlementPaths(
        _ value: String,
        replacements: [String: String]
    ) -> String {
        let direct = replacePaths(value, replacements: replacements)
        guard direct == value else {
            return direct
        }
        var result = value
        for marker in ["(subpath \"", "(literal \""] {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let markerRange = result.range(
                      of: marker,
                      range: searchStart..<result.endIndex
                  ) {
                let pathStart = markerRange.upperBound
                guard let pathEnd = result[pathStart...].firstIndex(of: "\"")
                else {
                    break
                }
                let path = String(result[pathStart..<pathEnd])
                let normalized = replacePaths(
                    path,
                    replacements: replacements
                )
                if normalized != path {
                    result.replaceSubrange(
                        pathStart..<pathEnd,
                        with: normalized
                    )
                    searchStart = result.index(
                        pathStart,
                        offsetBy: normalized.count
                    )
                } else {
                    searchStart = result.index(after: pathEnd)
                }
            }
        }
        return result
    }

    private static func compare(
        _ result: inout [PlayCoverDifferentialDifference],
        _ path: String,
        _ field: String,
        _ pinned: String,
        _ iosUse: String
    ) {
        appendDifference(
            &result,
            path: path,
            field: field,
            pinned: pinned,
            iosUse: iosUse
        )
    }

    private static func compareOptional(
        _ result: inout [PlayCoverDifferentialDifference],
        _ path: String,
        _ field: String,
        _ pinned: String?,
        _ iosUse: String?
    ) {
        appendDifference(
            &result,
            path: path,
            field: field,
            pinned: pinned,
            iosUse: iosUse
        )
    }

    private static func appendDifference(
        _ result: inout [PlayCoverDifferentialDifference],
        path: String,
        field: String,
        pinned: String?,
        iosUse: String?
    ) {
        guard pinned != iosUse else { return }
        result.append(
            PlayCoverDifferentialDifference(
                relativePath: path,
                field: field,
                pinnedValue: pinned,
                iosUseValue: iosUse
            )
        )
    }

    private static func pathsIdentifySameItem(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        guard
            let canonicalLHS = playCoverCanonicalExistingURL(
                URL(fileURLWithPath: lhs)
            ),
            let canonicalRHS = playCoverCanonicalExistingURL(
                URL(fileURLWithPath: rhs)
            )
        else {
            return false
        }
        return canonicalLHS.path == canonicalRHS.path
    }

    private static func isBoundApp(
        _ app: URL,
        to home: PlayCoverDifferentialNormalization.ManagedHomePaths
    ) -> Bool {
        let lexical = app.standardizedFileURL.path
        guard let canonical = playCoverCanonicalExistingURL(app)?.path else {
            return false
        }
        return home.aliases.contains {
            PlayCoverDifferentialNormalization.isStrictDescendant(
                lexical,
                of: $0
            )
        } && PlayCoverDifferentialNormalization.isStrictDescendant(
            canonical,
            of: home.canonical
        )
    }

    private static func implementationEvidence(
        repositoryRoot: URL
    ) throws -> PlayCoverDifferentialImplementationEvidence {
        let relativePaths = [
            "ThirdParty/PlayCover/Package.resolved",
            "ThirdParty/PlayCover/Package.swift",
            "ThirdParty/PlayCover/PROVENANCE.md",
            "ThirdParty/PlayCover/PlayCover/AppInstaller/Installer.swift",
            "ThirdParty/PlayCover/PlayCover/Headless/HeadlessSupport.swift",
            "ThirdParty/PlayCover/PlayCover/Headless/"
                + "PlayCoverPrepareDifferential.swift",
            "ThirdParty/PlayCover/PlayCover/Headless/"
                + "PlayCoverUpstreamEngine.swift",
            "ThirdParty/PlayCover/PlayCover/Model/AppInfo.swift",
            "ThirdParty/PlayCover/PlayCover/Model/BaseApp.swift",
            "ThirdParty/PlayCover/PlayCover/Model/PlayApp.swift",
            "ThirdParty/PlayCover/PlayCover/Model/PlayRules.swift",
            "ThirdParty/PlayCover/PlayCover/PlayCoverError.swift",
            "ThirdParty/PlayCover/PlayCover/Rules/default.yaml",
            "ThirdParty/PlayCover/PlayCover/Utils/Entitlements.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/Extensions/"
                + "DataExtensions.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/Extensions/"
                + "FileExtensions.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/Extensions/"
                + "PlayAppExtensions.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/Extensions/"
                + "URLExtensions.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/KeyCover.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/Macho.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/PlayTools.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/Shell.swift",
            "ThirdParty/PlayCover/PlayCover/Utils/SystemConfig.swift",
            "ThirdParty/inject/Injection/Injection/BitType.swift",
            "ThirdParty/inject/Injection/Injection/Command.swift",
            "ThirdParty/inject/Injection/Injection/Extension.swift",
            "ThirdParty/inject/Injection/Injection/Inject.swift",
            "ThirdParty/inject/Injection/Injection/Shell.swift",
            "ThirdParty/inject/Package.swift",
            "ThirdParty/inject/PROVENANCE.md",
            "scripts/audit_playcover_upstreams.sh",
            "scripts/test_playcover_external_prepare_differential.sh",
            "scripts/test_playcover_prepare_differential.sh",
            "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/"
                + "PlayCoverService.swift",
            "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/"
                + "PlayCoverStartTiming.swift",
            "swift-cli/Tests/IOSUseCLITests/PlayCover/"
                + "PlayCoverExternalPrepareDifferentialTests.swift",
            "swift-cli/Tests/IOSUseCLITests/PlayCover/"
                + "PlayCoverPrepareDifferentialTests.swift",
            "swift-cli/Package.resolved",
            "swift-cli/Package.swift",
        ].sorted()
        guard repositoryRoot.path.hasPrefix("/") else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "repository root must be absolute",
            ])
        }
        guard let canonicalRoot = playCoverCanonicalExistingURL(repositoryRoot),
              canonicalRoot.path != "/" else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "repository root must exist and cannot be the filesystem root",
            ])
        }
        var framed = Data()
        func appendLength(_ value: Int) {
            var bigEndian = UInt64(value).bigEndian
            withUnsafeBytes(of: &bigEndian) {
                framed.append(contentsOf: $0)
            }
        }
        for relativePath in relativePaths {
            let url = canonicalRoot.appendingPathComponent(relativePath)
                .standardizedFileURL
            guard url.path.hasPrefix(canonicalRoot.path + "/") else {
                throw PlayCoverDifferentialAttestationError.invalidIdentity([
                    "implementation source escaped repository root",
                ])
            }
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw PlayCoverDifferentialAttestationError.invalidIdentity([
                    "implementation source is not a regular file: "
                        + relativePath,
                ])
            }
            let pathData = Data(relativePath.utf8)
            let sourceData = try normalizedImplementationSourceData(
                relativePath: relativePath,
                data: Data(contentsOf: url, options: [.mappedIfSafe])
            )
            appendLength(pathData.count)
            framed.append(pathData)
            appendLength(sourceData.count)
            framed.append(sourceData)
        }
        let digest = SHA256.hash(data: framed).map {
            String(format: "%02x", $0)
        }.joined()
        guard digest
            == playCoverPrepareDifferentialEmbeddedSourceClosureSHA256 else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "loaded XCTest was not built from the attested source closure",
            ])
        }
        let loadedImage = try loadedXCTestImageIdentity()
        let descriptor = Darwin.open(
            loadedImage.executableURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "could not open the loaded XCTest image without following links",
            ])
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        var statBefore = stat()
        guard Darwin.fstat(descriptor, &statBefore) == 0,
              isRegularFile(statBefore),
              UInt64(statBefore.st_dev) == loadedImage.device,
              statBefore.st_ino == loadedImage.inode,
              statBefore.st_size > 0,
              UInt64(statBefore.st_size) == loadedImage.size else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "XCTest path no longer identifies the loaded image inode",
            ])
        }
        let executableData = try handle.readToEnd() ?? Data()
        var statAfter = stat()
        guard Darwin.fstat(descriptor, &statAfter) == 0,
              stableFileIdentity(statBefore, statAfter),
              Int64(executableData.count) == statAfter.st_size else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "loaded XCTest image changed while hashing its open inode",
            ])
        }
        let executableDigest = SHA256.hash(data: executableData).map {
            String(format: "%02x", $0)
        }.joined()
        return PlayCoverDifferentialImplementationEvidence(
            algorithm:
                "embedded-source-closure-plus-loaded-xctest-inode-sha256-v2",
            relativeSourcePaths: relativePaths,
            contentSHA256: digest,
            embeddedSourceClosureSHA256:
                playCoverPrepareDifferentialEmbeddedSourceClosureSHA256,
            testExecutableSHA256: executableDigest,
            testExecutableSize: UInt64(statAfter.st_size),
            testExecutableDevice: loadedImage.device,
            testExecutableInode: loadedImage.inode
        )
    }

    private struct LoadedXCTestImageIdentity {
        let executableURL: URL
        let device: UInt64
        let inode: UInt64
        let size: UInt64
    }

    private static func normalizedImplementationSourceData(
        relativePath: String,
        data: Data
    ) throws -> Data {
        let identitySource =
            "ThirdParty/PlayCover/PlayCover/Headless/"
                + "PlayCoverPrepareDifferential.swift"
        guard relativePath == identitySource else {
            return data
        }
        let declarationPrefix =
            "private let "
                + "playCoverPrepareDifferentialEmbeddedSourceClosureSHA256 =\n"
                + "    \""
        let declaration = Data(
            (
                declarationPrefix
                    + playCoverPrepareDifferentialEmbeddedSourceClosureSHA256
                    + "\""
            ).utf8
        )
        guard let range = data.range(of: declaration),
              data.range(
                  of: declaration,
                  in: range.upperBound..<data.endIndex
              ) == nil else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "source closure has no unique embedded identity declaration",
            ])
        }
        var normalized = data
        let replacement = Data(
            (
                declarationPrefix
                    + String(repeating: "0", count: 64)
                    + "\""
            ).utf8
        )
        normalized.replaceSubrange(range, with: replacement)
        return normalized
    }

    private static func loadedXCTestImageIdentity()
        throws -> LoadedXCTestImageIdentity
    {
        let bundleExecutables = Bundle.allBundles.compactMap {
            bundle -> URL? in
            guard bundle.bundleURL.pathExtension == "xctest" else {
                return nil
            }
            guard let executableURL = bundle.executableURL else {
                return nil
            }
            return playCoverCanonicalExistingURL(executableURL)
        }
        guard bundleExecutables.count == 1,
              let executableURL = bundleExecutables.first else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "exactly one loaded XCTest executable is required",
            ])
        }
        var matchedHeaders: [UnsafePointer<mach_header>] = []
        for index in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(index),
                  let header = _dyld_get_image_header(index) else {
                continue
            }
            guard let imageURL = playCoverCanonicalExistingURL(
                URL(fileURLWithPath: String(cString: imageName))
            ) else {
                continue
            }
            if imageURL.path == executableURL.path {
                matchedHeaders.append(header)
            }
        }
        guard matchedHeaders.count == 1,
              let header = matchedHeaders.first else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "XCTest bundle executable is not one exact loaded image",
            ])
        }
        var region = proc_regionwithpathinfo()
        let regionSize = MemoryLayout<proc_regionwithpathinfo>.size
        let bytesRead = proc_pidinfo(
            getpid(),
            PROC_PIDREGIONPATHINFO,
            UInt64(UInt(bitPattern: header)),
            &region,
            Int32(regionSize)
        )
        let loadedStat = region.prp_vip.vip_vi.vi_stat
        guard bytesRead == Int32(regionSize),
              loadedStat.vst_ino > 0,
              loadedStat.vst_size > 0,
              mode_t(loadedStat.vst_mode) & mode_t(S_IFMT)
                == mode_t(S_IFREG) else {
            throw PlayCoverDifferentialAttestationError.invalidIdentity([
                "could not bind XCTest's loaded VM image to a regular vnode",
            ])
        }
        return LoadedXCTestImageIdentity(
            executableURL: executableURL,
            device: UInt64(loadedStat.vst_dev),
            inode: loadedStat.vst_ino,
            size: UInt64(loadedStat.vst_size)
        )
    }

    private static func isRegularFile(_ value: stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func stableFileIdentity(
        _ before: stat,
        _ after: stat
    ) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_mode == after.st_mode
            && before.st_nlink == after.st_nlink
            && before.st_uid == after.st_uid
            && before.st_gid == after.st_gid
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func validateAllowances(
        _ allowances: [PlayCoverDifferentialAllowance]
    ) -> [String] {
        var errors: [String] = []
        var identifiers: Set<String> = []
        var selectors: Set<String> = []
        for allowance in allowances {
            if allowance.id.isEmpty
                || allowance.relativePath.isEmpty
                || allowance.field.isEmpty
                || allowance.reason.isEmpty
                || allowance.pinnedSymbol.isEmpty
                || allowance.iosUseSymbol.isEmpty {
                errors.append(
                    "allowance \(allowance.id) has an empty required field"
                )
            }
            if !identifiers.insert(allowance.id).inserted {
                errors.append("duplicate allowance id \(allowance.id)")
            }
            let selector = allowance.relativePath + "\u{0}"
                + allowance.field
            if !selectors.insert(selector).inserted {
                errors.append(
                    "duplicate allowance selector "
                        + "\(allowance.relativePath) \(allowance.field)"
                )
            }
            if !isStrictExpectation(
                    allowance.pinnedValue,
                    field: allowance.field
               )
                || !isStrictExpectation(
                    allowance.iosUseValue,
                    field: allowance.field
                ) {
                errors.append(
                    "allowance \(allowance.id) uses a non-exact expectation"
                )
            }
        }
        return errors.sorted()
    }

    private static func isStrictExpectation(
        _ expectation: PlayCoverDifferentialExpectation,
        field: String
    ) -> Bool {
        switch expectation {
        case .absent, .exact:
            return true
        case .lowercaseHexDigest(let length):
            return field.hasSuffix(".signature.cdHash") && length == 40
        case .any, .present, .containing:
            return false
        }
    }

    private static func validateBaselines(
        _ baselines: [PlayCoverDifferentialObjectBaseline]
    ) -> [String] {
        var errors: [String] = []
        var identifiers: Set<String> = []
        var selectors: Set<String> = []
        for baseline in baselines {
            if baseline.id.isEmpty
                || baseline.relativePath.isEmpty
                || baseline.provenance.isEmpty {
                errors.append(
                    "baseline \(baseline.id) has an empty required field"
                )
            }
            if !identifiers.insert(baseline.id).inserted {
                errors.append("duplicate baseline id \(baseline.id)")
            }
            let selector = baselineSelector(
                baseline.side,
                baseline.relativePath
            )
            if !selectors.insert(selector).inserted {
                errors.append(
                    "duplicate baseline selector "
                        + "\(baseline.side.rawValue) "
                        + baseline.relativePath
                )
            }
            if baseline.inspection.relativePath != baseline.relativePath {
                errors.append(
                    "baseline \(baseline.id) inspection path does not match"
                )
            }
            if baseline.sourceSHA256 != baseline.inspection.fileSHA256 {
                errors.append(
                    "baseline \(baseline.id) source hash does not match "
                        + "its inspection"
                )
            }
            if baseline.sourceSHA256.count != 64
                || !baseline.sourceSHA256.allSatisfy({
                    $0.isHexDigit
                }) {
                errors.append(
                    "baseline \(baseline.id) has an invalid source hash"
                )
            }
        }
        return errors.sorted()
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
