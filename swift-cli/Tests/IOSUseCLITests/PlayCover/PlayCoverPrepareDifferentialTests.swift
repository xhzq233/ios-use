import Foundation
@testable import PlayCoverUpstream
import XCTest
@testable import IOSUseCLI

final class PlayCoverPrepareDifferentialTests: XCTestCase {
    private enum HermeticOneSidedGoldenV1 {
        static let manifestID = "playcover-hermetic-one-sided-v1"
        static let runtimeSHA256 =
            "119fa7707e50c05fd7157223ab553af1140ee9ff437126c0a"
                + "2c2d00b853d2cd1"
        static let pluginSHA256 =
            "70af94bb12ace93bda3d29348ba4d209761832142108a28fa"
                + "5e5c7664e1771bf"
    }

    func testVendoredPlayAppSigningAuthorityIsOrderedAndExplicitlyExcluded()
        throws
    {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryRoot.deleteLastPathComponent()
        }
        let playAppURL = repositoryRoot.appendingPathComponent(
            "ThirdParty/PlayCover/PlayCover/Model/PlayApp.swift"
        )
        let source = try String(contentsOf: playAppURL, encoding: .utf8)
        let signStart = try XCTUnwrap(
            source.range(of: "    func sign() {")
        )
        let signEnd = try XCTUnwrap(
            source.range(
                of: "\n// MARK: - Policies",
                range: signStart.lowerBound..<source.endIndex
            )
        )
        let signBody = source[signStart.lowerBound..<signEnd.lowerBound]
        let compose = try XCTUnwrap(
            signBody.range(
                of: "let conf = try Entitlements.composeEntitlements(self)"
            )
        )
        let store = try XCTUnwrap(
            signBody.range(of: "try conf.store(tmpEnts)")
        )
        let rootSign = try XCTUnwrap(
            signBody.range(
                of: "try Shell.signAppWith("
                    + "executable, entitlements: tmpEnts)"
            )
        )
        XCTAssertLessThan(compose.lowerBound, store.lowerBound)
        XCTAssertLessThan(store.lowerBound, rootSign.lowerBound)

