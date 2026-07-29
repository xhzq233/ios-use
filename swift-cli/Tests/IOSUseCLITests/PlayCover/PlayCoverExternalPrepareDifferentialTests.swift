import CryptoKit
import Darwin
import Foundation
@testable import IOSUseCLI
@testable import PlayCoverUpstream
import XCTest

final class PlayCoverExternalPrepareDifferentialTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let identity = makePlayCoverTestSigningIdentity(
            codesignSelector: "-"
        )
        PlayCoverService.signingIdentityResolverOverrideForTesting = {
            _ in identity
        }
        PlayCoverService.rootCodeSignatureInspectorOverrideForTesting = {
            appURL in
            let inspection = try PlayCoverUpstreamEngine.inspect(
                appURL: appURL
            )
            guard let cdHash = inspection.signature.cdHash else {
                throw PlayCoverBackendError.verificationFailed(
                    "test App is missing final root CDHash evidence"
                )
            }
            return makePlayCoverTestRootCodeSignature(
                bundleIdentifier: inspection.bundleIdentifier,
                identity: identity,
                cdHash: cdHash.uppercased()
            )
        }
    }

    override func tearDown() {
        PlayCoverService.signingIdentityResolverOverrideForTesting = nil
        PlayCoverService.rootCodeSignatureInspectorOverrideForTesting = nil
        super.tearDown()
    }

    private static let profileScope = "external-app-structural-v2"

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
        let workRootSHA256: String
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
        let workRootSHA256: String
        let originalSource: OriginalSourceEvidence
        let inputs: InputTreeEvidence
        let differential: PlayCoverDifferentialAttestation
    }

    private struct ExternalCharacterizationReport: Codable, Equatable {
        let schemaVersion: Int
        let scope: String
        let kind: String
        let disposition: String
        let repositoryCommit: String
        let workRootSHA256: String
        let source: SourceProfile
        let sourceState: OriginalSourceEvidence
        let runtime: RuntimeProfile
        let playTools: PlayToolsProfile
        let revisions: RevisionProfile
        let inputs: InputTreeEvidence
        let pinnedOutputSHA256: String
        let iosUseOutputSHA256: String
        let normalizationMode: String
        let differences: [PlayCoverDifferentialDifference]
    }

    private struct ExternalComparison {
        let originalBefore: PlayCoverUpstreamAppInspection
        let snapshotBefore: PlayCoverUpstreamAppInspection
        let pinnedResult: PlayCoverPinnedPrimitivePrepareResult
        let iosUseResult: PlayCoverUpstreamPrepareResult
        let runtimeInputTreeSHA256: String
        let runtimeInputExecutableSHA256: String
        let playToolsInputTreeSHA256: String
        let runtimeSignedProjectionTreeSHA256: String
        let runtimeSignedProjectionExecutableSHA256: String
        let pluginSignedProjectionTreeSHA256: String
        let pluginSignedProjectionExecutableSHA256: String
        let baselines: [PlayCoverDifferentialObjectBaseline]
        let normalization: PlayCoverDifferentialNormalization
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
        try requireWorkRootBinding(
            profile,
            requestedWorkRoot: requestedWorkRoot
        )

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

        let comparison = try await prepareExternalComparison(
            scenario: scenario,
            runtime: runtime,
            playTools: playTools,
            requestedWorkRoot: requestedWorkRoot,
            expectedWorkRootSHA256: profile.workRootSHA256,
            runtimeExecutableRelativePath:
                profile.runtime.outputExecutableRelativePath,
            pluginExecutableRelativePath:
                profile.playTools.outputPluginExecutableRelativePath,
            pinnedBaselineProvenance:
                "external profile \(profileSHA256); pinned "
                + "PlayTools full-tree projection",
            iosUseBaselineProvenance:
                "external profile \(profileSHA256); fresh Runtime "
                + "full-tree projection",
            validateInput: {
                original,
                runtimeTree,
                runtimeExecutable,
                playToolsTree in
                try self.requireSourceProfile(
                    profile.source,
                    matches: original
                )
                guard runtimeTree
                        == profile.runtime.inputTreeSHA256,
                      runtimeExecutable
                        == profile.runtime.inputExecutableSHA256,
                      playToolsTree
                        == profile.playTools.inputTreeSHA256 else {
                    throw ProfileError.invalid(
                        "Runtime or PlayTools full input tree changed"
                    )
                }
            },
            validateProjection: {
                runtimeExecutable,
                runtimeTree,
                pluginExecutable,
                pluginTree in
                guard runtimeExecutable
                        == profile.runtime
                            .signedProjectionExecutableSHA256,
                      runtimeTree
                        == profile.runtime
                            .signedProjectionTreeSHA256,
                      pluginExecutable
                        == profile.playTools
                            .signedPluginExecutableSHA256,
                      pluginTree
                        == profile.playTools.signedPluginTreeSHA256 else {
                    throw ProfileError.invalid(
                        "independent one-sided projection changed"
                    )
                }
            }
        )
        let allowances = profile.allowances.map {
            $0.allowance()
        }
        let differences = try PlayCoverPrepareDifferentialGate.differences(
            pinned: comparison.pinnedResult.prepared,
            iosUse: comparison.iosUseResult.prepared,
            oneSidedBaselines: comparison.baselines,
            normalization: comparison.normalization
        )
        try requireExactSelectorBijection(
            differences: differences,
            profile: profile
        )
        let differential = try PlayCoverPrepareDifferentialGate.attest(
            scope: .externalApp,
            repositoryRoot: repository,
            sourceApp: URL(
                fileURLWithPath: comparison.snapshotBefore.appPath,
                isDirectory: true
            ),
            pinnedResult: comparison.pinnedResult,
            iosUseResult: comparison.iosUseResult,
            allowances: allowances,
            oneSidedBaselines: comparison.baselines,
            normalization: comparison.normalization
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

        let recheck = try recheckExternalInputs(
            comparison,
            runtime: runtime,
            playTools: playTools
        )

        let attestation = ExternalAttestation(
            schemaVersion: 2,
            scope: Self.profileScope,
            result: "pass",
            repositoryCommit: commit,
            profileSHA256: profileSHA256,
            workRootSHA256: profile.workRootSHA256,
            originalSource: OriginalSourceEvidence(
                scenarioSHA256: scenarioSHA256,
                inputContentSHA256:
                    comparison.originalBefore.sourceContentHash,
                snapshotContentSHA256:
                    comparison.snapshotBefore.sourceContentHash,
                recomputedAfterPrepareSHA256:
                    recheck.sourceContentHash,
                unchanged: true
            ),
            inputs: InputTreeEvidence(
                runtimeInputTreeSHA256:
                    comparison.runtimeInputTreeSHA256,
                runtimeSignedProjectionTreeSHA256:
                    comparison.runtimeSignedProjectionTreeSHA256,
                playToolsInputTreeSHA256:
                    comparison.playToolsInputTreeSHA256,
                playToolsSignedPluginTreeSHA256:
                    comparison.pluginSignedProjectionTreeSHA256,
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

    func testConfiguredExternalAppWritesDiagnosticCharacterization()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        let required = [
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_SCENARIO",
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_RUNTIME",
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_PLAYTOOLS",
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_WORK_ROOT",
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_REPORT",
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_COMMIT",
        ]
        guard required.allSatisfy({
            environment[$0]?.isEmpty == false
        }) else {
            throw XCTSkip(
                "external-App characterization inputs are intentionally "
                    + "explicit"
            )
        }

        let scenarioURL = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_SCENARIO",
            environment: environment,
            isDirectory: false
        )
        let runtime = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_RUNTIME",
            environment: environment,
            isDirectory: true
        )
        let playTools = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_PLAYTOOLS",
            environment: environment,
            isDirectory: true
        )
        let requestedWorkRoot = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_WORK_ROOT",
            environment: environment,
            isDirectory: true
        )
        let reportURL = try configuredURL(
            "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_REPORT",
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
            reportURL,
            repositoryRoot: repository,
            label: "report"
        )
        guard !FileManager.default.fileExists(
            atPath: requestedWorkRoot.path
        ), !FileManager.default.fileExists(atPath: reportURL.path) else {
            throw ProfileError.invalid(
                "work root and report must be fresh paths"
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
        let commit = try XCTUnwrap(
            environment[
                "IOS_USE_PLAYCOVER_EXTERNAL_CHARACTERIZATION_COMMIT"
            ]
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
        let requestedWorkRootSHA256 = workRootSHA256(
            requestedWorkRoot
        )

        let comparison = try await prepareExternalComparison(
            scenario: scenario,
            runtime: runtime,
            playTools: playTools,
            requestedWorkRoot: requestedWorkRoot,
            expectedWorkRootSHA256: requestedWorkRootSHA256,
            runtimeExecutableRelativePath:
                "Frameworks/IOSUsePlayRuntime.framework/"
                    + "Versions/A/IOSUsePlayRuntime",
            pluginExecutableRelativePath:
                "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface",
            pinnedBaselineProvenance:
                "supplied PlayTools full-tree signed projection",
            iosUseBaselineProvenance:
                "supplied Runtime full-tree signed projection",
            validateInput: { _, _, _, _ in },
            validateProjection: { _, _, _, _ in }
        )
        let differences =
            try PlayCoverPrepareDifferentialGate.differences(
                pinnedResult: comparison.pinnedResult,
                iosUseResult: comparison.iosUseResult,
                oneSidedBaselines: comparison.baselines,
                normalization: comparison.normalization
            )
        let recheck = try recheckExternalInputs(
            comparison,
            runtime: runtime,
            playTools: playTools
        )

        let report = ExternalCharacterizationReport(
            schemaVersion: 2,
            scope: Self.profileScope,
            kind: "playcover-external-prepare-characterization",
            disposition: "diagnostic-only",
            repositoryCommit: commit,
            workRootSHA256: requestedWorkRootSHA256,
            source: try sourceIdentity(
                comparison.originalBefore
            ),
            sourceState: OriginalSourceEvidence(
                scenarioSHA256: scenarioSHA256,
                inputContentSHA256:
                    comparison.originalBefore.sourceContentHash,
                snapshotContentSHA256:
                    comparison.snapshotBefore.sourceContentHash,
                recomputedAfterPrepareSHA256:
                    recheck.sourceContentHash,
                unchanged: true
            ),
            runtime: RuntimeProfile(
                inputTreeSHA256:
                    comparison.runtimeInputTreeSHA256,
                inputExecutableSHA256:
                    comparison.runtimeInputExecutableSHA256,
                signedProjectionTreeSHA256:
                    comparison.runtimeSignedProjectionTreeSHA256,
                signedProjectionExecutableSHA256:
                    comparison
                        .runtimeSignedProjectionExecutableSHA256,
                outputFrameworkRelativePath:
                    "Frameworks/IOSUsePlayRuntime.framework",
                outputExecutableRelativePath:
                    "Frameworks/IOSUsePlayRuntime.framework/"
                        + "Versions/A/IOSUsePlayRuntime"
            ),
            playTools: PlayToolsProfile(
                inputTreeSHA256:
                    comparison.playToolsInputTreeSHA256,
                signedPluginTreeSHA256:
                    comparison.pluginSignedProjectionTreeSHA256,
                signedPluginExecutableSHA256:
                    comparison.pluginSignedProjectionExecutableSHA256,
                outputPluginRelativePath:
                    "PlugIns/AKInterface.bundle",
                outputPluginExecutableRelativePath:
                    "PlugIns/AKInterface.bundle/"
                        + "Contents/MacOS/AKInterface"
            ),
            revisions: RevisionProfile(
                playCover:
                    PlayCoverPinnedHeadlessInstallerOracle
                        .playCoverRevision,
                inject: PlayCoverUpstreamEngine.injectRevision,
                rules: PlayCoverUpstreamEngine
                    .defaultRulesRevision,
                prepare:
                    PlayCoverService.prepareImplementationRevision
            ),
            inputs: InputTreeEvidence(
                runtimeInputTreeSHA256:
                    comparison.runtimeInputTreeSHA256,
                runtimeSignedProjectionTreeSHA256:
                    comparison.runtimeSignedProjectionTreeSHA256,
                playToolsInputTreeSHA256:
                    comparison.playToolsInputTreeSHA256,
                playToolsSignedPluginTreeSHA256:
                    comparison.pluginSignedProjectionTreeSHA256,
                runtimeUnchanged: true,
                playToolsUnchanged: true
            ),
            pinnedOutputSHA256:
                comparison.pinnedResult.prepared.sourceContentHash,
            iosUseOutputSHA256:
                comparison.iosUseResult.prepared.sourceContentHash,
            normalizationMode: "external-app-managed-paths-v1",
            differences: differences
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        try encoder.encode(report).write(
            to: reportURL,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: reportURL.path
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

    func testExternalProfileRejectsV1Schema() throws {
        let profile = minimalProfile(
            schemaVersion: 1,
            allowances: [minimalAllowance()]
        )
        XCTAssertThrowsError(try validate(profile)) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "schema, scope, or producer revisions changed"
                )
            )
        }
    }

    func testExternalProfileRejectsMalformedWorkRootDigest() throws {
        let profile = minimalProfile(
            workRootSHA256: "ABC",
            allowances: [minimalAllowance()]
        )
        XCTAssertThrowsError(try validate(profile)) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "workRootSHA256 must be a lowercase SHA-256 digest"
                )
            )
        }
    }

    func testExternalProfileRejectsMismatchedWorkRoot() throws {
        let requested = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-external-profile-work-root-requested",
                isDirectory: true
            )
        let profile = minimalProfile(
            workRootSHA256: String(repeating: "b", count: 64),
            allowances: [minimalAllowance()]
        )
        XCTAssertThrowsError(
            try requireWorkRootBinding(
                profile,
                requestedWorkRoot: requested
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "work-root SHA-256 does not match"
                )
            )
        }
    }

    func testExternalProfileAcceptsSameCanonicalWorkRoot() throws {
        let requested = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-external-profile-work-root-same",
                isDirectory: true
            )
        let profile = minimalProfile(
            workRootSHA256: workRootSHA256(requested),
            allowances: [minimalAllowance()]
        )
        XCTAssertNoThrow(
            try requireWorkRootBinding(
                profile,
                requestedWorkRoot: requested
            )
        )
    }

    func testWorkRootDigestMatchesShasumOfCanonicalUTF8Path() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-work-root-digest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: parent)
        }
        let requested = parent.appendingPathComponent(
            "candidate",
            isDirectory: true
        )
        let canonicalPath = parent.resolvingSymlinksInPath()
            .appendingPathComponent("candidate")
            .standardizedFileURL.path
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(canonicalPath.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let shellOutput =
            String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            workRootSHA256(requested),
            shellOutput.split(separator: " ").first.map(String.init)
        )
    }

    private func prepareExternalComparison(
        scenario: Scenario,
        runtime: URL,
        playTools: URL,
        requestedWorkRoot: URL,
        expectedWorkRootSHA256: String,
        runtimeExecutableRelativePath: String,
        pluginExecutableRelativePath: String,
        pinnedBaselineProvenance: String,
        iosUseBaselineProvenance: String,
        validateInput: (
            PlayCoverUpstreamAppInspection,
            String,
            String,
            String
        ) throws -> Void,
        validateProjection: (
            String,
            String,
            String,
            String
        ) throws -> Void
    ) async throws -> ExternalComparison {
        let runtimeFrameworkRelativePath =
            "Frameworks/IOSUsePlayRuntime.framework"
        let pluginBundleRelativePath = "PlugIns/AKInterface.bundle"
        let source = URL(
            fileURLWithPath: scenario.appPath,
            isDirectory: true
        ).standardizedFileURL
        let originalBefore = try PlayCoverUpstreamEngine.inspect(
            appURL: source
        )
        guard originalBefore.bundleIdentifier
                == scenario.bundleIdentifier else {
            throw ProfileError.invalid(
                "scenario bundle identifier does not match source App"
            )
        }
        let runtimeInputTreeSHA256 =
            try PlayCoverService.runtimeBuildHash(
                frameworkPath: runtime.path
            )
        let runtimeInputExecutable = runtime.appendingPathComponent(
            executableSuffix(
                from: runtimeExecutableRelativePath,
                below: runtimeFrameworkRelativePath
            )
        )
        let runtimeInputExecutableSHA256 =
            try PlayCoverUpstreamEngine.inspectMachO(
                at: runtimeInputExecutable,
                relativePath: runtimeExecutableRelativePath
            ).fileSHA256
        let playToolsInputTreeSHA256 =
            try PlayCoverUpstreamEngine.contentHash(appURL: playTools)
        try validateInput(
            originalBefore,
            runtimeInputTreeSHA256,
            runtimeInputExecutableSHA256,
            playToolsInputTreeSHA256
        )

        try FileManager.default.createDirectory(
            at: requestedWorkRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let workRoot = requestedWorkRoot.resolvingSymlinksInPath()
        guard workRootSHA256(workRoot) == expectedWorkRootSHA256 else {
            throw ProfileError.invalid(
                "configured work-root identity changed after creation"
            )
        }
        let sourceSnapshot = workRoot.appendingPathComponent(
            "source-snapshot/Source.app",
            isDirectory: true
        )
        try cloneTree(source, to: sourceSnapshot)
        let snapshotBefore =
            try PlayCoverUpstreamEngine.inspect(appURL: sourceSnapshot)
        try requireEquivalentInput(originalBefore, snapshotBefore)

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
        guard pinnedHome.resolvingSymlinksInPath()
                != iosUseHome.resolvingSymlinksInPath() else {
            throw ProfileError.invalid(
                "managed homes must be fresh and distinct"
            )
        }

        let pinnedOutput = pinnedHome.appendingPathComponent(
            "prepared/Pinned.app",
            isDirectory: true
        )
        let pinnedResult =
            try await PlayCoverPinnedHeadlessInstallerOracle.prepare(
                PlayCoverPinnedPrimitivePrepareOptions(
                    sourceApp: sourceSnapshot,
                    stagingApp: pinnedOutput,
                    managedHome: pinnedHome,
                    bundledPlayToolsFramework: playTools
                )
            )

        let iosUsePaths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": iosUseHome.path]
        )
        let candidateParent = URL(
            fileURLWithPath: iosUsePaths.playcoverPrepared,
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
        let inspectedSource =
            try PlayCoverService.inspectPreparationSource(
                appPath: sourceSnapshot.path
            )
        let plan = try PlayCoverService.makePreparationPlan(
            source: inspectedSource,
            runtimeFrameworkPath: runtime.path
        )
        guard plan.runtimeBuildHash == runtimeInputTreeSHA256 else {
            throw ProfileError.invalid(
                "preparation plan did not bind the supplied Runtime tree"
            )
        }
        let preparedArtifact = try PlayCoverService.prepareArtifact(
            plan: plan,
            outputAppPath: iosUseOutput.path,
            paths: iosUsePaths
        )
        let iosUseResult = try XCTUnwrap(
            preparedArtifact.upstreamResult
        )
        let recomputedIOSUse = try PlayCoverUpstreamEngine.inspect(
            appURL: iosUseOutput
        )
        XCTAssertEqual(iosUseResult.prepared, recomputedIOSUse)

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

        let runtimeInspection =
            try PlayCoverUpstreamEngine.inspectMachO(
                at: runtimeBaselineFramework.appendingPathComponent(
                    executableSuffix(
                        from: runtimeExecutableRelativePath,
                        below: runtimeFrameworkRelativePath
                    )
                ),
                relativePath: runtimeExecutableRelativePath
            )
        let pluginInspection =
            try PlayCoverUpstreamEngine.inspectMachO(
                at: pluginBaselineBundle.appendingPathComponent(
                    executableSuffix(
                        from: pluginExecutableRelativePath,
                        below: pluginBundleRelativePath
                    )
                ),
                relativePath: pluginExecutableRelativePath
            )
        let runtimeSignedProjectionTreeSHA256 =
            try PlayCoverUpstreamEngine.contentHash(
                appURL: runtimeBaselineFramework
            )
        let pluginSignedProjectionTreeSHA256 =
            try PlayCoverUpstreamEngine.contentHash(
                appURL: pluginBaselineBundle
            )
        try validateProjection(
            runtimeInspection.fileSHA256,
            runtimeSignedProjectionTreeSHA256,
            pluginInspection.fileSHA256,
            pluginSignedProjectionTreeSHA256
        )

        guard
            try PlayCoverUpstreamEngine.contentHash(
                appURL: iosUseOutput.appendingPathComponent(
                    runtimeFrameworkRelativePath,
                    isDirectory: true
                )
            ) == runtimeSignedProjectionTreeSHA256,
            try PlayCoverUpstreamEngine.contentHash(
                appURL: pinnedOutput.appendingPathComponent(
                    pluginBundleRelativePath,
                    isDirectory: true
                )
            ) == pluginSignedProjectionTreeSHA256
        else {
            throw ProfileError.invalid(
                "prepared one-sided tree is not its supplied projection"
            )
        }

        let baselines = [
            PlayCoverDifferentialObjectBaseline(
                id: "external-pinned-akinterface-input",
                side: .pinned,
                relativePath: pluginExecutableRelativePath,
                inspection: pluginInspection,
                sourceSHA256: pluginInspection.fileSHA256,
                provenance: pinnedBaselineProvenance
            ),
            PlayCoverDifferentialObjectBaseline(
                id: "external-ios-use-runtime-input",
                side: .iosUse,
                relativePath: runtimeExecutableRelativePath,
                inspection: runtimeInspection,
                sourceSHA256: runtimeInspection.fileSHA256,
                provenance: iosUseBaselineProvenance
            ),
        ]
        let normalization =
            try PlayCoverDifferentialNormalization.externalApp(
                pinnedManagedHome: pinnedHome,
                iosUseManagedHome: iosUseHome
        )
        return ExternalComparison(
            originalBefore: originalBefore,
            snapshotBefore: snapshotBefore,
            pinnedResult: pinnedResult,
            iosUseResult: iosUseResult,
            runtimeInputTreeSHA256: runtimeInputTreeSHA256,
            runtimeInputExecutableSHA256:
                runtimeInputExecutableSHA256,
            playToolsInputTreeSHA256: playToolsInputTreeSHA256,
            runtimeSignedProjectionTreeSHA256:
                runtimeSignedProjectionTreeSHA256,
            runtimeSignedProjectionExecutableSHA256:
                runtimeInspection.fileSHA256,
            pluginSignedProjectionTreeSHA256:
                pluginSignedProjectionTreeSHA256,
            pluginSignedProjectionExecutableSHA256:
                pluginInspection.fileSHA256,
            baselines: baselines,
            normalization: normalization
        )
    }

    private func recheckExternalInputs(
        _ comparison: ExternalComparison,
        runtime: URL,
        playTools: URL
    ) throws -> PlayCoverUpstreamAppInspection {
        let originalAfter = try PlayCoverUpstreamEngine.inspect(
            appURL: URL(
                fileURLWithPath: comparison.originalBefore.appPath,
                isDirectory: true
            )
        )
        let snapshotAfter = try PlayCoverUpstreamEngine.inspect(
            appURL: URL(
                fileURLWithPath: comparison.snapshotBefore.appPath,
                isDirectory: true
            )
        )
        try requireEquivalentInput(
            comparison.originalBefore,
            originalAfter
        )
        try requireEquivalentInput(
            comparison.snapshotBefore,
            snapshotAfter
        )
        guard
            comparison.pinnedResult.sourceBefore
                == comparison.snapshotBefore,
            comparison.iosUseResult.sourceBefore
                == comparison.snapshotBefore,
            comparison.pinnedResult.sourceHashAfterPrepare
                == comparison.snapshotBefore.sourceContentHash,
            comparison.iosUseResult.sourceHashAfterPrepare
                == comparison.snapshotBefore.sourceContentHash
        else {
            throw ProfileError.invalid(
                "prepare results did not preserve the fresh source snapshot"
            )
        }
        let runtimeAfter =
            try PlayCoverService.runtimeBuildHash(
                frameworkPath: runtime.path
            )
        let playToolsAfter =
            try PlayCoverUpstreamEngine.contentHash(appURL: playTools)
        guard runtimeAfter == comparison.runtimeInputTreeSHA256,
              playToolsAfter
                == comparison.playToolsInputTreeSHA256 else {
            throw ProfileError.invalid(
                "Runtime or PlayTools input changed during prepare"
            )
        }
        return originalAfter
    }

    private func validate(_ profile: ExternalProfile) throws {
        guard profile.schemaVersion == 2,
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
        guard isLowercaseHex(profile.workRootSHA256, count: 64) else {
            throw ProfileError.invalid(
                "workRootSHA256 must be a lowercase SHA-256 digest"
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

    private func requireWorkRootBinding(
        _ profile: ExternalProfile,
        requestedWorkRoot: URL
    ) throws {
        guard profile.workRootSHA256
                == workRootSHA256(requestedWorkRoot) else {
            throw ProfileError.invalid(
                "reviewed profile work-root SHA-256 does not match "
                    + "the configured canonical work root"
            )
        }
    }

    private func requireSourceProfile(
        _ profile: SourceProfile,
        matches inspection: PlayCoverUpstreamAppInspection
    ) throws {
        guard profile == (try sourceIdentity(inspection)) else {
            throw ProfileError.invalid(
                "source App no longer matches its reviewed full-tree "
                    + "selector identity"
            )
        }
    }

    private func sourceIdentity(
        _ inspection: PlayCoverUpstreamAppInspection
    ) throws -> SourceProfile {
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
        return SourceProfile(
            contentSHA256: inspection.sourceContentHash,
            executableSHA256: main.fileSHA256,
            bundleIdentifier: inspection.bundleIdentifier,
            mainExecutableRelativePath:
                inspection.mainExecutableRelativePath,
            inventorySelectorsSHA256: digest(inventorySelectors),
            objectSelectorsSHA256: digest(objectSelectors),
            sliceSelectorsSHA256: digest(sliceSelectors),
            inventoryCount: inventorySelectors.count,
            objectCount: objectSelectors.count,
            sliceCount: sliceSelectors.count
        )
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
                // The wrapper's umask protects the private work root, but the
                // snapshot itself must retain every source inventory mode.
                "-cRp",
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

    private func workRootSHA256(_ requestedWorkRoot: URL) -> String {
        let canonicalCandidate = requestedWorkRoot
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(requestedWorkRoot.lastPathComponent)
            .standardizedFileURL
        return sha256(Data(canonicalCandidate.path.utf8))
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
        schemaVersion: Int = 2,
        workRootSHA256: String = String(repeating: "a", count: 64),
        allowances: [ExactAllowanceProfile]
    ) -> ExternalProfile {
        let digest = String(repeating: "a", count: 64)
        return ExternalProfile(
            schemaVersion: schemaVersion,
            scope: Self.profileScope,
            workRootSHA256: workRootSHA256,
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

    private func minimalAllowance() -> ExactAllowanceProfile {
        ExactAllowanceProfile(
            id: "reviewed",
            relativePath: "Fixture",
            field: "inventory.size",
            pinnedValue: "1",
            iosUseValue: "2",
            reason: "reviewed reason",
            pinnedSymbol: "Pinned.symbol",
            iosUseSymbol: "IOSUse.symbol"
        )
    }
}
