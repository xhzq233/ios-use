import XCTest
import Darwin
import CoreGraphics
import IOSUseProtocol
@testable import IOSUseCLI

final class IOSUseCLITests: XCTestCase {
    override func setUp() {
        super.setUp()
        StatusService.macSigningResolutionForTesting = {
            PlayCoverSigningIdentityResolution(
                health: .healthy,
                evidence: nil
            )
        }
        StatusService.macRuntimeResolutionForTesting = { _ in
            "/test/IOSUsePlayRuntime.framework"
        }
    }

    override func tearDown() {
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.usbDeviceUdidsOverrideForTesting = nil
        DeviceService.realDeviceResolverForTesting = nil
        DeviceService.resetCacheForTesting()
        DriverClient.usbmuxConnectorForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        IOSUseCLI.playCoverDriverClientFactoryForTesting = nil
        ScreenshotArtifactService.ocrRecognizerForTesting = nil
        AppLifecycleService.realDeviceRunnerForTesting = nil
        AppLifecycleService.simulatorRunnerForTesting = nil
        AppLogCaptureService.executablePathOverrideForTesting = nil
        AppLogCaptureService.helperLauncherForTesting = nil
        AppLogCaptureService.processAliveOverrideForTesting = nil
        AppLogCaptureService.processCommandOverrideForTesting = nil
        AppLogCaptureService.signalSenderForTesting = nil
        AppLogCaptureService.processExitWaiterForTesting = nil
        AppLogCaptureService.terminateObservationTimeoutForTesting = nil
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
        OpenURLService.realDeviceURLLauncherForTesting = nil
        OpenURLService.macURLLauncherForTesting = nil
        AppManagementService.installerForTesting = nil
        AppManagementService.uninstallerForTesting = nil
        AppManagementService.appsProviderForTesting = nil
        RealDevicePackageInstaller.preparedPackageInstallerForTesting = nil
        RealDevicePackageInstaller.nativePackageInstallerForTesting = nil
        RealDevicePackageInstaller.installedAppLookupForTesting = nil
        RealDevicePackageInstaller.devicectlRunnerForTesting = nil
        DeveloperDiskImageService.mountForTesting = nil
        SessionService.simulatorDriverLauncherForTesting = nil
        SessionService.simulatorDriverReachableForTesting = nil
        SimulatorService.xcodebuildLauncherForTesting = nil
        DriverLifecycleService.holderLauncherForTesting = nil
        DriverLifecycleService.holderTerminatorForTesting = nil
        DriverLifecycleService.processAliveForTesting = nil
        DriverLifecycleService.holderProcessValidatorForTesting = nil
        DriverLifecycleService.signalSenderForTesting = nil
        DriverLifecycleService.processExitWaiterForTesting = nil
        Shell.runOverrideForTesting = nil
        Shell.runResultOverrideForTesting = nil
        ConfigService.nowProviderForTesting = nil
        StatusService.macSigningResolutionForTesting = nil
        StatusService.macRuntimeResolutionForTesting = nil
        super.tearDown()
    }







    func testTapResolutionPreservesSemanticPlacementIntent() throws {
        let bare = try DriverCommandExecutor.resolveTapParams(
            "Continue",
            offset: nil,
            offsetRatio: nil,
            traits: nil,
            cindex: nil
        )
        XCTAssertNil(bare.offset)
        XCTAssertNil(bare.ratio)

        let explicitCenter = try DriverCommandExecutor.resolveTapParams(
            "Continue",
            offset: nil,
            offsetRatio: "0.5,0.5",
            traits: nil,
            cindex: nil
        )
        XCTAssertEqual(explicitCenter.ratio?.x, 0.5)
        XCTAssertEqual(explicitCenter.ratio?.y, 0.5)

        let offset = try DriverCommandExecutor.resolveTapParams(
            "Continue",
            offset: "4,5",
            offsetRatio: nil,
            traits: nil,
            cindex: nil
        )
        XCTAssertEqual(offset.offset?.x, 4)
        XCTAssertEqual(offset.offset?.y, 5)
        XCTAssertNil(offset.ratio)
    }

    func testUnknownOptionFailsBeforeAnySessionWork() {
        let result = IOSUseCLI().run(arguments: ["--not-a-real-option"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("unknown option '--not-a-real-option'"))
        XCTAssertTrue(result.stderr.contains("Usage: ios-use [--help] [--version] <command>"))
        XCTAssertTrue(result.stdout.isEmpty)
    }








    func testStatusJSONReturnsVersionedTypedEnvelope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-status-json-\(UUID().uuidString)")
            .path
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            simulatorOnly ? [] : [IOSDevice(name: "Phone", version: "18.0", udid: "REAL-1", kind: .real)]
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["status", "--json"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["schemaVersion"] as? Int, 1)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(((data["connectedDevices"] as? [[String: Any]])?.first)?["udid"] as? String, "REAL-1")
    }









