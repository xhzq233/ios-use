/*
 * Differential prepare support for PlayCover at
 * 7190cc9ce57c8dee0e222918468f2579acc95e1b.
 *
 * PlayCover is GPL-3.0. See ../../../LICENSE and ../../../PROVENANCE.md.
 */

import CryptoKit
import Foundation
import injection

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

public struct PlayCoverPinnedPrimitivePrepareResult: Sendable {
    public let sourceBefore: PlayCoverUpstreamAppInspection
    public let sourceHashAfterPrepare: String
    public let prepared: PlayCoverUpstreamAppInspection
    public let convertedMachOs: [String]
    public let signingOrder: [String]
    public let executedPinnedSymbols: [String]

    public init(
        sourceBefore: PlayCoverUpstreamAppInspection,
        sourceHashAfterPrepare: String,
        prepared: PlayCoverUpstreamAppInspection,
        convertedMachOs: [String],
        signingOrder: [String],
        executedPinnedSymbols: [String]
    ) {
        self.sourceBefore = sourceBefore
        self.sourceHashAfterPrepare = sourceHashAfterPrepare
        self.prepared = prepared
        self.convertedMachOs = convertedMachOs
        self.signingOrder = signingOrder
        self.executedPinnedSymbols = executedPinnedSymbols
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
        let relativePaths = installerMachOs.map {
            relativePath($0, in: options.sourceApp)
        }
        let sourcePaths = Set(source.machOs.map(\.relativePath))
        guard Set(relativePaths) == sourcePaths else {
            throw PlayCoverUpstreamError.verificationFailed(
                "pinned Installer enumeration and neutral inspection disagree"
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
        return PlayCoverPinnedPrimitivePrepareResult(
            sourceBefore: source,
            sourceHashAfterPrepare: sourceAfter,
            prepared: prepared,
            convertedMachOs: converted,
            signingOrder: signingOrder,
            executedPinnedSymbols: executedPinnedSymbols
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

    private static func relativePath(_ url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return String(path.dropFirst(rootPath.count + 1))
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
    public let pinnedPathReplacements: [String: String]
    public let iosUsePathReplacements: [String: String]

    public init(
        pinnedPathReplacements: [String: String] = [:],
        iosUsePathReplacements: [String: String] = [:]
    ) {
        self.pinnedPathReplacements = pinnedPathReplacements
        self.iosUsePathReplacements = iosUsePathReplacements
    }
}

public enum PlayCoverDifferentialSide: String, Equatable, Sendable {
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

public struct PlayCoverDifferentialReport: Sendable {
    public let differences: [PlayCoverDifferentialDifference]
    public let consumedAllowanceIDs: [String]
    public let consumedBaselineIDs: [String]
    public let comparedSliceSelectors: [String]

    public init(
        differences: [PlayCoverDifferentialDifference],
        consumedAllowanceIDs: [String],
        consumedBaselineIDs: [String] = [],
        comparedSliceSelectors: [String] = []
    ) {
        self.differences = differences
        self.consumedAllowanceIDs = consumedAllowanceIDs
        self.consumedBaselineIDs = consumedBaselineIDs
        self.comparedSliceSelectors = comparedSliceSelectors
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
        var consumed: Set<String> = []
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
                consumed.insert(matches[0].id)
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
        return PlayCoverDifferentialReport(
            differences: actual,
            consumedAllowanceIDs: consumed.sorted(),
            consumedBaselineIDs: analysis.consumedBaselineIDs.sorted(),
            comparedSliceSelectors: analysis.comparedSliceSelectors.sorted()
        )
    }

    private struct Analysis {
        let differences: [PlayCoverDifferentialDifference]
        let consumedBaselineIDs: Set<String>
        let comparedSliceSelectors: Set<String>
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
        var consumedBaselines: Set<String> = []
        var comparedSlices: Set<String> = []

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
                    comparedSlices: &comparedSlices
                )
                consumedBaselines.insert(baseline.id)
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
                    comparedSlices: &comparedSlices
                )
                consumedBaselines.insert(baseline.id)
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
            compareMachO(
                pinnedMachO,
                iosUseMachO,
                path: path,
                normalization: normalization,
                fieldPrefix: "",
                comparedSlices: &comparedSlices,
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
            comparedSliceSelectors: comparedSlices
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
        comparedSlices: inout Set<String>
    ) throws {
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
                comparedSlices: &comparedSlices,
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
            comparedSlices: &comparedSlices,
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

    private static func compareMachO(
        _ pinned: PlayCoverUpstreamMachOInspection,
        _ iosUse: PlayCoverUpstreamMachOInspection,
        path: String,
        normalization: PlayCoverDifferentialNormalization,
        fieldPrefix: String,
        comparedSlices: inout Set<String>,
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
            comparedSlices.insert("\(path)#\(selector)")
            compareSlice(
                pinnedSlice,
                iosUseSlice,
                path: path,
                fieldPrefix: prefix,
                pinnedReplacements:
                    normalization.pinnedPathReplacements,
                iosUseReplacements:
                    normalization.iosUsePathReplacements,
                result: &result
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
        compareOptional(
            &result, path, fieldPrefix + "immutableContentSHA256",
            pinned.immutableContentSHA256,
            iosUse.immutableContentSHA256
        )
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
        compareOptional(
            &result, path, fieldPrefix + "firstSectionOffset",
            pinned.firstSectionOffset.map(String.init),
            iosUse.firstSectionOffset.map(String.init)
        )
        compare(
            &result, path, fieldPrefix + "encrypted",
            String(pinned.encrypted), String(iosUse.encrypted)
        )
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
        compareSignature(
            pinned.signature,
            iosUse.signature,
            path: path,
            fieldPrefix: fieldPrefix + "signature.",
            pinnedReplacements: pinnedReplacements,
            iosUseReplacements: iosUseReplacements,
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
        compareEntitlements(
            pinned.entitlementsPlist,
            iosUse.entitlementsPlist,
            path: path,
            fieldPrefix: fieldPrefix,
            pinnedReplacements: pinnedReplacements,
            iosUseReplacements: iosUseReplacements,
            result: &result
        )
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
            return "\"\(replacePaths(string, replacements: replacements))\""
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
            replacePaths($0, replacements: replacements)
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
            isPathBearingCommand && replacements.keys.contains {
                value.contains($0)
            } ? "<path-normalized-by-semantics>" : command.bytesSHA256
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
        replacements.keys.sorted {
            $0.count > $1.count
        }.reduce(value) {
            $0.replacingOccurrences(
                of: $1,
                with: replacements[$1] ?? ""
            )
        }
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
