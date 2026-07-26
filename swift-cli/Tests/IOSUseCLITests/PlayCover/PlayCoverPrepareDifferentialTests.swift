import Foundation
import PlayCoverUpstream
import XCTest
@testable import IOSUseCLI

final class PlayCoverPrepareDifferentialTests: XCTestCase {
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
        XCTAssertTrue(
            package.contains(
                "exclude: [\"Model/PlayApp.swift\"],"
            )
        )
        XCTAssertEqual(
            package.components(
                separatedBy: "\"Model/PlayApp.swift\""
            ).count - 1,
            1,
            "PlayApp.swift must be named only by the explicit GUI exclusion"
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
        let baselines = [
            PlayCoverDifferentialObjectBaseline(
                id: "pinned-akinterface-input",
                side: .pinned,
                relativePath: pluginRelativePath,
                inspection: pluginBaselineInspection,
                sourceSHA256: pluginBaselineInspection.fileSHA256,
                provenance:
                    "fixture PlayTools.framework resource consumed by "
                    + "PlayTools.installPluginInIPA"
            ),
            PlayCoverDifferentialObjectBaseline(
                id: "ios-use-runtime-input",
                side: .iosUse,
                relativePath: runtimeRelativePath,
                inspection: runtimeBaselineInspection,
                sourceSHA256: runtimeBaselineInspection.fileSHA256,
                provenance:
                    "fixture Runtime framework passed to "
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
        let manifest = try PlayCoverService.prepare(
            sourceAppPath: source.path,
            outputAppPath: candidateOutput.path,
            runtimeFrameworkPath: runtime.path,
            paths: paths
        )
        let iosUse = try PlayCoverUpstreamEngine.inspect(
            appURL: candidateOutput
        )

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
        XCTAssertEqual(manifest.entitlementDiff.removedFromOriginal, [])
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

        var pinnedReplacements = pathReplacements(for: pinnedHome)
        pinnedReplacements[
            PlayCoverPinnedPrimitiveCharacterization.playToolsLoadPath
        ] = "<PLAYTOOLS>"
        let normalization = PlayCoverDifferentialNormalization(
            pinnedPathReplacements: pinnedReplacements,
            iosUsePathReplacements: pathReplacements(
                for: iosUseHome
            )
        )
        let actual = try PlayCoverPrepareDifferentialGate.differences(
            pinned: pinned.prepared,
            iosUse: iosUse,
            oneSidedBaselines: baselines,
            normalization: normalization
        )
        let allowances = makeAllowances(
            pluginBaseline: pluginBaselineInspection,
            runtimeBaseline: runtimeBaselineInspection
        )
        let report = try PlayCoverPrepareDifferentialGate.enforce(
            pinned: pinned.prepared,
            iosUse: iosUse,
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

    private func makeAllowances(
        pluginBaseline: PlayCoverUpstreamMachOInspection,
        runtimeBaseline: PlayCoverUpstreamMachOInspection
    ) -> [PlayCoverDifferentialAllowance] {
        let pinnedSign = "Shell.signAppWith(--deep)"
        let iosUseSign = "PlayCoverUpstreamEngine.signInsideOut"
        let arm64 =
            "slices[cpu=16777228,subtype=0,occurrence=0]."
        let extensionPath =
            "PlugIns/FixtureExtension.appex/FixtureExtension"
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
                "main-signed-size",
                "Fixture",
                arm64 + "size",
                .exact("90096"),
                .exact("92912"),
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
                        + "filesize=27376;maxprot=1;initprot=1;sections=0;"
                        + "flags=0;sha256="
                        + "aa93b8f897221d6f3f3b08c71e71fe77b1dc0fbe2a210ac0"
                        + "b717e518278cace8"
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
                        + "datasize=27072;sha256="
                        + "62bfb13f4eac76422d1acc896c828b12723b819f69b3bbd66"
                        + "fd2e1c0926ff077"
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
                iosUse: "9065",
                reason: "The distinct canonical entitlement payloads have "
                    + "different complete SuperBlob lengths."
            ),
            signatureEvidenceAllowance(
                "main-superblob-padding-size",
                path: "Fixture",
                field: "superBlob.paddingSize",
                pinned: "18015",
                iosUse: "18007",
                reason: "codesign aligns the distinct SuperBlob payloads "
                    + "within their recorded LC_CODE_SIGNATURE extents."
            ),
            signatureEvidenceAllowance(
                "main-superblob-structure",
                path: "Fixture",
                field: "superBlob.structureSHA256",
                pinned:
                    "bfc22c32540b50c222c8c857a3bced4edb396770e1e472cc"
                        + "c80314f59dfccfcb",
                iosUse:
                    "a9238fa7c6ec3a3b3f5ff07075668a230e7cec8d2b29c5d7"
                        + "9428aee7aef56050",
                reason: "The exact slot offsets and envelope layout follow "
                    + "the two different entitlement blob sizes."
            ),
            signatureEvidenceAllowance(
                "main-superblob-padding",
                path: "Fixture",
                field: "superBlob.paddingSHA256",
                pinned:
                    "6374cf23aba8af727e5ee1206e3f182abcbebb2a88ed922cf"
                        + "9eee069b43f438d",
                iosUse:
                    "6b30a91c0f19e68955540a4cb036a2b6b769d771f170cbba"
                        + "d8f316def886ab67",
                reason: "The exact ignored alignment bytes left by each "
                    + "codesign path are retained as signature evidence."
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
                    "8b6e8a3a5f15c3318f6a279c60efec987c791dcf2804c406"
                        + "fb4912d290974ed3",
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
                    "3e237669308e5f410c2a863baa17f27979056b8d3243c001"
                        + "dc03da80e4558bfa",
                reason: "Code slot zero contains the deliberately different "
                    + "injected load command and signature extent."
            ),
            signatureEvidenceAllowance(
                "main-xml-entitlements-slot-length",
                path: "Fixture",
                field: "superBlob.slots[type=5,occurrence=0].length",
                pinned: "2986",
                iosUse: "4559",
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
                    "3cbe6b448be43b6692eafbed9da4d4698cd8b70dcfeeb5e5"
                        + "1a8c9482a6a20a4d",
                reason: "After zeroing only the run-specific managed-home "
                    + "path bytes, the full XML entitlement blobs must match "
                    + "these exact encodings."
            ),
            signatureEvidenceAllowance(
                "main-der-entitlements-slot-offset",
                path: "Fixture",
                field: "superBlob.slots[type=7,occurrence=0].offset",
                pinned: "3931",
                iosUse: "5504",
                reason: "The DER slot starts immediately after the different "
                    + "XML entitlement blob."
            ),
            signatureEvidenceAllowance(
                "main-der-entitlements-slot-length",
                path: "Fixture",
                field: "superBlob.slots[type=7,occurrence=0].length",
                pinned: "2302",
                iosUse: "3553",
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
                    "54d48840922e5363956de7cf363dad2db0f4a6c51b2c83cc"
                        + "60f11f5f0cf8c231",
                reason: "After zeroing only the run-specific managed-home "
                    + "path bytes, the full DER entitlement blobs must match "
                    + "these exact encodings."
            ),
            signatureEvidenceAllowance(
                "main-cms-slot-offset",
                path: "Fixture",
                field: "superBlob.slots[type=65536,occurrence=0].offset",
                pinned: "6233",
                iosUse: "9057",
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
                    "e3ed554e0df736b58dfe4edc90550338b6de5a63ecf8f7c"
                        + "c3ebdbee0399b0ce4",
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
                    "e3ed554e0df736b58dfe4edc90550338b6de5a63ecf8f7c"
                        + "c3ebdbee0399b0ce4"
                ),
                "The ios-use Runtime socket/managed-home rules intentionally "
                    + "change the signed main entitlement payload.",
                "Entitlements.composeEntitlements",
                "PlayCoverUpstreamEngine.composeEntitlements"
            ),
            allowance(
                "main-application-identifier",
                "Fixture",
                arm64 + "signature.entitlements.application-identifier",
                .absent,
                .exact("\"TEAM.com.example.differential\""),
                "ios-use preserves the source application identifier while "
                    + "the pinned final --deep sign drops it.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-push-environment",
                "Fixture",
                arm64 + "signature.entitlements.aps-environment",
                .absent,
                .exact("\"development\""),
                "ios-use preserves the source push environment while the "
                    + "pinned final --deep sign drops it.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-associated-domains",
                "Fixture",
                arm64 + "signature.entitlements."
                    + "com.apple.developer.associated-domains",
                .absent,
                .exact("[\"applinks:example.com\"]"),
                "ios-use preserves the source associated-domain capability.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-icloud-containers",
                "Fixture",
                arm64 + "signature.entitlements."
                    + "com.apple.developer.icloud-container-identifiers",
                .absent,
                .exact("[\"iCloud.com.example.differential\"]"),
                "ios-use preserves the source iCloud container capability.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-team-identifier",
                "Fixture",
                arm64 + "signature.entitlements."
                    + "com.apple.developer.team-identifier",
                .absent,
                .exact("\"TEAM\""),
                "ios-use preserves the source team identifier.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-application-groups",
                "Fixture",
                arm64 + "signature.entitlements."
                    + "com.apple.security.application-groups",
                .absent,
                .exact("[\"group.com.example.differential\"]"),
                "ios-use preserves the source App Group capability.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "main-keychain-groups",
                "Fixture",
                arm64 + "signature.entitlements.keychain-access-groups",
                .absent,
                .exact("[\"TEAM.com.example.differential\"]"),
                "ios-use preserves the source keychain group capability.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "embedded-runtime-object",
                "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime",
                "object.presence",
                .absent,
                .exact(
                    "present;baseline=ios-use-runtime-input;fileSHA256="
                        + runtimeBaseline.fileSHA256
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
                        + pluginBaseline.fileSHA256
                ),
                .absent,
                "Pinned PlayTools installs and signs its AppKit plugin bundle; "
                    + "ios-use deliberately embeds that fixed-window adapter "
                    + "inside its single Runtime framework.",
                "PlayTools.installPluginInIPA",
                "IOSUsePlayRuntime"
            ),
            allowance(
                "extension-signed-size",
                extensionPath,
                arm64 + "size",
                .exact("68032"),
                .exact("68928"),
                "Inside-out signing preserves extension entitlements, so its "
                    + "signed thin-slice is larger than pinned --deep output.",
                pinnedSign,
                iosUseSign
            ),
            signatureEvidenceAllowance(
                "extension-superblob-length",
                path: extensionPath,
                field: "superBlob.length",
                pinned: "691",
                iosUse: "1585",
                reason: "Only ios-use preserves the extension entitlement "
                    + "slots, producing this exact SuperBlob extent."
            ),
            signatureEvidenceAllowance(
                "extension-superblob-padding-size",
                path: extensionPath,
                field: "superBlob.paddingSize",
                pinned: "18013",
                iosUse: "18015",
                reason: "The two extension SuperBlobs have distinct exact "
                    + "alignment extents within LC_CODE_SIGNATURE."
            ),
            signatureEvidenceAllowance(
                "extension-superblob-structure",
                path: extensionPath,
                field: "superBlob.structureSHA256",
                pinned:
                    "02ab98f005a9f33d71005e0fce048eca18fc7bfda67b8ec0"
                        + "b9805a7182be7268",
                iosUse:
                    "3f50f1d3ad7c4f32a2056a095f092d8024a1eb326030111c"
                        + "3ade929bebe62e51",
                reason: "The exact envelope records the two additional "
                    + "ios-use entitlement slots and shifted offsets."
            ),
            signatureEvidenceAllowance(
                "extension-superblob-padding",
                path: extensionPath,
                field: "superBlob.paddingSHA256",
                pinned:
                    "a751f72fbbaea8b15333f8f9ddc6920d239e7987b7e8813a"
                        + "20bc4905c30d755a",
                iosUse:
                    "db67065cb20b009ec3df05a65c66fc14d13499cddfef6f82"
                        + "bcf38352ca7ed6d6",
                reason: "The exact ignored padding left by each codesign path "
                    + "is retained and explicitly allowed."
            ),
            signatureEvidenceAllowance(
                "extension-superblob-slot-count",
                path: extensionPath,
                field: "superBlob.slots.count",
                pinned: "3",
                iosUse: "5",
                reason: "ios-use adds exactly XML and DER entitlement slots "
                    + "that pinned --deep omits."
            ),
            signatureEvidenceAllowance(
                "extension-code-directory-offset",
                path: extensionPath,
                field: "superBlob.slots[type=0,occurrence=0].offset",
                pinned: "36",
                iosUse: "52",
                reason: "The larger ios-use SuperBlob index table shifts the "
                    + "primary CodeDirectory by sixteen bytes."
            ),
            signatureEvidenceAllowance(
                "extension-code-directory-length",
                path: extensionPath,
                field: "superBlob.slots[type=0,occurrence=0].length",
                pinned: "635",
                iosUse: "763",
                reason: "Preserved extension entitlements add four signed "
                    + "special-slot hash positions."
            ),
            signatureEvidenceAllowance(
                "extension-code-directory-structure",
                path: extensionPath,
                field: "superBlob.slots[type=0,occurrence=0]."
                    + "codeDirectory.structureSHA256",
                pinned:
                    "e63fc62d1f394fc81cd29cf5582f76ae6852e5761dc1c31b"
                        + "1fd5c9c256f6896b",
                iosUse:
                    "4bbc536f1bdd55010419df0ea9f29bf4d0ddbebe025d47dea"
                        + "7d22e0215b32cec",
                reason: "The structure hash captures the exact differing "
                    + "special-slot count while excluding hash payloads."
            ),
            signatureEvidenceAllowance(
                "extension-special-slot-minus-four",
                path: extensionPath,
                field: "superBlob.slots[type=0,occurrence=0]."
                    + "codeDirectory.specialSlots[-4]",
                pinned: nil,
                iosUse: String(repeating: "0", count: 64),
                reason: "The preserved entitlement slot range introduces the "
                    + "required empty -4 placeholder."
            ),
            signatureEvidenceAllowance(
                "extension-xml-entitlements-binding",
                path: extensionPath,
                field: "superBlob.slots[type=0,occurrence=0]."
                    + "codeDirectory.specialSlots[-5].binding",
                pinned: nil,
                iosUse: "bound",
                reason: "Only ios-use binds the preserved XML entitlements."
            ),
            signatureEvidenceAllowance(
                "extension-special-slot-minus-six",
                path: extensionPath,
                field: "superBlob.slots[type=0,occurrence=0]."
                    + "codeDirectory.specialSlots[-6]",
                pinned: nil,
                iosUse: String(repeating: "0", count: 64),
                reason: "The preserved DER slot range introduces the required "
                    + "empty -6 placeholder."
            ),
            signatureEvidenceAllowance(
                "extension-der-entitlements-binding",
                path: extensionPath,
                field: "superBlob.slots[type=0,occurrence=0]."
                    + "codeDirectory.specialSlots[-7].binding",
                pinned: nil,
                iosUse: "bound",
                reason: "Only ios-use binds the parity-checked DER "
                    + "entitlements."
            ),
            signatureEvidenceAllowance(
                "extension-code-slot-zero",
                path: extensionPath,
                field: "superBlob.slots[type=0,occurrence=0]."
                    + "codeDirectory.codeSlots[0]",
                pinned:
                    "b7e6b5795a5e9db819dc22a12f707f03985fc17c10f94353"
                        + "61d8f8c43d576dd9",
                iosUse:
                    "8002bfc1676ca44ba2ec5add34afef6033144c16fee81fda8"
                        + "643492975701677",
                reason: "Code slot zero contains the exact differing "
                    + "LC_CODE_SIGNATURE extent."
            ),
            signatureEvidenceAllowance(
                "extension-requirements-slot-offset",
                path: extensionPath,
                field: "superBlob.slots[type=2,occurrence=0].offset",
                pinned: "671",
                iosUse: "815",
                reason: "The identical requirement blob follows the exact "
                    + "differently sized CodeDirectory."
            ),
            signatureEvidenceAllowance(
                "extension-xml-entitlements-slot",
                path: extensionPath,
                field: "superBlob.slots[type=5,occurrence=0].presence",
                pinned: nil,
                iosUse:
                    "present;index=2;offset=827;type=5;magic=0xfade7171;"
                        + "length=507;normalizedBytesSHA256="
                        + "44b5de8a6f64ae13e1d5f98a89d2976f66e4ffc8b9b975b1"
                        + "1855a2799edcb50e",
                reason: "ios-use preserves exactly one XML entitlement slot "
                    + "with this path-normalized raw encoding."
            ),
            signatureEvidenceAllowance(
                "extension-cms-slot-index",
                path: extensionPath,
                field: "superBlob.slots[type=65536,occurrence=0].index",
                pinned: "2",
                iosUse: "4",
                reason: "The identical empty CMS wrapper follows the two "
                    + "additional entitlement table entries."
            ),
            signatureEvidenceAllowance(
                "extension-cms-slot-offset",
                path: extensionPath,
                field: "superBlob.slots[type=65536,occurrence=0].offset",
                pinned: "683",
                iosUse: "1577",
                reason: "The CMS wrapper follows the exact CodeDirectory, "
                    + "requirements, XML, and DER slot extents."
            ),
            signatureEvidenceAllowance(
                "extension-der-entitlements-slot",
                path: extensionPath,
                field: "superBlob.slots[type=7,occurrence=0].presence",
                pinned: nil,
                iosUse:
                    "present;index=3;offset=1334;type=7;magic=0xfade7172;"
                        + "length=243;normalizedBytesSHA256="
                        + "d836ebc012cf2cf760d6d2f21f20faffe5a7c8557a9814e1"
                        + "7b5daff854b9bf2b",
                reason: "ios-use preserves exactly one DER entitlement slot "
                    + "with this path-normalized raw encoding."
            ),
            signatureEvidenceAllowance(
                "extension-der-entitlements-hash",
                path: extensionPath,
                field: "derEntitlementsCanonicalSHA256",
                pinned: nil,
                iosUse:
                    "30df76f405220f89fd06a6d1aa1a29baddaa1fbf6f6fd622"
                        + "6224bba002ac2648",
                reason: "The decoded DER dictionary exactly matches the "
                    + "separately compared preserved XML entitlements."
            ),
            allowance(
                "extension-linkedit-command",
                extensionPath,
                arm64 + "loadCommands[2]",
                .exact(
                    "cmd=0x00000019;size=72;semantic=segment=__LINKEDIT;"
                        + "vmaddr=4295016448;vmsize=32768;fileoff=49152;"
                        + "filesize=18880;maxprot=1;initprot=1;sections=0;"
                        + "flags=0;sha256="
                        + "79287df6792b5a42fc0da9777505760011f2fe1d8f7738cae"
                        + "1b7fa0a2d2fdc64"
                ),
                .exact(
                    "cmd=0x00000019;size=72;semantic=segment=__LINKEDIT;"
                        + "vmaddr=4295016448;vmsize=32768;fileoff=49152;"
                        + "filesize=19776;maxprot=1;initprot=1;sections=0;"
                        + "flags=0;sha256="
                        + "46c911dd74a600ed9f6036bf1ef49a88e1e74795772ddf025"
                        + "bb0e0deebe27df1"
                ),
                "Preserved extension entitlements change the __LINKEDIT "
                    + "signature extent.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "extension-code-signature-command",
                extensionPath,
                arm64 + "loadCommands[15]",
                .exact(
                    "cmd=0x0000001d;size=16;semantic=dataoff=49328;"
                        + "datasize=18704;sha256="
                        + "d1d67e07cf6766879c042ae0b59d357c0f4e730aa328062c"
                        + "019f55f7d9116598"
                ),
                .exact(
                    "cmd=0x0000001d;size=16;semantic=dataoff=49328;"
                        + "datasize=19600;sha256="
                        + "bc622e5b5cae94fc611287502ff498450fdcca35a7ff2e6b"
                        + "1dbfa93e7656a33b"
                ),
                "Preserved extension entitlements change only the "
                    + "LC_CODE_SIGNATURE payload.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "extension-signature-cdhash",
                extensionPath,
                arm64 + "signature.cdHash",
                .lowercaseHexDigest(length: 40),
                .lowercaseHexDigest(length: 40),
                "Preserving source extension capabilities changes its "
                    + "CodeDirectory digest; immutable bytes and all other "
                    + "signature metadata are compared separately.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "extension-code-directory-slots",
                extensionPath,
                arm64 + "signature.codeDirectory.hashes",
                .exact("13+3"),
                .exact("13+7"),
                "The preserved extension entitlement payload contributes "
                    + "additional signed special slots.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "extension-signature-entitlements-hash",
                extensionPath,
                arm64 + "signature.entitlementsCanonicalSHA256",
                .absent,
                .exact(
                    "30df76f405220f89fd06a6d1aa1a29baddaa1fbf6f6fd622"
                        + "6224bba002ac2648"
                ),
                "Pinned --deep drops extension entitlements while ios-use "
                    + "inside-out signing restores their signed payload.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "extension-application-identifier",
                extensionPath,
                arm64 + "signature.entitlements.application-identifier",
                .absent,
                .exact("\"TEAM.com.example.differential.extension\""),
                "ios-use restores the source extension application identifier "
                    + "after pinned --deep signing drops it.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "extension-team-identifier",
                extensionPath,
                arm64 + "signature.entitlements."
                    + "com.apple.developer.team-identifier",
                .absent,
                .exact("\"TEAM\""),
                "ios-use restores the source extension team identifier after "
                    + "pinned --deep signing drops it.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "extension-application-group",
                extensionPath,
                arm64 + "signature.entitlements."
                    + "com.apple.security.application-groups",
                .absent,
                .exact("[\"group.com.example.differential\"]"),
                "ios-use restores the source extension App Group after pinned "
                    + "--deep signing drops it.",
                pinnedSign,
                iosUseSign
            ),
            allowance(
                "extension-custom-capability",
                extensionPath,
                arm64 + "signature.entitlements."
                    + "com.example.extension-capability",
                .absent,
                .exact("true"),
                "ios-use restores the representative extension capability "
                    + "after pinned --deep signing drops it.",
                pinnedSign,
                iosUseSign
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
        machOs: [PlayCoverUpstreamMachOInspection]
    ) -> PlayCoverUpstreamAppInspection {
        let signature = machOs.first?.signature
            ?? PlayCoverUpstreamSignature(
                isSigned: false,
                isValid: false,
                entitlementsPlist: nil
            )
        return PlayCoverUpstreamAppInspection(
            appPath: "/Fixture.app",
            sourceContentHash: String(repeating: "b", count: 64),
            infoPlistSHA256: String(repeating: "c", count: 64),
            bundleIdentifier: "com.example.fixture",
            executableName: "Fixture",
            executablePath: "/Fixture.app/Fixture",
            mainExecutableRelativePath: "Fixture",
            signature: signature,
            provisioning: PlayCoverUpstreamProvisioningEvidence(
                present: false,
                size: nil,
                sha256: nil
            ),
            inventory: [],
            machOs: machOs
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
