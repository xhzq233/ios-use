import Foundation
import XCTest
@testable import PlayCoverUpstream

final class PlayCoverUpstreamEngineTests: XCTestCase {
    func testLengthFramedTreeHashDistinguishesAmbiguousTrees() throws {
        let first = try makeApp(executable: makeThinMachO(dependencies: []))
        let second = try makeApp(executable: makeThinMachO(dependencies: []))
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        try Data([0x62, 0x00, 0x63]).write(
            to: first.app.appendingPathComponent("a")
        )
        try Data([0x63]).write(
            to: second.app.appendingPathComponent("a-b")
        )
        XCTAssertNotEqual(
            try PlayCoverUpstreamEngine.contentHash(appURL: first.app),
            try PlayCoverUpstreamEngine.contentHash(appURL: second.app)
        )
    }

    func testInfoPlistSymlinkEscapeIsRejectedBeforeExternalWrite() throws {
        let fixture = try makeApp(
            executable: makeThinMachO(dependencies: [])
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("external.plist")
        let original = try Data(
            contentsOf: fixture.app.appendingPathComponent("Info.plist")
        )
        try original.write(to: external)
        try FileManager.default.removeItem(
            at: fixture.app.appendingPathComponent("Info.plist")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.app.appendingPathComponent("Info.plist"),
            withDestinationURL: external
        )

        XCTAssertThrowsError(
            try PlayCoverUpstreamEngine.inspect(appURL: fixture.app)
        ) {
            XCTAssertTrue(
                String(describing: $0).contains(
                    "absolute symbolic link is not clone-safe"
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: external), original)
    }

    func testAbsoluteInternalSymlinkIsRejectedBeforePrepareWritesSource()
        throws
    {
        let fixture = try makeApp(
            executable: makeThinMachO(dependencies: [])
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let info = fixture.app.appendingPathComponent("Info.plist")
        let actual = fixture.app.appendingPathComponent(
            "ActualInfo.plist"
        )
        let before = try Data(contentsOf: info)
        try FileManager.default.moveItem(at: info, to: actual)
        try FileManager.default.createSymbolicLink(
            at: info,
            withDestinationURL: actual
        )
        let permissionsBefore = try XCTUnwrap(
            try FileManager.default.attributesOfItem(
                atPath: actual.path
            )[.posixPermissions] as? NSNumber
        )
        let staging = fixture.root.appendingPathComponent(
            "managed/playcover/prepared/Fixture.app",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try PlayCoverUpstreamEngine.prepare(
                PlayCoverUpstreamPrepareOptions(
                    sourceApp: fixture.app,
                    stagingApp: staging,
                    runtimeFramework: fixture.root
                        .appendingPathComponent(
                            "Unused.framework",
                            isDirectory: true
                        ),
                    managedHome: fixture.root.appendingPathComponent(
                        "managed",
                        isDirectory: true
                    ),
                    runtimeSocketPath: fixture.root
                        .appendingPathComponent("runtime.sock").path,
                    runtimeLoadPath:
                        "@executable_path/Frameworks/"
                        + "IOSUsePlayRuntime.framework/"
                        + "IOSUsePlayRuntime"
                )
            )
        ) {
            XCTAssertTrue(
                String(describing: $0).contains(
                    "absolute symbolic link is not clone-safe"
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: actual), before)
        XCTAssertEqual(
            try XCTUnwrap(
                try FileManager.default.attributesOfItem(
                    atPath: actual.path
                )[.posixPermissions] as? NSNumber
            ),
            permissionsBefore
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging.path)
        )
    }

    func testTightHeaderPaddingRejectsBeforeMachOMutation() throws {
        var bytes = makeThinMachO(dependencies: [])
        let inspectionFixture = try makeApp(executable: bytes)
        defer {
            try? FileManager.default.removeItem(at: inspectionFixture.root)
        }
        let executable = inspectionFixture.app.appendingPathComponent(
            "Fixture"
        )
        let initial = try PlayCoverUpstreamEngine.inspect(
            appURL: inspectionFixture.app
        ).mainExecutableRelativePath
        XCTAssertEqual(initial, "Fixture")
        let inspected = try PlayCoverUpstreamEngine.inspectMachO(
            at: executable,
            relativePath: "Fixture"
        )
        let commandsEnd = UInt32(32 + inspected.commandBytes)
        bytes.replaceSubrange(
            152..<156,
            with: withUnsafeBytes(of: commandsEnd.littleEndian) {
                Data($0)
            }
        )
        bytes.append(contentsOf: [0xff, 0xfe, 0xfd])
        try bytes.write(to: executable)
        let tight = try PlayCoverUpstreamEngine.inspectMachO(
            at: executable,
            relativePath: "Fixture"
        )
        let before = try Data(contentsOf: executable)
        XCTAssertThrowsError(
            try PlayCoverUpstreamEngine.preflightMachOMutations(
                tight,
                runtimeLoadPath:
                    "@executable_path/Frameworks/"
                    + "IOSUsePlayRuntime.framework/IOSUsePlayRuntime"
            )
        ) {
            guard case PlayCoverUpstreamError.insufficientMachOPadding =
                    $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: executable), before)
    }

    func testHeadlessKeyCoverRoundTripPersistsAndIsolatesHomes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstHome = root.appendingPathComponent("home-one")
        let secondHome = root.appendingPathComponent("home-two")
        try FileManager.default.createDirectory(
            at: firstHome,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondHome,
            withIntermediateDirectories: true
        )
        let bundleID = "com.example.keycover.\(UUID().uuidString)"
        let payload = Data("persistent-playchain".utf8)

        _ = try PlayCoverHeadlessKeyCover.configure(
            managedHome: firstHome
        )
        defer {
            _ = try? PlayCoverHeadlessKeyCover.configure(
                managedHome: firstHome
            )
            KeyCover.shared.restorePersistedKey()
            KeyCoverPassword.shared.removeKeyCoverPassword()
        }
        KeyCoverPassword.shared.setKeyCoverPassword("fixture-secret")
        let firstKey = KeyCoverKey(appBundleID: bundleID)
        try payload.write(to: firstKey.decryptedKeyDB)
        try PlayCoverHeadlessKeyCover.lock(
            bundleIdentifier: bundleID,
            managedHome: firstHome
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: firstKey.decryptedKeyDB.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: firstKey.encryptedKeyDB.path
            )
        )

        KeyCover.shared = KeyCover()
        try PlayCoverHeadlessKeyCover.unlock(
            bundleIdentifier: bundleID,
            managedHome: firstHome
        )
        XCTAssertEqual(
            try Data(contentsOf: firstKey.decryptedKeyDB),
            payload
        )
        try PlayCoverHeadlessKeyCover.lock(
            bundleIdentifier: bundleID,
            managedHome: firstHome
        )

        _ = try PlayCoverHeadlessKeyCover.configure(
            managedHome: secondHome
        )
        XCTAssertNil(KeyCoverPassword.shared.getKeyCoverPassword())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: KeyCoverKey(
                    appBundleID: bundleID
                ).encryptedKeyDB.path
            )
        )
    }

    func testInspectThinArm64CapturesBuildDependencyAndResourceInventory() throws {
        let fixture = try makeApp(
            executable: makeThinMachO(
                dependencies: ["@rpath/libswiftUIKit.dylib"]
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("fixture-resource".utf8).write(
            to: fixture.app.appendingPathComponent("asset.dat")
        )

        let result = try PlayCoverUpstreamEngine.inspect(appURL: fixture.app)

        XCTAssertEqual(result.bundleIdentifier, "com.example.fixture")
        XCTAssertEqual(result.executableName, "Fixture")
        XCTAssertEqual(result.machOs.count, 1)
        XCTAssertEqual(result.machOs[0].container, .thin)
        XCTAssertEqual(result.machOs[0].platform, 2)
        XCTAssertEqual(
            result.machOs[0].dependencies,
            ["@rpath/libswiftUIKit.dylib"]
        )
        XCTAssertTrue(
            result.inventory.contains {
                $0.relativePath == "asset.dat"
                    && $0.kind == .regularFile
                    && $0.sha256 != nil
            }
        )
        XCTAssertEqual(result.sourceContentHash.count, 64)
    }

    func testInspectFatArm64SelectsBoundedSlice() throws {
        let thin = makeThinMachO(dependencies: [])
        let fixture = try makeApp(executable: makeFatMachO(arm64: thin))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try PlayCoverUpstreamEngine.inspect(appURL: fixture.app)

        XCTAssertEqual(result.machOs[0].container, .fat)
        XCTAssertEqual(result.machOs[0].arm64SliceOffset, 4_096)
        XCTAssertEqual(result.machOs[0].arm64SliceSize, UInt64(thin.count))
    }

    func testInspectByteSwappedThinArm64() throws {
        let fixture = try makeApp(
            executable: makeThinMachO(
                dependencies: ["/usr/lib/libSystem.B.dylib"],
                bigEndian: true
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try PlayCoverUpstreamEngine.inspect(appURL: fixture.app)

        XCTAssertTrue(result.machOs[0].byteSwapped)
        XCTAssertEqual(result.machOs[0].platform, 2)
        XCTAssertEqual(
            result.machOs[0].dependencies,
            ["/usr/lib/libSystem.B.dylib"]
        )
    }

    func testEncryptedMachOIsManifestedWithoutMutation() throws {
        let bytes = makeThinMachO(dependencies: [], encrypted: true)
        let fixture = try makeApp(executable: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try PlayCoverUpstreamEngine.inspect(appURL: fixture.app)

        XCTAssertTrue(result.machOs[0].encrypted)
        XCTAssertEqual(
            try Data(contentsOf: fixture.app.appendingPathComponent("Fixture")),
            bytes
        )
    }

    func testMalformedFatSliceIsRejected() throws {
        var fat = Data([0xca, 0xfe, 0xba, 0xbe])
        appendU32(1, to: &fat, bigEndian: true)
        appendU32(0x0100_000c, to: &fat, bigEndian: true)
        appendU32(0, to: &fat, bigEndian: true)
        appendU32(4_096, to: &fat, bigEndian: true)
        appendU32(8_192, to: &fat, bigEndian: true)
        appendU32(12, to: &fat, bigEndian: true)
        let fixture = try makeApp(executable: fat)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try PlayCoverUpstreamEngine.inspect(appURL: fixture.app)
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("out of bounds")
            )
        }
    }

    func testPinnedConversionInjectionAndSigningHandleFatAndFat64() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let thinURL = try makeRealIOSExecutable(in: root, name: "Thin")
        let thin = try Data(contentsOf: thinURL)
        let runtimeLoadPath =
            "@executable_path/Frameworks/IOSUsePlayRuntime.framework/"
                + "IOSUsePlayRuntime"

        for (name, bytes, expectedContainer) in [
            ("Fat", makeFatMachO(arm64: thin),
             PlayCoverUpstreamMachOContainer.fat),
            ("FatSwapped", makeFatMachO(arm64: thin, bigEndian: false),
             PlayCoverUpstreamMachOContainer.fat),
            ("Fat64", makeFat64MachO(arm64: thin),
             PlayCoverUpstreamMachOContainer.fat64),
            (
                "Fat64Swapped",
                makeFat64MachO(arm64: thin, bigEndian: false),
                PlayCoverUpstreamMachOContainer.fat64
            ),
        ] {
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
            XCTAssertEqual(
                try PlayCoverUpstreamEngine.inspectMachO(
                    at: url,
                    relativePath: name
                ).container,
                expectedContainer
            )

            let converted = try PlayCoverUpstreamEngine.convertMachO(
                at: url,
                relativePath: name,
                injectRuntime: true,
                runtimeLoadPath: runtimeLoadPath
            )
            XCTAssertEqual(converted.container, .thin)
            XCTAssertEqual(
                converted.platform,
                PlayCoverUpstreamEngine.platformMacCatalyst
            )
            XCTAssertEqual(
                converted.dependencies.filter { $0 == runtimeLoadPath }.count,
                1
            )
            try Shell.signMacho(url)
            _ = try Shell.run(
                print: false,
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                url.path
            )
            XCTAssertThrowsError(
                try PlayCoverUpstreamEngine.convertMachO(
                    at: url,
                    relativePath: name,
                    injectRuntime: true,
                    runtimeLoadPath: runtimeLoadPath
                )
            ) { error in
                guard case PlayCoverUpstreamError.duplicateRuntimeLoad =
                        error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testPinnedConversionRewritesSwiftUIKitDependency() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("SwiftFixture")
        try makeThinMachO(
            dependencies: ["@rpath/libswiftUIKit.dylib"]
        ).write(to: url)

        let result = try PlayCoverUpstreamEngine.convertMachO(
            at: url,
            relativePath: "SwiftFixture",
            injectRuntime: false,
            runtimeLoadPath: "unused"
        )

        XCTAssertEqual(
            result.dependencies,
            ["/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib"]
        )
        XCTAssertEqual(
            result.platform,
            PlayCoverUpstreamEngine.platformMacCatalyst
        )
    }

    func testRuntimeDuplicateIsRejectedByExactPathAndBasename() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeLoadPath =
            "@executable_path/Frameworks/IOSUsePlayRuntime.framework/"
                + "IOSUsePlayRuntime"
        for (index, dependency) in [
            runtimeLoadPath,
            "@rpath/Elsewhere/IOSUsePlayRuntime",
        ].enumerated() {
            let url = root.appendingPathComponent("Duplicate-\(index)")
            try makeThinMachO(dependencies: [dependency]).write(to: url)
            XCTAssertThrowsError(
                try PlayCoverUpstreamEngine.convertMachO(
                    at: url,
                    relativePath: url.lastPathComponent,
                    injectRuntime: true,
                    runtimeLoadPath: runtimeLoadPath
                )
            ) { error in
                guard case PlayCoverUpstreamError.duplicateRuntimeLoad =
                        error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testNestedExtensionFrameworkAndResourcesAreInventoried() throws {
        let fixture = try makeApp(
            executable: makeThinMachO(dependencies: [])
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let extensionURL = fixture.app
            .appendingPathComponent("PlugIns/Test.appex", isDirectory: true)
        let frameworkURL = fixture.app
            .appendingPathComponent("Frameworks/Test.framework",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: frameworkURL,
            withIntermediateDirectories: true
        )
        try makeThinMachO(dependencies: []).write(
            to: extensionURL.appendingPathComponent("TestExtension")
        )
        try makeThinMachO(dependencies: []).write(
            to: frameworkURL.appendingPathComponent("Test")
        )
        try Data("extension-resource".utf8).write(
            to: extensionURL.appendingPathComponent("asset.dat")
        )

        let result = try PlayCoverUpstreamEngine.inspect(appURL: fixture.app)

        XCTAssertTrue(result.machOs.contains {
            $0.relativePath == "PlugIns/Test.appex/TestExtension"
        })
        XCTAssertTrue(result.machOs.contains {
            $0.relativePath == "Frameworks/Test.framework/Test"
        })
        XCTAssertTrue(result.inventory.contains {
            $0.relativePath == "PlugIns/Test.appex/asset.dat"
                && $0.sha256 != nil
        })
        XCTAssertTrue(result.inventory.contains {
            $0.relativePath == "PlugIns/Test.appex"
                && $0.codeObjectKind == "appExtensionBundle"
        })
    }

    func testPinnedEntitlementComposerPreservesRepresentativeCapabilities()
        throws {
        let fixture = try makeApp(
            executable: makeThinMachO(dependencies: [])
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let managed = fixture.root.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        try PlayTools.configureManagedContainer(managed)
        let original: [String: Any] = [
            "application-identifier": "TEAM.com.example.fixture",
            "com.apple.developer.team-identifier": "TEAM",
            "keychain-access-groups": ["TEAM.com.example.fixture"],
            "com.apple.security.application-groups": ["group.fixture"],
            "com.apple.developer.icloud-container-identifiers": [
                "iCloud.com.example.fixture",
            ],
            "aps-environment": "production",
            "com.apple.developer.associated-domains": [
                "applinks:example.com",
            ],
        ]
        let originalData = try PropertyListSerialization.data(
            fromPropertyList: original,
            format: .xml,
            options: 0
        )
        let socket = fixture.root
            .appendingPathComponent("run/s-one.sock").path

        let composition = try PlayCoverUpstreamEngine.composeEntitlements(
            appURL: fixture.app,
            originalPlist: originalData,
            runtimeSocketPath: socket,
            playSignActive: false
        )
        let final = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: composition.finalPlist,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        for key in original.keys {
            XCTAssertNotNil(final[key], "lost original entitlement \(key)")
        }
        XCTAssertTrue(composition.diff.removedFromOriginal.isEmpty)
        let sandbox = try XCTUnwrap(
            final["com.apple.security.temporary-exception.sbpl"]
                as? [String]
        )
        XCTAssertTrue(sandbox.contains {
            $0.contains(fixture.root.appendingPathComponent("run").path)
        })
        XCTAssertFalse(sandbox.contains { $0.contains("s-one.sock") })
    }

    func testEntitlementComposerCanonicalizesTmpSandboxPaths()
        throws {
        let lexicalRoot = URL(
            fileURLWithPath:
                "/tmp/ios-use-play-sandbox-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: lexicalRoot)
        }
        let app = lexicalRoot.appendingPathComponent(
            "Fixture.app",
            isDirectory: true
        )
        let run = lexicalRoot.appendingPathComponent(
            "playcover/run",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: run,
            withIntermediateDirectories: true
        )
        try plistData([
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
        ]).write(to: app.appendingPathComponent("Info.plist"))

        let composition =
            try PlayCoverUpstreamEngine.composeEntitlements(
                appURL: app,
                originalPlist: nil,
                runtimeSocketPath: run.appendingPathComponent(
                    "s-runtime.sock"
                ).path,
                managedHome: lexicalRoot,
                playSignActive: false
            )
        let final = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: composition.finalPlist,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let sandbox = try XCTUnwrap(
            final["com.apple.security.temporary-exception.sbpl"]
                as? [String]
        )
        let canonicalRoot = "/private\(lexicalRoot.path)"
        XCTAssertTrue(canonicalRoot.hasPrefix("/private/tmp/"))
        let iosUseRules = sandbox.filter {
            $0.contains(
                "(allow file-read* file-write* file-read-metadata"
            )
        }
        XCTAssertTrue(iosUseRules.contains {
            $0.contains(canonicalRoot)
        })
        XCTAssertFalse(iosUseRules.contains {
            $0.contains(
                "(subpath \"\(lexicalRoot.path)"
            )
        })
        XCTAssertTrue(sandbox.contains {
            $0 == "(allow network-bind (subpath \""
                + "\(canonicalRoot)/playcover/run\"))"
        })
    }

    func testInfoCompatibilityPreservesLaunchAndSceneDeclarations()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let infoURL = root.appendingPathComponent("Info.plist")
        let scene: [String: Any] = [
            "UIApplicationSupportsMultipleScenes": false,
            "UISceneConfigurations": [
                "UIWindowSceneSessionRoleApplication": [
                    ["UISceneConfigurationName": "Default"],
                ],
            ],
        ]
        try plistData([
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleExecutable": "Fixture",
            "MinimumOSVersion": "17.0",
            "UILaunchStoryboardName": "LaunchScreen",
            "UIApplicationSceneManifest": scene,
        ]).write(to: infoURL)

        try PlayCoverUpstreamEngine.updateInfoPlist(infoURL)

        let result = try XCTUnwrap(NSDictionary(contentsOf: infoURL))
        XCTAssertEqual(result["MinimumOSVersion"] as? String, "11")
        XCTAssertEqual(
            result["UILaunchStoryboardName"] as? String,
            "LaunchScreen"
        )
        XCTAssertNil(result["UILaunchScreen"])
        XCTAssertEqual(
            result["UIApplicationSceneManifest"] as? NSDictionary,
            scene as NSDictionary
        )
    }

    func testInfoCompatibilityAddsModernLaunchDeclarationForEmptyLegacyName()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let infoURL = root.appendingPathComponent("Info.plist")
        try plistData([
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleExecutable": "Fixture",
            "UILaunchStoryboardName": "",
        ]).write(to: infoURL)

        try PlayCoverUpstreamEngine.updateInfoPlist(infoURL)

        let result = try XCTUnwrap(NSDictionary(contentsOf: infoURL))
        XCTAssertEqual(result["UILaunchStoryboardName"] as? String, "")
        XCTAssertNotNil(result["UILaunchScreen"] as? NSDictionary)
    }

    func testNestedBundleSigningPreservesExtensionEntitlements() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(
            "Source.app",
            isDirectory: true
        )
        try makeHostAppWithExtension(at: source)
        let extensionURL = source.appendingPathComponent(
            "PlugIns/Test.appex",
            isDirectory: true
        )
        let extensionEntitlements: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.application-groups": ["group.fixture"],
            "com.example.extension-capability": true,
        ]
        let extensionEntitlementsURL = root.appendingPathComponent(
            "extension-entitlements.plist"
        )
        try plistData(extensionEntitlements).write(
            to: extensionEntitlementsURL
        )
        try codesign(extensionURL, entitlements: extensionEntitlementsURL)
        try codesign(source, entitlements: nil)
        let sourceInspection = try PlayCoverUpstreamEngine.inspect(
            appURL: source
        )

        let prepared = root.appendingPathComponent(
            "Prepared.app",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: source, to: prepared)
        let mainEntitlements = try plistData([
            "com.apple.security.app-sandbox": true,
        ])
        let order = try PlayCoverUpstreamEngine.signInsideOut(
            appURL: prepared,
            source: sourceInspection,
            finalEntitlements: mainEntitlements
        )

        XCTAssertTrue(order.contains("PlugIns/Test.appex"))
        XCTAssertFalse(order.contains("PlugIns/Test.appex/TestExtension"))
        XCTAssertEqual(order.last, ".")
        let preparedExtensionExecutable = prepared.appendingPathComponent(
            "PlugIns/Test.appex/TestExtension"
        )
        let evidence = try PlayCoverUpstreamEngine.inspectMachO(
            at: preparedExtensionExecutable,
            relativePath: "PlugIns/Test.appex/TestExtension"
        ).signature
        let restored = try XCTUnwrap(
            evidence.entitlementsPlist.flatMap {
                try? PropertyListSerialization.propertyList(
                    from: $0,
                    options: [],
                    format: nil
                ) as? [String: Any]
            }
        )
        XCTAssertEqual(
            restored["com.example.extension-capability"] as? Bool,
            true
        )
        XCTAssertEqual(
            restored["com.apple.security.application-groups"] as? [String],
            ["group.fixture"]
        )
        for codeObject in [extensionURL.lastPathComponent, "."] {
            let url = codeObject == "."
                ? prepared
                : prepared.appendingPathComponent("PlugIns/Test.appex")
            _ = try Shell.run(
                print: false,
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                url.path
            )
        }
    }

    func testCompleteHeadlessPrepareUsesPinnedInstallerPipeline() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(
            "Source.app",
            isDirectory: true
        )
        try makeIOSAppWithExtension(at: source, root: root)
        let sourceExecutable = source.appendingPathComponent("Fixture")
        let sourceExecutableBefore = try Data(contentsOf: sourceExecutable)
        let sourceHashBefore = try PlayCoverUpstreamEngine.contentHash(
            appURL: source
        )

        let runtime = try makeCatalystRuntimeFramework(in: root)
        let managed = root.appendingPathComponent(
            "managed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managed,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: managed.appendingPathComponent("prepared"),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let staging = managed.appendingPathComponent(
            "prepared/Fixture.app",
            isDirectory: true
        )
        let runtimeLoadPath =
            "@executable_path/Frameworks/IOSUsePlayRuntime.framework/"
                + "IOSUsePlayRuntime"
        let result = try PlayCoverUpstreamEngine.prepare(
            PlayCoverUpstreamPrepareOptions(
                sourceApp: source,
                stagingApp: staging,
                runtimeFramework: runtime,
                managedHome: managed,
                runtimeSocketPath: managed.appendingPathComponent(
                    "run/s-runtime.sock"
                ).path,
                runtimeLoadPath: runtimeLoadPath
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: sourceExecutable),
            sourceExecutableBefore
        )
        XCTAssertEqual(
            try PlayCoverUpstreamEngine.contentHash(appURL: source),
            sourceHashBefore
        )
        XCTAssertEqual(result.sourceHashAfterPrepare, sourceHashBefore)
        XCTAssertTrue(result.convertedMachOs.contains("Fixture"))
        XCTAssertTrue(
            result.convertedMachOs.contains(
                "PlugIns/Test.appex/TestExtension"
            )
        )
        XCTAssertTrue(
            result.prepared.mainExecutableRelativePath == "Fixture"
        )
        XCTAssertEqual(
            result.prepared.machOs.first {
                $0.relativePath == "Fixture"
            }?.dependencies.filter { $0 == runtimeLoadPath }.count,
            1
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staging.appendingPathComponent(
                    "embedded.mobileprovision"
                ).path
            )
        )
        let preparedInfo = try XCTUnwrap(
            NSDictionary(
                contentsOf: staging.appendingPathComponent("Info.plist")
            )
        )
        XCTAssertNotNil(preparedInfo["UILaunchScreen"])
        XCTAssertEqual(preparedInfo["MinimumOSVersion"] as? String, "11")
        XCTAssertEqual(
            try Data(
                contentsOf: staging.appendingPathComponent(
                    "PlugIns/Test.appex/asset.dat"
                )
            ),
            Data("sealed-resource".utf8)
        )
        XCTAssertTrue(
            result.signingOrder.contains("PlugIns/Test.appex")
        )
        XCTAssertTrue(
            result.signingOrder.contains(
                "Frameworks/IOSUsePlayRuntime.framework"
            )
        )
        XCTAssertEqual(result.signingOrder.last, ".")
        XCTAssertTrue(result.entitlementDiff.removedFromOriginal.isEmpty)
        _ = try Shell.run(
            print: false,
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            staging.path
        )
    }

    private struct AppFixture {
        let root: URL
        let app: URL
    }

    private func makeApp(executable: Data) throws -> AppFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlayCoverUpstream-\(UUID().uuidString)",
                isDirectory: true
            )
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleExecutable": "Fixture",
            "MinimumOSVersion": "17.0",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let executableURL = app.appendingPathComponent("Fixture")
        try executable.write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return AppFixture(root: root, app: app)
    }

    private func makeFatMachO(
        arm64: Data,
        bigEndian: Bool = true
    ) -> Data {
        var result = Data(
            bigEndian
                ? [0xca, 0xfe, 0xba, 0xbe]
                : [0xbe, 0xba, 0xfe, 0xca]
        )
        appendU32(1, to: &result, bigEndian: bigEndian)
        appendU32(0x0100_000c, to: &result, bigEndian: bigEndian)
        appendU32(0, to: &result, bigEndian: bigEndian)
        appendU32(4_096, to: &result, bigEndian: bigEndian)
        appendU32(
            UInt32(arm64.count),
            to: &result,
            bigEndian: bigEndian
        )
        appendU32(12, to: &result, bigEndian: bigEndian)
        result.append(Data(repeating: 0, count: 4_096 - result.count))
        result.append(arm64)
        return result
    }

    private func makeFat64MachO(
        arm64: Data,
        bigEndian: Bool = true
    ) -> Data {
        var result = Data(
            bigEndian
                ? [0xca, 0xfe, 0xba, 0xbf]
                : [0xbf, 0xba, 0xfe, 0xca]
        )
        appendU32(1, to: &result, bigEndian: bigEndian)
        appendU32(0x0100_000c, to: &result, bigEndian: bigEndian)
        appendU32(0, to: &result, bigEndian: bigEndian)
        appendU64(4_096, to: &result, bigEndian: bigEndian)
        appendU64(
            UInt64(arm64.count),
            to: &result,
            bigEndian: bigEndian
        )
        appendU32(12, to: &result, bigEndian: bigEndian)
        appendU32(0, to: &result, bigEndian: bigEndian)
        result.append(Data(repeating: 0, count: 4_096 - result.count))
        result.append(arm64)
        return result
    }

    private func makeThinMachO(
        dependencies: [String],
        encrypted: Bool = false,
        bigEndian: Bool = false
    ) -> Data {
        var commands: [Data] = []

        var segment = Data()
        appendU32(0x19, to: &segment, bigEndian: bigEndian)
        appendU32(152, to: &segment, bigEndian: bigEndian)
        segment.append(Data(repeating: 0, count: 56))
        appendU32(1, to: &segment, bigEndian: bigEndian)
        appendU32(0, to: &segment, bigEndian: bigEndian)
        segment.append(Data(repeating: 0, count: 48))
        appendU32(512, to: &segment, bigEndian: bigEndian)
        segment.append(Data(repeating: 0, count: 28))
        commands.append(segment)

        var build = Data()
        appendU32(0x32, to: &build, bigEndian: bigEndian)
        appendU32(24, to: &build, bigEndian: bigEndian)
        appendU32(2, to: &build, bigEndian: bigEndian)
        appendU32(0x0011_0000, to: &build, bigEndian: bigEndian)
        appendU32(0x0011_0400, to: &build, bigEndian: bigEndian)
        appendU32(0, to: &build, bigEndian: bigEndian)
        commands.append(build)

        if encrypted {
            var encryption = Data()
            appendU32(0x2c, to: &encryption, bigEndian: bigEndian)
            appendU32(24, to: &encryption, bigEndian: bigEndian)
            appendU32(0, to: &encryption, bigEndian: bigEndian)
            appendU32(0, to: &encryption, bigEndian: bigEndian)
            appendU32(1, to: &encryption, bigEndian: bigEndian)
            appendU32(0, to: &encryption, bigEndian: bigEndian)
            commands.append(encryption)
        }

        for dependency in dependencies {
            let raw = Data(dependency.utf8)
            let commandSize = 24 + raw.count + 1
            let aligned = (commandSize + 7) & ~7
            var command = Data()
            appendU32(0x0c, to: &command, bigEndian: bigEndian)
            appendU32(UInt32(aligned), to: &command, bigEndian: bigEndian)
            appendU32(24, to: &command, bigEndian: bigEndian)
            appendU32(0, to: &command, bigEndian: bigEndian)
            appendU32(0, to: &command, bigEndian: bigEndian)
            appendU32(0, to: &command, bigEndian: bigEndian)
            command.append(raw)
            command.append(0)
            command.append(Data(repeating: 0, count: aligned - command.count))
            commands.append(command)
        }

        let commandBytes = commands.reduce(0) { $0 + $1.count }
        var result = Data()
        result.append(
            contentsOf: bigEndian
                ? [0xfe, 0xed, 0xfa, 0xcf]
                : [0xcf, 0xfa, 0xed, 0xfe]
        )
        appendU32(0x0100_000c, to: &result, bigEndian: bigEndian)
        appendU32(0, to: &result, bigEndian: bigEndian)
        appendU32(2, to: &result, bigEndian: bigEndian)
        appendU32(UInt32(commands.count), to: &result, bigEndian: bigEndian)
        appendU32(UInt32(commandBytes), to: &result, bigEndian: bigEndian)
        appendU32(0, to: &result, bigEndian: bigEndian)
        appendU32(0, to: &result, bigEndian: bigEndian)
        for command in commands {
            result.append(command)
        }
        if result.count < 512 {
            result.append(Data(repeating: 0, count: 512 - result.count))
        }
        result.append(Data(repeating: 0xab, count: 64))
        return result
    }

    private func appendU32(
        _ value: UInt32,
        to data: inout Data,
        bigEndian: Bool
    ) {
        let bytes: [UInt8]
        if bigEndian {
            bytes = [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff),
            ]
        } else {
            bytes = [
                UInt8(value & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 24) & 0xff),
            ]
        }
        data.append(contentsOf: bytes)
    }

    private func appendU64(
        _ value: UInt64,
        to data: inout Data,
        bigEndian: Bool
    ) {
        let shifts = bigEndian
            ? Array(stride(from: 56, through: 0, by: -8))
            : Array(stride(from: 0, through: 56, by: 8))
        data.append(
            contentsOf: shifts.map {
                UInt8((value >> UInt64($0)) & 0xff)
            }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlayCoverUpstream-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeRealIOSExecutable(
        in root: URL,
        name: String
    ) throws -> URL {
        let source = root.appendingPathComponent("\(name).c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let output = root.appendingPathComponent(name)
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
                source.path,
                "-o", output.path,
            ]
        )
        return output
    }

    private func makeHostAppWithExtension(at app: URL) throws {
        let extensionURL = app.appendingPathComponent(
            "PlugIns/Test.appex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: extensionURL,
            withIntermediateDirectories: true
        )
        try plistData([
            "CFBundleIdentifier": "com.example.host",
            "CFBundleExecutable": "Host",
            "CFBundlePackageType": "APPL",
        ]).write(to: app.appendingPathComponent("Info.plist"))
        try plistData([
            "CFBundleIdentifier": "com.example.host.extension",
            "CFBundleExecutable": "TestExtension",
            "CFBundlePackageType": "XPC!",
        ]).write(to: extensionURL.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: app.appendingPathComponent("Host")
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: extensionURL.appendingPathComponent("TestExtension")
        )
        try Data("sealed-resource".utf8).write(
            to: extensionURL.appendingPathComponent("asset.dat")
        )
    }

    private func makeIOSAppWithExtension(
        at app: URL,
        root: URL
    ) throws {
        let extensionURL = app.appendingPathComponent(
            "PlugIns/Test.appex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: extensionURL,
            withIntermediateDirectories: true
        )
        try plistData([
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
            "MinimumOSVersion": "17.0",
        ]).write(to: app.appendingPathComponent("Info.plist"))
        try plistData([
            "CFBundleIdentifier": "com.example.fixture.extension",
            "CFBundleExecutable": "TestExtension",
            "CFBundlePackageType": "XPC!",
            "MinimumOSVersion": "17.0",
        ]).write(to: extensionURL.appendingPathComponent("Info.plist"))
        let main = try makeRealIOSExecutable(in: root, name: "Fixture")
        let nested = try makeRealIOSExecutable(
            in: root,
            name: "TestExtension"
        )
        try FileManager.default.moveItem(
            at: main,
            to: app.appendingPathComponent("Fixture")
        )
        try FileManager.default.moveItem(
            at: nested,
            to: extensionURL.appendingPathComponent("TestExtension")
        )
        try Data("sealed-resource".utf8).write(
            to: extensionURL.appendingPathComponent("asset.dat")
        )
        try Data("fixture-provision".utf8).write(
            to: app.appendingPathComponent("embedded.mobileprovision")
        )
        let extensionEntitlements = root.appendingPathComponent(
            "ios-extension-entitlements.plist"
        )
        try plistData([
            "application-identifier":
                "TEAM.com.example.fixture.extension",
            "com.apple.developer.team-identifier": "TEAM",
            "com.apple.security.application-groups": ["group.fixture"],
            "com.example.extension-capability": true,
        ]).write(to: extensionEntitlements)
        try codesign(extensionURL, entitlements: extensionEntitlements)
        let appEntitlements = root.appendingPathComponent(
            "ios-app-entitlements.plist"
        )
        try plistData([
            "application-identifier": "TEAM.com.example.fixture",
            "com.apple.developer.team-identifier": "TEAM",
            "keychain-access-groups": ["TEAM.com.example.fixture"],
            "com.apple.developer.associated-domains": [
                "applinks:example.com",
            ],
        ]).write(to: appEntitlements)
        try codesign(app, entitlements: appEntitlements)
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
        try Data("int ios_use_runtime_fixture(void) { return 1; }\n".utf8)
            .write(to: source)
        let output = framework.appendingPathComponent("IOSUsePlayRuntime")
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
                "-Wl,-install_name,"
                    + "@rpath/IOSUsePlayRuntime.framework/"
                    + "IOSUsePlayRuntime",
                source.path,
                "-o", output.path,
            ]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: output.path
        )
        return framework
    }

    private func plistData(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }

    private func codesign(
        _ url: URL,
        entitlements: URL?
    ) throws {
        var arguments = ["-f", "-s", "-"]
        if let entitlements {
            arguments += ["--entitlements", entitlements.path]
        }
        arguments.append(url.path)
        _ = try run("/usr/bin/codesign", arguments)
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
            throw PlayCoverUpstreamError.commandFailed(
                "\(executable) \(arguments.joined(separator: " ")): \(text)"
            )
        }
        return text
    }
}
