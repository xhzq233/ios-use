import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverSessionTests: XCTestCase {
    override func tearDown() {
        PlayCoverSessionService.launchOverrideForTesting = nil
        PlayCoverSessionService.terminateOverrideForTesting = nil
        PlayCoverManagedAppService.inspectOverrideForTesting = nil
        PlayCoverManagedAppService.verifyOverrideForTesting = nil
        PlayCoverManagedAppService.prepareOverrideForTesting = nil
        PlayCoverManagedAppService.runtimePathOverrideForTesting = nil
        PlayCoverManagedAppService.executablePathOverrideForTesting = nil
        PlayCoverManagedAppService.generationKeyOverrideForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        IOSUseCLI.playCoverDriverClientFactoryForTesting = nil
        super.tearDown()
    }

    func testStartWithoutAppUsesLastPreparedAndStopClearsSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let preparedApp = "\(root)/Prepared.app"
        try PlayCoverSessionService.recordPrepared(
            manifest(appPath: preparedApp),
            paths: paths
        )

        var launches: [(String, Double)] = []
        PlayCoverSessionService.launchOverrideForTesting = { appPath, timeout in
            launches.append((appPath, timeout))
            return self.launchResult(appPath: appPath)
        }

        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])
        let start = cli.run(arguments: ["start", "--playcover"])

        XCTAssertEqual(start.exitCode, 0)
        XCTAssertEqual(
            start.stdout,
            "PlayCover session started for com.example.demo (pid 4242)\n"
        )
        XCTAssertEqual(launches.map(\.0), [preparedApp])
        XCTAssertEqual(launches.map(\.1), [15])
        XCTAssertEqual(
            try PlayCoverSessionService.readPreparedReference(
                paths: paths
            )?.preparedGenerationID,
            "prepared-generation"
        )

        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.udid, "playcover:com.example.demo")
        XCTAssertEqual(lock.deviceType, "playcover")
        XCTAssertEqual(lock.deviceName, "iPhone16,2")
        XCTAssertEqual(lock.runnerPid, 4242)
        XCTAssertEqual(lock.bundleId, "com.example.demo")
        XCTAssertEqual(lock.playCoverAppPath, preparedApp)
        XCTAssertEqual(lock.profileHash, "profile-hash")
        XCTAssertEqual(lock.playCoverRuntimeSocketPath, "/state/run/runtime.sock")
        XCTAssertEqual(lock.playCoverLaunchNonce, "launch-nonce")
        XCTAssertEqual(lock.playCoverPreparedGenerationID, "prepared-generation")
        XCTAssertEqual(lock.playCoverRuntimeInstanceID, "runtime-instance")
        let lockAttributes = try FileManager.default.attributesOfItem(
            atPath: paths.driverLock
        )
        XCTAssertEqual(
            (lockAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        var terminated: [String] = []
        PlayCoverSessionService.terminateOverrideForTesting = { appPath in
            terminated.append(appPath)
            return 4242
        }
        let stop = cli.run(arguments: ["stop"])

        XCTAssertEqual(stop.exitCode, 0)
        XCTAssertEqual(
            stop.stdout,
            "PlayCover App stopped (pid 4242)\nPlayCover session stopped\n"
        )
        XCTAssertEqual(terminated, [preparedApp])
        XCTAssertNil(try SessionService.readDriverLockInfo(paths: paths))
    }

    func testExplicitAppOverridesLastPreparedForActiveSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let rememberedApp = "\(root)/Remembered.app"
        let explicitApp = "\(root)/Explicit.app"
        try PlayCoverSessionService.recordPrepared(
            manifest(appPath: rememberedApp),
            paths: paths
        )
        try markAsPrepared(explicitApp)
        PlayCoverManagedAppService.verifyOverrideForTesting = { appPath in
            XCTAssertEqual(appPath, explicitApp)
            return self.verification(appPath: appPath)
        }

        PlayCoverSessionService.launchOverrideForTesting = { appPath, timeout in
            XCTAssertEqual(appPath, explicitApp)
            XCTAssertEqual(timeout, 0.8, accuracy: 0.001)
            return self.launchResult(appPath: appPath)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: [
                "start", "--playcover",
                "--app", explicitApp,
                "--timeout", "800ms",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            try SessionService.readDriverLockInfo(paths: paths)?.playCoverAppPath,
            explicitApp
        )
        XCTAssertEqual(
            try PlayCoverSessionService.readPreparedReference(paths: paths)?.appPath,
            rememberedApp
        )
    }

    func testStartRejectsExistingSessionBeforeLaunching() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "SIM-1",
                deviceName: "Simulator",
                deviceVersion: "26.0",
                deviceType: "simulator"
            ),
            paths: paths
        )
        PlayCoverSessionService.launchOverrideForTesting = { _, _ in
            XCTFail("an existing session must block PlayCover launch")
            return self.launchResult(appPath: "/unused.app")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["start", "--playcover", "--app", "/work/Demo.app"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Driver already started for SIM-1"))
    }

    func testStartCleansLaunchedAppWhenSessionLockCannotBeWritten() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try Data("not-a-directory".utf8).write(
            to: URL(fileURLWithPath: "\(root)/state")
        )
        let preparedApp = "\(root)/Prepared.app"
        try markAsPrepared(preparedApp)
        PlayCoverManagedAppService.verifyOverrideForTesting = { appPath in
            self.verification(appPath: appPath)
        }
        PlayCoverSessionService.launchOverrideForTesting = { appPath, _ in
            self.launchResult(appPath: appPath)
        }
        var terminated: [String] = []
        PlayCoverSessionService.terminateOverrideForTesting = { appPath in
            terminated.append(appPath)
            return 4242
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: [
                "start", "--playcover",
                "--app", preparedApp,
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(terminated, [preparedApp])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.driverLock))
    }

    func testExplicitSourceAppIsPreparedWithDefaultRuntimeAndLaunched() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let sourceApp = "\(root)/Source.app"
        let runtime = try makeRuntimeFramework(root: root)
        let inspection = try sourceInspection(appPath: sourceApp)
        let generationKey = String(repeating: "a", count: 64)
        let expectedOutput = "\(paths.playcoverPrepared)/com.example.demo-\(generationKey.prefix(16)).app"

        PlayCoverManagedAppService.inspectOverrideForTesting = { appPath in
            XCTAssertEqual(appPath, sourceApp)
            return inspection
        }
        PlayCoverManagedAppService.runtimePathOverrideForTesting = { _ in runtime }
        PlayCoverManagedAppService.generationKeyOverrideForTesting = { actual, runtimePath in
            XCTAssertEqual(actual, inspection)
            XCTAssertEqual(runtimePath, runtime)
            return generationKey
        }
        var preparations: [(String, String, String)] = []
        PlayCoverManagedAppService.prepareOverrideForTesting = {
            source,
            output,
            runtimePath,
            _
            in
            preparations.append((source, output, runtimePath))
            return self.manifest(
                appPath: output,
                sourceAppPath: source,
                profileHash: inspection.profileHash
            )
        }
        PlayCoverSessionService.launchOverrideForTesting = { appPath, timeout in
            XCTAssertEqual(appPath, expectedOutput)
            XCTAssertEqual(timeout, 15)
            return self.launchResult(
                appPath: appPath,
                profileHash: inspection.profileHash
            )
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["start", "--playcover", "--app", sourceApp]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(preparations.count, 1)
        XCTAssertEqual(preparations.first?.0, sourceApp)
        XCTAssertEqual(preparations.first?.1, expectedOutput)
        XCTAssertEqual(preparations.first?.2, runtime)
        XCTAssertEqual(
            try PlayCoverSessionService.readPreparedReference(paths: paths)?.appPath,
            expectedOutput
        )
        XCTAssertEqual(
            try SessionService.readDriverLockInfo(paths: paths)?.playCoverAppPath,
            expectedOutput
        )
    }

    func testExplicitPreparedAppLaunchesWithoutRuntimeOrPrepare() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let preparedApp = "\(root)/Prepared.app"
        try markAsPrepared(preparedApp)

        PlayCoverManagedAppService.verifyOverrideForTesting = { appPath in
            XCTAssertEqual(appPath, preparedApp)
            return self.verification(appPath: appPath)
        }
        PlayCoverManagedAppService.inspectOverrideForTesting = { _ in
            XCTFail("prepared App must not be inspected as a source")
            throw PlayCoverBackendError.invalidApp("unexpected inspection")
        }
        PlayCoverManagedAppService.runtimePathOverrideForTesting = { _ in
            XCTFail("prepared App must not resolve a standalone runtime")
            throw PlayCoverBackendError.missingRuntime("unexpected resolution")
        }
        PlayCoverManagedAppService.prepareOverrideForTesting = { _, _, _, _ in
            XCTFail("prepared App must not be prepared again")
            throw PlayCoverBackendError.prepareFailed("unexpected preparation")
        }
        PlayCoverSessionService.launchOverrideForTesting = { appPath, _ in
            self.launchResult(appPath: appPath)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["start", "--playcover", "--app", preparedApp]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            try SessionService.readDriverLockInfo(
                paths: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
            )?.playCoverAppPath,
            preparedApp
        )
    }

    func testManagedSourceGenerationIsVerifiedAndReused() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let sourceApp = "\(root)/Source.app"
        let runtime = try makeRuntimeFramework(root: root)
        let inspection = try sourceInspection(appPath: sourceApp)
        let generationKey = String(repeating: "b", count: 64)
        let output = "\(paths.playcoverPrepared)/com.example.demo-\(generationKey.prefix(16)).app"
        try FileManager.default.createDirectory(
            atPath: output,
            withIntermediateDirectories: true
        )

        PlayCoverManagedAppService.inspectOverrideForTesting = { _ in inspection }
        PlayCoverManagedAppService.runtimePathOverrideForTesting = { _ in runtime }
        PlayCoverManagedAppService.generationKeyOverrideForTesting = { _, _ in
            generationKey
        }
        var verified: [String] = []
        PlayCoverManagedAppService.verifyOverrideForTesting = { appPath in
            verified.append(appPath)
            return self.verification(
                appPath: appPath,
                sourceAppPath: sourceApp,
                profileHash: inspection.profileHash
            )
        }
        PlayCoverManagedAppService.prepareOverrideForTesting = { _, _, _, _ in
            XCTFail("an existing verified managed generation must be reused")
            throw PlayCoverBackendError.prepareFailed("unexpected preparation")
        }
        PlayCoverSessionService.launchOverrideForTesting = { appPath, _ in
            self.launchResult(
                appPath: appPath,
                profileHash: inspection.profileHash
            )
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["start", "--playcover", "--app", sourceApp]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(verified, [output])
        XCTAssertEqual(
            try PlayCoverSessionService.readPreparedReference(paths: paths)?.appPath,
            output
        )
    }

    func testSourceStartReportsMissingDefaultRuntimeBeforePreparing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourceApp = "\(root)/Source.app"
        let inspection = try sourceInspection(appPath: sourceApp)

        PlayCoverManagedAppService.inspectOverrideForTesting = { _ in inspection }
        PlayCoverManagedAppService.executablePathOverrideForTesting = {
            "\(root)/bin/ios-use"
        }
        PlayCoverManagedAppService.prepareOverrideForTesting = { _, _, _, _ in
            XCTFail("missing runtime must fail before preparation")
            throw PlayCoverBackendError.prepareFailed("unexpected preparation")
        }
        PlayCoverSessionService.launchOverrideForTesting = { _, _ in
            XCTFail("missing runtime must fail before launch")
            return self.launchResult(appPath: "/unused.app")
        }

        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["start", "--playcover", "--app", sourceApp]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("no default runtime was found"))
        XCTAssertTrue(result.stderr.contains("build_swift_cli.sh --debug"))
        XCTAssertNil(try SessionService.readDriverLockInfo(paths: paths))
    }

    func testMalformedPreparedAppDoesNotFallBackToSourcePreparation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let preparedApp = "\(root)/Broken.app"
        try markAsPrepared(preparedApp)

        PlayCoverManagedAppService.verifyOverrideForTesting = { _ in
            throw PlayCoverBackendError.verificationFailed("broken fixture")
        }
        PlayCoverManagedAppService.inspectOverrideForTesting = { _ in
            XCTFail("a marked prepared App must not fall back to source inspection")
            throw PlayCoverBackendError.invalidApp("unexpected inspection")
        }
        PlayCoverManagedAppService.prepareOverrideForTesting = { _, _, _, _ in
            XCTFail("a malformed prepared App must not be overwritten")
            throw PlayCoverBackendError.prepareFailed("unexpected preparation")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["start", "--playcover", "--app", preparedApp]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("broken fixture"))
    }

    func testStopFailurePreservesPlayCoverSessionLock() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writePlayCoverLock(paths: paths)
        PlayCoverSessionService.terminateOverrideForTesting = { _ in
            throw PlayCoverBackendError.terminateFailed("fixture failure")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["stop"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("fixture failure"))
        XCTAssertNotNil(try SessionService.readDriverLockInfo(paths: paths))
    }

    func testDriverCommandRoutesToPlayCoverWithoutCreatingXCTestClient() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writePlayCoverLock(paths: paths)
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("PlayCover session must not create an XCTest driver client")
            fatalError("unexpected XCTest client")
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["dom"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "PlayCover Runtime capability `dom` is not implemented yet"
            )
        )
    }

    func testHostTargetCommandDoesNotFallBackToDeviceBackend() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writePlayCoverLock(paths: paths)

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(
            arguments: ["apps"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("does not support `apps` yet"))
    }

    func testIncompletePlayCoverLockIsRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "playcover:broken",
                deviceName: "iPhone16,2",
                deviceVersion: "Mac Catalyst",
                deviceType: "playcover"
            ),
            paths: paths
        )

        XCTAssertThrowsError(try SessionService.readDriverLockInfo(paths: paths)) {
            XCTAssertTrue(String(describing: $0).contains("incomplete PlayCover session"))
        }
    }

    private func writePlayCoverLock(paths: IOSUsePaths) throws {
        try SessionService.writeDriverLock(
            info: PlayCoverSessionService.makeSessionInfo(
                from: launchResult(appPath: "/work/Demo.app")
            ),
            paths: paths
        )
    }

    private func launchResult(
        appPath: String,
        profileHash: String = "profile-hash"
    ) -> PlayCoverSessionService.LaunchResult {
        PlayCoverSessionService.LaunchResult(
            appPath: appPath,
            bundleIdentifier: "com.example.demo",
            profileHash: profileHash,
            productType: "iPhone16,2",
            pid: 4242,
            runtimeSocketPath: "/state/run/runtime.sock",
            launchNonce: "launch-nonce",
            preparedGenerationID: "prepared-generation",
            runtimeInstanceID: "runtime-instance"
        )
    }

    private func manifest(
        appPath: String,
        sourceAppPath: String = "/fixtures/Demo.app",
        profileHash: String = "profile-hash"
    ) -> PlayCoverPrepareManifest {
        PlayCoverPrepareManifest(
            schemaVersion: 2,
            backend: "playcover-headless",
            sourceAppPath: sourceAppPath,
            preparedAppPath: appPath,
            bundleIdentifier: "com.example.demo",
            executableName: "Demo",
            profileHash: profileHash,
            runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
            runtimeFrameworkName: "IOSUsePlayRuntime.framework",
            convertedMachOs: ["Demo"],
            preparedAt: "2026-07-25T00:00:00Z",
            helloPath: "/state/run/hello.json",
            preparedGenerationID: "prepared-generation",
            runtimeBootstrapPath: "/state/run/bootstrap.json",
            runtimeSocketPath: "/state/run/runtime.sock"
        )
    }

    private func verification(
        appPath: String,
        sourceAppPath: String = "/fixtures/Demo.app",
        profileHash: String = "profile-hash"
    ) -> PlayCoverVerification {
        PlayCoverVerification(
            manifest: manifest(
                appPath: appPath,
                sourceAppPath: sourceAppPath,
                profileHash: profileHash
            ),
            profile: .vphoneDefault,
            mainExecutable: machOInspection(
                path: "\(appPath)/Demo",
                platform: PlayCoverMachO.platformMacCatalyst,
                runtimeInjected: true
            ),
            signatureValid: true
        )
    }

    private func sourceInspection(appPath: String) throws -> PlayCoverAppInspection {
        let profile = PlayCoverDeviceProfile.vphoneDefault
        return PlayCoverAppInspection(
            appPath: appPath,
            bundleIdentifier: "com.example.demo",
            executableName: "Demo",
            executablePath: "\(appPath)/Demo",
            profile: profile,
            profileHash: try profile.stableHash(),
            mainExecutable: machOInspection(
                path: "\(appPath)/Demo",
                platform: PlayCoverMachO.platformIPhoneOS,
                runtimeInjected: false
            )
        )
    }

    private func machOInspection(
        path: String,
        platform: UInt32,
        runtimeInjected: Bool
    ) -> PlayCoverMachOInspection {
        PlayCoverMachOInspection(
            path: path,
            cpuType: 0x0100_000c,
            fileType: 2,
            commandCount: 3,
            commandBytes: 200,
            firstSectionOffset: 4096,
            availableCommandPadding: 3800,
            platform: platform,
            minimumOS: 0x000d_0000,
            sdk: 0x001a_0000,
            encrypted: false,
            runtimeInjected: runtimeInjected
        )
    }

    private func markAsPrepared(_ appPath: String) throws {
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: app.appendingPathComponent(PlayCoverService.manifestFilename)
        )
    }

    private func makeRuntimeFramework(root: String) throws -> String {
        let framework = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(
                PlayCoverService.runtimeFrameworkName,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: framework,
            withIntermediateDirectories: true
        )
        let executable = framework.appendingPathComponent(
            PlayCoverService.runtimeExecutableName
        )
        try Data("runtime".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return framework.path
    }

    private func temporaryRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-session-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root.path
    }
}