        let package = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "ThirdParty/PlayCover/Package.swift"
            ),
            encoding: .utf8
        )
        let exactExclusionBlock =
            "            exclude: [\n"
            + "                \"Model/PlayApp.swift\",\n"
            + "                \"Utils/Extensions/"
            + "PlayAppExtensions.swift\",\n"
            + "            ],\n"
            + "            sources: ["
        XCTAssertEqual(
            package.components(
                separatedBy: exactExclusionBlock
            ).count - 1,
            1,
            "both pinned GUI authorities must remain in the exact "
                + "exclude block immediately before sources"
        )
        XCTAssertEqual(
            package.components(
                separatedBy: "\"Model/PlayApp.swift\""
            ).count - 1,
            1,
            "PlayApp.swift must be named only by the explicit GUI exclusion"
        )
        XCTAssertEqual(
            package.components(
                separatedBy:
                    "\"Utils/Extensions/PlayAppExtensions.swift\""
            ).count - 1,
            1,
            "PlayAppExtensions.swift must be named only by the "
                + "explicit GUI exclusion"
        )
        XCTAssertTrue(
            PlayCoverPinnedHeadlessInstallerOracle
                .adapterBoundaryEvidence
                .contains {
                    $0.contains("PlayApp.sign")
                        && $0.contains("Entitlements.composeEntitlements")
                        && $0.contains("Shell.signAppWith")
                        && $0.contains("root last")
                }
        )
    }

    func testPinnedOracleUsesCanonicalRelativePathsForSymlinkedSourceAncestor()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-differential-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeSourceFixture(in: root)
        let sourceParent = source
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let aliasParent = root.appendingPathComponent(
            "source-parent-alias",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasParent,
            withDestinationURL: sourceParent
        )
        let aliasedSource = aliasParent.appendingPathComponent(
            "Source/Fixture.app",
            isDirectory: true
        )
        let managedHome = root.appendingPathComponent(
            "pinned-home",
            isDirectory: true
        )
        try makePrivateDirectory(managedHome)
        let staging = managedHome.appendingPathComponent(
            "prepared/Pinned.app",
            isDirectory: true
        )

        let result = try await PlayCoverPinnedPrimitiveCharacterization.prepare(
            PlayCoverPinnedPrimitivePrepareOptions(
                sourceApp: aliasedSource,
                stagingApp: staging,
                managedHome: managedHome
            )
        )

        XCTAssertEqual(
            Set(result.convertedMachOs),
            Set(result.sourceBefore.machOs.map(\.relativePath))
        )
        XCTAssertEqual(
            result.sourceBefore.sourceContentHash,
            result.sourceHashAfterPrepare
        )
    }

    func testPinnedHeadlessInstallerOracleAndIOSUsePrepareHaveOnlyRecordedDifferences()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-differential-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeSourceFixture(in: root)
        let runtime = try makeCatalystRuntimeFramework(in: root)
        let playTools = try makePinnedPlayToolsFramework(in: root)
        let runtimeRelativePath =
            "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime"
        let pluginRelativePath =
            "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface"
        let runtimeBaselineInspection =
            try PlayCoverUpstreamEngine.inspectMachO(
                at: runtime.appendingPathComponent("IOSUsePlayRuntime"),
                relativePath: runtimeRelativePath
            )
        let pluginBaselineInspection =
            try PlayCoverUpstreamEngine.inspectMachO(
                at: playTools.appendingPathComponent(
                    "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface"
                ),
                relativePath: pluginRelativePath
            )
        try requireGoldenDigest(
            runtimeBaselineInspection.fileSHA256,
            expected: HermeticOneSidedGoldenV1.runtimeSHA256,
            name: "fixture Runtime"
        )
        try requireGoldenDigest(
            pluginBaselineInspection.fileSHA256,
            expected: HermeticOneSidedGoldenV1.pluginSHA256,
            name: "fixture AKInterface plugin"
        )
        let baselines = [
            PlayCoverDifferentialObjectBaseline(
                id: "pinned-akinterface-input",
                side: .pinned,
                relativePath: pluginRelativePath,
                inspection: pluginBaselineInspection,
                sourceSHA256: HermeticOneSidedGoldenV1.pluginSHA256,
                provenance:
                    HermeticOneSidedGoldenV1.manifestID
                    + "; fixture PlayTools.framework resource consumed by "
                    + "PlayTools.installPluginInIPA"
            ),
            PlayCoverDifferentialObjectBaseline(
                id: "ios-use-runtime-input",
                side: .iosUse,
                relativePath: runtimeRelativePath,
                inspection: runtimeBaselineInspection,
                sourceSHA256: HermeticOneSidedGoldenV1.runtimeSHA256,
                provenance:
                    HermeticOneSidedGoldenV1.manifestID
                    + "; fixture Runtime framework passed to "
                    + "PlayCoverService.prepare"
            ),
        ]
        let sourceHash = try PlayCoverUpstreamEngine.contentHash(
            appURL: source
        )

        let pinnedHome = root.appendingPathComponent(
            "pinned-home",
            isDirectory: true
        )
        try makePrivateDirectory(pinnedHome)
        let pinnedOutput = pinnedHome.appendingPathComponent(
            "prepared/Pinned.app",
            isDirectory: true
        )
        let pinned = try await PlayCoverPinnedHeadlessInstallerOracle.prepare(
            PlayCoverPinnedPrimitivePrepareOptions(
                sourceApp: source,
                stagingApp: pinnedOutput,
                managedHome: pinnedHome,
                bundledPlayToolsFramework: playTools
            )
        )

        let iosUseHome = root.appendingPathComponent(
            "ios-use-home",
            isDirectory: true
        )
        try makePrivateDirectory(iosUseHome)
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": iosUseHome.path]
        )
        let candidateParent = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).appendingPathComponent("differential", isDirectory: true)
        try makePrivateDirectory(candidateParent)
        let candidateOutput = candidateParent.appendingPathComponent(
            "IOSUse.app",
            isDirectory: true
        )
        let plan = try PlayCoverService.makePreparationPlan(
            source: PlayCoverService.inspectPreparationSource(
                appPath: source.path
            ),
            runtimeFrameworkPath: runtime.path
        )
        let preparedArtifact = try PlayCoverService.prepareMeasured(
            plan: plan,
            outputAppPath: candidateOutput.path,
            paths: paths
        )
        let manifest = preparedArtifact.manifest
        let iosUseResult = try XCTUnwrap(
            preparedArtifact.upstreamResult
        )
        let iosUse = try PlayCoverUpstreamEngine.inspect(
            appURL: candidateOutput
        )
        XCTAssertEqual(iosUseResult.prepared, iosUse)

        XCTAssertEqual(
            PlayCoverPinnedHeadlessInstallerOracle.referenceLineage,
            "pinned-installer-headless-adapter;"
                + "exact-playtools-install-in-ipa;"
                + "independent-of-ios-use-prepare"
        )
        XCTAssertEqual(
            PlayCoverPinnedHeadlessInstallerOracle.playCoverRevision,
            "7190cc9ce57c8dee0e222918468f2579acc95e1b"
        )
        XCTAssertEqual(
            PlayCoverUpstreamEngine.playCoverRevision,
            "7190cc9ce57c8dee0e222918468f2579acc95e1b"
        )
        let expectedPinnedTrace = [
            "Installer.saveEntitlements",
            "Installer.resolveValidMachOs",
        ] + pinned.convertedMachOs.map {
            "Macho.isMachoEncrypted[\($0)]"
        } + pinned.convertedMachOs.flatMap {
            [
                "Macho.convertMacho[\($0)]",
                "Shell.signMacho[\($0)]",
            ]
        } + [
            "PlayTools.installInIPA",
            "Inject.injectMachO (called by PlayTools.installInIPA)",
            "PlayTools.installPluginInIPA",
            "Shell.signMacho(AKInterface.bundle)",
            "Shell.signApp(--deep --preserve-metadata=entitlements)",
            "AppInfo.applicationCategoryType(default:.none)",
            "FileManager.setAttributes(mainExecutable,0755)",
            "Installer.removeMobileProvision",
            "AppInfo.assert(minimumVersion:)",
            "PlayApp.sign adapter -> Entitlements.composeEntitlements",
            "PlayApp.sign adapter -> Shell.signAppWith(--deep)",
            "IPA.removeQuarantine operation (/usr/bin/xattr)",
        ]
        XCTAssertEqual(
            pinned.executedPinnedSymbols,
            expectedPinnedTrace
        )
        XCTAssertEqual(
            Set(pinned.convertedMachOs),
            Set(pinned.sourceBefore.machOs.map(\.relativePath))
        )
        XCTAssertEqual(
            pinned.signingOrder,
            pinned.convertedMachOs + ["."]
        )
        let composeIndex = try XCTUnwrap(
            pinned.executedPinnedSymbols.firstIndex(
                of: "PlayApp.sign adapter -> "
                    + "Entitlements.composeEntitlements"
            )
        )
        let rootSignIndex = try XCTUnwrap(
            pinned.executedPinnedSymbols.firstIndex(
                of: "PlayApp.sign adapter -> "
                    + "Shell.signAppWith(--deep)"
            )
        )
        XCTAssertLessThan(composeIndex, rootSignIndex)
        XCTAssertEqual(pinned.signingOrder.last, ".")
        XCTAssertEqual(
            manifest.signingOrder,
            [
                "Frameworks/Fat64Fixture",
                "Frameworks/libswiftUIKit.dylib",
                "Frameworks/FixtureKit.framework",
                "Frameworks/IOSUsePlayRuntime.framework",
                "PlugIns/FixtureExtension.appex",
                ".",
            ],
            "ios-use must sign loose children and nested bundles before root"
        )
        XCTAssertEqual(
            manifest.entitlementDiff.removedFromOriginal,
            [
                "application-identifier",
                "aps-environment",
                "com.apple.developer.associated-domains",
                "com.apple.developer.icloud-container-identifiers",
                "com.apple.developer.team-identifier",
                "com.apple.security.application-groups",
                "keychain-access-groups",
            ]
        )
        XCTAssertFalse(
            manifest.entitlementDiff.playCoverBaseline.isEmpty,
            "the root signature must retain the PlayCover composer baseline"
        )
        XCTAssertFalse(
            PlayCoverPinnedHeadlessInstallerOracle
                .adapterBoundaryEvidence.isEmpty
        )
        XCTAssertEqual(pinned.sourceHashAfterPrepare, sourceHash)
        XCTAssertEqual(manifest.sourceHashAfterPreparation, sourceHash)
        XCTAssertEqual(
            try PlayCoverUpstreamEngine.contentHash(appURL: source),
            sourceHash
        )
        let sourceMainInventory = try XCTUnwrap(
            pinned.sourceBefore.inventory.first {
                $0.relativePath == "Fixture"
            }
        )
        let pinnedMainInventory = try XCTUnwrap(
            pinned.prepared.inventory.first {
                $0.relativePath == "Fixture"
            }
        )
        let iosUseMainInventory = try XCTUnwrap(
            iosUse.inventory.first {
                $0.relativePath == "Fixture"
            }
        )
        XCTAssertEqual(sourceMainInventory.posixPermissions, 0o700)
        XCTAssertEqual(pinnedMainInventory.posixPermissions, 0o755)
        XCTAssertEqual(iosUseMainInventory.posixPermissions, 0o755)
        let sourceInfo = try infoDictionary(
            source.appendingPathComponent("Info.plist")
        )
        let pinnedInfo = try infoDictionary(
            pinnedOutput.appendingPathComponent("Info.plist")
        )
        let iosUseInfo = try infoDictionary(
            candidateOutput.appendingPathComponent("Info.plist")
        )
        XCTAssertEqual(
            sourceInfo["LSApplicationCategoryType"] as? String,
            "public.app-category.games"
        )
        XCTAssertEqual(sourceInfo["MinimumOSVersion"] as? String, "17.0")
        XCTAssertNil(pinnedInfo["LSApplicationCategoryType"])
        XCTAssertNil(iosUseInfo["LSApplicationCategoryType"])
        XCTAssertEqual(
            pinnedInfo["MinimumOSVersion"] as? String,
            "11"
        )
        XCTAssertEqual(
            iosUseInfo["MinimumOSVersion"] as? String,
            "11"
        )
        XCTAssertTrue(
            NSDictionary(dictionary: pinnedInfo).isEqual(
                to: iosUseInfo
            )
        )
        XCTAssertEqual(
            pinned.prepared.infoPlistSHA256,
            iosUse.infoPlistSHA256
        )
        XCTAssertFalse(pinned.prepared.provisioning.present)
        XCTAssertFalse(iosUse.provisioning.present)
        for output in [pinnedOutput, candidateOutput] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: output.appendingPathComponent(
                        "embedded.mobileprovision"
                    ).path
                )
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: output.appendingPathComponent(
                        "Frameworks/FixtureKit.framework/asset.dat"
                    )
                ),
                Data("sealed-framework-resource".utf8)
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: output.appendingPathComponent(
                        "PlugIns/FixtureExtension.appex/asset.dat"
                    )
                ),
                Data("sealed-extension-resource".utf8)
            )
            XCTAssertThrowsError(
                try run(
                    "/usr/bin/xattr",
                    [
                        "-p",
                        "com.apple.quarantine",
                        output.path,
                    ]
                )
            )
        }
        XCTAssertNoThrow(
            try run(
                "/usr/bin/xattr",
                [
                    "-p",
                    "com.apple.quarantine",
                    source.path,
                ]
            )
        )
        XCTAssertEqual(
            try Data(
                contentsOf: pinnedOutput.appendingPathComponent(
                    "en.lproj/Playtools.strings"
                )
            ),
            Data("\"fixture\" = \"pinned\";\n".utf8)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pinnedOutput.appendingPathComponent(
                    "PlugIns/AKInterface.bundle/Contents/Info.plist"
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: candidateOutput.appendingPathComponent(
                    "Frameworks/IOSUsePlayRuntime.framework/Info.plist"
                ).path
            )
        )
        XCTAssertEqual(
            pinned.sourceBefore.machOs.first {
                $0.relativePath == "Fixture"
            }?.container,
            .fat
        )
        let sourceMain = try XCTUnwrap(
            pinned.sourceBefore.machOs.first {
                $0.relativePath == "Fixture"
            }
        )
        XCTAssertEqual(sourceMain.allSlices.count, 2)
        XCTAssertEqual(
            Set(sourceMain.allSlices.map(\.cpuType)),
            [0x0100_000c, 0x0100_0007]
        )
        let sourceFat64 = try XCTUnwrap(
            pinned.sourceBefore.machOs.first {
                $0.relativePath == "Frameworks/Fat64Fixture"
            }
        )
        XCTAssertEqual(sourceFat64.container, .fat64)
        XCTAssertEqual(sourceFat64.allSlices.count, 2)
        XCTAssertEqual(
            Set(sourceFat64.allSlices.map(\.cpuType)),
            [0x0100_000c, 0x0100_0007]
        )
        XCTAssertEqual(pinned.prepared.machOs.count, 6)
        XCTAssertEqual(iosUse.machOs.count, 6)
        XCTAssertEqual(
            pinned.prepared.machOs.first {
                $0.relativePath == "Frameworks/Fat64Fixture"
            }?.container,
            .thin
        )
        XCTAssertEqual(
            iosUse.machOs.first {
                $0.relativePath == "Frameworks/Fat64Fixture"
            }?.container,
            .thin
        )
        let pinnedMain = try XCTUnwrap(
            pinned.prepared.machOs.first {
                $0.relativePath == "Fixture"
            }
        )
        let iosUseMain = try XCTUnwrap(
            iosUse.machOs.first {
                $0.relativePath == "Fixture"
            }
        )
        XCTAssertEqual(pinnedMain.container, .thin)
        XCTAssertEqual(iosUseMain.container, .thin)
        XCTAssertEqual(pinnedMain.allSlices.count, 1)
        XCTAssertEqual(iosUseMain.allSlices.count, 1)
        XCTAssertEqual(
            pinnedMain.platform,
            PlayCoverUpstreamEngine.platformMacCatalyst
        )
        XCTAssertEqual(iosUseMain.platform, pinnedMain.platform)
        XCTAssertEqual(
            pinnedMain.rpaths,
            ["@executable_path/Frameworks"]
        )
        XCTAssertEqual(iosUseMain.rpaths, pinnedMain.rpaths)
        for main in [pinnedMain, iosUseMain] {
            XCTAssertTrue(main.signature.isSigned)
            XCTAssertTrue(main.signature.isValid)
            let sliceSignature = try XCTUnwrap(
                main.allSlices.first
            ).signature
            XCTAssertNotNil(sliceSignature.superBlobLength)
            XCTAssertNotNil(sliceSignature.superBlobStructureSHA256)
            XCTAssertNotNil(sliceSignature.superBlobPaddingSHA256)
            XCTAssertFalse(sliceSignature.embeddedSlots.isEmpty)
            let primaryCodeDirectory = try XCTUnwrap(
                sliceSignature.embeddedSlots.first {
                    $0.type == 0
                }?.codeDirectory
            )
            XCTAssertEqual(primaryCodeDirectory.hashType, 2)
            XCTAssertEqual(primaryCodeDirectory.hashSize, 32)
            XCTAssertNotNil(sliceSignature.derEntitlementsPlist)
            XCTAssertTrue(
                main.dependencies.contains(
                    "/System/iOSSupport/usr/lib/swift/"
                        + "libswiftUIKit.dylib"
                )
            )
            XCTAssertFalse(
                main.dependencies.contains(
                    "@rpath/libswiftUIKit.dylib"
                )
            )
            XCTAssertEqual(
                main.loadCommands.count,
                Int(main.commandCount)
            )
        }
        let pinnedPlugin = try XCTUnwrap(
            pinned.prepared.machOs.first {
                $0.relativePath
                    == pluginRelativePath
            }
        )
        XCTAssertEqual(pinnedPlugin.platform, 1)
        XCTAssertTrue(pinnedPlugin.signature.isSigned)
        XCTAssertTrue(pinnedPlugin.signature.isValid)
        XCTAssertEqual(
            pinnedPlugin.loadCommands.count,
            Int(pinnedPlugin.commandCount)
        )

        let normalization =
            try PlayCoverDifferentialNormalization.hermeticFixture(
                pinnedManagedHome: pinnedHome,
                iosUseManagedHome: iosUseHome
            )
        let actual = try PlayCoverPrepareDifferentialGate.differences(
            pinned: pinned.prepared,
            iosUse: iosUse,
            oneSidedBaselines: baselines,
            normalization: normalization
        )
        let allowances = makeAllowances()
        let report = try PlayCoverPrepareDifferentialGate.enforce(
            pinned: pinned.prepared,
            iosUse: iosUse,
            allowances: allowances,
            oneSidedBaselines: baselines,
            normalization: normalization
        )
        let attestation = try PlayCoverPrepareDifferentialGate.attest(
            repositoryRoot: repositoryRoot(),
            sourceApp: source,
            pinnedResult: pinned,
            iosUseResult: iosUseResult,
            allowances: allowances,
            oneSidedBaselines: baselines,
            normalization: normalization
        )

        XCTAssertEqual(report.differences, actual)
        XCTAssertEqual(report.differences.count, allowances.count)
        XCTAssertEqual(
            Set(report.consumedAllowanceIDs),
            Set(allowances.map(\.id))
        )
        XCTAssertFalse(report.differences.isEmpty)
        XCTAssertEqual(
            Set(report.consumedBaselineIDs),
            ["pinned-akinterface-input", "ios-use-runtime-input"]
        )
        XCTAssertTrue(
            report.comparedSliceSelectors.contains {
                $0.hasPrefix(pluginRelativePath + "#cpu=")
            }
        )
        XCTAssertTrue(
            report.comparedSliceSelectors.contains {
                $0.hasPrefix(runtimeRelativePath + "#cpu=")
            }
        )
        XCTAssertTrue(
            report.differences.contains {
                $0.field.contains(".loadCommands[")
            }
        )
        XCTAssertTrue(
            report.differences.contains {
                $0.field.contains(".entitlements.")
            }
        )
        XCTAssertTrue(
            report.differences.contains {
                $0.field.contains(".signature.")
            }
        )

        let commonObjectSelectors = [
            "Fixture",
            "Frameworks/Fat64Fixture",
            "Frameworks/FixtureKit.framework/FixtureKit",
            "Frameworks/libswiftUIKit.dylib",
            "PlugIns/FixtureExtension.appex/FixtureExtension",
        ]
        let expectedPinnedObjects = (
            commonObjectSelectors + [pluginRelativePath]
        ).sorted()
        let expectedIOSUseObjects = (
            commonObjectSelectors + [runtimeRelativePath]
        ).sorted()
        func arm64SliceSelectors(_ paths: [String]) -> [String] {
            paths.map {
                $0 + "#cpu=16777228,subtype=0,occurrence=0"
            }.sorted()
        }
        let expectedPinnedSlices = arm64SliceSelectors(
            expectedPinnedObjects
        )
        let expectedIOSUseSlices = arm64SliceSelectors(
            expectedIOSUseObjects
        )
        let expectedMatchedSlices = Array(
            Set(expectedPinnedSlices).union(expectedIOSUseSlices)
        ).sorted()
        XCTAssertEqual(attestation.schemaVersion, 1)
        XCTAssertEqual(attestation.scope, .hermeticFixture)
        XCTAssertEqual(attestation.result, "pass")
        XCTAssertEqual(
            attestation.implementation.algorithm,
            "embedded-source-closure-plus-loaded-xctest-inode-sha256-v2"
        )
        XCTAssertEqual(
            attestation.implementation.relativeSourcePaths,
            [
                "ThirdParty/PlayCover/Package.resolved",
                "ThirdParty/PlayCover/Package.swift",
                "ThirdParty/PlayCover/PROVENANCE.md",
                "ThirdParty/PlayCover/PlayCover/AppInstaller/"
                    + "Installer.swift",
                "ThirdParty/PlayCover/PlayCover/Headless/"
                    + "HeadlessSupport.swift",
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
                "ThirdParty/PlayCover/PlayCover/Utils/"
                    + "Entitlements.swift",
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
                "swift-cli/Package.resolved",
                "swift-cli/Package.swift",
                "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/"
                    + "PlayCoverLaunchCrashCut.swift",
                "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/"
                    + "PlayCoverService.swift",
                "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/"
                    + "PlayCoverStartTiming.swift",
                "swift-cli/Tests/IOSUseCLITests/PlayCover/"
                    + "PlayCoverExternalPrepareDifferentialTests.swift",
                "swift-cli/Tests/IOSUseCLITests/PlayCover/"
                    + "PlayCoverPrepareDifferentialTests.swift",
            ].sorted()
        )
        XCTAssertEqual(attestation.implementation.contentSHA256.count, 64)
        XCTAssertEqual(
            attestation.implementation.embeddedSourceClosureSHA256,
            attestation.implementation.contentSHA256
        )
        XCTAssertEqual(
            attestation.implementation.testExecutableSHA256.count,
            64
        )
        XCTAssertGreaterThan(
            attestation.implementation.testExecutableSize,
            0
        )
        XCTAssertGreaterThan(
            attestation.implementation.testExecutableDevice,
            0
        )
        XCTAssertGreaterThan(
            attestation.implementation.testExecutableInode,
            0
        )
        XCTAssertEqual(
            attestation.normalization.mode,
            .hermeticFixtureManagedPathsV1
        )
        XCTAssertEqual(
            attestation.source,
            PlayCoverDifferentialSourceEvidence(
                inputContentSHA256: sourceHash,
                pinnedHashAfterPrepare: sourceHash,
                iosUseHashAfterPrepare: sourceHash,
                recomputedAtAttestationSHA256: sourceHash,
                unchanged: true
            )
        )
        XCTAssertEqual(
            attestation.pinnedOutput.contentSHA256,
            pinned.prepared.sourceContentHash
        )
        XCTAssertEqual(
            attestation.pinnedOutput.playCoverRevision,
            PlayCoverPinnedHeadlessInstallerOracle.playCoverRevision
        )
        XCTAssertEqual(
            attestation.pinnedOutput.preparationLineage,
            .pinnedHeadlessInstallerOracle
        )
        XCTAssertEqual(
            attestation.pinnedOutput.consumedBaselineIDs,
            ["pinned-akinterface-input"]
        )
        XCTAssertEqual(
            attestation.iosUseOutput.contentSHA256,
            iosUse.sourceContentHash
        )
        XCTAssertEqual(
            attestation.iosUseOutput.playCoverRevision,
            PlayCoverUpstreamEngine.playCoverRevision
        )
        XCTAssertEqual(
            attestation.iosUseOutput.preparationLineage,
            .iosUseServiceAndUpstreamEngine
        )
        XCTAssertEqual(
            attestation.iosUseOutput.consumedBaselineIDs,
            ["ios-use-runtime-input"]
        )
        XCTAssertEqual(
            attestation.selectorCoverage.pinnedObjectSelectors,
            expectedPinnedObjects
        )
        XCTAssertEqual(
            attestation.selectorCoverage.iosUseObjectSelectors,
            expectedIOSUseObjects
        )
        XCTAssertEqual(
            attestation.selectorCoverage.pinnedSliceSelectors,
            expectedPinnedSlices
        )
        XCTAssertEqual(
            attestation.selectorCoverage.iosUseSliceSelectors,
            expectedIOSUseSlices
        )
        XCTAssertEqual(
            attestation.selectorCoverage.objects.map(\.selector),
            Array(
                Set(expectedPinnedObjects).union(expectedIOSUseObjects)
            ).sorted()
        )
        XCTAssertEqual(
            attestation.selectorCoverage.matchedSlices.map(\.selector),
            expectedMatchedSlices
        )
        XCTAssertEqual(
            attestation.selectorCoverage.matchedSlices.map(
                \.checkedFieldFamilies
            ),
            Array(
                repeating: PlayCoverDifferentialFieldFamily.allCases,
                count: expectedMatchedSlices.count
            )
        )
        XCTAssertEqual(
            attestation.appCoverage.checkedFieldFamilies,
            PlayCoverDifferentialAppFieldFamily.allCases
        )
        let expectedInventorySelectors = Array(
            Set(pinned.prepared.inventory.map(\.relativePath))
                .union(iosUse.inventory.map(\.relativePath))
        ).sorted()
        XCTAssertEqual(
            attestation.appCoverage.inventoryEntries.map(\.selector),
            expectedInventorySelectors
        )
        XCTAssertEqual(
            attestation.appCoverage.inventoryEntries.map(
                \.checkedFieldFamilies
            ),
            Array(
                repeating:
                    PlayCoverDifferentialInventoryFieldFamily.allCases,
                count: expectedInventorySelectors.count
            )
        )
        let matchedCoverage = Dictionary(
            uniqueKeysWithValues:
                attestation.selectorCoverage.matchedSlices.map {
                    ($0.selector, $0)
                }
        )
        for path in commonObjectSelectors {
            let selector = try XCTUnwrap(
                arm64SliceSelectors([path]).first
            )
            XCTAssertEqual(
                matchedCoverage[selector]?.comparison,
                .pinnedVersusIOSUse
            )
            XCTAssertNil(matchedCoverage[selector]?.baselineID)
        }
        let pluginSelector = try XCTUnwrap(
            arm64SliceSelectors([pluginRelativePath]).first
        )
        XCTAssertEqual(
            matchedCoverage[pluginSelector]?.comparison,
            .pinnedVersusBaseline
        )
        XCTAssertEqual(
            matchedCoverage[pluginSelector]?.baselineID,
            "pinned-akinterface-input"
        )
        let runtimeSelector = try XCTUnwrap(
            arm64SliceSelectors([runtimeRelativePath]).first
        )
        XCTAssertEqual(
            matchedCoverage[runtimeSelector]?.comparison,
            .iosUseVersusBaseline
        )
        XCTAssertEqual(
            matchedCoverage[runtimeSelector]?.baselineID,
            "ios-use-runtime-input"
        )

        let allowancesByID = Dictionary(
            uniqueKeysWithValues: allowances.map { ($0.id, $0) }
        )
        XCTAssertEqual(
            attestation.consumedAllowances.map(\.id),
            allowances.map(\.id).sorted()
        )
        for evidence in attestation.consumedAllowances {
            let recorded = try XCTUnwrap(allowancesByID[evidence.id])
            let difference = try XCTUnwrap(
                report.differences.first {
                    $0.relativePath == evidence.relativePath
                        && $0.field == evidence.field
                }
            )
            XCTAssertEqual(evidence.relativePath, recorded.relativePath)
            XCTAssertEqual(evidence.field, recorded.field)
            XCTAssertEqual(evidence.reason, recorded.reason)
            XCTAssertEqual(evidence.pinnedSymbol, recorded.pinnedSymbol)
            XCTAssertEqual(evidence.iosUseSymbol, recorded.iosUseSymbol)
            XCTAssertEqual(
                evidence.observedPinnedValue,
                difference.pinnedValue
            )
            XCTAssertEqual(
                evidence.observedIOSUseValue,
                difference.iosUseValue
            )
        }
        XCTAssertEqual(
            attestation.consumedBaselines.map(\.id),
            ["ios-use-runtime-input", "pinned-akinterface-input"]
        )
        let attestedBaselines = Dictionary(
            uniqueKeysWithValues:
                attestation.consumedBaselines.map { ($0.id, $0) }
        )
        for baseline in baselines {
            let evidence = try XCTUnwrap(attestedBaselines[baseline.id])
            XCTAssertEqual(evidence.side, baseline.side)
            XCTAssertEqual(evidence.relativePath, baseline.relativePath)
            XCTAssertEqual(evidence.sourceSHA256, baseline.sourceSHA256)
            XCTAssertEqual(evidence.provenance, baseline.provenance)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encodedAttestation = try encoder.encode(attestation)
        XCTAssertEqual(
            try JSONDecoder().decode(
                PlayCoverDifferentialAttestation.self,
                from: encodedAttestation
            ),
            attestation
        )
        if let outputPath = ProcessInfo.processInfo.environment[
            "IOS_USE_PLAYCOVER_DIFFERENTIAL_ATTESTATION_PATH"
        ], !outputPath.isEmpty {
            guard outputPath.hasPrefix("/") else {
                XCTFail("attestation candidate path must be absolute")
                throw NSError(
                    domain: "PlayCoverPrepareDifferentialTests",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "attestation candidate path must be absolute",
                    ]
                )
            }
            let output = URL(fileURLWithPath: outputPath)
            try encodedAttestation.write(
                to: output,
                options: .withoutOverwriting
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: output.path
            )
        }
    }

    func testDifferentialGateRejectsUnrecordedAndStaleAllowances() throws {
        let signature = PlayCoverUpstreamSignature(
            isSigned: true,
            isValid: true,
            entitlementsPlist: nil
        )
        let pinnedMachO = makeInspection(
            path: "Fixture",
            dependencies: [
                PlayCoverPinnedPrimitiveCharacterization.playToolsLoadPath
            ],
            signature: signature
        )
        let iosUseMachO = makeInspection(
            path: "Fixture",
            dependencies: [
                "@executable_path/Frameworks/"
                    + "IOSUsePlayRuntime.framework/IOSUsePlayRuntime",
            ],
            signature: signature
        )
        let pinned = makeAppInspection(machOs: [pinnedMachO])
        let iosUse = makeAppInspection(machOs: [iosUseMachO])

        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.enforce(
                pinned: pinned,
                iosUse: iosUse,
                allowances: []
            )
        ) {
            guard case PlayCoverDifferentialGateError.unallowed(let values) =
                    $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(
                values.map(\.field),
                [
                    "slices[cpu=16777228,subtype=0,occurrence=0]."
                        + "dependencies",
                ]
            )
        }

        let broad = PlayCoverDifferentialAllowance(
            id: "runtime-load-path",
            relativePath: "Fixture",
            field:
                "slices[cpu=16777228,subtype=0,occurrence=0].dependencies",
            pinnedValue: .containing("PlayTools.framework"),
            iosUseValue: .containing("IOSUsePlayRuntime.framework"),
            reason: "ios-use embeds its Runtime instead of system PlayTools",
            pinnedSymbol: "PlayTools.installInIPA",
            iosUseSymbol: "PlayCoverUpstreamEngine.prepare"
        )
        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.enforce(
                pinned: pinned,
                iosUse: iosUse,
                allowances: [broad]
            )
        ) {
            guard case PlayCoverDifferentialGateError.invalidAllowances =
                    $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        let valid = PlayCoverDifferentialAllowance(
            id: "runtime-load-path",
            relativePath: "Fixture",
            field:
                "slices[cpu=16777228,subtype=0,occurrence=0].dependencies",
            pinnedValue: .exact(
                jsonStringArray([
                    PlayCoverPinnedPrimitiveCharacterization
                        .playToolsLoadPath,
                ])
            ),
            iosUseValue: .exact(
                jsonStringArray([
                    "@executable_path/Frameworks/"
                        + "IOSUsePlayRuntime.framework/IOSUsePlayRuntime",
                ])
            ),
            reason: "ios-use embeds its Runtime instead of system PlayTools",
            pinnedSymbol: "PlayTools.installInIPA",
            iosUseSymbol: "PlayCoverUpstreamEngine.prepare"
        )
        let stale = PlayCoverDifferentialAllowance(
            id: "stale-platform",
            relativePath: "Fixture",
            field:
                "slices[cpu=16777228,subtype=0,occurrence=0].platform",
            pinnedValue: .exact("6"),
            iosUseValue: .exact("2"),
            reason: "fixture-only stale record",
            pinnedSymbol: "Macho.replaceVersionCommand",
            iosUseSymbol: "Macho.replaceVersionCommand"
        )
        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.enforce(
                pinned: pinned,
                iosUse: iosUse,
                allowances: [valid, stale]
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDifferentialGateError,
                .staleAllowances(["stale-platform"])
            )
        }
    }

    func testAppAndInventoryDifferencesRequireExactAllowances() throws {
        let machO = makeInspection(
            path: "Fixture",
            dependencies: [],
            signature: PlayCoverUpstreamSignature(
                isSigned: true,
                isValid: true,
                entitlementsPlist: nil
            )
        )
        let pinned = makeAppInspection(
            machOs: [machO],
            infoPlistSHA256: String(repeating: "c", count: 64),
            inventory: [
                PlayCoverUpstreamInventoryEntry(
                    relativePath: "asset.dat",
                    kind: .regularFile,
                    size: 4,
                    posixPermissions: 0o644,
                    sha256: String(repeating: "d", count: 64),
                    symbolicLinkDestination: nil,
                    codeObjectKind: nil
                ),
            ]
        )
        let iosUse = makeAppInspection(
            machOs: [machO],
            infoPlistSHA256: String(repeating: "e", count: 64),
            provisioning: PlayCoverUpstreamProvisioningEvidence(
                present: true,
                size: 12,
                sha256: String(repeating: "f", count: 64)
            ),
            inventory: [
                PlayCoverUpstreamInventoryEntry(
                    relativePath: "asset.dat",
                    kind: .regularFile,
                    size: 4,
                    posixPermissions: 0o644,
                    sha256: String(repeating: "0", count: 64),
                    symbolicLinkDestination: nil,
                    codeObjectKind: nil
                ),
            ]
        )

        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.enforce(
                pinned: pinned,
                iosUse: iosUse,
                allowances: []
            )
        ) {
            guard case PlayCoverDifferentialGateError.unallowed(let values) =
                    $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(
                values.map { "\($0.relativePath) \($0.field)" },
                [
                    ". app.infoPlistSHA256",
                    ". app.provisioning.present",
                    ". app.provisioning.size",
                    ". app.provisioning.sha256",
                    "asset.dat inventory.sha256",
                ]
            )
        }
    }

    func testAttestationRejectsUnconstrainedNormalization() throws {
        let machO = makeInspection(
            path: "Fixture",
            dependencies: [],
            signature: PlayCoverUpstreamSignature(
                isSigned: true,
                isValid: true,
                entitlementsPlist: nil
            )
        )
        let inspection = makeAppInspection(machOs: [machO])
        let source = makeAppInspection(
            machOs: [machO],
            appPath: "/Source.app",
            sourceContentHash: String(repeating: "d", count: 64)
        )

        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.attest(
                repositoryRoot: repositoryRoot(),
                sourceApp: URL(fileURLWithPath: source.appPath),
                pinnedResult: makePinnedPrepareResult(
                    source: source,
                    prepared: inspection
                ),
                iosUseResult: makeIOSUsePrepareResult(
                    source: source,
                    prepared: inspection
                ),
                allowances: []
            )
        ) {
            guard case PlayCoverDifferentialAttestationError
                    .invalidIdentity(let messages) = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(
                messages.contains(
                    "differential attestation requires constrained normalization"
                )
            )
        }
    }

    func testHermeticNormalizationRejectsAliasedOrNestedHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-home-identity-\(UUID().uuidString)",
                isDirectory: true
            )
        let pinnedHome = root.appendingPathComponent(
            "pinned",
            isDirectory: true
        )
        let nestedHome = pinnedHome.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        let aliasHome = root.appendingPathComponent(
            "alias",
            isDirectory: true
        )
        try makePrivateDirectory(nestedHome)
        try FileManager.default.createSymbolicLink(
            at: aliasHome,
            withDestinationURL: pinnedHome
        )
        defer { try? FileManager.default.removeItem(at: root) }

        for iosUseHome in [nestedHome, aliasHome] {
            XCTAssertThrowsError(
                try PlayCoverDifferentialNormalization.hermeticFixture(
                    pinnedManagedHome: pinnedHome,
                    iosUseManagedHome: iosUseHome
                )
            ) {
                guard case PlayCoverDifferentialAttestationError
                        .invalidIdentity(let messages) = $0 else {
                    return XCTFail("unexpected error: \($0)")
                }
                XCTAssertTrue(
                    messages.contains {
                        $0.contains(
                            "canonical, non-overlapping directories"
                        )
                    }
                )
            }
        }
    }

    func testHermeticNormalizationDoesNotRewriteSiblingPrefixes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-path-boundary-\(UUID().uuidString)",
                isDirectory: true
            )
        let pinnedHome = root.appendingPathComponent(
            "pinned",
            isDirectory: true
        )
        let iosUseHome = root.appendingPathComponent(
            "ios-use",
            isDirectory: true
        )
        try makePrivateDirectory(pinnedHome)
        try makePrivateDirectory(iosUseHome)
        defer { try? FileManager.default.removeItem(at: root) }
        let normalization =
            try PlayCoverDifferentialNormalization.hermeticFixture(
                pinnedManagedHome: pinnedHome,
                iosUseManagedHome: iosUseHome
            )
        let signature = PlayCoverUpstreamSignature(
            isSigned: true,
            isValid: true,
            entitlementsPlist: nil
        )
        let pinned = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: [
                        pinnedHome.path + "/child/libEqual.dylib",
                        pinnedHome.path + "-sibling/libBoundary.dylib",
                        pinnedHome.path + ":sibling/libColon.dylib",
                        pinnedHome.path + " sibling/libSpace.dylib",
                    ],
                    signature: signature
                ),
            ]
        )
        let iosUse = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: [
                        iosUseHome.path + "/child/libEqual.dylib",
                        iosUseHome.path + "-sibling/libBoundary.dylib",
                        iosUseHome.path + ":sibling/libColon.dylib",
                        iosUseHome.path + " sibling/libSpace.dylib",
                    ],
                    signature: signature
                ),
            ]
        )

        let differences = try PlayCoverPrepareDifferentialGate.differences(
            pinned: pinned,
            iosUse: iosUse,
            normalization: normalization
        )
        XCTAssertEqual(
            differences.map(\.field),
            ["slices[cpu=16777228,subtype=0,occurrence=0].dependencies"]
        )
        let difference = try XCTUnwrap(differences.first)
        let pinnedDependencies = try JSONDecoder().decode(
            [String].self,
            from: Data(try XCTUnwrap(difference.pinnedValue).utf8)
        )
        let iosUseDependencies = try JSONDecoder().decode(
            [String].self,
            from: Data(try XCTUnwrap(difference.iosUseValue).utf8)
        )
        XCTAssertEqual(
            pinnedDependencies,
            [
                "<MANAGED_HOME>/child/libEqual.dylib",
                pinnedHome.path + "-sibling/libBoundary.dylib",
                pinnedHome.path + ":sibling/libColon.dylib",
                pinnedHome.path + " sibling/libSpace.dylib",
            ]
        )
        XCTAssertEqual(
            iosUseDependencies,
            [
                "<MANAGED_HOME>/child/libEqual.dylib",
                iosUseHome.path + "-sibling/libBoundary.dylib",
                iosUseHome.path + ":sibling/libColon.dylib",
                iosUseHome.path + " sibling/libSpace.dylib",
            ]
        )
    }

    func testAttestationRejectsPrimitiveCharacterizationLineage() throws {
        let inspection = makeAppInspection(machOs: [])
        let pinnedResult = makePinnedPrepareResult(
            source: inspection,
            prepared: inspection,
            producer: .primitiveCharacterization
        )
        let iosUseResult = makeIOSUsePrepareResult(
            source: inspection,
            prepared: inspection
        )

        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.attest(
                repositoryRoot: URL(fileURLWithPath: "/"),
                sourceApp: URL(fileURLWithPath: inspection.appPath),
                pinnedResult: pinnedResult,
                iosUseResult: iosUseResult,
                allowances: []
            )
        ) {
            guard case PlayCoverDifferentialAttestationError
                    .invalidIdentity(let messages) = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(
                messages,
                [
                    "pinned prepare result was not produced by the full "
                        + "PlayTools Installer oracle",
                ]
            )
        }
    }

    func testPrepareResultDifferencesRejectsPrimitiveBeforeComparison()
        throws
    {
        let inspection = makeAppInspection(machOs: [])
        let baselineInspection = makeInspection(
            path: "Fixture",
            dependencies: [],
            signature: PlayCoverUpstreamSignature(
                isSigned: true,
                isValid: true,
                entitlementsPlist: nil
            )
        )
        let staleBaseline = PlayCoverDifferentialObjectBaseline(
            id: "must-not-reach-inspection-comparator",
            side: .iosUse,
            relativePath: "Fixture",
            inspection: baselineInspection,
            sourceSHA256: baselineInspection.fileSHA256,
            provenance: "producer guard ordering fixture"
        )

        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.differences(
                pinnedResult: makePinnedPrepareResult(
                    source: inspection,
                    prepared: inspection,
                    producer: .primitiveCharacterization
                ),
                iosUseResult: makeIOSUsePrepareResult(
                    source: inspection,
                    prepared: inspection
                ),
                oneSidedBaselines: [staleBaseline]
            )
        ) {
            guard case PlayCoverDifferentialAttestationError
                    .invalidIdentity(let messages) = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(
                messages,
                [
                    "pinned prepare result was not produced by the full "
                        + "PlayTools Installer oracle",
                ]
            )
        }
    }

    func testPrepareResultDifferencesMatchInspectionOverloadInOrder()
        throws
    {
        let signature = PlayCoverUpstreamSignature(
            isSigned: true,
            isValid: true,
            entitlementsPlist: nil
        )
        let pinned = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: ["pinned"],
                    signature: signature
                ),
            ],
            infoPlistSHA256: String(repeating: "1", count: 64)
        )
        let iosUse = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: ["ios-use"],
                    signature: signature
                ),
            ],
            infoPlistSHA256: String(repeating: "2", count: 64)
        )

        let inspectionDifferences =
            try PlayCoverPrepareDifferentialGate.differences(
                pinned: pinned,
                iosUse: iosUse
            )
        let prepareResultDifferences =
            try PlayCoverPrepareDifferentialGate.differences(
                pinnedResult: makePinnedPrepareResult(
                    source: pinned,
                    prepared: pinned
                ),
                iosUseResult: makeIOSUsePrepareResult(
                    source: pinned,
                    prepared: iosUse
                )
            )

        XCTAssertEqual(prepareResultDifferences, inspectionDifferences)
        XCTAssertEqual(
            prepareResultDifferences.map(\.field),
            [
                "app.infoPlistSHA256",
                "slices[cpu=16777228,subtype=0,occurrence=0]."
                    + "dependencies",
            ]
        )
    }

    func testDifferentialDifferenceCodableRoundTripIsStable() throws {
        let differences = [
            PlayCoverDifferentialDifference(
                relativePath: ".",
                field: "app.infoPlistSHA256",
                pinnedValue: "pinned",
                iosUseValue: "ios-use"
            ),
            PlayCoverDifferentialDifference(
                relativePath: "Frameworks/Runtime",
                field: "object.presence",
                pinnedValue: nil,
                iosUseValue: "present"
            ),
            PlayCoverDifferentialDifference(
                relativePath: "PlugIns/Plugin",
                field: "object.presence",
                pinnedValue: "present",
                iosUseValue: nil
            ),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(differences)
        let decoded = try JSONDecoder().decode(
            [PlayCoverDifferentialDifference].self,
            from: encoded
        )

        XCTAssertEqual(decoded, differences)
        XCTAssertEqual(try encoder.encode(decoded), encoded)
    }

    func testHermeticNormalizationDoesNotInventPrivateAlias() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".ios-use-playcover-alias-boundary-\(UUID().uuidString)",
                isDirectory: true
            )
        let pinnedHome = root.appendingPathComponent(
            "pinned",
            isDirectory: true
        )
        let iosUseHome = root.appendingPathComponent(
            "ios-use",
            isDirectory: true
        )
        try makePrivateDirectory(pinnedHome)
        try makePrivateDirectory(iosUseHome)
        defer { try? FileManager.default.removeItem(at: root) }
        let normalization =
            try PlayCoverDifferentialNormalization.hermeticFixture(
                pinnedManagedHome: pinnedHome,
                iosUseManagedHome: iosUseHome
            )
        let signature = PlayCoverUpstreamSignature(
            isSigned: true,
            isValid: true,
            entitlementsPlist: nil
        )
        let pinned = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: [
                        "/private" + pinnedHome.path + "/libBoundary.dylib",
                    ],
                    signature: signature
                ),
            ]
        )
        let iosUse = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: [
                        "/private" + iosUseHome.path + "/libBoundary.dylib",
                    ],
                    signature: signature
                ),
            ]
        )

        let differences = try PlayCoverPrepareDifferentialGate.differences(
            pinned: pinned,
            iosUse: iosUse,
            normalization: normalization
        )
        XCTAssertEqual(
            differences.map(\.field),
            ["slices[cpu=16777228,subtype=0,occurrence=0].dependencies"]
        )
        let difference = try XCTUnwrap(differences.first)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String].self,
                from: Data(try XCTUnwrap(difference.pinnedValue).utf8)
            ),
            ["/private" + pinnedHome.path + "/libBoundary.dylib"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String].self,
                from: Data(try XCTUnwrap(difference.iosUseValue).utf8)
            ),
            ["/private" + iosUseHome.path + "/libBoundary.dylib"]
        )
    }

    func testAttestationBindsPreparedAppsToTheirManagedHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-output-binding-\(UUID().uuidString)",
                isDirectory: true
            )
        let pinnedHome = root.appendingPathComponent(
            "pinned",
            isDirectory: true
        )
        let iosUseHome = root.appendingPathComponent(
            "ios-use",
            isDirectory: true
        )
        try makePrivateDirectory(pinnedHome)
        try makePrivateDirectory(iosUseHome)
        defer { try? FileManager.default.removeItem(at: root) }
        let normalization =
            try PlayCoverDifferentialNormalization.hermeticFixture(
                pinnedManagedHome: pinnedHome,
                iosUseManagedHome: iosUseHome
            )
        let machO = makeInspection(
            path: "Fixture",
            dependencies: [],
            signature: PlayCoverUpstreamSignature(
                isSigned: true,
                isValid: true,
                entitlementsPlist: nil
            )
        )
        let source = makeAppInspection(
            machOs: [machO],
            appPath: root.appendingPathComponent("Source.app").path
        )
        let pinned = makeAppInspection(
            machOs: [machO],
            appPath: root.appendingPathComponent(
                "outside/Pinned.app"
            ).path
        )
        let iosUse = makeAppInspection(
            machOs: [machO],
            appPath: iosUseHome.appendingPathComponent(
                "IOSUse.app"
            ).path
        )

        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.attest(
                repositoryRoot: repositoryRoot(),
                sourceApp: URL(fileURLWithPath: source.appPath),
                pinnedResult: makePinnedPrepareResult(
                    source: source,
                    prepared: pinned
                ),
                iosUseResult: makeIOSUsePrepareResult(
                    source: source,
                    prepared: iosUse
                ),
                allowances: [],
                normalization: normalization
            )
        ) {
            guard case PlayCoverDifferentialAttestationError
                    .invalidIdentity(let messages) = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(
                messages.contains(
                    "pinned prepared App is outside its managed home"
                )
            )
        }
    }

    func testAttestationRequiresEverySliceSelectorToBeCovered()
        throws
    {
        let signature = PlayCoverUpstreamSignature(
            isSigned: true,
            isValid: true,
            entitlementsPlist: nil
        )
        let base = makeInspection(
            path: "Fixture",
            dependencies: [],
            signature: signature
        )
        let arm64 = try XCTUnwrap(base.allSlices.first)
        let x86 = PlayCoverUpstreamMachOSliceInspection(
            fatIndex: 1,
            cpuType: 0x0100_0007,
            cpuSubtype: 3,
            offset: 1_024,
            size: 1_024,
            alignment: 12,
            byteSwapped: false,
            fileType: 2,
            commandCount: 1,
            commandBytes: 24,
            firstSectionOffset: 512,
            platform: 7,
            minimumOS: 0x000b_0000,
            sdk: 0x000e_0000,
            encrypted: false,
            dependencies: [],
            rpaths: [],
            loadCommands: [],
            signature: signature,
            sliceSHA256: String(repeating: "1", count: 64),
            immutableContentSHA256: String(repeating: "2", count: 64)
        )
        let allowance = PlayCoverDifferentialAllowance(
            id: "reviewed-extra-slice-presence",
            relativePath: "Fixture",
            field: "slices[cpu=16777223,subtype=3,occurrence=0].presence",
            pinnedValue: .absent,
            iosUseValue: .exact("present"),
            reason:
                "Negative test proves presence allowance cannot replace "
                + "full slice comparison or a reviewed baseline.",
            pinnedSymbol: "negative-test-pinned",
            iosUseSymbol: "negative-test-ios-use"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-normalization-\(UUID().uuidString)",
                isDirectory: true
            )
        let pinnedHome = root.appendingPathComponent(
            "pinned",
            isDirectory: true
        )
        let iosUseHome = root.appendingPathComponent(
            "ios-use",
            isDirectory: true
        )
        try makePrivateDirectory(pinnedHome)
        try makePrivateDirectory(iosUseHome)
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: [],
                    signature: signature,
                    sliceInspections: [arm64]
                ),
            ],
            appPath: pinnedHome.appendingPathComponent(
                "Pinned.app"
            ).path
        )
        let iosUse = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: [],
                    signature: signature,
                    sliceInspections: [arm64, x86]
                ),
            ],
            appPath: iosUseHome.appendingPathComponent(
                "IOSUse.app"
            ).path
        )
        let normalization =
            try PlayCoverDifferentialNormalization.hermeticFixture(
                pinnedManagedHome: pinnedHome,
                iosUseManagedHome: iosUseHome
            )
        let source = makeAppInspection(
            machOs: [base],
            appPath: root.appendingPathComponent("Source.app").path,
            sourceContentHash: String(repeating: "d", count: 64)
        )

        XCTAssertNoThrow(
            try PlayCoverPrepareDifferentialGate.enforce(
                pinned: pinned,
                iosUse: iosUse,
                allowances: [allowance],
                normalization: normalization
            )
        )
        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.attest(
                repositoryRoot: repositoryRoot(),
                sourceApp: URL(fileURLWithPath: source.appPath),
                pinnedResult: makePinnedPrepareResult(
                    source: source,
                    prepared: pinned
                ),
                iosUseResult: makeIOSUsePrepareResult(
                    source: source,
                    prepared: iosUse
                ),
                allowances: [allowance],
                normalization: normalization
            )
        ) {
            guard case PlayCoverDifferentialAttestationError
                    .invalidIdentity(let messages) = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(
                messages.contains(
                    "slice selectors are not each covered exactly once"
                )
            )
        }
    }

    func testDifferentialGateRejectsSecondarySliceOnlyMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-secondary-slice-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SecondarySlice.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let arm64 = root.appendingPathComponent("SecondarySlice-arm64")
        try compileIOS(source: source, output: arm64, extraArguments: [])
        let x86_64 = root.appendingPathComponent("SecondarySlice-x86_64")
        try compileIOSSimulatorX86_64(
            source: source,
            output: x86_64
        )
        let pinnedURL = root.appendingPathComponent("PinnedFat")
        try makeFatMachO(
            arm64: Data(contentsOf: arm64),
            x86_64: Data(contentsOf: x86_64)
        ).write(to: pinnedURL)
        try makeExecutable(pinnedURL)
        let pinnedInspection = try PlayCoverUpstreamEngine.inspectMachO(
            at: pinnedURL,
            relativePath: "Fixture"
        )
        let secondary = try XCTUnwrap(
            pinnedInspection.allSlices.first {
                $0.cpuType == 0x0100_0007
            }
        )
        let firstSection = try XCTUnwrap(secondary.firstSectionOffset)
        var mutated = try Data(contentsOf: pinnedURL)
        let mutationOffset = Int(secondary.offset + firstSection)
        mutated[mutationOffset] ^= 0x01
        let iosUseURL = root.appendingPathComponent("IOSUseFat")
        try mutated.write(to: iosUseURL)
        try makeExecutable(iosUseURL)
        let iosUseInspection = try PlayCoverUpstreamEngine.inspectMachO(
            at: iosUseURL,
            relativePath: "Fixture"
        )
        let pinned = makeAppInspection(machOs: [pinnedInspection])
        let iosUse = makeAppInspection(machOs: [iosUseInspection])

        let differences = try PlayCoverPrepareDifferentialGate.differences(
            pinned: pinned,
            iosUse: iosUse
        )
        XCTAssertEqual(
            differences.map(\.field),
            [
                "slices[cpu=16777223,subtype=3,occurrence=0]."
                    + "immutableContentSHA256",
            ]
        )
        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.enforce(
                pinned: pinned,
                iosUse: iosUse,
                allowances: []
            )
        ) {
            guard case PlayCoverDifferentialGateError.unallowed(let values) =
                    $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(values, differences)
        }
    }

    func testEmptySliceArrayFallsBackToCoveredLegacySlice() throws {
        let signature = PlayCoverUpstreamSignature(
            isSigned: true,
            isValid: true,
            entitlementsPlist: nil
        )
        let pinned = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: ["pinned"],
                    signature: signature,
                    sliceInspections: []
                ),
            ]
        )
        let iosUse = makeAppInspection(
            machOs: [
                makeInspection(
                    path: "Fixture",
                    dependencies: ["ios-use"],
                    signature: signature
                ),
            ]
        )

        XCTAssertEqual(
            try PlayCoverPrepareDifferentialGate.differences(
                pinned: pinned,
                iosUse: iosUse
            ).map(\.field),
            [
                "slices[cpu=16777228,subtype=0,occurrence=0]."
                    + "dependencies",
            ]
        )
    }

    func testOneSidedObjectsRequireExactNonStaleBaselines() throws {
        let signature = PlayCoverUpstreamSignature(
            isSigned: true,
            isValid: true,
            entitlementsPlist: nil
        )
        let runtime = makeInspection(
            path: "Frameworks/Runtime",
            dependencies: ["runtime-v1"],
            signature: signature
        )
        let pinned = makeAppInspection(machOs: [])
        let iosUse = makeAppInspection(machOs: [runtime])

        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.differences(
                pinned: pinned,
                iosUse: iosUse
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDifferentialGateError,
                .missingBaseline(
                    side: .iosUse,
                    path: "Frameworks/Runtime"
                )
            )
        }

        let baseline = PlayCoverDifferentialObjectBaseline(
            id: "runtime-input",
            side: .iosUse,
            relativePath: "Frameworks/Runtime",
            inspection: runtime,
            sourceSHA256: runtime.fileSHA256,
            provenance: "unit fixture pre-transform Runtime"
        )
        let changedRuntime = makeInspection(
            path: "Frameworks/Runtime",
            dependencies: ["runtime-v2"],
            signature: signature
        )
        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.differences(
                pinned: pinned,
                iosUse: makeAppInspection(machOs: [changedRuntime]),
                oneSidedBaselines: [baseline]
            )
        ) {
            guard case PlayCoverDifferentialGateError.baselineMismatch(
                let identifier,
                let differences
            ) = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(identifier, "runtime-input")
            XCTAssertFalse(differences.isEmpty)
        }

        let invalidHash = PlayCoverDifferentialObjectBaseline(
            id: "invalid-runtime-input",
            side: .iosUse,
            relativePath: "Frameworks/Runtime",
            inspection: runtime,
            sourceSHA256: String(repeating: "f", count: 64),
            provenance: "unit fixture with deliberately invalid hash"
        )
        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.differences(
                pinned: pinned,
                iosUse: iosUse,
                oneSidedBaselines: [invalidHash]
            )
        ) {
            guard case PlayCoverDifferentialGateError.invalidBaselines =
                    $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }

        XCTAssertThrowsError(
            try PlayCoverPrepareDifferentialGate.differences(
                pinned: makeAppInspection(machOs: [runtime]),
                iosUse: iosUse,
                oneSidedBaselines: [baseline]
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDifferentialGateError,
                .staleBaselines(["runtime-input"])
            )
        }
    }

    private func repositoryRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        return root.standardizedFileURL
    }

    private func requireGoldenDigest(
        _ actual: String,
        expected: String,
        name: String
    ) throws {
        guard actual == expected else {
            XCTFail(
                "\(name) does not match the reviewed "
                    + "\(HermeticOneSidedGoldenV1.manifestID) manifest: "
                    + "expected \(expected), observed \(actual)"
            )
            throw NSError(
                domain: "PlayCoverPrepareDifferentialTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(name) one-sided golden digest changed",
                ]
            )
        }
    }

    private func makeAllowances() -> [PlayCoverDifferentialAllowance] {
        let pinnedSign = "Shell.signAppWith(--deep)"
        let iosUseSign = "PlayCoverUpstreamEngine.signInsideOut"
        let arm64 =
            "slices[cpu=16777228,subtype=0,occurrence=0]."
        let pinnedSandbox = [
            "(allow user-preference-write (preference-domain "
                + "\".GlobalPreferences\"))",
            "(allow user-preference-read (preference-domain "
                + "\".GlobalPreferences\"))",
            "(allow file* file-read* file-write* file-write-data "
                + "file-read-metadata file-ioctl (subpath "
                + "\"<MANAGED_HOME>/Library/Containers/"
                + "io.playcover.PlayCover\"))",
            "(allow file* file-read* file-read-metadata file-ioctl "
                + "(subpath \"<MANAGED_HOME>/Library/Frameworks/"
                + "PlayTools.framework\"))",
            "(allow file* file-read* (subpath "
                + "\"<MANAGED_HOME>/Library/Group Containers/\"))",
            "(deny process-fork)",
            "(deny file* file-read* file-read-metadata file-ioctl "
                + "(literal \"/bin/bash\"))",
            "(deny file* file-read* file-read-metadata file-ioctl "
                + "(literal \"/usr/sbin/sshd\"))",
            "(deny file* file-read* file-read-metadata file-ioctl "
                + "(literal \"/usr/libexec/ssh-keysign\"))",
            "(deny file* file-read* file-read-metadata file-ioctl "
                + "(literal \"/bin/sh\"))",
            "(deny file* file-read* file-read-metadata file-ioctl "
                + "(literal \"/etc/ssh/sshd_config\"))",
            "(deny file* file-read* file-read-metadata file-ioctl "
                + "(literal \"/usr/libexec/sftp-server\"))",
            "(deny file* file-read* file-read-metadata file-ioctl "
                + "(literal \"/usr/bin/ssh\"))",
        ]
        let iosUseSandbox = pinnedSandbox + [
            "(allow file-read* file-write* file-read-metadata "
                + "(subpath \"<MANAGED_HOME>/playcover/run\"))",
            "(allow network-bind (subpath "
                + "\"<MANAGED_HOME>/playcover/run\"))",
            "(allow file-read* file-write* file-read-metadata "
                + "(subpath \"<MANAGED_HOME>\"))",
            "(allow file-read* file-write* file-read-metadata "
                + "(subpath \"<MANAGED_HOME>/playcover/PlayChain\"))",
        ]
        func exactExpectation(
            _ value: String?
        ) -> PlayCoverDifferentialExpectation {
            value.map(PlayCoverDifferentialExpectation.exact) ?? .absent
        }
        func signatureEvidenceAllowance(
            _ id: String,
            path: String,
            field: String,
            pinned: String?,
            iosUse: String?,
            reason: String
        ) -> PlayCoverDifferentialAllowance {
            allowance(
                id,
                path,
                arm64 + "signature." + field,
                exactExpectation(pinned),
                exactExpectation(iosUse),
                reason,
                pinnedSign,
                iosUseSign
            )
        }
        return [
            allowance(
                "app-root-signature-cdhash",
                ".",
                "app.signature.cdHash",
                .lowercaseHexDigest(length: 40),
                .lowercaseHexDigest(length: 40),
                "Both complete App roots are validly ad-hoc signed over "
                    + "different reviewed embedded code/resource sets.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "app-root-entitlements-hash",
                ".",
                "app.signature.entitlementsCanonicalSHA256",
                .exact(
                    "0fefbbc83136bf80b28853dd1c249300f56c34cad6e06600"
                        + "f4fe3f102713c62d"
                ),
                .exact(
                    "bd75e59e2503ecfb9f94c2a74d0078ad14af6fa8dcd4bb5"
                        + "a628faf785fad5e85"
                ),
                "The root signature carries the same separately reviewed "
                    + "entitlement dictionaries as the main executable.",
                "Entitlements.composeEntitlements",
                "PlayCoverUpstreamEngine.composeEntitlements"
            ),
            allowance(
                "app-root-runtime-sandbox",
                ".",
                "app.signature.entitlements."
                    + "com.apple.security.temporary-exception.sbpl",
                .exact(entitlementStringArray(pinnedSandbox)),
                .exact(entitlementStringArray(iosUseSandbox)),
                "The direct Runtime socket and managed PlayChain require the "
                    + "same four ios-use-only rules reviewed on the main "
                    + "executable signature.",
                "Entitlements.composeEntitlements",
                "PlayCoverUpstreamEngine.composeEntitlements"
            ),
            allowance(
                "inventory-main-executable-size",
                "Fixture",
                "inventory.size",
                .exact("90096"),
                .exact("91824"),
                "The exact signed main executable sizes are also recorded by "
                    + "the inventory comparator.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "inventory-runtime-framework-directory",
                "Frameworks/IOSUsePlayRuntime.framework",
                "inventory.presence",
                .absent,
                .exact(
                    jsonStringArray([
                        "present", "directory", "<absent>", "493",
                        "<absent>", "<absent>", "frameworkBundle",
                    ])
                ),
                "ios-use embeds one reviewed Runtime framework; pinned "
                    + "PlayCover loads its system PlayTools framework.",
                "PlayTools.playToolsPath",
                "PlayCoverUpstreamEngine.prepare"
            ),
            allowance(
                "inventory-runtime-executable",
                "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime",
                "inventory.presence",
                .absent,
                .exact(
                    jsonStringArray([
                        "present", "regularFile", "51472", "448",
                        "<MACHO-COMPARATOR>", "<absent>",
                        "frameworkExecutable",
                    ])
                ),
                "The one-sided executable is independently pinned by "
                    + "\(HermeticOneSidedGoldenV1.manifestID) and compared as "
                    + "a complete Mach-O baseline.",
                "PlayTools.playToolsPath",
                "PlayCoverUpstreamEngine.prepare"
            ),
            allowance(
                "inventory-runtime-info",
                "Frameworks/IOSUsePlayRuntime.framework/Info.plist",
                "inventory.presence",
                .absent,
                .exact(
                    jsonStringArray([
                        "present", "regularFile", "389", "420",
                        "570393b042e964dc7fba7e1ed127935241c6d605ada7ed9f5"
                            + "a9d10611bad5a86",
                        "<absent>", "<absent>",
                    ])
                ),
                "The fixture Runtime Info.plist is a reviewed immutable "
                    + "resource of the ios-use-only framework.",
                "PlayTools.playToolsPath",
                "makeCatalystRuntimeFramework"
            ),
            allowance(
                "inventory-runtime-signature-directory",
                "Frameworks/IOSUsePlayRuntime.framework/_CodeSignature",
                "inventory.presence",
                .absent,
                .exact(
                    jsonStringArray([
                        "present", "directory", "<absent>", "493",
                        "<absent>", "<absent>", "<absent>",
                    ])
                ),
                "Inside-out signing creates the ios-use Runtime framework "
                    + "signature directory.",
                "Shell.signAppWith(--deep)",
                "PlayCoverUpstreamEngine.signInsideOut"
            ),
            allowance(
                "inventory-runtime-code-resources",
                "Frameworks/IOSUsePlayRuntime.framework/_CodeSignature/"
                    + "CodeResources",
                "inventory.presence",
                .absent,
                .exact(
                    jsonStringArray([
                        "present", "regularFile", "1798", "420",
                        "<SIGNATURE-COMPARATOR>", "<absent>", "<absent>",
                    ])
                ),
                "The Runtime framework seal is validated by the signature "
                    + "comparator; inventory fixes its exact shape.",
                "Shell.signAppWith(--deep)",
                "PlayCoverUpstreamEngine.signInsideOut"
            ),
            allowance(
                "inventory-plugin-directory",
                "PlugIns/AKInterface.bundle",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "directory", "<absent>", "511",
                        "<absent>", "<absent>", "<absent>",
                    ])
                ),
                .absent,
                "Pinned PlayTools installs its AppKit plugin; ios-use ports "
                    + "that adapter into the single Runtime framework.",
                "PlayTools.installPluginInIPA",
                "IOSUsePlayRuntime"
            ),
            allowance(
                "inventory-plugin-contents-directory",
                "PlugIns/AKInterface.bundle/Contents",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "directory", "<absent>", "493",
                        "<absent>", "<absent>", "<absent>",
                    ])
                ),
                .absent,
                "This is the exact reviewed bundle layout of the pinned "
                    + "AKInterface plugin.",
                "PlayTools.installPluginInIPA",
                "IOSUsePlayRuntime"
            ),
            allowance(
                "inventory-plugin-info",
                "PlugIns/AKInterface.bundle/Contents/Info.plist",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "regularFile", "386", "420",
                        "b86f9460df6e0db3cc600b1629e8c51a42331bf1789f53abd"
                            + "838563712d40e72",
                        "<absent>", "<absent>",
                    ])
                ),
                .absent,
                "The pinned plugin Info.plist is an exact reviewed "
                    + "one-sided resource.",
                "PlayTools.installPluginInIPA",
                "IOSUsePlayRuntime"
            ),
            allowance(
                "inventory-plugin-macos-directory",
                "PlugIns/AKInterface.bundle/Contents/MacOS",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "directory", "<absent>", "493",
                        "<absent>", "<absent>", "<absent>",
                    ])
                ),
                .absent,
                "This directory contains only the independently pinned "
                    + "AKInterface Mach-O.",
                "PlayTools.installPluginInIPA",
                "IOSUsePlayRuntime"
            ),
            allowance(
                "inventory-plugin-executable",
                "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "regularFile", "51520", "448",
                        "<MACHO-COMPARATOR>", "<absent>", "machO",
                    ])
                ),
                .absent,
                "The one-sided executable is independently pinned by "
                    + "\(HermeticOneSidedGoldenV1.manifestID) and compared as "
                    + "a complete Mach-O baseline.",
                "PlayTools.installPluginInIPA",
                "IOSUsePlayRuntime"
            ),
            allowance(
                "inventory-plugin-signature-directory",
                "PlugIns/AKInterface.bundle/Contents/_CodeSignature",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "directory", "<absent>", "493",
                        "<absent>", "<absent>", "<absent>",
                    ])
                ),
                .absent,
                "Pinned signing creates the exact plugin signature "
                    + "directory.",
                "Shell.signAppWith(--deep)",
                "PlayCoverUpstreamEngine.signInsideOut"
            ),
            allowance(
                "inventory-plugin-code-resources",
                "PlugIns/AKInterface.bundle/Contents/_CodeSignature/"
                    + "CodeResources",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "regularFile", "2200", "420",
                        "<SIGNATURE-COMPARATOR>", "<absent>", "<absent>",
                    ])
                ),
                .absent,
                "The plugin seal is validated by the signature comparator; "
                    + "inventory fixes its exact shape.",
                "Shell.signAppWith(--deep)",
                "PlayCoverUpstreamEngine.signInsideOut"
            ),
            allowance(
                "inventory-root-code-resources-size",
                "_CodeSignature/CodeResources",
                "inventory.size",
                .exact("5747"),
                .exact("5418"),
                "The root resource seals enumerate different reviewed "
                    + "one-sided Runtime/plugin resource sets.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "inventory-playtools-localization-directory",
                "en.lproj",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "directory", "<absent>", "493",
                        "<absent>", "<absent>", "<absent>",
                    ])
                ),
                .absent,
                "Pinned PlayTools contributes its fixture localization "
                    + "directory; ios-use has no GUI localization payload.",
                "PlayTools.installInIPA",
                "IOSUsePlayRuntime"
            ),
            allowance(
                "inventory-playtools-localization-file",
                "en.lproj/Playtools.strings",
                "inventory.presence",
                .exact(
                    jsonStringArray([
                        "present", "regularFile", "22", "420",
                        "0254a5ed327f1e3c33590be0d2e350fe80c86dce060720197"
                            + "fea81ad3973177a",
                        "<absent>", "<absent>",
                    ])
                ),
                .absent,
                "Pinned PlayTools contributes this exact reviewed fixture "
                    + "localization file; ios-use ports no GUI strings.",
                "PlayTools.installInIPA",
                "IOSUsePlayRuntime"
            ),
            allowance(
                "main-signed-size",
                "Fixture",
                arm64 + "size",
                .exact("90096"),
                .exact("91824"),
                "The pinned PlayTools path and --deep entitlement signature "
                    + "produce a different signed thin-slice size.",
                "PlayTools.installInIPA + \(pinnedSign)",
                "PlayTools.injectRuntime + \(iosUseSign)"
            ),
            allowance(
                "main-load-command-bytes",
                "Fixture",
                arm64 + "loadCommands.bytes",
                .exact("1208"),
                .exact("1216"),
                "The two injected load paths have different aligned command "
                    + "sizes.",
                "PlayTools.installInIPA",
                "PlayTools.injectRuntime"
            ),
            allowance(
                "main-linkedit-command",
                "Fixture",
                arm64 + "loadCommands[3]",
                .exact(
                    "cmd=0x00000019;size=72;semantic=segment=__LINKEDIT;"
                        + "vmaddr=4295032832;vmsize=32768;fileoff=65536;"
                        + "filesize=24560;maxprot=1;initprot=1;sections=0;"
                        + "flags=0;sha256="
                        + "07763ec34417aa335d8957a1d7e4bb12362514a15ff1d82d0"
                        + "a49156817a7750c"
                ),
                .exact(
                    "cmd=0x00000019;size=72;semantic=segment=__LINKEDIT;"
                        + "vmaddr=4295032832;vmsize=32768;fileoff=65536;"
                        + "filesize=26288;maxprot=1;initprot=1;sections=0;"
                        + "flags=0;sha256="
                        + "9f0db39d2e7f7bbd542923bec31766fea83b697ef99e129c0"
                        + "7cbbfb406e92208"
                ),
                "Different signature payload sizes change only the __LINKEDIT "
                    + "segment extent.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-code-signature-command",
                "Fixture",
                arm64 + "loadCommands[18]",
                .exact(
                    "cmd=0x0000001d;size=16;semantic=dataoff=65840;"
                        + "datasize=24256;sha256="
                        + "cd386937faa56bf241c2a35bb31721b0d7b906cff7d1ee928"
                        + "26cf9bd5b7e3bcb"
                ),
                .exact(
                    "cmd=0x0000001d;size=16;semantic=dataoff=65840;"
                        + "datasize=25984;sha256="
                        + "21de3d7e64c8e726e82709dd8241b76421ada099338c264f2"
                        + "697a38563f80d50"
                ),
                "Pinned --deep and ios-use inside-out signing encode different "
                    + "entitlement payload sizes in LC_CODE_SIGNATURE.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-runtime-command",
                "Fixture",
                arm64 + "loadCommands[20]",
                .exact(
                    "cmd=0x0000000c;size=96;semantic=path=<PLAYTOOLS>;"
                        + "pathOffset=24;timestamp=2;current=0;"
                        + "compatibility=0;sha256="
                        + "<path-normalized-by-semantics>"
                ),
                .exact(
                    "cmd=0x0000000c;size=104;semantic=path="
                        + "@executable_path/Frameworks/"
                        + "IOSUsePlayRuntime.framework/IOSUsePlayRuntime;"
                        + "pathOffset=24;timestamp=2;current=0;"
                        + "compatibility=0;sha256="
                        + "cf94904a9ab238dab64d6a784752782cfcfe4a23c10bd1660"
                        + "a49483f137e860a"
                ),
                "ios-use replaces pinned system PlayTools with its App-embedded "
                    + "Runtime at the same injection point.",
                "PlayTools.installInIPA",
                "PlayTools.injectRuntime"
            ),
            allowance(
                "main-runtime-dependency",
                "Fixture",
                arm64 + "dependencies",
                .exact(
                    jsonStringArray([
                        "/System/iOSSupport/usr/lib/swift/"
                            + "libswiftUIKit.dylib",
                        "/usr/lib/libSystem.B.dylib",
                        "<PLAYTOOLS>",
                    ])
                ),
                .exact(
                    jsonStringArray([
                        "/System/iOSSupport/usr/lib/swift/"
                            + "libswiftUIKit.dylib",
                        "/usr/lib/libSystem.B.dylib",
                        "@executable_path/Frameworks/"
                            + "IOSUsePlayRuntime.framework/"
                            + "IOSUsePlayRuntime",
                    ])
                ),
                "The locally permitted Runtime substitution changes exactly "
                    + "one dependency path.",
                "PlayTools.installInIPA",
                "PlayTools.injectRuntime"
            ),
            allowance(
                "main-runtime-sandbox",
                "Fixture",
                arm64 + "signature.entitlements."
                    + "com.apple.security.temporary-exception.sbpl",
                .exact(entitlementStringArray(pinnedSandbox)),
                .exact(entitlementStringArray(iosUseSandbox)),
                "ios-use appends owner-home file and AF_UNIX bind rules required "
                    + "by the direct Runtime socket and PlayChain.",
                "Entitlements.composeEntitlements",
                "PlayCoverUpstreamEngine.composeEntitlements"
            ),
            signatureEvidenceAllowance(
                "main-superblob-length",
                path: "Fixture",
                field: "superBlob.length",
                pinned: "6241",
                iosUse: "7969",
                reason: "The distinct canonical entitlement payloads have "
                    + "different complete SuperBlob lengths."
            ),
            signatureEvidenceAllowance(
                "main-superblob-structure",
                path: "Fixture",
                field: "superBlob.structureSHA256",
                pinned:
                    "bfc22c32540b50c222c8c857a3bced4edb396770e1e472cc"
                        + "c80314f59dfccfcb",
                iosUse:
                    "9c696f32d870c04857eb33bb0e59e5d3da2154c6044a7be1"
                        + "c1fdb1b3eb9d99ed",
                reason: "The exact slot offsets and envelope layout follow "
                    + "the two different entitlement blob sizes."
            ),
            signatureEvidenceAllowance(
                "main-resource-seal-slot",
                path: "Fixture",
                field: "superBlob.slots[type=0,occurrence=0]."
                    + "codeDirectory.specialSlots[-3]",
                pinned:
                    "539c4ff7df096fe00ff51aefcd29f3ce7adc4e2be315ee372"
                        + "4519d2eecaf52d4",
                iosUse:
                    "dd3156e16f9a14b23b4ffdaeb9db0887eacca77acc7a27aaf"
                        + "34decede49d3d2b",
                reason: "The pinned PlayTools/plugin resources and ios-use "
                    + "Runtime resources have distinct exact CodeResources "
                    + "seals."
            ),
            signatureEvidenceAllowance(
                "main-code-slot-zero",
                path: "Fixture",
                field: "superBlob.slots[type=0,occurrence=0]."
                    + "codeDirectory.codeSlots[0]",
                pinned:
                    "0ba86751c7eeb8616eb14d560b4c7e8f8903e101854520f9"
                        + "6edc1c95db87781f",
                iosUse:
                    "db0a6717fd6d5592540f0989fd74dbdf7df42bb80e8887c39"
                        + "3c0d9effd759742",
                reason: "Code slot zero contains the deliberately different "
                    + "injected load command and signature extent."
            ),
            signatureEvidenceAllowance(
                "main-xml-entitlements-slot-length",
                path: "Fixture",
                field: "superBlob.slots[type=5,occurrence=0].length",
                pinned: "2986",
                iosUse: "3884",
                reason: "The compared canonical XML entitlement dictionaries "
                    + "serialize to these exact blob lengths."
            ),
            signatureEvidenceAllowance(
                "main-xml-entitlements-raw-bytes",
                path: "Fixture",
                field: "superBlob.slots[type=5,occurrence=0]."
                    + "normalizedBytesSHA256",
                pinned:
                    "0a7652ac0273840acb038840ead73854a58f76340105fc1210"
                        + "ea7a67033c7aea",
                iosUse:
                    "3f18e655ddc17d07e9e4ffd771dd6b02038bfa91b3f964967"
                        + "068c94c0a47a362",
                reason: "After zeroing only the run-specific managed-home "
                    + "path bytes, the full XML entitlement blobs must match "
                    + "these exact encodings."
            ),
            signatureEvidenceAllowance(
                "main-der-entitlements-slot-offset",
                path: "Fixture",
                field: "superBlob.slots[type=7,occurrence=0].offset",
                pinned: "3931",
                iosUse: "4829",
                reason: "The DER slot starts immediately after the different "
                    + "XML entitlement blob."
            ),
            signatureEvidenceAllowance(
                "main-der-entitlements-slot-length",
                path: "Fixture",
                field: "superBlob.slots[type=7,occurrence=0].length",
                pinned: "2302",
                iosUse: "3132",
                reason: "The decoded and parity-checked DER entitlement "
                    + "dictionaries have these exact encoded lengths."
            ),
            signatureEvidenceAllowance(
                "main-der-entitlements-raw-bytes",
                path: "Fixture",
                field: "superBlob.slots[type=7,occurrence=0]."
                    + "normalizedBytesSHA256",
                pinned:
                    "0c0a0d9d9d91d53004e2d343aedba1b4f6110cea9783bacc"
                        + "6c2fe2ddcce8e08f",
                iosUse:
                    "69ab921a7ad11599dc961ebc273cde53a828ac157bc958561"
                        + "b6cd6e4ffe1d03e",
                reason: "After zeroing only the run-specific managed-home "
                    + "path bytes, the full DER entitlement blobs must match "
                    + "these exact encodings."
            ),
            signatureEvidenceAllowance(
                "main-cms-slot-offset",
                path: "Fixture",
                field: "superBlob.slots[type=65536,occurrence=0].offset",
                pinned: "6233",
                iosUse: "7961",
                reason: "The empty ad-hoc CMS wrapper follows the exact XML "
                    + "and DER entitlement slot extents."
            ),
            signatureEvidenceAllowance(
                "main-der-entitlements-hash",
                path: "Fixture",
                field: "derEntitlementsCanonicalSHA256",
                pinned:
                    "0fefbbc83136bf80b28853dd1c249300f56c34cad6e06600"
                        + "f4fe3f102713c62d",
                iosUse:
                    "bd75e59e2503ecfb9f94c2a74d0078ad14af6fa8dcd4bb5"
                        + "a628faf785fad5e85",
                reason: "DER decoding matches each side's separately allowed "
                    + "canonical XML entitlement dictionary."
            ),
            allowance(
                "main-signature-cdhash",
                "Fixture",
                arm64 + "signature.cdHash",
                .lowercaseHexDigest(length: 40),
                .lowercaseHexDigest(length: 40),
                "The injected dependency and final entitlement payload are "
                    + "different, so each side has a distinct valid 20-byte "
                    + "CodeDirectory digest; immutable bytes and all signature "
                    + "metadata are compared separately.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-signature-entitlements-hash",
                "Fixture",
                arm64 + "signature.entitlementsCanonicalSHA256",
                .exact(
                    "0fefbbc83136bf80b28853dd1c249300f56c34cad6e06600"
                        + "f4fe3f102713c62d"
                ),
                .exact(
                    "bd75e59e2503ecfb9f94c2a74d0078ad14af6fa8dcd4bb5"
                        + "a628faf785fad5e85"
                ),
                "The ios-use Runtime socket/managed-home rules intentionally "
                    + "change the signed main entitlement payload.",
                "Entitlements.composeEntitlements",
                "PlayCoverUpstreamEngine.composeEntitlements"
            ),
            allowance(
                "embedded-runtime-object",
                "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime",
                "object.presence",
                .absent,
                .exact(
                    "present;baseline=ios-use-runtime-input;fileSHA256="
                        + HermeticOneSidedGoldenV1.runtimeSHA256
                ),
                "Pinned PlayCover loads system PlayTools; ios-use embeds and "
                    + "signs its Runtime framework in the managed App.",
                "PlayTools.playToolsPath",
                "PlayCoverUpstreamEngine.prepare"
            ),
            allowance(
                "pinned-akinterface-plugin-object",
                "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface",
                "object.presence",
                .exact(
                    "present;baseline=pinned-akinterface-input;fileSHA256="
                        + HermeticOneSidedGoldenV1.pluginSHA256
                ),
                .absent,
                "Pinned PlayTools installs and signs its AppKit plugin bundle; "
                    + "ios-use deliberately embeds that fixed-window adapter "
                    + "inside its single Runtime framework.",
                "PlayTools.installPluginInIPA",
                "IOSUsePlayRuntime"
            ),
        ]
    }

    private func allowance(
        _ id: String,
        _ path: String,
        _ field: String,
        _ pinned: PlayCoverDifferentialExpectation,
        _ iosUse: PlayCoverDifferentialExpectation,
        _ reason: String,
        _ pinnedSymbol: String,
        _ iosUseSymbol: String
    ) -> PlayCoverDifferentialAllowance {
        PlayCoverDifferentialAllowance(
            id: id,
            relativePath: path,
            field: field,
            pinnedValue: pinned,
            iosUseValue: iosUse,
            reason: reason,
            pinnedSymbol: pinnedSymbol,
            iosUseSymbol: iosUseSymbol
        )
    }

    private func jsonStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else {
            return "<JSON encoding failed>"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func entitlementStringArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private func makeSourceFixture(in root: URL) throws -> URL {
        let app = root.appendingPathComponent(
            "Source/Fixture.app",
            isDirectory: true
        )
        let frameworks = app.appendingPathComponent(
            "Frameworks",
            isDirectory: true
        )
        let framework = frameworks.appendingPathComponent(
            "FixtureKit.framework",
            isDirectory: true
        )
        let appExtension = app.appendingPathComponent(
            "PlugIns/FixtureExtension.appex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: framework,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: appExtension,
            withIntermediateDirectories: true
        )
        let build = root.appendingPathComponent("fixture-build")
        try FileManager.default.createDirectory(
            at: build,
            withIntermediateDirectories: true
        )

        let swiftUIKitSource = build.appendingPathComponent("SwiftUIKit.c")
        try Data(
            "int ios_use_swift_uikit_fixture(void) { return 7; }\n".utf8
        ).write(to: swiftUIKitSource)
        let swiftUIKit = build.appendingPathComponent(
            "libswiftUIKit.dylib"
        )
        try compileIOS(
            source: swiftUIKitSource,
            output: swiftUIKit,
            extraArguments: [
                "-dynamiclib",
                "-Wl,-install_name,@rpath/libswiftUIKit.dylib",
            ]
        )

        let mainSource = build.appendingPathComponent("Fixture.c")
        try Data(
            """
            extern int ios_use_swift_uikit_fixture(void);
            int main(void) { return ios_use_swift_uikit_fixture() == 7 ? 0 : 1; }
            """.utf8
        ).write(to: mainSource)
        let thinMain = build.appendingPathComponent("Fixture-thin")
        try compileIOS(
            source: mainSource,
            output: thinMain,
            extraArguments: [
                swiftUIKit.path,
                "-Wl,-rpath,@executable_path/Frameworks",
            ]
        )
        let secondarySource = build.appendingPathComponent(
            "FixtureSecondary.c"
        )
        try Data("int main(void) { return 0; }\n".utf8).write(
            to: secondarySource
        )
        let x86Main = build.appendingPathComponent("Fixture-x86_64")
        try compileIOSSimulatorX86_64(
            source: secondarySource,
            output: x86Main
        )
        let main = app.appendingPathComponent("Fixture")
        try makeFatMachO(
            arm64: Data(contentsOf: thinMain),
            x86_64: Data(contentsOf: x86Main)
        ).write(to: main)
        try makeExecutable(main)
        let fat64Fixture = frameworks.appendingPathComponent(
            "Fat64Fixture"
        )
        try makeFat64MachO(
            arm64: Data(contentsOf: thinMain),
            x86_64: Data(contentsOf: x86Main)
        ).write(to: fat64Fixture)
        try makeExecutable(fat64Fixture)
        let embeddedSwiftUIKit = frameworks.appendingPathComponent(
            "libswiftUIKit.dylib"
        )
        try FileManager.default.copyItem(
            at: swiftUIKit,
            to: embeddedSwiftUIKit
        )

        let frameworkSource = build.appendingPathComponent("FixtureKit.c")
        try Data(
            "int ios_use_fixture_kit(void) { return 1; }\n".utf8
        ).write(to: frameworkSource)
        let frameworkExecutable = framework.appendingPathComponent(
            "FixtureKit"
        )
        try compileIOS(
            source: frameworkSource,
            output: frameworkExecutable,
            extraArguments: [
                "-dynamiclib",
                "-Wl,-install_name,@rpath/FixtureKit.framework/FixtureKit",
                "-Wl,-rpath,@loader_path/..",
            ]
        )

        let extensionSource = build.appendingPathComponent(
            "FixtureExtension.c"
        )
        try Data("int main(void) { return 0; }\n".utf8).write(
            to: extensionSource
        )
        let extensionExecutable = appExtension.appendingPathComponent(
            "FixtureExtension"
        )
        try compileIOS(
            source: extensionSource,
            output: extensionExecutable,
            extraArguments: []
        )

        try plistData([
            "CFBundleIdentifier": "com.example.differential",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
            "MinimumOSVersion": "17.0",
            "LSApplicationCategoryType": "public.app-category.games",
            "UILaunchScreen": [String: Any](),
        ]).write(to: app.appendingPathComponent("Info.plist"))
        try plistData([
            "CFBundleIdentifier": "com.example.differential.fixturekit",
            "CFBundleExecutable": "FixtureKit",
            "CFBundlePackageType": "FMWK",
            "MinimumOSVersion": "17.0",
        ]).write(to: framework.appendingPathComponent("Info.plist"))
        try plistData([
            "CFBundleIdentifier": "com.example.differential.extension",
            "CFBundleExecutable": "FixtureExtension",
            "CFBundlePackageType": "XPC!",
            "MinimumOSVersion": "17.0",
        ]).write(to: appExtension.appendingPathComponent("Info.plist"))
        try Data("sealed-framework-resource".utf8).write(
            to: framework.appendingPathComponent("asset.dat")
        )
        try Data("sealed-extension-resource".utf8).write(
            to: appExtension.appendingPathComponent("asset.dat")
        )
        try Data("fixture-provision".utf8).write(
            to: app.appendingPathComponent("embedded.mobileprovision")
        )

        let extensionEntitlements = root.appendingPathComponent(
            "extension-entitlements.plist"
        )
        try plistData([
            "application-identifier":
                "TEAM.com.example.differential.extension",
            "com.apple.developer.team-identifier": "TEAM",
            "com.apple.security.application-groups": [
                "group.com.example.differential",
            ],
            "com.example.extension-capability": true,
        ]).write(to: extensionEntitlements)
        let appEntitlements = root.appendingPathComponent(
            "app-entitlements.plist"
        )
        try plistData([
            "application-identifier": "TEAM.com.example.differential",
            "com.apple.developer.team-identifier": "TEAM",
            "keychain-access-groups": [
                "TEAM.com.example.differential",
            ],
            "com.apple.security.application-groups": [
                "group.com.example.differential",
            ],
            "com.apple.developer.icloud-container-identifiers": [
                "iCloud.com.example.differential",
            ],
            "com.apple.developer.associated-domains": [
                "applinks:example.com",
            ],
            "aps-environment": "development",
        ]).write(to: appEntitlements)

        try codesign(embeddedSwiftUIKit, entitlements: nil)
        try codesign(framework, entitlements: nil)
        try codesign(appExtension, entitlements: extensionEntitlements)
        try codesign(app, entitlements: appEntitlements)
        _ = try run(
            "/usr/bin/xattr",
            [
                "-w",
                "com.apple.quarantine",
                "0081;fixture;ios-use;",
                app.path,
            ]
        )
        return app
    }

    private func makeCatalystRuntimeFramework(in root: URL) throws -> URL {
        let framework = root.appendingPathComponent(
            "IOSUsePlayRuntime.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: framework,
            withIntermediateDirectories: true
        )
        try plistData([
            "CFBundleIdentifier": "com.example.IOSUsePlayRuntime",
            "CFBundleExecutable": "IOSUsePlayRuntime",
            "CFBundlePackageType": "FMWK",
        ]).write(to: framework.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("Runtime.c")
        try Data(
            "int ios_use_runtime_fixture(void) { return 1; }\n".utf8
        ).write(to: source)
        let output = framework.appendingPathComponent(
            "IOSUsePlayRuntime"
        )
        let sdk = try run(
            "/usr/bin/xcrun",
            ["--sdk", "macosx", "--show-sdk-path"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(
            "/usr/bin/xcrun",
            [
                "--sdk", "macosx", "clang",
                "-target", "arm64-apple-ios17.0-macabi",
                "-isysroot", sdk,
                "-dynamiclib",
                "-Wl,-headerpad,0x4000",
                "-Wl,-install_name,@rpath/IOSUsePlayRuntime.framework/"
                    + "IOSUsePlayRuntime",
                source.path,
                "-o", output.path,
            ]
        )
        try makeExecutable(output)
        try codesign(framework, entitlements: nil)
        return framework
    }

    private func makePinnedPlayToolsFramework(in root: URL) throws -> URL {
        let framework = root.appendingPathComponent(
            "PinnedPlayCover.app/Contents/Frameworks/PlayTools.framework",
            isDirectory: true
        )
        let plugin = framework.appendingPathComponent(
            "PlugIns/AKInterface.bundle",
            isDirectory: true
        )
        let pluginExecutableParent = plugin.appendingPathComponent(
            "Contents/MacOS",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: pluginExecutableParent,
            withIntermediateDirectories: true
        )
        try plistData([
            "CFBundleIdentifier": "io.playcover.AKInterface.fixture",
            "CFBundleExecutable": "AKInterface",
            "CFBundlePackageType": "BNDL",
        ]).write(to: plugin.appendingPathComponent("Contents/Info.plist"))

        let pluginSource = root.appendingPathComponent(
            "PinnedAKInterface.c"
        )
        try Data(
            "int ios_use_pinned_akinterface_fixture(void) { return 1; }\n".utf8
        ).write(to: pluginSource)
        let pluginExecutable = pluginExecutableParent.appendingPathComponent(
            "AKInterface"
        )
        let macOSSDK = try run(
            "/usr/bin/xcrun",
            ["--sdk", "macosx", "--show-sdk-path"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(
            "/usr/bin/xcrun",
            [
                "--sdk", "macosx", "clang",
                "-target", "arm64-apple-macos13.0",
                "-isysroot", macOSSDK,
                "-bundle",
                "-Wl,-headerpad,0x4000",
                pluginSource.path,
                "-o", pluginExecutable.path,
            ]
        )
        try makeExecutable(pluginExecutable)
        try codesign(plugin, entitlements: nil)

        try plistData([
            "CFBundleIdentifier": "io.playcover.PlayTools.fixture",
            "CFBundleExecutable": "PlayTools",
            "CFBundlePackageType": "FMWK",
        ]).write(to: framework.appendingPathComponent("Info.plist"))
        let frameworkSource = root.appendingPathComponent(
            "PinnedPlayTools.c"
        )
        try Data(
            "int ios_use_pinned_playtools_fixture(void) { return 1; }\n".utf8
        ).write(to: frameworkSource)
        let frameworkExecutable = framework.appendingPathComponent(
            "PlayTools"
        )
        _ = try run(
            "/usr/bin/xcrun",
            [
                "--sdk", "macosx", "clang",
                "-target", "arm64-apple-ios17.0-macabi",
                "-isysroot", macOSSDK,
                "-dynamiclib",
                "-Wl,-headerpad,0x4000",
                "-Wl,-install_name,"
                    + "@rpath/PlayTools.framework/PlayTools",
                frameworkSource.path,
                "-o", frameworkExecutable.path,
            ]
        )
        try makeExecutable(frameworkExecutable)

        let localization = framework.appendingPathComponent(
            "en.lproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localization,
            withIntermediateDirectories: true
        )
        try Data("\"fixture\" = \"pinned\";\n".utf8).write(
            to: localization.appendingPathComponent("Playtools.strings")
        )
        return framework
    }

    private func compileIOS(
        source: URL,
        output: URL,
        extraArguments: [String]
    ) throws {
        let sdk = try run(
            "/usr/bin/xcrun",
            ["--sdk", "iphoneos", "--show-sdk-path"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(
            "/usr/bin/xcrun",
            [
                "--sdk", "iphoneos", "clang",
                "-target", "arm64-apple-ios17.0",
                "-isysroot", sdk,
                "-Wl,-headerpad,0x4000",
            ] + extraArguments + [
                source.path,
                "-o", output.path,
            ]
        )
        try makeExecutable(output)
    }

    private func compileIOSSimulatorX86_64(
        source: URL,
        output: URL
    ) throws {
        let sdk = try run(
            "/usr/bin/xcrun",
            ["--sdk", "iphonesimulator", "--show-sdk-path"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(
            "/usr/bin/xcrun",
            [
                "--sdk", "iphonesimulator", "clang",
                "-target", "x86_64-apple-ios17.0-simulator",
                "-isysroot", sdk,
                "-Wl,-headerpad,0x4000",
                source.path,
                "-o", output.path,
            ]
        )
        try makeExecutable(output)
    }

    private func makeFatMachO(arm64: Data, x86_64: Data) -> Data {
        let arm64Offset = 4_096
        let x86Offset = aligned(
            arm64Offset + arm64.count,
            to: 4_096
        )
        var result = Data([0xca, 0xfe, 0xba, 0xbe])
        appendU32(2, to: &result)
        appendU32(0x0100_000c, to: &result)
        appendU32(0, to: &result)
        appendU32(UInt32(arm64Offset), to: &result)
        appendU32(UInt32(arm64.count), to: &result)
        appendU32(12, to: &result)
        appendU32(0x0100_0007, to: &result)
        appendU32(3, to: &result)
        appendU32(UInt32(x86Offset), to: &result)
        appendU32(UInt32(x86_64.count), to: &result)
        appendU32(12, to: &result)
        result.append(Data(repeating: 0, count: arm64Offset - result.count))
        result.append(arm64)
        result.append(Data(repeating: 0, count: x86Offset - result.count))
        result.append(x86_64)
        return result
    }

    private func makeFat64MachO(arm64: Data, x86_64: Data) -> Data {
        let arm64Offset = 4_096
        let x86Offset = aligned(
            arm64Offset + arm64.count,
            to: 4_096
        )
        var result = Data([0xca, 0xfe, 0xba, 0xbf])
        appendU32(2, to: &result)
        appendU32(0x0100_000c, to: &result)
        appendU32(0, to: &result)
        appendU64(UInt64(arm64Offset), to: &result)
        appendU64(UInt64(arm64.count), to: &result)
        appendU32(12, to: &result)
        appendU32(0, to: &result)
        appendU32(0x0100_0007, to: &result)
        appendU32(3, to: &result)
        appendU64(UInt64(x86Offset), to: &result)
        appendU64(UInt64(x86_64.count), to: &result)
        appendU32(12, to: &result)
        appendU32(0, to: &result)
        result.append(Data(repeating: 0, count: arm64Offset - result.count))
        result.append(arm64)
        result.append(Data(repeating: 0, count: x86Offset - result.count))
        result.append(x86_64)
        return result
    }

    private func aligned(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }

    private func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    private func appendU64(_ value: UInt64, to data: inout Data) {
        data.append(contentsOf: [
            UInt8((value >> 56) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func plistData(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }

    private func infoDictionary(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(
                domain: "PlayCoverPrepareDifferentialTests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Info.plist is not a dictionary: \(url.path)",
                ]
            )
        }
        return value
    }

    private func codesign(_ url: URL, entitlements: URL?) throws {
        var arguments = ["-f", "-s", "-"]
        if let entitlements {
            arguments += ["--entitlements", entitlements.path]
        }
        arguments.append(url.path)
        _ = try run("/usr/bin/codesign", arguments)
    }

    private func pathReplacements(for home: URL) -> [String: String] {
        let lexical = home.standardizedFileURL.path
        let canonical = home.resolvingSymlinksInPath()
            .standardizedFileURL.path
        var result = [lexical: "<MANAGED_HOME>"]
        result[canonical] = "<MANAGED_HOME>"
        result["/private" + lexical] = "<MANAGED_HOME>"
        return result
    }

    private func makeInspection(
        path: String,
        dependencies: [String],
        signature: PlayCoverUpstreamSignature,
        sliceInspections: [PlayCoverUpstreamMachOSliceInspection]? = nil
    ) -> PlayCoverUpstreamMachOInspection {
        PlayCoverUpstreamMachOInspection(
            relativePath: path,
            fileSHA256: String(repeating: "a", count: 64),
            container: .thin,
            arm64SliceOffset: 0,
            arm64SliceSize: 1_024,
            byteSwapped: false,
            cpuType: 0x0100_000c,
            fileType: 2,
            commandCount: 1,
            commandBytes: 24,
            firstSectionOffset: 512,
            platform: 6,
            minimumOS: 0x000b_0000,
            sdk: 0x000e_0000,
            encrypted: false,
            dependencies: dependencies,
            rpaths: [],
            loadCommands: [],
            signature: signature,
            sliceInspections: sliceInspections
        )
    }

    private func makeAppInspection(
        machOs: [PlayCoverUpstreamMachOInspection],
        appPath: String = "/Fixture.app",
        sourceContentHash: String = String(repeating: "b", count: 64),
        infoPlistSHA256: String = String(repeating: "c", count: 64),
        provisioning: PlayCoverUpstreamProvisioningEvidence =
            PlayCoverUpstreamProvisioningEvidence(
                present: false,
                size: nil,
                sha256: nil
            ),
        inventory: [PlayCoverUpstreamInventoryEntry] = []
    ) -> PlayCoverUpstreamAppInspection {
        let signature = machOs.first?.signature
            ?? PlayCoverUpstreamSignature(
                isSigned: false,
                isValid: false,
                entitlementsPlist: nil
        )
        return PlayCoverUpstreamAppInspection(
            appPath: appPath,
            sourceContentHash: sourceContentHash,
            infoPlistSHA256: infoPlistSHA256,
            bundleIdentifier: "com.example.fixture",
            executableName: "Fixture",
            executablePath: appPath + "/Fixture",
            mainExecutableRelativePath: "Fixture",
            signature: signature,
            provisioning: provisioning,
            inventory: inventory,
            machOs: machOs
        )
    }

    private func makePinnedPrepareResult(
        source: PlayCoverUpstreamAppInspection,
        prepared: PlayCoverUpstreamAppInspection,
        producer: PlayCoverPinnedPrepareProducer =
            .fullPlayToolsInstallerOracle
    ) -> PlayCoverPinnedPrimitivePrepareResult {
        PlayCoverPinnedPrimitivePrepareResult(
            sourceBefore: source,
            sourceHashAfterPrepare: source.sourceContentHash,
            prepared: prepared,
            convertedMachOs: prepared.machOs.map(\.relativePath),
            signingOrder: ["."],
            executedPinnedSymbols: ["negative-test"],
            producer: producer
        )
    }

    private func makeIOSUsePrepareResult(
        source: PlayCoverUpstreamAppInspection,
        prepared: PlayCoverUpstreamAppInspection
    ) -> PlayCoverUpstreamPrepareResult {
        PlayCoverUpstreamPrepareResult(
            sourceBefore: source,
            sourceHashAfterPrepare: source.sourceContentHash,
            prepared: prepared,
            convertedMachOs: prepared.machOs.map(\.relativePath),
            signingOrder: ["."],
            entitlementDiff: PlayCoverUpstreamEntitlementDiff(
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

    @discardableResult
    private func run(
        _ executable: String,
        _ arguments: [String]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PlayCoverPrepareDifferentialTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable) "
                        + "\(arguments.joined(separator: " ")): \(text)",
                ]
            )
        }
        return text
    }
}