    func testPlayCoverConfigJSONUsesCommonFailureEnvelope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-playcover-config-failure-\(UUID().uuidString)"
            )
            .path
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": root],
            playCoverSignerInitializer: {
                throw PlayCoverSigningIdentityServiceError
                    .bindingUnavailable
            }
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = cli.run(
            arguments: ["config", "--mac", "--json"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.isEmpty)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(result.stderr.utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(envelope["schemaVersion"] as? Int, 1)
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        XCTAssertEqual(envelope["command"] as? String, "config")
        let error = try XCTUnwrap(
            envelope["error"] as? [String: Any]
        )
        XCTAssertEqual(
            error["code"] as? String,
            "mac_signing_identity_binding_unavailable"
        )
        XCTAssertEqual(
            error["phase"] as? String,
            "mac_signing_identity"
        )
        XCTAssertEqual(
            error["mutationMayHaveApplied"] as? Bool,
            true
        )
    }


    func testReadOnlySignerFailureRemainsNonMutating() throws {
        for health in [
            PlayCoverSigningIdentityHealth.missing,
            .trustRequired,
            .unavailable,
        ] {
            let result = MachineOutput.failure(
                command: "start",
                error: PlayCoverSigningIdentityServiceError
                    .unhealthy(health)
            )
            let envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(result.stderr.utf8)
                ) as? [String: Any]
            )
            let error = try XCTUnwrap(
                envelope["error"] as? [String: Any]
            )

            XCTAssertEqual(
                error["mutationMayHaveApplied"] as? Bool,
                false,
                health.rawValue
            )
        }
    }

    func testOrdinaryStartNeverCallsPlayCoverConfigInitializer() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-start-no-signer-init-\(UUID().uuidString)"
            )
            .path
        DeviceService.listDevicesOverrideForTesting = { _, _ in [] }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": root],
            playCoverSignerInitializer: {
                XCTFail(
                    "ordinary start must not initialize Mac backend signing"
                )
                return makePlayCoverTestSigningIdentity()
            }
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = cli.run(arguments: ["start"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "No --udid and no USB real devices detected"
            )
        )
    }


    func testInstallCommandWithExplicitUdidIsHostOnlyAndDoesNotWriteDriverLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-host-only-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app")
        var installs: [(String, String, String?)] = []
        AppManagementService.installerForTesting = { ipa, udid, bundleID in
            installs.append((ipa, udid, bundleID))
            return self.installResult(bundleID: bundleID ?? "com.example.app")
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("install is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", ipaPath, "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(installs.map(\.0), [ipaPath])
        XCTAssertEqual(installs.map(\.1), ["REAL-1"])
        XCTAssertEqual(installs.map(\.2), ["com.example.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root]).driverLock))
    }

    func testInstallStopsRunningAppLogCaptureForSameBundleBeforeInstalling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-stops-log-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app")
        try AppLogCaptureService.writeState(AppLogState(
            lastLogFile: "\(root)/logs/app.log",
            lastCapture: AppLogCaptureTarget(
                bundleID: "com.example.app",
                udid: "REAL-1",
                deviceType: "real",
                logFile: "\(root)/logs/app.log",
                startedAt: 1,
                stoppedAt: nil,
                status: "running",
                helperPID: 4321,
                lastError: nil
            )
        ), paths: paths)
        AppLogCaptureService.processAliveOverrideForTesting = { pid in pid == 4321 }
        AppLogCaptureService.processCommandOverrideForTesting = { pid in
            pid == 4321 ? "/usr/local/bin/ios-use __ios-use-app-log-capture --home \(root)" : nil
        }
        var signals: [(Int32, Int32)] = []
        AppLogCaptureService.signalSenderForTesting = { pid, signal in
            signals.append((pid, signal))
            return 0
        }
        AppLogCaptureService.processExitWaiterForTesting = { _, _ in true }
        var installed = false
        AppManagementService.installerForTesting = { _, _, _ in
            installed = true
            let capture = try XCTUnwrap(AppLogCaptureService.readState(paths: paths)?.lastCapture)
            XCTAssertEqual(capture.status, "stopped")
            XCTAssertNil(capture.helperPID)
            return self.installResult(bundleID: "com.example.app")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", ipaPath, "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(installed)
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.0, 4321)
        XCTAssertEqual(signals.first?.1, SIGTERM)
    }

    func testInstallJSONReturnsVerifiedTypedReceipt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-json-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app", build: "42", version: "1.3.2")
        AppManagementService.installerForTesting = { _, _, bundleID in
            self.installResult(
                bundleID: bundleID ?? "com.example.app",
                build: "42",
                version: "1.3.2",
                installer: .devicectl
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: [
            "install", ipaPath, "--udid", "REAL-1", "--json"
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(data["version"] as? String, "1.3.2")
        XCTAssertEqual(data["build"] as? String, "42")
        XCTAssertEqual(data["installer"] as? String, "devicectl")
        XCTAssertEqual(data["verifiedOnDevice"] as? Bool, true)
        XCTAssertNotNil(data["elapsed"] as? Double)
    }



    func testIpaInstallUsesPreparedDeviceInstallerDirectly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-ipa-direct-install-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ipaPath = "\(root)/Demo.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.demo")
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        var installerCalls: [(package: RealDevicePackageInstaller.PreparedInstallPackage, udid: String)] = []

        RealDevicePackageInstaller.preparedPackageInstallerForTesting = { package, udid, _ in
            installerCalls.append((package, udid))
        }

        try RealDevicePackageInstaller.installPackage(
            packagePath: ipaPath,
            kind: .ipa,
            udid: "REAL-1",
            bundleID: "com.example.demo"
        )

        XCTAssertEqual(installerCalls.count, 1)
        XCTAssertEqual(installerCalls[0].udid, "REAL-1")
        let package = installerCalls[0].package
        XCTAssertEqual(package.localPath, ipaPath)
        XCTAssertEqual(package.remotePath, "PublicStaging/com.example.demo")
        XCTAssertEqual(package.packagePath, "PublicStaging/com.example.demo")
        XCTAssertEqual(package.bundleID, "com.example.demo")
        XCTAssertEqual(package.uploadMode, .file)
        XCTAssertEqual(package.clientOptions["CFBundleIdentifier"] as? String, "com.example.demo")
        XCTAssertNil(package.clientOptions["PackageType"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipaPath))
    }




    func testIpaInstallFallsBackWhenDevicectlDoesNotSupportPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-devicectl-ipa-fallback-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ipaPath = "\(root)/Demo.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.demo", build: "7", version: "1.2")
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        var nativePackages: [RealDevicePackageInstaller.PreparedInstallPackage] = []
        RealDevicePackageInstaller.devicectlRunnerForTesting = { arguments in
            XCTAssertEqual(arguments, ["devicectl", "device", "install", "app", "--device", "REAL-1", ipaPath])
            return Shell.RunResult(stdout: "", stderr: "unsupported app bundle package", exitCode: 1)
        }
        RealDevicePackageInstaller.nativePackageInstallerForTesting = { package, _, _ in
            nativePackages.append(package)
        }
        RealDevicePackageInstaller.installedAppLookupForTesting = { _, bundleID in
            [
                "LookupResult": [
                    bundleID: [
                        "CFBundleIdentifier": bundleID,
                        "CFBundleVersion": "7",
                        "CFBundleShortVersionString": "1.2",
                    ],
                ],
            ]
        }

        try RealDevicePackageInstaller.installPackage(
            packagePath: ipaPath,
            kind: .ipa,
            udid: "REAL-1",
            bundleID: "com.example.demo"
        )

        XCTAssertEqual(nativePackages.count, 1)
        XCTAssertEqual(nativePackages.first?.remotePath, "PublicStaging/com.example.demo")
        XCTAssertEqual(nativePackages.first?.uploadMode, .file)
    }



    func testDevicectlPackageValidationFailureDoesNotFallBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-devicectl-validation-error-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let appPath = "\(root)/Demo.app"
        try makeMinimalVersionedApp(path: appPath, bundleID: "com.example.demo", build: "7", version: "1.2")
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        var nativeCalled = false
        RealDevicePackageInstaller.devicectlRunnerForTesting = { arguments in
            XCTAssertEqual(arguments, ["devicectl", "device", "install", "app", "--device", "REAL-1", appPath])
            return Shell.RunResult(stdout: "", stderr: "ApplicationVerificationFailed: signature invalid", exitCode: 1)
        }
        RealDevicePackageInstaller.nativePackageInstallerForTesting = { _, _, _ in
            nativeCalled = true
        }

        XCTAssertThrowsError(try RealDevicePackageInstaller.installPackage(
            packagePath: appPath,
            kind: .app,
            udid: "REAL-1",
            bundleID: "com.example.demo"
        )) { error in
            XCTAssertTrue("\(error)".contains("ApplicationVerificationFailed"))
        }
        XCTAssertFalse(nativeCalled)
    }


    func testInstallCommandRejectsUnsupportedPackageExtensionBeforeTargetResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-unsupported-extension-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let zipPath = "\(root)/Demo.zip"
        FileManager.default.createFile(atPath: zipPath, contents: Data(), attributes: nil)
        AppManagementService.installerForTesting = { _, _, _ in
            XCTFail("unsupported package extension must fail before installation")
            throw CLIParseError.invalidValue("unexpected installer invocation")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", zipPath])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("install supports .ipa and .app packages only"))
        XCTAssertFalse(result.stderr.contains("install requires --udid"))
    }


    func testAppManagementCommandsRejectActiveSimulatorLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-app-management-simulator-lock-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-LOCK", deviceType: "simulator", paths: paths)
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app")
        AppManagementService.installerForTesting = { _, _, _ in
            XCTFail("simulator lock must fail before install")
            throw CLIParseError.invalidValue("unexpected installer invocation")
        }
        AppManagementService.uninstallerForTesting = { _, _ in
            XCTFail("simulator lock must fail before uninstall")
        }
        AppManagementService.appsProviderForTesting = { _, _ in
            XCTFail("simulator lock must fail before apps")
            return []
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])
        let install = cli.run(arguments: ["install", ipaPath])
        let uninstall = cli.run(arguments: ["uninstall", "com.example.app"])
        let apps = cli.run(arguments: ["apps"])

        XCTAssertEqual(install.exitCode, 1)
        XCTAssertTrue(install.stderr.contains("install supports USB real devices only"))
        XCTAssertEqual(uninstall.exitCode, 1)
        XCTAssertTrue(uninstall.stderr.contains("uninstall supports USB real devices only"))
        XCTAssertEqual(apps.exitCode, 1)
        XCTAssertTrue(apps.stderr.contains("apps supports USB real devices only"))
    }











    func testDriverCommandRetriesAfterInitialConnectFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-driver-retry-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try """
        {"devices":{"REAL-CMD":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "REAL-CMD", deviceType: "real", paths: paths)

        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("direct driver command must not discover devices")
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = {
            XCTFail("direct driver command must not inspect USB devices")
            return []
        }
        var holderLaunches: [(String, String)] = []
        DriverLifecycleService.holderLauncherForTesting = { udid, bundleId, _, _ in
            holderLaunches.append((udid, bundleId))
            return DriverLifecycleService.LaunchMetadata(
                holderPid: 111,
                runnerPid: 222,
                sessionIdentifier: "RECOVERED",
                bundleId: bundleId,
                controlSocketPath: "\(root)/state/holder-recovered.sock"
            )
        }
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTAssertEqual(session.udid, "REAL-CMD")
            XCTAssertEqual(session.deviceType, "real")
            attempts += 1
            if attempts == 1 {
                return FakeDriverCommandClient(domHandler: { _, _, _ in
                    throw DriverClientError.connectFailed(61)
                })
            }
            return FakeDriverCommandClient(domHandler: { _, _, _ in
                ForyDomPayload(app: "com.example.app", windowSize: ForyPoint(x: 100, y: 200))
            })
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("App: com.example.app"))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(holderLaunches.map(\.0), ["REAL-CMD"])
        XCTAssertEqual(holderLaunches.map(\.1), ["com.example.driver"])
    }



    func testDriverCommandRecoversXCTestHolderOnConnectFailureOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-unresponsive-xctest-recover-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try """
        {"devices":{"REAL-XCTEST-HUNG":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        let staleInfo = SessionService.Info(
            udid: "REAL-XCTEST-HUNG",
            deviceName: "Phone",
            deviceVersion: "26.0",
            deviceType: "real",
            startedAt: 1,
            holderPid: 333,
            runnerPid: 444,
            startMode: "full-xctest",
            sessionIdentifier: "HUNG",
            bundleId: "com.example.driver"
        )
        try SessionService.writeDriverLock(info: staleInfo, paths: paths)

        DriverLifecycleService.processAliveForTesting = { pid in pid == 333 }
        DriverLifecycleService.holderProcessValidatorForTesting = { pid, udid in
            pid == 333 && udid == "REAL-XCTEST-HUNG"
        }
        var terminated: [SessionService.Info] = []
        DriverLifecycleService.holderTerminatorForTesting = { info, _ in
            terminated.append(info)
            return .terminated
        }
        var holderLaunches: [(String, String)] = []
        DriverLifecycleService.holderLauncherForTesting = { udid, bundleId, _, _ in
            holderLaunches.append((udid, bundleId))
            return DriverLifecycleService.LaunchMetadata(
                holderPid: 555,
                runnerPid: 666,
                sessionIdentifier: "RECOVERED-HUNG",
                bundleId: bundleId,
                controlSocketPath: "\(root)/state/holder-recovered-hung.sock"
            )
        }
        var clientSessions: [SessionService.Info] = []
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { session in
            clientSessions.append(session)
            attempts += 1
            if attempts == 1 {
                return FakeDriverCommandClient(domHandler: { _, _, _ in
                    throw DriverClientError.connectFailed(61)
                })
            }
            return FakeDriverCommandClient(domHandler: { _, _, _ in
                ForyDomPayload(app: "com.example.app", windowSize: ForyPoint(x: 100, y: 200))
            })
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("App: com.example.app"))
        XCTAssertEqual(terminated.map(\.holderPid), [333])
        XCTAssertEqual(holderLaunches.map(\.0), ["REAL-XCTEST-HUNG"])
        XCTAssertEqual(holderLaunches.map(\.1), ["com.example.driver"])
        XCTAssertEqual(clientSessions.map(\.holderPid), [333, 555])
    }

    func testDriverRecoveryRejectsChangedLifecycleIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-stale-recovery-identity-\(UUID().uuidString)"
            )
            .path
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root]
        )
        try """
        {"devices":{"REAL-STALE-RECOVERY":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(
            toFile: "\(root)/config.json",
            atomically: true,
            encoding: .utf8
        )
        let original = SessionService.Info(
            udid: "REAL-STALE-RECOVERY",
            deviceName: "Phone",
            deviceVersion: "26.0",
            deviceType: "real",
            startedAt: 1,
            holderPid: 101,
            runnerPid: 102,
            startMode: "full-xctest",
            sessionIdentifier: "ORIGINAL",
            bundleId: "com.example.driver",
            controlSocketPath: "\(root)/state/original.sock"
        )
        let replacement = SessionService.Info(
            udid: original.udid,
            deviceName: original.deviceName,
            deviceVersion: original.deviceVersion,
            deviceType: original.deviceType,
            startedAt: 2,
            holderPid: 201,
            runnerPid: 202,
            startMode: nil,
            sessionIdentifier: "REPLACEMENT",
            bundleId: original.bundleId,
            controlSocketPath: "\(root)/state/replacement.sock"
        )
        try SessionService.writeDriverLock(
            info: original,
            paths: paths
        )
        DriverLifecycleService.holderTerminatorForTesting = { _, _ in
            XCTFail("stale recovery must not terminate any holder")
            return .failed
        }
        DriverLifecycleService.holderLauncherForTesting = {
            _, _, _, _ in
            XCTFail("stale recovery must not launch a holder")
            throw CLIParseError.invalidValue("unexpected launch")
        }
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            attempts += 1
            return FakeDriverCommandClient(
                domHandler: { _, _, _ in
                    try SessionService.writeDriverLock(
                        info: replacement,
                        paths: paths
                    )
                    throw DriverClientError.connectFailed(61)
                }
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": root]
        ).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.contains(
                "Driver lifecycle changed before connection recovery"
            ),
            result.stderr
        )
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            try SessionService.readDriverLockInfo(paths: paths),
            replacement
        )
    }

    func testDriverRecoveryAndStopShareLifecycleLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-recovery-stop-lock-\(UUID().uuidString)"
            )
            .path
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root]
        )
        try """
        {"devices":{"REAL-RECOVERY-STOP":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(
            toFile: "\(root)/config.json",
            atomically: true,
            encoding: .utf8
        )
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-RECOVERY-STOP",
                deviceName: "Phone",
                deviceVersion: "26.0",
                deviceType: "real",
                startedAt: 1,
                holderPid: 301,
                runnerPid: 302,
                startMode: "full-xctest",
                sessionIdentifier: "BEFORE-RECOVERY",
                bundleId: "com.example.driver",
                controlSocketPath: "\(root)/state/before.sock"
            ),
            paths: paths
        )

        let firstOldTermination = DispatchSemaphore(value: 1)
        defer { firstOldTermination.signal() }
        let recoveryEnteredTermination = DispatchSemaphore(value: 0)
        let concurrentStopEnteredOldTermination =
            DispatchSemaphore(value: 0)
        let releaseRecoveryTermination = DispatchSemaphore(value: 0)
        let stopTerminatedRecoveredIdentity =
            DispatchSemaphore(value: 0)
        DriverLifecycleService.holderTerminatorForTesting = {
            info, _ in
            if info.sessionIdentifier == "BEFORE-RECOVERY" {
                if firstOldTermination.wait(timeout: .now())
                    == .success {
                    recoveryEnteredTermination.signal()
                } else {
                    concurrentStopEnteredOldTermination.signal()
                }
                _ = releaseRecoveryTermination.wait(
                    timeout: .now() + 5
                )
                return .terminated
            }
            XCTAssertEqual(
                info.sessionIdentifier,
                "AFTER-RECOVERY"
            )
            stopTerminatedRecoveredIdentity.signal()
            return .terminated
        }
        DriverLifecycleService.holderLauncherForTesting = {
            udid, bundleID, _, _ in
            XCTAssertEqual(udid, "REAL-RECOVERY-STOP")
            return DriverLifecycleService.LaunchMetadata(
                holderPid: 401,
                runnerPid: 402,
                sessionIdentifier: "AFTER-RECOVERY",
                bundleId: bundleID,
                controlSocketPath: "\(root)/state/after.sock"
            )
        }
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            attempts += 1
            if attempts == 1 {
                return FakeDriverCommandClient(
                    domHandler: { _, _, _ in
                        throw DriverClientError.connectFailed(61)
                    }
                )
            }
            return FakeDriverCommandClient(
                domHandler: { _, _, _ in
                    ForyDomPayload(
                        app: "com.example.app",
                        windowSize: ForyPoint(x: 100, y: 200)
                    )
                }
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let recoveryFinished = expectation(
            description: "driver recovery finished"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = IOSUseCLI(
                environment: ["IOS_USE_HOME": root]
            ).run(arguments: ["dom"])
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            recoveryFinished.fulfill()
        }
        XCTAssertEqual(
            recoveryEnteredTermination.wait(timeout: .now() + 5),
            .success
        )

        let stopFinished = expectation(
            description: "stop finished after recovery"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try SessionService.stop(paths: paths)
            } catch {
                XCTFail("stop failed: \(error)")
            }
            stopFinished.fulfill()
        }
        XCTAssertEqual(
            concurrentStopEnteredOldTermination.wait(
                timeout: .now() + 0.2
            ),
            .timedOut,
            "stop entered stale-holder termination while recovery "
                + "owned the lifecycle lock"
        )

        releaseRecoveryTermination.signal()
        releaseRecoveryTermination.signal()
        wait(
            for: [recoveryFinished, stopFinished],
            timeout: 5
        )
        XCTAssertEqual(
            stopTerminatedRecoveredIdentity.wait(timeout: .now()),
            .success
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.driverLock
            )
        )
    }

    func testDriverCommandDoesNotRelaunchWhenStaleHolderCannotBeStopped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-stuck-xctest-recover-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try """
        {"devices":{"REAL-XCTEST-STUCK":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-XCTEST-STUCK",
                deviceName: "Phone",
                deviceVersion: "26.0",
                deviceType: "real",
                startedAt: 1,
                holderPid: 777,
                runnerPid: 888,
                startMode: "full-xctest",
                sessionIdentifier: "STUCK",
                bundleId: "com.example.driver"
            ),
            paths: paths
        )

        DriverLifecycleService.processAliveForTesting = { pid in pid == 777 }
        DriverLifecycleService.holderProcessValidatorForTesting = { pid, udid in
            pid == 777 && udid == "REAL-XCTEST-STUCK"
        }
        var signals: [(Int32, Int32)] = []
        DriverLifecycleService.signalSenderForTesting = { pid, signal in
            signals.append((pid, signal))
            return 0
        }
        DriverLifecycleService.processExitWaiterForTesting = { _, _ in false }
        DriverLifecycleService.holderLauncherForTesting = { _, _, _, _ in
            XCTFail("must not relaunch a new holder when stale holder cleanup fails")
            return DriverLifecycleService.LaunchMetadata(
                holderPid: 999,
                runnerPid: 1000,
                sessionIdentifier: "BAD",
                bundleId: "com.example.driver",
                controlSocketPath: "\(root)/state/holder-bad.sock"
            )
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(domHandler: { _, _, _ in
                throw DriverClientError.connectFailed(61)
            })
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Failed to stop XCTest holder pid=777"))
        XCTAssertEqual(signals.map(\.0), [777, 777])
        XCTAssertEqual(signals.map(\.1), [SIGTERM, SIGKILL])
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.holderPid, 777)
        XCTAssertEqual(lock.sessionIdentifier, "STUCK")
    }


    func testActivateAppDefaultsToReadinessAndReusesReturnedDom() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-activate-ready-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "REAL-ACTIVE", deviceType: "real", paths: paths)
        var events: [String] = []
        AppLifecycleService.realDeviceRunnerForTesting = { options, udid in
            events.append("host:\(udid)")
            return AppLifecycleService.Result(message: "App \(options.bundleID) activated")
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(waitAppForegroundHandler: { expected, timeout, returnDom in
                events.append("driver:\(expected)")
                XCTAssertEqual(timeout, 0)
                XCTAssertTrue(returnDom)
                return ForyWaitAppForegroundPayload(
                    expectedBundleId: expected,
                    activeBundleId: expected,
                    appState: IOSUseAppState.foreground.rawValue,
                    snapshotReady: true,
                    elapsed: 0.125,
                    dom: ForyDomPayload(
                        app: expected,
                        windowSize: ForyPoint(x: 402, y: 874),
                        elements: [ForyDomElement(traits: ["Button"], label: "Ready")]
                    )
                )
            })
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            AppLifecycleService.realDeviceRunnerForTesting = nil
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: [
            "activateApp", "com.example.app", "--dom"
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(events, ["host:REAL-ACTIVE", "driver:com.example.app"])
        XCTAssertTrue(result.stdout.contains("Readiness: UI ready | active: com.example.app | elapsed: 0.1250s"))
        XCTAssertTrue(result.stdout.contains("Ready [Button]"))
    }

    func testActivateAppTargetMismatchFailsBeforeHostMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-activate-mismatch-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "REAL-A", deviceType: "real", paths: paths)
        AppLifecycleService.realDeviceRunnerForTesting = { _, _ in
            XCTFail("mismatched readiness target must fail before host launch")
            return AppLifecycleService.Result(message: "unexpected")
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("mismatched readiness target must fail before Driver connection")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            AppLifecycleService.realDeviceRunnerForTesting = nil
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: [
            "activateApp", "com.example.app", "--udid", "REAL-B"
        ])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("does not match active Driver target REAL-A"))
    }



    func testMutatingCommandRetriesTransientPostDomAndReturnsTypedJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-post-dom-retry-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-POST-DOM", deviceType: "simulator", paths: paths)
        var domCalls = 0
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(
                domHandler: { _, fresh, _ in
                    XCTAssertTrue(fresh)
                    domCalls += 1
                    if domCalls == 1 {
                        throw DriverClientError.driverError(
                            message: "snapshot warming up",
                            payload: ForyErrorPayload(
                                category: IOSUseErrorCategory.lookup,
                                code: IOSUseErrorCode.snapshotFailed,
                                phase: IOSUseErrorPhase.snapshot,
                                retryable: true
                            )
                        )
                    }
                    return ForyDomPayload(app: "com.example", elements: [
                        ForyDomElement(traits: ["Text"], label: "Ready")
                    ])
                },
                tapHandler: { target, _, _, _, _ in
                    ForyElementPayload(elemType: 9, label: target.label, rect: ForyRect(x: 1, y: 2, w: 3, h: 4))
                }
            )
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: [
            "tap", "Continue", "--dom", "100", "--json"
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(domCalls, 2)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual((data["element"] as? [String: Any])?["label"] as? String, "Continue")
        XCTAssertEqual((data["postDom"] as? [String: Any])?["app"] as? String, "com.example")
    }


    func testMutatingCommandPostDomReusesOneTCPConnection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-post-dom-tcp-reuse-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-POST-DOM-TCP", deviceType: "simulator", paths: paths)
        let fory = ForyRegistry.create()
        let server = try FakeDriverServer(responses: [
            ForyResponseFrame(ok: true, payload: try fory.serialize(ForyElementPayload(elemType: 9, label: "Continue", rect: ForyRect(x: 10, y: 20, w: 30, h: 40)))),
            ForyResponseFrame(ok: true, payload: try fory.serialize(ForyDomPayload(app: "com.example"))),
        ])
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            DriverClient(port: UInt16(server.port))
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            server.stop()
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["tap", "Continue", "--dom", "100"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Tap\nButton \"Continue\" (10,20,30,40)"))
        XCTAssertTrue(result.stdout.contains("DOM after 100ms\nApp: com.example"))
        XCTAssertEqual(server.acceptCount, 1)
        XCTAssertEqual(server.requestCommands, ["tap", "dom"])
        XCTAssertTrue(server.waitForDisconnect(timeout: 1.0))
    }


    func testHostSideAppLifecycleRequiresUdidOrActiveLock() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-app-lifecycle-no-target-\(UUID().uuidString)")
            .path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["activateApp", "com.apple.Preferences"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("activateApp requires an active driver for UI readiness"))
    }

    func testDriverCommandWithoutLockFailsBeforeClientOrDiscovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-driver-no-lock-\(UUID().uuidString)")
            .path
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("direct driver command without lock must not discover devices")
            return []
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("direct driver command without lock must not create a client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("No active driver. Run `ios-use start` first."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/state/session.json"))
    }

    func testDriverCommandUsesLockInsteadOfStaleSessionJSONAndDoesNotRetryReadFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-driver-lock-over-session-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try """
        {"sessionId":"legacy","udid":"SESSION-UDID","deviceType":"real"}
        """.write(toFile: paths.session, atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "SIM-LOCK", deviceType: "simulator", paths: paths)
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { session in
            attempts += 1
            XCTAssertEqual(session.udid, "SIM-LOCK")
            XCTAssertEqual(session.deviceType, "simulator")
            return FakeDriverCommandClient(domHandler: { _, _, _ in
                throw DriverClientError.readFailed
            })
        }
        SessionService.simulatorDriverLauncherForTesting = { _ in
            XCTFail("read/write failures after command send must not relaunch")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["dom"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("driver TCP read failed"))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(SessionService.readDriverLock(paths: paths), "SIM-LOCK")
    }





    func testOpenURLDomWaitsForVerifiedRealDeviceHandlerInsteadOfCurrentForegroundApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-dom-handler-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "REAL-1", deviceType: "real", paths: paths)
        var events: [String] = []
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, udid in
            XCTAssertEqual(scheme, "https")
            XCTAssertEqual(udid, "REAL-1")
            return OpenURLService.SchemeRegistry.LookupResult(
                registeredHandlers: ["com.apple.mobilesafari"],
                lookupFailed: false
            )
        }
        OpenURLService.realDeviceURLLauncherForTesting = { url, udid in
            XCTAssertEqual(url, "https://example.com")
            XCTAssertEqual(udid, "REAL-1")
            events.append("open")
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(waitAppForegroundHandler: { expected, timeout, returnDom in
                events.append("readiness:\(expected)")
                XCTAssertEqual(timeout, 0)
                XCTAssertTrue(returnDom)
                return ForyWaitAppForegroundPayload(
                    expectedBundleId: expected,
                    activeBundleId: expected,
                    appState: IOSUseAppState.foreground.rawValue,
                    snapshotReady: true,
                    elapsed: 0.25,
                    dom: ForyDomPayload(app: expected)
                )
            })
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: [
            "open", "https://example.com", "--dom"
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(events, ["open", "readiness:com.apple.mobilesafari"])
        XCTAssertTrue(result.stdout.contains("App: com.apple.mobilesafari"))
    }

    func testOpenURLDomRejectsUnverifiableRealDeviceHandlerAfterDispatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-dom-unverified-handler-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "REAL-1", deviceType: "real", paths: paths)
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { _, _ in
            OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: [], lookupFailed: true)
        }
        var dispatched = false
        OpenURLService.realDeviceURLLauncherForTesting = { _, _ in dispatched = true }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("unverified real-device URL handler must not return an unrelated Driver snapshot")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: [
            "open", "retouch://debug", "--dom"
        ])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(dispatched)
        XCTAssertTrue(result.stderr.contains("URL dispatch was accepted"))
        XCTAssertTrue(result.stderr.contains("cannot verify the target App"))
    }

    func testOpenURLExplicitBootedSimulatorUsesSimctlWithoutConfig() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-explicit-sim-\(UUID().uuidString)")
            .path
        let simulatorUdid = "00000000-0000-0000-0000-000000000001"
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
            return [IOSDevice(name: "iPhone", version: "26.0", udid: simulatorUdid, kind: .simulator)]
        }
        var shellCalls: [(String, [String])] = []
        Shell.runResultOverrideForTesting = { executable, arguments, _ in
            shellCalls.append((executable, arguments))
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("open URL for explicit booted simulator should not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runResultOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", simulatorUdid])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Opened URL: https://example.com\n")
        XCTAssertEqual(shellCalls.map(\.0), ["xcrun"])
        XCTAssertEqual(shellCalls.first?.1, ["simctl", "openurl", simulatorUdid, "https://example.com"])
    }


    func testOpenURLExplicitRealDeviceUsesNativeLauncherWithoutDevicectl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("explicit real-device open must not inspect Simulator devices")
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-CMD"] }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "https" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: ["com.apple.mobilesafari"], lookupFailed: false)
            }
            return nil
        }
        var nativeLaunches: [(String, String)] = []
        OpenURLService.realDeviceURLLauncherForTesting = { url, udid in
            nativeLaunches.append((url, udid))
        }
        var shellCalls: [(String, [String])] = []
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun", arguments.contains("devicectl") {
                XCTFail("real-device open must not call devicectl")
            }
            shellCalls.append((executable, arguments))
            return ""
        }
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTFail("open URL for real device should not create a driver client, got session \(String(describing: session))")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", "REAL-CMD"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Opened URL: https://example.com (handler: com.apple.mobilesafari)"))
        XCTAssertEqual(nativeLaunches.map(\.0), ["https://example.com"])
        XCTAssertEqual(nativeLaunches.map(\.1), ["REAL-CMD"])
        XCTAssertTrue(shellCalls.isEmpty)
    }






    func testOpenURLMacTargetsActiveSlotThroughSystemDispatcher() throws {
        let fixture = try makeMacOpenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var dispatchedURL: URL?
        var targetAppURL: URL?
        var targetPID: Int?
        OpenURLService.macURLLauncherForTesting = { url, appURL, session in
            dispatchedURL = url
            targetAppURL = appURL
            targetPID = session.runnerPid
        }
        IOSUseCLI.playCoverDriverClientFactoryForTesting = { _ in
            XCTFail("host-side Mac open must not call the Runtime")
            return FakeDriverCommandClient()
        }

        let result = IOSUseCLI(pathsForTesting: fixture.paths).run(
            arguments: ["open", "demo://route"]
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(dispatchedURL?.absoluteString, "demo://route")
        XCTAssertEqual(targetAppURL?.path, fixture.appPath)
        XCTAssertEqual(targetPID, fixture.runnerPID)
        XCTAssertTrue(result.stdout.contains("active Mac App"))
    }

    func testOpenURLMacRejectsUnregisteredSchemeBeforeDispatch() throws {
        let fixture = try makeMacOpenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        OpenURLService.macURLLauncherForTesting = { _, _, _ in
            XCTFail("unregistered scheme must not reach LaunchServices")
        }

        let result = IOSUseCLI(pathsForTesting: fixture.paths).run(
            arguments: ["open", "other://route", "--json"]
        )

        XCTAssertEqual(result.exitCode, 1)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(result.stderr.utf8)
            ) as? [String: Any]
        )
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "open_scheme_unregistered")
        XCTAssertEqual(error["mutationMayHaveApplied"] as? Bool, false)
    }

    func testOpenURLMacClassifiesSystemDispatchRejection() throws {
        let fixture = try makeMacOpenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        OpenURLService.macURLLauncherForTesting = { _, _, _ in
            throw OpenURLService.MacOpenError.dispatchRejected(
                "fixture rejection"
            )
        }

        let result = IOSUseCLI(pathsForTesting: fixture.paths).run(
            arguments: ["open", "demo://route", "--json"]
        )

        XCTAssertEqual(result.exitCode, 1)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(result.stderr.utf8)
            ) as? [String: Any]
        )
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "open_dispatch_rejected")
        XCTAssertEqual(error["retryable"] as? Bool, true)
    }

    func testOpenURLMacRejectsSlotIdentityMismatchBeforeDispatch() throws {
        let fixture = try makeMacOpenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("unexpected".utf8).write(
            to: URL(fileURLWithPath: fixture.appPath)
                .deletingLastPathComponent()
                .appendingPathComponent("unexpected-entry")
        )
        OpenURLService.macURLLauncherForTesting = { _, _, _ in
            XCTFail("invalid active slot must not reach LaunchServices")
        }

        let result = IOSUseCLI(pathsForTesting: fixture.paths).run(
            arguments: ["open", "demo://route", "--json"]
        )

        XCTAssertEqual(result.exitCode, 1)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(result.stderr.utf8)
            ) as? [String: Any]
        )
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(
            error["code"] as? String,
            "open_target_mismatch",
            result.stderr
        )
        XCTAssertEqual(error["mutationMayHaveApplied"] as? Bool, false)
    }






    func testDismissAlertSendsGuardedSelectionAndReturnsHumanAndJSONDetails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-dismiss-alert-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-ALERT", deviceType: "simulator", paths: paths)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        var received: [ForyDismissAlertArgs] = []
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(dismissAlertHandler: { args in
                received.append(args)
                return ForyAlertPayload(
                    dismissed: true,
                    surface: "springboard",
                    kind: "alert",
                    text: "Runner request",
                    buttonCount: 2,
                    buttons: [
                        ForyAlertButton(
                            queryIndex: 1,
                            label: "Allow",
                            hittable: true,
                            frame: ForyRect(x: 120, y: 300, w: 120, h: 44)
                        ),
                    ],
                    requestedSelection: "visualPrimary",
                    selectionStrategy: "visualPrimaryHeuristic",
                    selectedIndex: 1,
                    button: "Allow",
                    layoutDirection: "leftToRight",
                    layoutDirectionSource: "runnerEffective"
                )
            })
        }
        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])

        let human = cli.run(arguments: [
            "dismissAlert", "--primary", "--scope", "springboard", "--wait", "3s",
        ])
        let json = cli.run(arguments: [
            "dismissAlert", "--primary", "--scope", "springboard", "--wait", "3s", "--json",
        ])

        XCTAssertEqual(
            human.stdout,
            "Button \"Allow\" dismissed alert (selection=visualPrimaryHeuristic, index=1)\n"
        )
        XCTAssertEqual(json.exitCode, 0)
        XCTAssertTrue(json.stdout.contains(#""requestedSelection" : "visualPrimary""#))
        XCTAssertTrue(json.stdout.contains(#""layoutDirectionSource" : "runnerEffective""#))
        XCTAssertTrue(json.stdout.contains(#""queryIndex" : 1"#))
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy {
            $0.selection == IOSUseAlertSelectionMode.visualPrimary.rawValue
                && $0.scope == IOSUseAlertScope.springboard.rawValue
                && $0.wait == 3
        })
    }

    func testDismissAlertFailureReturnsBoundedAlertContextInHumanAndJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-dismiss-alert-error-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-ALERT", deviceType: "simulator", paths: paths)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let alert = ForyAlertPayload(
            surface: "springboard",
            kind: "alert",
            text: "private alert text",
            buttonCount: 2,
            buttons: [
                ForyAlertButton(
                    queryIndex: 0,
                    label: "Cancel",
                    hittable: true,
                    frame: ForyRect(x: 0, y: 0, w: 100, h: 44)
                ),
                ForyAlertButton(
                    queryIndex: 1,
                    label: "Continue",
                    hittable: true,
                    frame: ForyRect(x: 100, y: 0, w: 100, h: 44)
                ),
            ],
            requestedSelection: "onlyButton",
            reason: "2 hittable buttons require an explicit selection"
        )
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(dismissAlertHandler: { _ in
                throw DriverClientError.driverError(
                    message: "2 hittable buttons require an explicit selection",
                    payload: ForyErrorPayload(
                        category: IOSUseErrorCategory.lookup,
                        code: IOSUseErrorCode.alertAmbiguous,
                        phase: IOSUseErrorPhase.lookup,
                        alert: alert
                    )
                )
            })
        }
        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])

        let human = cli.run(arguments: ["dismissAlert"])
        let json = cli.run(arguments: ["dismissAlert", "--json"])

        XCTAssertEqual(human.exitCode, 1)
        XCTAssertTrue(human.stderr.contains("[alert_ambiguous]"))
        XCTAssertTrue(human.stderr.contains("Candidates:"))
        XCTAssertTrue(human.stderr.contains("[1] \"Continue\""))
        XCTAssertEqual(json.exitCode, 1)
        XCTAssertTrue(json.stderr.contains(#""code" : "alert_ambiguous""#))
        XCTAssertTrue(json.stderr.contains(#""buttonCount" : 2"#))
        XCTAssertTrue(json.stderr.contains(#""requestedSelection" : "onlyButton""#))
    }

    func testMediaImportSendsTypedBytesAndReturnsHumanAndJSONReceipts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-media-import-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: root).appendingPathComponent("fixture.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        try bytes.write(to: source)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-MEDIA", deviceType: "simulator", paths: paths)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        var received: [ForyMediaImportArgs] = []
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(mediaImportHandler: { args in
                received.append(args)
                return ForyMediaImportPayload(
                    kind: args.kind,
                    originalFilename: args.originalFilename,
                    byteCount: args.byteCount,
                    assetLocalIdentifier: "asset/fixture",
                    permissionPromptHandled: received.count == 1
                )
            })
        }
        let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])

        let human = cli.run(arguments: ["media", "import", source.path])
        let json = cli.run(arguments: ["media", "import", source.path, "--json"])

        XCTAssertEqual(human.exitCode, 0)
        XCTAssertEqual(
            human.stdout,
            "Imported photo fixture.png (4 bytes, asset asset/fixture)\n"
        )
        XCTAssertEqual(json.exitCode, 0)
        XCTAssertTrue(json.stdout.contains(#""command" : "media import""#))
        XCTAssertTrue(json.stdout.contains(#""assetLocalIdentifier" : "asset/fixture""#))
        XCTAssertTrue(json.stdout.contains(#""permissionPromptHandled" : false"#))
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { $0.kind == "photo" })
        XCTAssertTrue(received.allSatisfy { $0.originalFilename == "fixture.png" })
        XCTAssertTrue(received.allSatisfy { $0.uniformTypeIdentifier == "public.png" })
        XCTAssertTrue(received.allSatisfy { $0.byteCount == 4 && $0.data == bytes })
    }

    func testMediaImportRoutesActivePlayCoverSessionToHostClient()
        throws
    {
        let root =
            "/tmp/iu-pcm-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        let source = URL(fileURLWithPath: root)
            .appendingPathComponent("fixture.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        try bytes.write(to: source)
        let accountRoot = "\(root)/account"
        let socketRoot = "\(root)/socket"
        try FileManager.default.createDirectory(
            atPath: accountRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: socketRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root],
            accountHomeDirectoryOverrideForTesting: accountRoot,
            socketRootOverrideForTesting: socketRoot
        )
        let sessionID = "media-session"
        let installRevision = String(repeating: "a", count: 64)
        let bundleIdentifier = "com.example.media"
        let slotDirectory =
            "\(paths.playcoverApps)/\(bundleIdentifier)"
        let appPath =
            "\(slotDirectory)/App.app"
        try FileManager.default.createDirectory(
            atPath: appPath,
            withIntermediateDirectories: true
        )
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleExecutable": "Media",
            ],
            format: .xml,
            options: 0
        )
        try info.write(
            to: URL(fileURLWithPath: appPath)
                .appendingPathComponent("Info.plist")
        )
        let executablePath = "\(appPath)/Media"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: executablePath,
                contents: Data()
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executablePath
        )
        for embeddedExecutable in [
            "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime",
            "Frameworks/IOSUseFridaEngine.framework/IOSUseFridaEngine",
        ] {
            let url = URL(fileURLWithPath: appPath)
                .appendingPathComponent(embeddedExecutable)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: Data()
                )
            )
        }
        let metadata = PlayCoverSlotMetadata(
            bundleIdentifier: bundleIdentifier,
            executableRelativePath: "Media",
            installRevision: installRevision,
            sourceContentHash: String(repeating: "b", count: 64),
            signingCertificateSHA256:
                String(repeating: "B", count: 64)
        )
        let metadataURL = URL(fileURLWithPath: slotDirectory)
            .appendingPathComponent("slot.json")
        try JSONEncoder().encode(metadata).write(to: metadataURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: metadataURL.path
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverRun,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(paths.playcoverRun, 0o700), 0)
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "mac",
                deviceName: "iPhone16,2",
                deviceVersion: "18.7",
                deviceType: PlayCoverSessionService.deviceType,
                startedAt: 1,
                runnerPid: 42,
                startMode: PlayCoverSessionService.deviceType,
                sessionIdentifier: sessionID,
                bundleId: bundleIdentifier,
                macAppPath: appPath,
                macExecutablePath: executablePath,
                macInstallRevision: installRevision,
                macRuntimeSocketPath:
                    try paths.macRuntimeSocketPath(
                        sessionID: sessionID
                    )
            ),
            paths: paths
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        var received: ForyMediaImportArgs?
        IOSUseCLI.playCoverDriverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(mediaImportHandler: {
                received = $0
                return ForyMediaImportPayload(
                    kind: $0.kind,
                    originalFilename: $0.originalFilename,
                    byteCount: $0.byteCount,
                    assetLocalIdentifier: "playcover/asset",
                    permissionPromptHandled: false
                )
            })
        }

        let result = IOSUseCLI(pathsForTesting: paths).run(
            arguments: ["media", "import", source.path]
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "Imported photo fixture.png "
                + "(4 bytes, asset playcover/asset)\n"
        )
        XCTAssertEqual(received?.data, bytes)
        XCTAssertEqual(received?.uniformTypeIdentifier, "public.png")
    }



    // MARK: - SchemeRegistry.parseSchemeHandlers











    private func makeMinimalIpa(
        path: String,
        bundleID: String,
        build: String? = nil,
        version: String? = nil,
        applicationSINF: Data? = nil,
        iTunesMetadata: Data? = nil
    ) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-test-ipa-\(UUID().uuidString)", isDirectory: true)
            .path
        let appPath = "\(tmp)/Payload/App.app"
        if let build, let version {
            try makeMinimalVersionedApp(path: appPath, bundleID: bundleID, build: build, version: version)
        } else {
            try makeMinimalApp(path: appPath, bundleID: bundleID)
        }
        if let applicationSINF {
            let scInfoPath = "\(appPath)/SC_Info"
            try FileManager.default.createDirectory(atPath: scInfoPath, withIntermediateDirectories: true)
            try applicationSINF.write(to: URL(fileURLWithPath: "\(scInfoPath)/App.sinf"))
        }
        if let iTunesMetadata {
            try iTunesMetadata.write(to: URL(fileURLWithPath: "\(tmp)/iTunesMetadata.plist"))
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var zipInputs = ["Payload"]
        if iTunesMetadata != nil {
            zipInputs.append("iTunesMetadata.plist")
        }
        _ = try Shell.run("zip", arguments: ["-r", "-q", path] + zipInputs, cwd: tmp)
    }

    private func installResult(
        bundleID: String,
        build: String? = nil,
        version: String? = nil,
        installer: RealDevicePackageInstaller.InstallerRoute = .installationProxy
    ) -> RealDevicePackageInstaller.InstallResult {
        let versionInfo = AppVersionInfo(bundleVersion: build, shortVersion: version)
        return RealDevicePackageInstaller.InstallResult(
            bundleID: bundleID,
            sourceVersion: versionInfo,
            installedVersion: versionInfo,
            installer: installer
        )
    }

    private func makeMinimalApp(path: String, bundleID: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "App",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: "\(path)/Info.plist"))
    }

    private func makeMinimalVersionedApp(path: String, bundleID: String, build: String, version: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "App",
            "CFBundleVersion": build,
            "CFBundleShortVersionString": version,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: "\(path)/Info.plist"))
        try Data("binary".utf8).write(to: URL(fileURLWithPath: "\(path)/App"))
    }

    private struct MacOpenFixture {
        let root: URL
        let paths: IOSUsePaths
        let appPath: String
        let runnerPID: Int
    }

    private func makeMacOpenFixture() throws -> MacOpenFixture {
        let root = URL(
            fileURLWithPath: "/tmp/iu-mo-"
                + String(UUID().uuidString.prefix(8)),
            isDirectory: true
        )
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": root.appendingPathComponent("home").path,
            ],
            accountHomeDirectoryOverrideForTesting:
                root.appendingPathComponent("account").path,
            socketRootOverrideForTesting:
                root.appendingPathComponent("sockets").path
        )
        let bundleIdentifier = "com.example.macopen"
        let installRevision = String(repeating: "a", count: 64)
        let slot = URL(
            fileURLWithPath: paths.playcoverApps,
            isDirectory: true
        ).appendingPathComponent(bundleIdentifier, isDirectory: true)
        let app = slot.appendingPathComponent("App.app", isDirectory: true)
        let runtime = app.appendingPathComponent(
            "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime"
        )
        let engine = app.appendingPathComponent(
            "Frameworks/IOSUseFridaEngine.framework/IOSUseFridaEngine"
        )
        try FileManager.default.createDirectory(
            at: runtime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: engine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let executable = app.appendingPathComponent("Demo")
        for file in [executable, runtime, engine] {
            try Data("fixture".utf8).write(to: file)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "Demo",
            "CFBundleURLTypes": [[
                "CFBundleURLSchemes": ["demo"],
            ]],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let metadata = PlayCoverSlotMetadata(
            bundleIdentifier: bundleIdentifier,
            executableRelativePath: "Demo",
            installRevision: installRevision,
            sourceContentHash: String(repeating: "b", count: 64),
            signingCertificateSHA256: String(repeating: "B", count: 64)
        )
        let metadataURL = slot.appendingPathComponent("slot.json")
        try JSONEncoder().encode(metadata).write(to: metadataURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: metadataURL.path
        )
        let sessionID = UUID().uuidString
        let runnerPID = 42
        try FileManager.default.createDirectory(
            atPath: paths.playcoverRun,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(Darwin.chmod(paths.playcoverRun, 0o700), 0)
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: PlayCoverSessionService.deviceType,
                deviceName: "Mac",
                deviceVersion: "Mac Catalyst",
                deviceType: PlayCoverSessionService.deviceType,
                startedAt: 1,
                runnerPid: runnerPID,
                startMode: PlayCoverSessionService.deviceType,
                sessionIdentifier: sessionID,
                bundleId: bundleIdentifier,
                macAppPath: app.path,
                macExecutablePath: executable.path,
                macInstallRevision: installRevision,
                macRuntimeSocketPath: try paths.macRuntimeSocketPath(
                    sessionID: sessionID
                )
            ),
            paths: paths
        )
        return MacOpenFixture(
            root: root,
            paths: paths,
            appPath: app.path,
            runnerPID: runnerPID
        )
    }

    private func writeDriverLock(udid: String, deviceType: String, paths: IOSUsePaths) throws {
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: udid,
                deviceName: deviceType == "simulator" ? "iPhone" : "Phone",
                deviceVersion: "26.0",
                deviceType: deviceType,
                startedAt: 1
            ),
            paths: paths
        )
    }
}
private final class FakeDriverCommandClient: DriverCommandClient {
    private let domHandler: (Bool, Bool, Bool) throws -> ForyDomPayload
    private let tapHandler: (ForyTarget, String?, Int32?, ForyPoint?, ForyPoint?) throws -> ForyElementPayload
    private let activateHandler: (String) throws -> Void
    private let terminateHandler: (String) throws -> Void
    private let screenshotHandler: () throws -> ScreenshotCapture
    private let waitAppForegroundHandler: (String, Double, Bool) throws -> ForyWaitAppForegroundPayload
    private let mediaImportHandler: (ForyMediaImportArgs) throws -> ForyMediaImportPayload
    private let dismissAlertHandler: (ForyDismissAlertArgs) throws -> ForyAlertPayload

    init(
        domHandler: @escaping (Bool, Bool, Bool) throws -> ForyDomPayload = { _, _, _ in
            throw CLIParseError.invalidValue("unexpected dom")
        },
        tapHandler: @escaping (ForyTarget, String?, Int32?, ForyPoint?, ForyPoint?) throws -> ForyElementPayload = { _, _, _, _, _ in
            throw CLIParseError.invalidValue("unexpected tap")
        },
        activateHandler: @escaping (String) throws -> Void = { _ in
            throw CLIParseError.invalidValue("unexpected activateApp")
        },
        terminateHandler: @escaping (String) throws -> Void = { _ in
            throw CLIParseError.invalidValue("unexpected terminateApp")
        },
        screenshotHandler: @escaping () throws -> ScreenshotCapture = {
            throw CLIParseError.invalidValue("unexpected screenshot")
        },
        waitAppForegroundHandler: @escaping (String, Double, Bool) throws -> ForyWaitAppForegroundPayload = { _, _, _ in
            throw CLIParseError.invalidValue("unexpected waitAppForeground")
        },
        mediaImportHandler: @escaping (ForyMediaImportArgs) throws -> ForyMediaImportPayload = { _ in
            throw CLIParseError.invalidValue("unexpected media import")
        },
        dismissAlertHandler: @escaping (ForyDismissAlertArgs) throws -> ForyAlertPayload = { _ in
            throw CLIParseError.invalidValue("unexpected dismissAlert")
        }
    ) {
        self.domHandler = domHandler
        self.tapHandler = tapHandler
        self.activateHandler = activateHandler
        self.terminateHandler = terminateHandler
        self.screenshotHandler = screenshotHandler
        self.waitAppForegroundHandler = waitAppForegroundHandler
        self.mediaImportHandler = mediaImportHandler
        self.dismissAlertHandler = dismissAlertHandler
    }

    func close() {}

    func dom(raw: Bool, fresh: Bool, waitQuiescence: Bool) throws -> ForyDomPayload {
        try domHandler(raw, fresh, waitQuiescence)
    }

    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload {
        throw CLIParseError.invalidValue("unexpected waitFor")
    }

    func screenshot() throws -> Data {
        try screenshotHandler().jpeg
    }

    func screenshotCapture() throws -> ScreenshotCapture {
        try screenshotHandler()
    }

    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint?) throws -> ForyElementPayload {
        try tapHandler(target, traits, cindex, offset, ratio)
    }

    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload {
        throw CLIParseError.invalidValue("unexpected longPress")
    }

    func input(
        tap: ForyTarget?,
        content: String
    ) throws -> ForyElementPayload {
        throw CLIParseError.invalidValue("unexpected input")
    }

    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload {
        throw CLIParseError.invalidValue("unexpected swipe")
    }

    func activateApp(bundleId: String) throws {
        try activateHandler(bundleId)
    }

    func terminateApp(bundleId: String) throws {
        try terminateHandler(bundleId)
    }

    func home() throws {
        throw CLIParseError.invalidValue("unexpected home")
    }

    func dismissAlert(args: ForyDismissAlertArgs) throws -> ForyAlertPayload {
        try dismissAlertHandler(args)
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        throw CLIParseError.invalidValue("unexpected proxyCAPush")
    }

    func waitAppForeground(expectedBundleId: String, timeout: Double, returnDom: Bool) throws -> ForyWaitAppForegroundPayload {
        try waitAppForegroundHandler(expectedBundleId, timeout, returnDom)
    }

    func mediaImport(args: ForyMediaImportArgs) throws -> ForyMediaImportPayload {
        try mediaImportHandler(args)
    }

}
