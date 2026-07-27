import CryptoKit
import Darwin
import Foundation
@testable import IOSUseCLI
@testable import PlayCoverUpstream
import XCTest

final class PlayCoverExternalPrepareDifferentialTests: XCTestCase {
    private static let profileScope = "external-app-structural-v1"

    private struct Scenario: Decodable {
        let schemaVersion: Int
        let appPath: String
        let bundleIdentifier: String
    }

    private struct SourceProfile: Codable, Equatable {
        let contentSHA256: String
        let executableSHA256: String
        let bundleIdentifier: String
        let mainExecutableRelativePath: String
        let inventorySelectorsSHA256: String
        let objectSelectorsSHA256: String
        let sliceSelectorsSHA256: String
        let inventoryCount: Int
        let objectCount: Int
        let sliceCount: Int
    }

    private struct RuntimeProfile: Codable, Equatable {
        let inputTreeSHA256: String
        let inputExecutableSHA256: String
        let signedProjectionTreeSHA256: String
        let signedProjectionExecutableSHA256: String
        let outputFrameworkRelativePath: String
        let outputExecutableRelativePath: String
    }

    private struct PlayToolsProfile: Codable, Equatable {
        let inputTreeSHA256: String
        let signedPluginTreeSHA256: String
        let signedPluginExecutableSHA256: String
        let outputPluginRelativePath: String
        let outputPluginExecutableRelativePath: String
    }

    private struct RevisionProfile: Codable, Equatable {
        let playCover: String
        let inject: String
        let rules: String
        let prepare: String
    }

    private struct ExactAllowanceProfile: Codable, Equatable {
        let id: String
        let relativePath: String
        let field: String
        let pinnedValue: String?
        let iosUseValue: String?
        let reason: String
        let pinnedSymbol: String
        let iosUseSymbol: String

        func allowance() -> PlayCoverDifferentialAllowance {
            PlayCoverDifferentialAllowance(
                id: id,
                relativePath: relativePath,
                field: field,
                pinnedValue: pinnedValue.map {
                    .exact($0)
                } ?? .absent,
                iosUseValue: iosUseValue.map {
                    .exact($0)
                } ?? .absent,
                reason: reason,
                pinnedSymbol: pinnedSymbol,
                iosUseSymbol: iosUseSymbol
            )
        }
    }

    private struct ExternalProfile: Codable, Equatable {
        let schemaVersion: Int
        let scope: String
        let source: SourceProfile
        let runtime: RuntimeProfile
        let playTools: PlayToolsProfile
        let revisions: RevisionProfile
        let allowances: [ExactAllowanceProfile]
    }

    private struct OriginalSourceEvidence: Codable, Equatable {
        let scenarioSHA256: String
        let inputContentSHA256: String
        let snapshotContentSHA256: String
        let recomputedAfterPrepareSHA256: String
        let unchanged: Bool
    }

    private struct InputTreeEvidence: Codable, Equatable {
        let runtimeInputTreeSHA256: String
        let runtimeSignedProjectionTreeSHA256: String
        let playToolsInputTreeSHA256: String
        let playToolsSignedPluginTreeSHA256: String
        let runtimeUnchanged: Bool
        let playToolsUnchanged: Bool
    }

    private struct ExternalAttestation: Codable, Equatable {
        let schemaVersion: Int
        let scope: String
        let result: String
        let repositoryCommit: String
        let profileSHA256: String
        let originalSource: OriginalSourceEvidence
        let inputs: InputTreeEvidence
        let differential: PlayCoverDifferentialAttestation
    }

