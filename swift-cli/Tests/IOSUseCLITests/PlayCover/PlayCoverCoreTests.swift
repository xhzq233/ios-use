import Foundation
import XCTest
@testable import IOSUseCLI
#if canImport(Darwin)
import Darwin
#endif

final class PlayCoverCoreTests: XCTestCase {
    override func tearDown() {
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = nil
        super.tearDown()
    }

    func testVPhoneProfileIsInternallyConsistentAndStable() throws {
        let profile = PlayCoverDeviceProfile.vphoneDefault

        XCTAssertNoThrow(try profile.validate())
        XCTAssertEqual(profile.logicalWidth, 430)
        XCTAssertEqual(profile.logicalHeight, 932)
        XCTAssertEqual(profile.nativeWidth, 1290)
        XCTAssertEqual(profile.nativeHeight, 2796)
        XCTAssertEqual(profile.scale, 3)
        XCTAssertEqual(try profile.stableHash().count, 64)
        XCTAssertEqual(try profile.stableHash(), try profile.stableHash())
    }

    func testProfileRejectsInconsistentNativeGeometry() {
        let profile = PlayCoverDeviceProfile(
            identifier: "bad",
            productType: "iPhone16,2",
            hardwareTarget: "A2849",
            logicalWidth: 430,
            logicalHeight: 932,
            nativeWidth: 1289,
            nativeHeight: 2796,
            scale: 3,
            pixelsPerInch: 460,
            orientation: "portrait"
        )

        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(
                error as? PlayCoverBackendError,
                .invalidProfile("native size must equal logical size multiplied by scale")
            )
        }
    }

    func testMachOConversionUsesVerifiedPaddingAndIsIdempotent() throws {
        let url = try makeTemporaryMachO()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let originalPayload = try payloadByte(at: url)

        let before = try PlayCoverMachO.inspect(at: url)
        XCTAssertEqual(before.platform, PlayCoverMachO.platformIPhoneOS)
        XCTAssertFalse(before.runtimeInjected)
        XCTAssertFalse(before.encrypted)

        let converted = try PlayCoverMachO.convert(at: url, injectRuntime: true)
        XCTAssertTrue(converted.isMacCatalyst)
        XCTAssertTrue(converted.runtimeInjected)
        XCTAssertEqual(converted.commandCount, before.commandCount + 1)
        XCTAssertEqual(try payloadByte(at: url), originalPayload)

        let convertedAgain = try PlayCoverMachO.convert(at: url, injectRuntime: true)
        XCTAssertEqual(convertedAgain.commandCount, converted.commandCount)
        XCTAssertEqual(convertedAgain.commandBytes, converted.commandBytes)
        XCTAssertEqual(try payloadByte(at: url), originalPayload)
    }

    func testEncryptedMachOIsRejectedWithoutMutation() throws {
        let url = try makeTemporaryMachO(encrypted: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try PlayCoverMachO.convert(at: url, injectRuntime: true)) { error in
            XCTAssertEqual(error as? PlayCoverBackendError, .encryptedMachO(url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testNonZeroConsumedPaddingIsRejectedWithoutMutation() throws {
        let url = try makeTemporaryMachO(nonZeroPadding: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try PlayCoverMachO.convert(at: url, injectRuntime: true)) { error in
            XCTAssertEqual(error as? PlayCoverBackendError, .nonZeroLoadCommandPadding(url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testInsufficientPaddingIsRejectedWithoutMutation() throws {
        let url = try makeTemporaryMachO(firstSectionOffset: 248)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try PlayCoverMachO.convert(at: url, injectRuntime: true)) { error in
            guard case .insufficientLoadCommandSpace = error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAppInspectionIsReadOnlyAndUsesIOSUsePathsForBackendState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-playcover-app-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = app.appendingPathComponent("Demo")
        let fixture = makeMachOData()
        try fixture.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleExecutable": "Demo",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let before = try Data(contentsOf: executable)

        let inspection = try PlayCoverService.inspect(appPath: app.path)
        XCTAssertEqual(inspection.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(inspection.profile.logicalWidth, 430)
        XCTAssertEqual(try Data(contentsOf: executable), before)

        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path])
        XCTAssertEqual(paths.playcover, root.appendingPathComponent("playcover").path)
        XCTAssertEqual(
            paths.playcoverRun,
            root.appendingPathComponent("playcover/run").path
        )
        XCTAssertEqual(
            paths.playcoverRuntimeBootstrap,
            root.appendingPathComponent("playcover/run/bootstrap.json").path
        )
        XCTAssertEqual(
            paths.playcoverRuntimeSocket,
            root.appendingPathComponent("playcover/run/runtime.sock").path
        )
        XCTAssertEqual(
            paths.playcoverHello,
            root.appendingPathComponent("playcover/run/hello.json").path
        )
        XCTAssertEqual(
            paths.playcoverLastPrepared,
            root.appendingPathComponent("playcover/last-prepared.json").path
        )
        XCTAssertEqual(
            paths.playcoverPrepared,
            root.appendingPathComponent("playcover/prepared").path
        )
        XCTAssertEqual(
            paths.playcoverRuntime,
            root.appendingPathComponent(
                "playcover/IOSUsePlayRuntime.framework"
            ).path
        )
    }

    func testRuntimeCandidatesPreferManagedHomeThenExecutableLayouts() {
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": "/state/ios-use"]
        )

        XCTAssertEqual(
            PlayCoverManagedAppService.runtimeCandidates(
                paths: paths,
                executablePath: "/opt/ios-use/bin/ios-use"
            ),
            [
                "/state/ios-use/playcover/IOSUsePlayRuntime.framework",
                "/opt/ios-use/bin/.ios-use/playcover/IOSUsePlayRuntime.framework",
                "/opt/ios-use/share/ios-use/playcover/IOSUsePlayRuntime.framework",
            ]
        )
    }

    func testLaunchEnvironmentDoesNotForwardUnrelatedCredentials() {
        let environment = PlayCoverService.sanitizedLaunchEnvironment(source: [
            "HOME": "/Users/test",
            "TMPDIR": "/tmp/example",
            "PATH": "/private/tooling",
            "API_TOKEN": "do-not-forward",
            "IOS_USE_HOME": "/private/state",
        ])

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/example")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(environment["API_TOKEN"])
        XCTAssertNil(environment["IOS_USE_HOME"])
    }

    func testRuntimeSandboxRulesGrantOnlyRunFilesAndExactSocketBind() {
        XCTAssertEqual(PlayCoverManagedAppService.preparationRevision, 3)
        XCTAssertEqual(
            PlayCoverService.runtimeSandboxRules(
                runtimeRunPath: #"/state/play\"cover/run"#,
                runtimeSocketPath: #"/state/play\"cover/run/runtime.sock"#
            ),
            [
                #"(allow file-read* file-write* file-read-metadata (subpath "/state/play\\\"cover/run"))"#,
                #"(allow network-bind network-inbound (literal "/state/play\\\"cover/run/runtime.sock"))"#,
            ]
        )
    }

    func testRuntimeLaunchStateIsPrivateAndDoesNotPersistNonceInPreparedState() throws {
        let root = URL(
            fileURLWithPath: "/tmp/ios-use-pc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = runtimeManifest(run: root.appendingPathComponent("run"))

        try PlayCoverService.prepareRuntimeStateForLaunch(
            manifest: manifest,
            launchNonce: "launch-nonce"
        )

        let runAttributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("run").path
        )
        XCTAssertEqual(
            (runAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        let bootstrapAttributes = try FileManager.default.attributesOfItem(
            atPath: manifest.runtimeBootstrapPath
        )
        XCTAssertEqual(
            (bootstrapAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        let bootstrap = try JSONDecoder().decode(
            PlayCoverRuntimeBootstrap.self,
            from: Data(
                contentsOf: URL(fileURLWithPath: manifest.runtimeBootstrapPath)
            )
        )
        XCTAssertEqual(
            bootstrap,
            PlayCoverRuntimeBootstrap(
                schemaVersion: 1,
                launchNonce: "launch-nonce",
                runtimeSocketPath: manifest.runtimeSocketPath,
                profileHash: manifest.profileHash,
                bundleIdentifier: manifest.bundleIdentifier,
                preparedGenerationID: manifest.preparedGenerationID
            )
        )
        XCTAssertNil(
            try JSONEncoder().encode(manifest).range(
                of: Data("launch-nonce".utf8)
            )
        )
    }

    func testRuntimeLaunchStateRejectsSymlinkAtSocketPath() throws {
        #if canImport(Darwin)
        let root = URL(
            fileURLWithPath: "/tmp/ios-use-pc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let run = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: run,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("do-not-remove")
        try Data("sentinel".utf8).write(to: target)
        let manifest = runtimeManifest(run: run)
        XCTAssertEqual(
            symlink(target.path, manifest.runtimeSocketPath),
            0
        )

        XCTAssertThrowsError(
            try PlayCoverService.prepareRuntimeStateForLaunch(
                manifest: manifest,
                launchNonce: "launch-nonce"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("symlink"))
        }
        XCTAssertEqual(try String(contentsOf: target), "sentinel")
        #endif
    }

    func testRuntimeSocketPathOverDarwinLimitFailsBeforeCreatingRunState() {
        let longRoot = "/tmp/" + String(repeating: "x", count: 100)
        let run = URL(fileURLWithPath: longRoot, isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        let manifest = runtimeManifest(run: run)

        XCTAssertThrowsError(
            try PlayCoverService.prepareRuntimeStateForLaunch(
                manifest: manifest,
                launchNonce: "launch-nonce"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("maximum 103"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path))
    }

    func testRuntimeLaunchStateRefusesLiveSocketAndRemovesOwnedStaleSocket() throws {
        #if canImport(Darwin)
        let root = URL(
            fileURLWithPath: "/tmp/ios-use-pc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let run = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: run,
            withIntermediateDirectories: true
        )
        let manifest = runtimeManifest(run: run)
        let listener = try bindRuntimeSocket(path: manifest.runtimeSocketPath)

        XCTAssertThrowsError(
            try PlayCoverService.prepareRuntimeStateForLaunch(
                manifest: manifest,
                launchNonce: "first"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("already listening"))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifest.runtimeSocketPath)
        )

        Darwin.close(listener)
        try PlayCoverService.prepareRuntimeStateForLaunch(
            manifest: manifest,
            launchNonce: "second"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manifest.runtimeSocketPath)
        )
        #endif
    }

    func testRuntimeHelloRequiresExactGenerationGeometryAndReadyStage() throws {
        let run = URL(fileURLWithPath: "/state/run", isDirectory: true)
        let manifest = runtimeManifest(run: run)
        let verification = PlayCoverVerification(
            manifest: manifest,
            profile: .vphoneDefault,
            mainExecutable: PlayCoverMachOInspection(
                path: "/fixtures/Prepared.app/Demo",
                cpuType: 0x0100_000c,
                fileType: 2,
                commandCount: 3,
                commandBytes: 200,
                firstSectionOffset: 4096,
                availableCommandPadding: 3800,
                platform: PlayCoverMachO.platformMacCatalyst,
                minimumOS: 0x000d_0000,
                sdk: 0x001a_0000,
                encrypted: false,
                runtimeInjected: true
            ),
            signatureValid: true
        )
        var payload = runtimePayload(manifest: manifest)
        // Use this test process so the production liveness check is real.
        payload = PlayCoverRuntimeResponsePayload(
            protocolVersion: payload.protocolVersion,
            pid: getpid(),
            bundleIdentifier: payload.bundleIdentifier,
            profileHash: payload.profileHash,
            preparedGenerationID: payload.preparedGenerationID,
            runtimeSocketPath: payload.runtimeSocketPath,
            runtimeInstanceID: payload.runtimeInstanceID,
            launchNonce: payload.launchNonce,
            capabilities: payload.capabilities,
            logicalWidth: payload.logicalWidth,
            logicalHeight: payload.logicalHeight,
            nativeWidth: payload.nativeWidth,
            nativeHeight: payload.nativeHeight,
            scale: payload.scale,
            windowWidth: payload.windowWidth,
            windowHeight: payload.windowHeight,
            stage: payload.stage,
            observed: payload.observed,
            diagnostics: payload.diagnostics
        )

        let hello = try PlayCoverService.validateRuntimeHello(
            payload,
            launchNonce: "launch-nonce",
            verification: verification
        )
        XCTAssertEqual(hello.runtimeInstanceID, "runtime-instance")
        XCTAssertEqual(hello.launchNonce, "launch-nonce")

        let scaledPresentation = runtimePayload(
            manifest: manifest,
            pid: getpid(),
            windowWidth: 332,
            windowHeight: 718
        )
        XCTAssertNoThrow(
            try PlayCoverService.validateRuntimeHello(
                scaledPresentation,
                launchNonce: "launch-nonce",
                verification: verification
            )
        )

        for invalidPresentation in [
            runtimePayload(
                manifest: manifest,
                pid: getpid(),
                windowWidth: 332,
                windowHeight: 680
            ),
            runtimePayload(
                manifest: manifest,
                pid: getpid(),
                windowWidth: 0,
                windowHeight: 718
            ),
            runtimePayload(
                manifest: manifest,
                pid: getpid(),
                windowWidth: 431,
                windowHeight: 932
            ),
        ] {
            XCTAssertThrowsError(
                try PlayCoverService.validateRuntimeHello(
                    invalidPresentation,
                    launchNonce: "launch-nonce",
                    verification: verification
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "geometry does not match"
                    )
                )
            }
        }

        let wrongGeneration = runtimePayload(
            manifest: manifest,
            preparedGenerationID: "other-generation",
            pid: getpid()
        )
        XCTAssertThrowsError(
            try PlayCoverService.validateRuntimeHello(
                wrongGeneration,
                launchNonce: "launch-nonce",
                verification: verification
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("signed prepared generation")
            )
        }

        let notReady = runtimePayload(
            manifest: manifest,
            stage: "runtime-loaded",
            pid: getpid()
        )
        XCTAssertThrowsError(
            try PlayCoverService.validateRuntimeHello(
                notReady,
                launchNonce: "launch-nonce",
                verification: verification
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("not ready"))
        }
    }

    func testFailedLaunchRollbackUsesMatchingHelloIdentityAndCleansState() throws {
        let root = URL(
            fileURLWithPath: "/tmp/ios-use-pc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = runtimeManifest(
            run: root.appendingPathComponent("run")
        )
        let verification = runtimeVerification(manifest: manifest)
        try PlayCoverService.prepareRuntimeStateForLaunch(
            manifest: manifest,
            launchNonce: "launch-nonce"
        )
        let hello = PlayCoverHello(
            schemaVersion: 1,
            launchNonce: "launch-nonce",
            preparedGenerationID: manifest.preparedGenerationID,
            runtimeInstanceID: "runtime-instance",
            runtimeSocketPath: manifest.runtimeSocketPath,
            pid: 4242,
            bundleIdentifier: manifest.bundleIdentifier,
            profileHash: manifest.profileHash,
            logicalWidth: 430,
            logicalHeight: 932,
            nativeWidth: 1290,
            nativeHeight: 2796,
            scale: 3,
            windowWidth: 430,
            windowHeight: 932,
            stage: "window-configured"
        )
        try JSONEncoder().encode(hello).write(
            to: URL(fileURLWithPath: manifest.helloPath),
            options: .atomic
        )
        var terminated: [Int32] = []
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = {
            pid,
            actualManifest in
            XCTAssertEqual(actualManifest, manifest)
            terminated.append(pid)
        }

        try PlayCoverService.rollbackFailedLaunch(
            verification: verification,
            launchNonce: "launch-nonce",
            knownIdentity: nil
        )

        XCTAssertEqual(terminated, [4242])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: manifest.runtimeBootstrapPath
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manifest.helloPath)
        )
    }

    func testFailedLaunchRollbackPrioritizesNSWorkspacePIDOverHelloPID() throws {
        let root = URL(
            fileURLWithPath: "/tmp/ios-use-pc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = runtimeManifest(
            run: root.appendingPathComponent("run")
        )
        let verification = runtimeVerification(manifest: manifest)
        try PlayCoverService.prepareRuntimeStateForLaunch(
            manifest: manifest,
            launchNonce: "launch-nonce"
        )
        let hello = PlayCoverHello(
            schemaVersion: 1,
            launchNonce: "launch-nonce",
            preparedGenerationID: manifest.preparedGenerationID,
            runtimeInstanceID: "runtime-instance",
            runtimeSocketPath: manifest.runtimeSocketPath,
            pid: 4242,
            bundleIdentifier: manifest.bundleIdentifier,
            profileHash: manifest.profileHash,
            logicalWidth: 430,
            logicalHeight: 932,
            nativeWidth: 1290,
            nativeHeight: 2796,
            scale: 3,
            windowWidth: 430,
            windowHeight: 932,
            stage: "window-configured"
        )
        try JSONEncoder().encode(hello).write(
            to: URL(fileURLWithPath: manifest.helloPath),
            options: .atomic
        )
        var terminated: [Int32] = []
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = {
            pid,
            _ in
            terminated.append(pid)
        }

        try PlayCoverService.rollbackFailedLaunch(
            verification: verification,
            launchNonce: "launch-nonce",
            knownIdentity: nil,
            launchedPID: 5151
        )

        XCTAssertEqual(terminated, [5151])
    }

    func testFailedLaunchRollbackDoesNotTouchMismatchedHello() throws {
        let root = URL(
            fileURLWithPath: "/tmp/ios-use-pc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = runtimeManifest(
            run: root.appendingPathComponent("run")
        )
        let verification = runtimeVerification(manifest: manifest)
        try PlayCoverService.prepareRuntimeStateForLaunch(
            manifest: manifest,
            launchNonce: "launch-nonce"
        )
        let otherHello = PlayCoverHello(
            schemaVersion: 1,
            launchNonce: "other-launch",
            preparedGenerationID: manifest.preparedGenerationID,
            runtimeInstanceID: "other-runtime",
            runtimeSocketPath: manifest.runtimeSocketPath,
            pid: 4343,
            bundleIdentifier: manifest.bundleIdentifier,
            profileHash: manifest.profileHash,
            logicalWidth: 430,
            logicalHeight: 932,
            nativeWidth: 1290,
            nativeHeight: 2796,
            scale: 3,
            windowWidth: 430,
            windowHeight: 932,
            stage: "window-configured"
        )
        try JSONEncoder().encode(otherHello).write(
            to: URL(fileURLWithPath: manifest.helloPath),
            options: .atomic
        )
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = { _, _ in
            XCTFail("mismatched hello must never select a process")
        }

        XCTAssertThrowsError(
            try PlayCoverService.rollbackFailedLaunch(
                verification: verification,
                launchNonce: "launch-nonce",
                knownIdentity: nil
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "hello does not match this launch"
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: manifest.runtimeBootstrapPath
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifest.helloPath)
        )
    }

    func testFailedLaunchRollbackUsesLaunchedPIDAndCleansBootstrap() throws {
        let root = URL(
            fileURLWithPath: "/tmp/ios-use-pc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = runtimeManifest(
            run: root.appendingPathComponent("run")
        )
        try PlayCoverService.prepareRuntimeStateForLaunch(
            manifest: manifest,
            launchNonce: "launch-nonce"
        )
        var terminated: [Int32] = []
        PlayCoverService.failedLaunchTerminatorOverrideForTesting = {
            pid,
            actualManifest in
            XCTAssertEqual(actualManifest, manifest)
            terminated.append(pid)
        }

        try PlayCoverService.rollbackFailedLaunch(
            verification: runtimeVerification(manifest: manifest),
            launchNonce: "launch-nonce",
            knownIdentity: nil,
            launchedPID: 5151
        )

        XCTAssertEqual(terminated, [5151])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: manifest.runtimeBootstrapPath
            )
        )
    }

    private func makeTemporaryMachO(
        encrypted: Bool = false,
        nonZeroPadding: Bool = false,
        firstSectionOffset: Int = 4096
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-playcover-macho-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Demo")
        try makeMachOData(
            encrypted: encrypted,
            nonZeroPadding: nonZeroPadding,
            firstSectionOffset: firstSectionOffset
        ).write(to: url)
        return url
    }

    private func makeMachOData(
        encrypted: Bool = false,
        nonZeroPadding: Bool = false,
        firstSectionOffset: Int = 4096
    ) -> Data {
        let segmentCommandSize = 72 + 80
        let buildVersionSize = 24
        let encryptionSize = 24
        let commandsSize = segmentCommandSize + buildVersionSize + encryptionSize
        var data = Data(repeating: 0, count: max(firstSectionOffset + 16, 512))

        writeUInt32(0xfeedfacf, to: &data, at: 0)
        writeUInt32(0x0100_000c, to: &data, at: 4)
        writeUInt32(0, to: &data, at: 8)
        writeUInt32(2, to: &data, at: 12)
        writeUInt32(3, to: &data, at: 16)
        writeUInt32(UInt32(commandsSize), to: &data, at: 20)

        var cursor = 32
        writeUInt32(0x19, to: &data, at: cursor)
        writeUInt32(UInt32(segmentCommandSize), to: &data, at: cursor + 4)
        writeUInt32(1, to: &data, at: cursor + 64)
        writeUInt32(UInt32(firstSectionOffset), to: &data, at: cursor + 72 + 48)
        cursor += segmentCommandSize

        writeUInt32(0x32, to: &data, at: cursor)
        writeUInt32(UInt32(buildVersionSize), to: &data, at: cursor + 4)
        writeUInt32(2, to: &data, at: cursor + 8)
        writeUInt32(0x000d_0000, to: &data, at: cursor + 12)
        writeUInt32(0x001a_0000, to: &data, at: cursor + 16)
        cursor += buildVersionSize

        writeUInt32(0x2c, to: &data, at: cursor)
        writeUInt32(UInt32(encryptionSize), to: &data, at: cursor + 4)
        writeUInt32(encrypted ? 1 : 0, to: &data, at: cursor + 16)
        cursor += encryptionSize

        if nonZeroPadding {
            data[cursor] = 0x7f
        }
        data[firstSectionOffset] = 0xaa
        return data
    }

    private func payloadByte(at url: URL) throws -> UInt8 {
        try Data(contentsOf: url)[4096]
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func runtimeManifest(run: URL) -> PlayCoverPrepareManifest {
        PlayCoverPrepareManifest(
            schemaVersion: 2,
            backend: "playcover-headless",
            sourceAppPath: "/fixtures/Demo.app",
            preparedAppPath: "/fixtures/Prepared.app",
            bundleIdentifier: "com.example.demo",
            executableName: "Demo",
            profileHash: "profile-hash",
            runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
            runtimeFrameworkName: PlayCoverService.runtimeFrameworkName,
            convertedMachOs: ["Demo"],
            preparedAt: "2026-07-25T00:00:00Z",
            helloPath: run.appendingPathComponent("hello.json").path,
            preparedGenerationID: "prepared-generation",
            runtimeBootstrapPath: run.appendingPathComponent(
                "bootstrap.json"
            ).path,
            runtimeSocketPath: run.appendingPathComponent("runtime.sock").path
        )
    }

    private func runtimePayload(
        manifest: PlayCoverPrepareManifest,
        preparedGenerationID: String? = nil,
        stage: String = "window-configured",
        pid: Int32 = 1,
        windowWidth: Double = 430,
        windowHeight: Double = 932
    ) -> PlayCoverRuntimeResponsePayload {
        PlayCoverRuntimeResponsePayload(
            protocolVersion: 1,
            pid: pid,
            bundleIdentifier: manifest.bundleIdentifier,
            profileHash: manifest.profileHash,
            preparedGenerationID: preparedGenerationID
                ?? manifest.preparedGenerationID,
            runtimeSocketPath: manifest.runtimeSocketPath,
            runtimeInstanceID: "runtime-instance",
            launchNonce: "launch-nonce",
            capabilities: ["hello", "ping", "diagnostics"],
            logicalWidth: 430,
            logicalHeight: 932,
            nativeWidth: 1290,
            nativeHeight: 2796,
            scale: 3,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            stage: stage,
            observed: nil,
            diagnostics: nil
        )
    }

    private func runtimeVerification(
        manifest: PlayCoverPrepareManifest
    ) -> PlayCoverVerification {
        PlayCoverVerification(
            manifest: manifest,
            profile: .vphoneDefault,
            mainExecutable: PlayCoverMachOInspection(
                path: "\(manifest.preparedAppPath)/\(manifest.executableName)",
                cpuType: 0x0100_000c,
                fileType: 2,
                commandCount: 3,
                commandBytes: 200,
                firstSectionOffset: 4096,
                availableCommandPadding: 3800,
                platform: PlayCoverMachO.platformMacCatalyst,
                minimumOS: 0x000d_0000,
                sdk: 0x001a_0000,
                encrypted: false,
                runtimeInjected: true
            ),
            signatureValid: true
        )
    }

    #if canImport(Darwin)
    private func bindRuntimeSocket(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(
                to: Int8.self,
                capacity: pathCapacity
            ) { raw in
                for index in bytes.indices {
                    raw[index] = Int8(bitPattern: bytes[index])
                }
                raw[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code)
            )
        }
        return descriptor
    }
    #endif
}