    private enum ProfileError: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let message):
                return "invalid external differential profile: \(message)"
            }
        }
    }

    func testConfiguredExternalAppPassesReviewedStructuralProfile()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        let required = [
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_SCENARIO",
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PROFILE",
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PROFILE_SHA256",
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_RUNTIME",
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PLAYTOOLS",
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_WORK_ROOT",
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_ATTESTATION",
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_COMMIT",
        ]
        guard required.allSatisfy({
            environment[$0]?.isEmpty == false
        }) else {
            throw XCTSkip(
                "external-App differential inputs are intentionally explicit"
            )
        }

        let scenarioURL = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_SCENARIO",
            environment: environment,
            isDirectory: false
        )
        let profileURL = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PROFILE",
            environment: environment,
            isDirectory: false
        )
        let runtime = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_RUNTIME",
            environment: environment,
            isDirectory: true
        )
        let playTools = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PLAYTOOLS",
            environment: environment,
            isDirectory: true
        )
        let requestedWorkRoot = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_WORK_ROOT",
            environment: environment,
            isDirectory: true
        )
        let attestationURL = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_ATTESTATION",
            environment: environment,
            isDirectory: false
        )
        let repository = repositoryRoot()
        try requireOutsideRepository(
            requestedWorkRoot,
            repositoryRoot: repository,
            label: "work root"
        )
        try requireOutsideRepository(
            attestationURL,
            repositoryRoot: repository,
            label: "attestation"
        )
        guard !FileManager.default.fileExists(
            atPath: requestedWorkRoot.path
        ), !FileManager.default.fileExists(atPath: attestationURL.path) else {
            throw ProfileError.invalid(
                "work root and attestation must be fresh paths"
            )
        }

        let scenarioData = try boundedRegularFile(
            scenarioURL,
            maximumBytes: 1_048_576
        )
        let scenarioSHA256 = sha256(scenarioData)
        let scenario = try JSONDecoder().decode(
            Scenario.self,
            from: scenarioData
        )
        guard scenario.schemaVersion == 1,
              scenario.appPath.hasPrefix("/"),
              !scenario.bundleIdentifier.isEmpty else {
            throw ProfileError.invalid("scenario identity is incomplete")
        }
        let source = URL(
            fileURLWithPath: scenario.appPath,
            isDirectory: true
        ).standardizedFileURL

        let profileData = try boundedRegularFile(
            profileURL,
            maximumBytes: 16 * 1_024 * 1_024
        )
        let profileSHA256 = sha256(profileData)
        guard profileSHA256
                == environment[
                    "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_PROFILE_SHA256"
                ] else {
            throw ProfileError.invalid(
                "profile bytes do not match the separately reviewed digest"
            )
        }
        let profile = try JSONDecoder().decode(
            ExternalProfile.self,
            from: profileData
        )
        try validate(profile)

        let commit = try XCTUnwrap(
            environment["IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_COMMIT"]
        )
        guard isLowercaseHex(commit, count: 40) else {
            throw ProfileError.invalid(
                "repository commit is not lowercase 40-digit Git identity"
            )
        }
        let currentCommit = try Shell.run(
            print: false,
            "/usr/bin/git",
            "-C",
            repository.path,
            "rev-parse",
            "HEAD"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit == currentCommit else {
            throw ProfileError.invalid(
                "repository commit does not identify the current checkout"
            )
        }

        let originalBefore = try PlayCoverUpstreamEngine.inspect(
            appURL: source
        )
        guard originalBefore.bundleIdentifier
                == scenario.bundleIdentifier else {
            throw ProfileError.invalid(
                "scenario bundle identifier does not match source App"
            )
        }
        try requireSourceProfile(profile.source, matches: originalBefore)

        let runtimeInputTreeSHA256 =
            try PlayCoverService.runtimeBuildHash(
                frameworkPath: runtime.path
            )
        let runtimeInputExecutable =
            runtime.appendingPathComponent(
                executableSuffix(
                    from: profile.runtime.outputExecutableRelativePath,
                    below: profile.runtime.outputFrameworkRelativePath
                )
            )
        let runtimeInputExecutableSHA256 =
            try PlayCoverUpstreamEngine.inspectMachO(
                at: runtimeInputExecutable,
                relativePath:
                    profile.runtime.outputExecutableRelativePath
            ).fileSHA256
        let playToolsInputTreeSHA256 =
            try PlayCoverUpstreamEngine.contentHash(appURL: playTools)
        guard runtimeInputTreeSHA256
                == profile.runtime.inputTreeSHA256,
              runtimeInputExecutableSHA256
                == profile.runtime.inputExecutableSHA256,
              playToolsInputTreeSHA256
                == profile.playTools.inputTreeSHA256 else {
            throw ProfileError.invalid(
                "Runtime or PlayTools full input tree changed"
            )
        }

        try FileManager.default.createDirectory(
            at: requestedWorkRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let workRoot = requestedWorkRoot.resolvingSymlinksInPath()
        defer {
            if environment[
                "IOS_USE_PLAYCOVER_EXTERNAL_DIFFERENTIAL_KEEP_WORK"
            ] != "1" {
                try? FileManager.default.removeItem(at: workRoot)
            }
        }
        let sourceSnapshot = workRoot.appendingPathComponent(
            "source-snapshot/Source.app",
            isDirectory: true
        )
        try cloneTree(source, to: sourceSnapshot)
        let snapshotInspection =
            try PlayCoverUpstreamEngine.inspect(appURL: sourceSnapshot)
        try requireEquivalentInput(
            originalBefore,
            snapshotInspection
        )

        let pinnedHome = try makePrivateDirectory(
            workRoot.appendingPathComponent(
                "pinned-home",
                isDirectory: true
            )
        )
        let iosUseHome = try makePrivateDirectory(
            workRoot.appendingPathComponent(
                "ios-use-home",
                isDirectory: true
            )
        )
        let baselineRoot = try makePrivateDirectory(
            workRoot.appendingPathComponent(
                "baselines",
                isDirectory: true
            )
        )

        let pinnedOutput = pinnedHome.appendingPathComponent(
            "prepared/Pinned.app",
            isDirectory: true
        )
        let pinned = try await PlayCoverPinnedHeadlessInstallerOracle.prepare(
            PlayCoverPinnedPrimitivePrepareOptions(
                sourceApp: sourceSnapshot,
                stagingApp: pinnedOutput,
                managedHome: pinnedHome,
                bundledPlayToolsFramework: playTools
            )
        )

        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": iosUseHome.path]
        )
        let candidateParent = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).appendingPathComponent("differential", isDirectory: true)
        try FileManager.default.createDirectory(
            at: candidateParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let iosUseOutput = candidateParent.appendingPathComponent(
            "IOSUse.app",
            isDirectory: true
        )
        let plan = try PlayCoverService.makePreparationPlan(
            source: PlayCoverService.inspectPreparationSource(
                appPath: sourceSnapshot.path
            ),
            runtimeFrameworkPath: runtime.path
        )
        guard plan.runtimeBuildHash == runtimeInputTreeSHA256 else {
            throw ProfileError.invalid(
                "preparation plan did not bind the reviewed Runtime tree"
            )
        }
        let preparedArtifact = try PlayCoverService.prepareMeasured(
            plan: plan,
            outputAppPath: iosUseOutput.path,
            paths: paths
        )
        let iosUseResult = try XCTUnwrap(preparedArtifact.upstreamResult)
        let iosUse = try PlayCoverUpstreamEngine.inspect(
            appURL: iosUseOutput
        )
        XCTAssertEqual(iosUseResult.prepared, iosUse)

        let runtimeBaselineFramework =
            baselineRoot.appendingPathComponent(
                "IOSUsePlayRuntime.framework",
                isDirectory: true
            )
        try FileManager.default.copyItem(
            at: runtime,
            to: runtimeBaselineFramework
        )
        try Shell.signMacho(runtimeBaselineFramework)
        let pluginBaselineBundle = baselineRoot.appendingPathComponent(
            "AKInterface.bundle",
            isDirectory: true
        )
        try FileManager.default.copyItem(
            at: playTools.appendingPathComponent(
                "PlugIns/AKInterface.bundle"
            ),
            to: pluginBaselineBundle
        )
        try Shell.signMacho(pluginBaselineBundle)

        let runtimeBaselineExecutable =
            runtimeBaselineFramework.appendingPathComponent(
                executableSuffix(
                    from: profile.runtime.outputExecutableRelativePath,
                    below: profile.runtime.outputFrameworkRelativePath
                )
            )
        let pluginBaselineExecutable =
            pluginBaselineBundle.appendingPathComponent(
                executableSuffix(
                    from:
                        profile.playTools.outputPluginExecutableRelativePath,
                    below: profile.playTools.outputPluginRelativePath
                )
            )
        let runtimeInspection =
            try PlayCoverUpstreamEngine.inspectMachO(
                at: runtimeBaselineExecutable,
                relativePath:
                    profile.runtime.outputExecutableRelativePath
            )
        let pluginInspection =
            try PlayCoverUpstreamEngine.inspectMachO(
                at: pluginBaselineExecutable,
                relativePath:
                    profile.playTools.outputPluginExecutableRelativePath
            )
        let runtimeSignedProjectionTreeSHA256 =
            try PlayCoverUpstreamEngine.contentHash(
                appURL: runtimeBaselineFramework
            )
        let pluginSignedProjectionTreeSHA256 =
            try PlayCoverUpstreamEngine.contentHash(
                appURL: pluginBaselineBundle
            )
        guard
            runtimeInspection.fileSHA256
                == profile.runtime.signedProjectionExecutableSHA256,
            runtimeSignedProjectionTreeSHA256
                == profile.runtime.signedProjectionTreeSHA256,
            pluginInspection.fileSHA256
                == profile.playTools.signedPluginExecutableSHA256,
            pluginSignedProjectionTreeSHA256
                == profile.playTools.signedPluginTreeSHA256
        else {
            throw ProfileError.invalid(
                "independent one-sided projection changed"
            )
        }

        let actualRuntimeFramework = iosUseOutput.appendingPathComponent(
            profile.runtime.outputFrameworkRelativePath,
            isDirectory: true
        )
        let actualPluginBundle = pinnedOutput.appendingPathComponent(
            profile.playTools.outputPluginRelativePath,
            isDirectory: true
        )
        guard
            try PlayCoverUpstreamEngine.contentHash(
                appURL: actualRuntimeFramework
            ) == runtimeSignedProjectionTreeSHA256,
            try PlayCoverUpstreamEngine.contentHash(
                appURL: actualPluginBundle
            ) == pluginSignedProjectionTreeSHA256
        else {
            throw ProfileError.invalid(
                "prepared one-sided tree is not its reviewed projection"
            )
        }

        let baselines = [
            PlayCoverDifferentialObjectBaseline(
                id: "external-pinned-akinterface-input",
                side: .pinned,
                relativePath:
                    profile.playTools.outputPluginExecutableRelativePath,
                inspection: pluginInspection,
                sourceSHA256: pluginInspection.fileSHA256,
                provenance:
                    "external profile \(profileSHA256); pinned "
                    + "PlayTools full-tree projection"
            ),
            PlayCoverDifferentialObjectBaseline(
                id: "external-ios-use-runtime-input",
                side: .iosUse,
                relativePath:
                    profile.runtime.outputExecutableRelativePath,
                inspection: runtimeInspection,
                sourceSHA256: runtimeInspection.fileSHA256,
                provenance:
                    "external profile \(profileSHA256); fresh Runtime "
                    + "full-tree projection"
            ),
        ]
        let normalization =
            try PlayCoverDifferentialNormalization.externalApp(
                pinnedManagedHome: pinnedHome,
                iosUseManagedHome: iosUseHome
            )
        let allowances = profile.allowances.map {
            $0.allowance()
        }
        let differences = try PlayCoverPrepareDifferentialGate.differences(
            pinned: pinned.prepared,
            iosUse: iosUse,
            oneSidedBaselines: baselines,
            normalization: normalization
        )
        try requireExactSelectorBijection(
            differences: differences,
            profile: profile
        )
        let differential = try PlayCoverPrepareDifferentialGate.attest(
            scope: .externalApp,
            repositoryRoot: repository,
            sourceApp: sourceSnapshot,
            pinnedResult: pinned,
            iosUseResult: iosUseResult,
            allowances: allowances,
            oneSidedBaselines: baselines,
            normalization: normalization
        )
        guard differential.consumedAllowances.count == allowances.count,
              differential.consumedAllowances.count == differences.count,
              differential.scope == .externalApp,
              differential.normalization.mode
                == .externalAppManagedPathsV1 else {
            throw ProfileError.invalid(
                "external allowance consumption is not a strict bijection"
            )
        }

        let originalAfter = try PlayCoverUpstreamEngine.inspect(
            appURL: source
        )
        try requireEquivalentInput(originalBefore, originalAfter)
        let runtimeAfter =
            try PlayCoverService.runtimeBuildHash(
                frameworkPath: runtime.path
            )
        let playToolsAfter =
            try PlayCoverUpstreamEngine.contentHash(appURL: playTools)
        guard runtimeAfter == runtimeInputTreeSHA256,
              playToolsAfter == playToolsInputTreeSHA256 else {
            throw ProfileError.invalid(
                "Runtime or PlayTools input changed during prepare"
            )
        }

        let attestation = ExternalAttestation(
            schemaVersion: 1,
            scope: Self.profileScope,
            result: "pass",
            repositoryCommit: commit,
            profileSHA256: profileSHA256,
            originalSource: OriginalSourceEvidence(
                scenarioSHA256: scenarioSHA256,
                inputContentSHA256: originalBefore.sourceContentHash,
                snapshotContentSHA256:
                    snapshotInspection.sourceContentHash,
                recomputedAfterPrepareSHA256:
                    originalAfter.sourceContentHash,
                unchanged: true
            ),
            inputs: InputTreeEvidence(
                runtimeInputTreeSHA256: runtimeInputTreeSHA256,
                runtimeSignedProjectionTreeSHA256:
                    runtimeSignedProjectionTreeSHA256,
                playToolsInputTreeSHA256: playToolsInputTreeSHA256,
                playToolsSignedPluginTreeSHA256:
                    pluginSignedProjectionTreeSHA256,
                runtimeUnchanged: true,
                playToolsUnchanged: true
            ),
            differential: differential
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        try encoder.encode(attestation).write(
            to: attestationURL,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: attestationURL.path
        )
    }

    func testExternalProfileRejectsDuplicateAllowanceIdentity() throws {
        let allowance = ExactAllowanceProfile(
            id: "duplicate",
            relativePath: "Fixture",
            field: "inventory.size",
            pinnedValue: "1",
            iosUseValue: "2",
            reason: "reviewed reason",
            pinnedSymbol: "Pinned.symbol",
            iosUseSymbol: "IOSUse.symbol"
        )
        let profile = minimalProfile(
            allowances: [allowance, allowance]
        )
        XCTAssertThrowsError(try validate(profile))
    }

    func testExternalProfileRejectsDuplicateAllowanceSelector() throws {
        let first = ExactAllowanceProfile(
            id: "first",
            relativePath: "Fixture",
            field: "inventory.size",
            pinnedValue: "1",
            iosUseValue: "2",
            reason: "first reviewed reason",
            pinnedSymbol: "Pinned.symbol",
            iosUseSymbol: "IOSUse.symbol"
        )
        let second = ExactAllowanceProfile(
            id: "second",
            relativePath: first.relativePath,
            field: first.field,
            pinnedValue: "3",
            iosUseValue: "4",
            reason: "second reviewed reason",
            pinnedSymbol: "Pinned.symbol",
            iosUseSymbol: "IOSUse.symbol"
        )
        XCTAssertThrowsError(
            try validate(
                minimalProfile(allowances: [first, second])
            )
        )
    }

    func testExternalProfileRejectsAllowanceWithoutDifference() throws {
        let allowance = ExactAllowanceProfile(
            id: "not-a-difference",
            relativePath: "Fixture",
            field: "inventory.size",
            pinnedValue: nil,
            iosUseValue: nil,
            reason: "reviewed reason",
            pinnedSymbol: "Pinned.symbol",
            iosUseSymbol: "IOSUse.symbol"
        )
        XCTAssertThrowsError(
            try validate(minimalProfile(allowances: [allowance]))
        )
    }

    func testExternalProfileRequiresExactSelectorBijection() throws {
        let allowance = ExactAllowanceProfile(
            id: "reviewed",
            relativePath: "Fixture",
            field: "inventory.size",
            pinnedValue: "1",
            iosUseValue: "2",
            reason: "reviewed reason",
            pinnedSymbol: "Pinned.symbol",
            iosUseSymbol: "IOSUse.symbol"
        )
        let difference = PlayCoverDifferentialDifference(
            relativePath: "Unexpected",
            field: allowance.field,
            pinnedValue: allowance.pinnedValue,
            iosUseValue: allowance.iosUseValue
        )
        XCTAssertThrowsError(
            try requireExactSelectorBijection(
                differences: [difference],
                profile: minimalProfile(allowances: [allowance])
            )
        )
    }

    private func validate(_ profile: ExternalProfile) throws {
        guard profile.schemaVersion == 1,
              profile.scope == Self.profileScope,
              profile.revisions.playCover
                == PlayCoverPinnedHeadlessInstallerOracle
                    .playCoverRevision,
              profile.revisions.playCover
                == PlayCoverUpstreamEngine.playCoverRevision,
              profile.revisions.inject
                == PlayCoverUpstreamEngine.injectRevision,
              profile.revisions.rules
                == PlayCoverUpstreamEngine.defaultRulesRevision,
              profile.revisions.prepare
                == PlayCoverService.prepareImplementationRevision else {
            throw ProfileError.invalid(
                "schema, scope, or producer revisions changed"
            )
        }
        let hashes = [
            profile.source.contentSHA256,
            profile.source.executableSHA256,
            profile.source.inventorySelectorsSHA256,
            profile.source.objectSelectorsSHA256,
            profile.source.sliceSelectorsSHA256,
            profile.runtime.inputTreeSHA256,
            profile.runtime.inputExecutableSHA256,
            profile.runtime.signedProjectionTreeSHA256,
            profile.runtime.signedProjectionExecutableSHA256,
            profile.playTools.inputTreeSHA256,
            profile.playTools.signedPluginTreeSHA256,
            profile.playTools.signedPluginExecutableSHA256,
        ]
        guard hashes.allSatisfy({
            isLowercaseHex($0, count: 64)
        }),
            profile.source.inventoryCount > 0,
            profile.source.objectCount > 0,
            profile.source.sliceCount > 0,
            !profile.source.bundleIdentifier.isEmpty,
            !profile.source.mainExecutableRelativePath.isEmpty,
            profile.runtime.outputFrameworkRelativePath
                == "Frameworks/IOSUsePlayRuntime.framework",
            profile.runtime.outputExecutableRelativePath.hasPrefix(
                profile.runtime.outputFrameworkRelativePath + "/"
            ),
            profile.playTools.outputPluginRelativePath
                == "PlugIns/AKInterface.bundle",
            profile.playTools.outputPluginExecutableRelativePath.hasPrefix(
                profile.playTools.outputPluginRelativePath + "/"
            ),
            !profile.allowances.isEmpty else {
            throw ProfileError.invalid(
                "tree identities or fixed one-sided paths are invalid"
            )
        }
        let identifiers = profile.allowances.map(\.id)
        guard Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy({ !$0.isEmpty }) else {
            throw ProfileError.invalid(
                "allowance identifiers must be unique and non-empty"
            )
        }
        let selectors = profile.allowances.map {
            "\($0.relativePath)\u{0}\($0.field)"
        }
        guard Set(selectors).count == selectors.count else {
            throw ProfileError.invalid(
                "allowance selectors must be unique"
            )
        }
        for allowance in profile.allowances {
            guard !allowance.relativePath.isEmpty,
                  !allowance.field.isEmpty,
                  !allowance.reason.isEmpty,
                  !allowance.pinnedSymbol.isEmpty,
                  !allowance.iosUseSymbol.isEmpty,
                  allowance.pinnedValue != nil
                    || allowance.iosUseValue != nil else {
                throw ProfileError.invalid(
                    "allowances must be exact, explained, and one-sided "
                        + "or two-sided"
                )
            }
        }
    }

    private func requireSourceProfile(
        _ profile: SourceProfile,
        matches inspection: PlayCoverUpstreamAppInspection
    ) throws {
        let main = try XCTUnwrap(
            inspection.machOs.first {
                $0.relativePath
                    == inspection.mainExecutableRelativePath
            }
        )
        let inventorySelectors = inspection.inventory
            .map(\.relativePath).sorted()
        let objectSelectors = inspection.machOs
            .map(\.relativePath).sorted()
        let sliceSelectors = allSliceSelectors(in: inspection)
        guard profile.contentSHA256 == inspection.sourceContentHash,
              profile.executableSHA256 == main.fileSHA256,
              profile.bundleIdentifier == inspection.bundleIdentifier,
              profile.mainExecutableRelativePath
                == inspection.mainExecutableRelativePath,
              profile.inventorySelectorsSHA256
                == digest(inventorySelectors),
              profile.objectSelectorsSHA256 == digest(objectSelectors),
              profile.sliceSelectorsSHA256 == digest(sliceSelectors),
              profile.inventoryCount == inventorySelectors.count,
              profile.objectCount == objectSelectors.count,
              profile.sliceCount == sliceSelectors.count else {
            throw ProfileError.invalid(
                "source App no longer matches its reviewed full-tree "
                    + "selector identity"
            )
        }
    }

    private func requireEquivalentInput(
        _ lhs: PlayCoverUpstreamAppInspection,
        _ rhs: PlayCoverUpstreamAppInspection
    ) throws {
        guard lhs.sourceContentHash == rhs.sourceContentHash,
              lhs.infoPlistSHA256 == rhs.infoPlistSHA256,
              lhs.bundleIdentifier == rhs.bundleIdentifier,
              lhs.executableName == rhs.executableName,
              lhs.mainExecutableRelativePath
                == rhs.mainExecutableRelativePath,
              lhs.signature == rhs.signature,
              lhs.provisioning == rhs.provisioning,
              lhs.inventory == rhs.inventory,
              lhs.machOs == rhs.machOs else {
            throw ProfileError.invalid(
                "source snapshot is not byte-for-byte equivalent"
            )
        }
    }

    private func requireExactSelectorBijection(
        differences: [PlayCoverDifferentialDifference],
        profile: ExternalProfile
    ) throws {
        let actual = differences.map {
            "\($0.relativePath)\u{0}\($0.field)"
        }
        let expected = profile.allowances.map {
            "\($0.relativePath)\u{0}\($0.field)"
        }
        guard actual.count == profile.allowances.count,
              Set(actual).count == actual.count,
              Set(expected).count == expected.count,
              Set(actual) == Set(expected) else {
            throw ProfileError.invalid(
                "actual difference selectors do not exactly match the "
                    + "reviewed profile"
            )
        }
    }

    private func allSliceSelectors(
        in inspection: PlayCoverUpstreamAppInspection
    ) -> [String] {
        inspection.machOs.flatMap { object in
            var occurrences: [String: Int] = [:]
            return object.allSlices.map { slice in
                let identity =
                    "\(slice.cpuType):\(slice.cpuSubtype)"
                let occurrence = occurrences[identity, default: 0]
                occurrences[identity] = occurrence + 1
                return object.relativePath
                    + "#cpu=\(slice.cpuType),subtype=\(slice.cpuSubtype),"
                    + "occurrence=\(occurrence)"
            }
        }.sorted()
    }

    private func configuredURL(
        _ key: String,
        environment: [String: String],
        isDirectory: Bool
    ) throws -> URL {
        let value = try XCTUnwrap(environment[key])
        guard value.hasPrefix("/") else {
            throw ProfileError.invalid("\(key) must be an absolute path")
        }
        return URL(
            fileURLWithPath: value,
            isDirectory: isDirectory
        ).standardizedFileURL
    }

    private func requireOutsideRepository(
        _ url: URL,
        repositoryRoot: URL,
        label: String
    ) throws {
        let root = repositoryRoot.standardizedFileURL
            .resolvingSymlinksInPath().path
        let candidate = url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL.path
        guard candidate != root,
              !candidate.hasPrefix(root + "/") else {
            throw ProfileError.invalid(
                "\(label) must be outside the checkout"
            )
        }
    }

    private func boundedRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProfileError.invalid(
                "cannot open \(url.lastPathComponent) without following links"
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0,
              status.st_size <= Int64(maximumBytes) else {
            throw ProfileError.invalid(
                "\(url.lastPathComponent) is not a bounded regular file"
            )
        }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw ProfileError.invalid(
                        "\(url.lastPathComponent) could not be read completely"
                    )
                }
            }
        }
        return data
    }

    private func cloneTree(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let result = try Shell.runWithResult(
            "/bin/cp",
            arguments: [
                "-cR",
                source.path,
                destination.path,
            ]
        )
        guard result.exitCode == 0 else {
            throw ProfileError.invalid(
                "source snapshot clone failed: \(result.stderr)"
            )
        }
    }

    @discardableResult
    private func makePrivateDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func executableSuffix(
        from executable: String,
        below container: String
    ) -> String {
        String(executable.dropFirst(container.count + 1))
    }

    private func repositoryRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        return root
    }

    private func digest(_ values: [String]) -> String {
        let data = try! JSONEncoder().encode(values.sorted())
        return sha256(data)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func isLowercaseHex(
        _ value: String,
        count: Int
    ) -> Bool {
        value.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0)
                || (0x61...0x66).contains($0)
        }
    }

    private func minimalProfile(
        allowances: [ExactAllowanceProfile]
    ) -> ExternalProfile {
        let digest = String(repeating: "a", count: 64)
        return ExternalProfile(
            schemaVersion: 1,
            scope: Self.profileScope,
            source: SourceProfile(
                contentSHA256: digest,
                executableSHA256: digest,
                bundleIdentifier: "com.example.fixture",
                mainExecutableRelativePath: "Fixture",
                inventorySelectorsSHA256: digest,
                objectSelectorsSHA256: digest,
                sliceSelectorsSHA256: digest,
                inventoryCount: 1,
                objectCount: 1,
                sliceCount: 1
            ),
            runtime: RuntimeProfile(
                inputTreeSHA256: digest,
                inputExecutableSHA256: digest,
                signedProjectionTreeSHA256: digest,
                signedProjectionExecutableSHA256: digest,
                outputFrameworkRelativePath:
                    "Frameworks/IOSUsePlayRuntime.framework",
                outputExecutableRelativePath:
                    "Frameworks/IOSUsePlayRuntime.framework/"
                        + "Versions/A/IOSUsePlayRuntime"
            ),
            playTools: PlayToolsProfile(
                inputTreeSHA256: digest,
                signedPluginTreeSHA256: digest,
                signedPluginExecutableSHA256: digest,
                outputPluginRelativePath:
                    "PlugIns/AKInterface.bundle",
                outputPluginExecutableRelativePath:
                    "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface"
            ),
            revisions: RevisionProfile(
                playCover:
                    PlayCoverUpstreamEngine.playCoverRevision,
                inject: PlayCoverUpstreamEngine.injectRevision,
                rules: PlayCoverUpstreamEngine.defaultRulesRevision,
                prepare: PlayCoverService.prepareImplementationRevision
            ),
            allowances: allowances
        )
    }
}
