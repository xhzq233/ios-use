import XCTest
import Darwin
import IOSUseProtocol
@testable import IOSUseCLI

final class IOSUseCLITests: XCTestCase {
    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        DeviceService.listDevicesOverrideForTesting = nil
        DeviceService.usbDeviceUdidsOverrideForTesting = nil
        DeviceService.realDeviceResolverForTesting = nil
        DeviceService.resetCacheForTesting()
        DriverClient.usbmuxConnectorForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
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
        AppManagementService.installerForTesting = nil
        AppManagementService.uninstallerForTesting = nil
        AppManagementService.appsProviderForTesting = nil
        RealDevicePackageInstaller.preparedPackageInstallerForTesting = nil
        RealDevicePackageInstaller.nativePackageInstallerForTesting = nil
        RealDevicePackageInstaller.installedAppLookupForTesting = nil
        RealDevicePackageInstaller.devicectlRunnerForTesting = nil
        DeveloperDiskImageService.mountForTesting = nil
        StatusService.simctlAvailableForTesting = nil
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
        super.tearDown()
    }

    func testHelpContainsRootUsageAndCommands() {
        let result = IOSUseCLI().run(arguments: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Swift CLI for ios-use"))
        XCTAssertTrue(result.stdout.contains("Usage: ios-use [--help] [--version] <command>"))
        XCTAssertTrue(result.stdout.contains("status, config, start, stop, dom"))
        XCTAssertTrue(result.stdout.contains("ddi-mount"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testUnknownOptionFailsBeforeAnySessionWork() {
        let result = IOSUseCLI().run(arguments: ["--not-a-real-option"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("unknown option '--not-a-real-option'"))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testPerCommandHelpShortCircuitsInCLI() {
        let result = IOSUseCLI().run(arguments: ["oslog", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage: ios-use oslog"))
        XCTAssertTrue(result.stdout.contains("--process <name>"))
        XCTAssertTrue(result.stdout.contains("--pid <pid>"))
        XCTAssertFalse(result.stdout.contains("Usage: ios-use [--help]"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testHelpCommandReturnsPerCommandHelp() {
        let result = IOSUseCLI().run(arguments: ["help", "tap"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage: ios-use tap <target>"))
        XCTAssertTrue(result.stdout.contains("--offset-ratio <x,y>"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testStatusReportsDevicesCapturesProxyAndConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-status-\(UUID().uuidString)", isDirectory: true)
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try FileManager.default.createDirectory(atPath: "\(root)/state", withIntermediateDirectories: true)
        try """
        {"devices":{"REAL-1":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: paths.config, atomically: true, encoding: .utf8)
        try SessionService.writeDriverLock(info: SessionService.Info(
            udid: "REAL-1",
            deviceName: "Real Phone",
            deviceVersion: "17.4",
            deviceType: "real",
            startedAt: 1,
            holderPid: 11,
            runnerPid: 12,
            startMode: "xctest-holder",
            sessionIdentifier: "session-1",
            bundleId: "com.example.driver"
        ), paths: paths)
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
                helperPID: 101,
                lastError: nil
            )
        ), paths: paths)
        try JSONEncoder().encode(NSLogState(lastCapture: NSLogCaptureTarget(
            logFile: "\(root)/logs/nslog.log",
            name: "unit",
            startedAt: 1,
            stoppedAt: nil,
            status: "running",
            pid: 202,
            port: 303
        ))).write(to: URL(fileURLWithPath: paths.nslogState))
        try JSONEncoder().encode(ProxySessionState(
            sessionId: "proxy-1",
            status: "running",
            startedAt: 1,
            udid: "REAL-1",
            flowFile: "\(root)/artifacts/proxy.flow",
            caInstalled: true,
            network: ProxySessionState.NetworkInfo(interface: "en0", macLanIp: "192.168.1.10"),
            mitmdumpPid: 404,
            mitmdumpPort: 8080,
            serverStatus: "running",
            deviceProxyStatus: "configured",
            caStatus: "trusted"
        )).write(to: URL(fileURLWithPath: "\(root)/state/proxy-session.json"))
        StatusService.simctlAvailableForTesting = { true }
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                return [IOSDevice(name: "Booted Sim", version: "26.0", udid: "SIM-1", kind: .simulator)]
            }
            return [IOSDevice(name: "Real Phone", version: "17.4", udid: "REAL-1", kind: .real)]
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["status"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Connected devices:"))
        XCTAssertTrue(result.stdout.contains("Real Phone | iOS 17.4 | Device | UDID: REAL-1 | configured"))
        XCTAssertTrue(result.stdout.contains("Booted Sim | iOS 26.0 | Simulator | UDID: SIM-1"))
        XCTAssertTrue(result.stdout.contains("Driver:"))
        XCTAssertTrue(result.stdout.contains("running | udid: REAL-1 | device: real | name: Real Phone | iOS: 17.4 | bundle: com.example.driver | holder pid: 11 | runner pid: 12 | session: session-1"))
        XCTAssertTrue(result.stdout.contains("App log:"))
        XCTAssertTrue(result.stdout.contains("running | bundle: com.example.app | udid: REAL-1 | device: real | pid: 101"))
        XCTAssertTrue(result.stdout.contains("NSLog:"))
        XCTAssertTrue(result.stdout.contains("running | name: unit | pid: 202 | port: 303"))
        XCTAssertTrue(result.stdout.contains("Proxy:"))
        XCTAssertTrue(result.stdout.contains("running | udid: REAL-1 | server: running | device proxy: configured | CA: trusted"))
        XCTAssertTrue(result.stdout.contains("Config:"))
        XCTAssertTrue(result.stdout.contains("REAL-1 | bundleId: com.example.driver | driverVersion: \(IOSUseCLI.version)"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testStatusSkipsBootedSimulatorsWhenSimctlIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-status-no-simctl-\(UUID().uuidString)", isDirectory: true)
            .path
        StatusService.simctlAvailableForTesting = { false }
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            if simulatorOnly {
                XCTFail("status must not list booted Simulators when simctl is unavailable")
                return []
            }
            return [IOSDevice(name: "Real Phone", version: "17.4", udid: "REAL-1", kind: .real)]
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["status"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Connected devices:"))
        XCTAssertFalse(result.stdout.contains("Booted Simulators:"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testAppLifecycleHelpIsHostSide() {
        let result = IOSUseCLI().run(arguments: ["activateApp", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage: ios-use activateApp <bundleId> [--udid <udid>]"))
        XCTAssertTrue(result.stdout.contains("using host-side device services"))
        XCTAssertTrue(result.stdout.contains("--udid <udid>"))
        XCTAssertTrue(result.stdout.contains("--terminateExisting"))
        XCTAssertTrue(result.stdout.contains("--log"))
        XCTAssertFalse(result.stdout.contains("Requires an active driver.lock"))
    }

    func testAllDocumentedCommandsReturnPerCommandHelp() {
        let cases: [(arguments: [String], usage: String)] = [
            (["status", "--help"], "Usage: ios-use status"),
            (["config", "--help"], "Usage: ios-use config"),
            (["start", "--help"], "Usage: ios-use start"),
            (["stop", "--help"], "Usage: ios-use stop"),
            (["dom", "--help"], "Usage: ios-use dom"),
            (["waitFor", "--help"], "Usage: ios-use waitFor"),
            (["screenshot", "--help"], "Usage: ios-use screenshot"),
            (["tap", "--help"], "Usage: ios-use tap"),
            (["longpress", "--help"], "Usage: ios-use longpress"),
            (["input", "--help"], "Usage: ios-use input"),
            (["swipe", "--help"], "Usage: ios-use swipe"),
            (["activateApp", "--help"], "Usage: ios-use activateApp"),
            (["terminateApp", "--help"], "Usage: ios-use terminateApp"),
            (["home", "--help"], "Usage: ios-use home"),
            (["open", "--help"], "Usage: ios-use open"),
            (["install", "--help"], "Usage: ios-use install"),
            (["uninstall", "--help"], "Usage: ios-use uninstall"),
            (["apps", "--help"], "Usage: ios-use apps"),
            (["ddi-mount", "--help"], "Usage: ios-use ddi-mount"),
            (["dismissAlert", "--help"], "Usage: ios-use dismissAlert"),
            (["flow", "--help"], "Usage: ios-use flow"),
            (["proxy", "--help"], "Usage: ios-use proxy"),
            (["proxy", "start", "--help"], "Usage: ios-use proxy start"),
            (["proxy", "stop", "--help"], "Usage: ios-use proxy stop"),
            (["proxy", "configca", "--help"], "Usage: ios-use proxy configca"),
            (["proxy", "doctor", "--help"], "Usage: ios-use proxy doctor"),
            (["oslog", "--help"], "Usage: ios-use oslog"),
            (["nslog", "--help"], "Usage: ios-use nslog"),
            (["log-read", "--help"], "Usage: ios-use log-read"),
        ]

        for entry in cases {
            let result = IOSUseCLI().run(arguments: entry.arguments)

            XCTAssertEqual(result.exitCode, 0, entry.arguments.joined(separator: " "))
            XCTAssertTrue(result.stdout.contains(entry.usage), entry.arguments.joined(separator: " "))
            XCTAssertFalse(result.stdout.contains("Usage: ios-use [--help]"), entry.arguments.joined(separator: " "))
            XCTAssertTrue(result.stderr.isEmpty, entry.arguments.joined(separator: " "))
        }
    }

    func testDriverDeploymentTargetsStayAtIOS17() throws {
        let repoRoot = repositoryRootForTest()
        let driverProject = try String(contentsOf: repoRoot.appendingPathComponent("driver/project.yml"))
        let sharedPackage = try String(contentsOf: repoRoot.appendingPathComponent("shared/IOSUseProtocol/Package.swift"))

        XCTAssertTrue(driverProject.contains("iOS: \"17.0\""))
        XCTAssertFalse(driverProject.contains("iOS: \"16.0\""))
        XCTAssertTrue(sharedPackage.contains(".iOS(.v17)"))
        XCTAssertFalse(sharedPackage.contains(".iOS(.v16)"))
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

    private func repositoryRootForTest() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }

    func testInstallCommandUsesActiveDriverLockWhenUdidIsOmitted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-active-lock-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "LOCK-REAL", deviceType: "real", paths: paths)
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app")
        var installs: [(String, String, String?)] = []
        AppManagementService.installerForTesting = { ipa, udid, bundleID in
            installs.append((ipa, udid, bundleID))
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("install is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", ipaPath])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(installs.map(\.1), ["LOCK-REAL"])
        XCTAssertTrue(result.stdout.contains("Installed IPA on LOCK-REAL"))
    }

    func testInstallCommandAcceptsAppBundleAndExtractsBundleID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-app-bundle-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let appPath = "\(root)/Demo.app"
        try makeMinimalApp(path: appPath, bundleID: "com.example.demo")
        var installs: [(String, String, String?)] = []
        AppManagementService.installerForTesting = { package, udid, bundleID in
            installs.append((package, udid, bundleID))
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", appPath, "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(installs.map(\.0), [appPath])
        XCTAssertEqual(installs.map(\.1), ["REAL-1"])
        XCTAssertEqual(installs.map(\.2), ["com.example.demo"])
        XCTAssertTrue(result.stdout.contains("Installed app on REAL-1 (com.example.demo)"))
    }

    func testAppBundleInstallUsesDeveloperDirectoryPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-app-directory-install-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let appPath = "\(root)/Demo.app"
        try makeMinimalApp(path: appPath, bundleID: "com.example.demo")
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        var installerCalls: [(package: RealDevicePackageInstaller.PreparedInstallPackage, udid: String)] = []

        RealDevicePackageInstaller.preparedPackageInstallerForTesting = { package, udid, _ in
            installerCalls.append((package, udid))
        }

        try RealDevicePackageInstaller.installPackage(
            packagePath: appPath,
            kind: .app,
            udid: "REAL-1",
            bundleID: "com.example.demo"
        )

        XCTAssertEqual(installerCalls.count, 1)
        XCTAssertEqual(installerCalls[0].udid, "REAL-1")
        let package = installerCalls[0].package
        XCTAssertEqual(package.localPath, appPath)
        XCTAssertEqual(package.remotePath, "PublicStaging/Demo.app")
        XCTAssertEqual(package.packagePath, "PublicStaging/Demo.app")
        XCTAssertEqual(package.bundleID, "com.example.demo")
        XCTAssertEqual(package.uploadMode, .directory)
        XCTAssertEqual(package.clientOptions["PackageType"] as? String, "Developer")
        XCTAssertNil(package.clientOptions["CFBundleIdentifier"])
    }

    func testSparseInstallCommandsRecordSourceAndTargetVersions() throws {
        let data = RealDevicePackageInstaller.sparseInstallCommands(
            bundleID: "com.example.demo",
            sourceVersion: AppVersionInfo(bundleVersion: "1", shortVersion: "1.0"),
            targetVersion: AppVersionInfo(bundleVersion: "2", shortVersion: "2.0")
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\n1 1.0\n+Info.plist\n+_CodeSignature/CodeResources\nxEOF\n"))
        XCTAssertTrue(text.contains("#Bundle id: com.example.demo"))
        XCTAssertTrue(text.contains("#Old bundle version: 1 1.0"))
        XCTAssertTrue(text.contains("#New bundle version: 2 2.0"))
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

    func testPreparedIpaPackageReadsSinfAndITunesMetadataOptions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-ipa-metadata-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ipaPath = "\(root)/Demo.ipa"
        try makeMinimalIpa(
            path: ipaPath,
            bundleID: "com.example.demo",
            build: "7",
            version: "1.2",
            applicationSINF: Data([0x01, 0x02]),
            iTunesMetadata: Data([0x03, 0x04])
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let package = try RealDevicePackageInstaller.preparedIpaPackage(ipaPath: ipaPath, explicitBundleID: "com.example.demo")

        XCTAssertEqual(package.remotePath, "PublicStaging/com.example.demo")
        XCTAssertEqual(package.expectedVersion, AppVersionInfo(bundleVersion: "7", shortVersion: "1.2"))
        XCTAssertEqual(package.clientOptions["ApplicationSINF"] as? Data, Data([0x01, 0x02]))
        XCTAssertEqual(package.clientOptions["iTunesMetadata"] as? Data, Data([0x03, 0x04]))
    }

    func testInstallPackageUsesDevicectlWhenDeviceIsAvailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-devicectl-install-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let appPath = "\(root)/Demo.app"
        try makeMinimalVersionedApp(path: appPath, bundleID: "com.example.demo", build: "7", version: "1.2")
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        var devicectlCalls: [[String]] = []
        var nativeCalled = false
        RealDevicePackageInstaller.devicectlRunnerForTesting = { arguments in
            devicectlCalls.append(arguments)
            return Shell.RunResult(stdout: "installed\n", stderr: "", exitCode: 0)
        }
        RealDevicePackageInstaller.nativePackageInstallerForTesting = { _, _, _ in
            nativeCalled = true
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
            packagePath: appPath,
            kind: .app,
            udid: "REAL-1",
            bundleID: "com.example.demo"
        )

        XCTAssertFalse(nativeCalled)
        XCTAssertEqual(devicectlCalls, [["devicectl", "device", "install", "app", "--device", "REAL-1", appPath]])
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

    func testAppInstallFallsBackWhenDevicectlEnvironmentIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-devicectl-app-fallback-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let appPath = "\(root)/Demo.app"
        try makeMinimalVersionedApp(path: appPath, bundleID: "com.example.demo", build: "7", version: "1.2")
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        var nativePackages: [RealDevicePackageInstaller.PreparedInstallPackage] = []
        RealDevicePackageInstaller.devicectlRunnerForTesting = { arguments in
            XCTAssertEqual(arguments, ["devicectl", "device", "install", "app", "--device", "REAL-1", appPath])
            return Shell.RunResult(stdout: "", stderr: "CoreDevice failed to prepare Developer Disk Image", exitCode: 1)
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
            packagePath: appPath,
            kind: .app,
            udid: "REAL-1",
            bundleID: "com.example.demo"
        )

        XCTAssertEqual(nativePackages.count, 1)
        XCTAssertEqual(nativePackages.first?.remotePath, "PublicStaging/Demo.app")
        XCTAssertEqual(nativePackages.first?.uploadMode, .directory)
    }

    func testAppInstallFallsBackWhenDevicectlToolIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-devicectl-missing-fallback-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let appPath = "\(root)/Demo.app"
        try makeMinimalVersionedApp(path: appPath, bundleID: "com.example.demo", build: "7", version: "1.2")
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }
        var nativePackages: [RealDevicePackageInstaller.PreparedInstallPackage] = []
        RealDevicePackageInstaller.devicectlRunnerForTesting = { arguments in
            XCTAssertEqual(arguments, ["devicectl", "device", "install", "app", "--device", "REAL-1", appPath])
            return Shell.RunResult(stdout: "", stderr: "env: xcrun: No such file or directory", exitCode: 127)
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
            packagePath: appPath,
            kind: .app,
            udid: "REAL-1",
            bundleID: "com.example.demo"
        )

        XCTAssertEqual(nativePackages.count, 1)
        XCTAssertEqual(nativePackages.first?.remotePath, "PublicStaging/Demo.app")
        XCTAssertEqual(nativePackages.first?.uploadMode, .directory)
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

    func testGenericCoreDeviceInstallFailureDoesNotFallBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-devicectl-coredevice-error-\(UUID().uuidString)")
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
            return Shell.RunResult(stdout: "", stderr: "CoreDeviceError: install failed for app bundle", exitCode: 1)
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
            XCTAssertTrue("\(error)".contains("CoreDeviceError"))
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
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", zipPath])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("install supports .ipa and .app packages only"))
        XCTAssertFalse(result.stderr.contains("install requires --udid"))
    }

    func testInstallCommandWithoutUdidOrDriverLockFailsBeforeInstaller() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-install-no-target-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ipaPath = "\(root)/app.ipa"
        try makeMinimalIpa(path: ipaPath, bundleID: "com.example.app")
        AppManagementService.installerForTesting = { _, _, _ in
            XCTFail("install without a target must not call installer")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["install", ipaPath])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("install requires --udid or an active driver"))
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

    func testAppsCommandJsonRendersProviderResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-apps-host-only-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        AppManagementService.appsProviderForTesting = { udid, includeSystem in
            XCTAssertEqual(udid, "REAL-1")
            XCTAssertTrue(includeSystem)
            return [
                AppManagementService.AppInfo(bundleID: "com.example.b", displayName: "B", version: "2", applicationType: "User"),
                AppManagementService.AppInfo(bundleID: "com.example.a", displayName: "A", version: "1", applicationType: "System"),
            ]
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["apps", "--udid", "REAL-1", "--system", "--json"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains(#""bundleId" : "com.example.a""#))
        XCTAssertTrue(result.stdout.contains(#""applicationType" : "System""#))
    }

    func testAppsCommandUsesActiveDriverLockWhenUdidIsOmitted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-apps-active-lock-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "LOCK-REAL", deviceType: "real", paths: paths)
        AppManagementService.appsProviderForTesting = { udid, includeSystem in
            XCTAssertEqual(udid, "LOCK-REAL")
            XCTAssertFalse(includeSystem)
            return [
                AppManagementService.AppInfo(bundleID: "com.example.app", displayName: "Example", version: "1", applicationType: "User")
            ]
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("apps is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["apps"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("com.example.app | Example | 1 | User"))
    }

    func testAppsCommandExplicitUdidOverridesActiveDriverLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-apps-explicit-udid-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "LOCK-REAL", deviceType: "real", paths: paths)
        AppManagementService.appsProviderForTesting = { udid, includeSystem in
            XCTAssertEqual(udid, "EXPLICIT-REAL")
            XCTAssertFalse(includeSystem)
            return []
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["apps", "--udid", "EXPLICIT-REAL"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "No apps found on EXPLICIT-REAL\n")
    }

    func testAppsCommandWithoutUdidOrDriverLockFailsAtExecution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-apps-no-target-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        AppManagementService.appsProviderForTesting = { _, _ in
            XCTFail("apps without a target must not query installation_proxy")
            return []
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["apps"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("apps requires --udid or an active driver"))
    }

    func testUninstallCommandWithExplicitUdidIsHostOnlyAndDoesNotWriteDriverLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-uninstall-host-only-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        var uninstalls: [(String, String)] = []
        AppManagementService.uninstallerForTesting = { bundleID, udid in
            uninstalls.append((bundleID, udid))
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("uninstall is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["uninstall", "com.example.app", "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(uninstalls.map(\.0), ["com.example.app"])
        XCTAssertEqual(uninstalls.map(\.1), ["REAL-1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root]).driverLock))
    }

    func testUninstallCommandUsesActiveDriverLockWhenUdidIsOmitted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-uninstall-active-lock-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "LOCK-REAL", deviceType: "real", paths: paths)
        var uninstalls: [(String, String)] = []
        AppManagementService.uninstallerForTesting = { bundleID, udid in
            uninstalls.append((bundleID, udid))
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("uninstall is host-only and must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["uninstall", "com.example.app"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(uninstalls.map(\.0), ["com.example.app"])
        XCTAssertEqual(uninstalls.map(\.1), ["LOCK-REAL"])
        XCTAssertEqual(result.stdout, "Uninstalled com.example.app from LOCK-REAL\n")
    }

    func testUninstallCommandWithoutUdidOrDriverLockFailsBeforeInstaller() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-uninstall-no-target-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        AppManagementService.uninstallerForTesting = { _, _ in
            XCTFail("uninstall without a target must not call installation_proxy")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["uninstall", "com.example.app"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("uninstall requires --udid or an active driver"))
    }

    func testProxyDoctorReportsLocalProxyStatus() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-proxy-doctor-\(UUID().uuidString)")
            .path
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": home]).run(arguments: ["proxy", "doctor"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Wi-Fi LAN IP"))
        XCTAssertTrue(result.stdout.contains("Proxy: not running"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testRemovedFindCommandFailsBeforeExecution() {
        let result = IOSUseCLI().run(arguments: ["find", "General"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("unknown command 'find'"))
    }

    func testCLILogTimestampIncludesMilliseconds() {
        let timestamp = CLILogService.formatTimestamp(Date(timeIntervalSince1970: 0.123))

        XCTAssertEqual(timestamp, "1970-01-01T00:00:00.123Z")
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

    func testDriverCommandReconnectRecoveryUsesXCTestHolderDefaultWithoutXcode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-driver-holder-retry-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try """
        {"devices":{"REAL-CORE-CMD":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try writeDriverLock(udid: "REAL-CORE-CMD", deviceType: "real", paths: paths)
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
        Shell.runOverrideForTesting = { executable, _, _, _ in
            if executable == "xcrun" {
                XCTFail("real reconnect recovery default path must not call xcrun/devicectl")
            }
            return ""
        }
        var attempts = 0
        IOSUseCLI.driverClientFactoryForTesting = { _ in
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
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(holderLaunches.map(\.0), ["REAL-CORE-CMD"])
        XCTAssertEqual(holderLaunches.map(\.1), ["com.example.driver"])
    }

    func testDriverCommandDoesNotPreflightStaleXCTestHolderBeforeCommand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-stale-xctest-recover-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try """
        {"devices":{"REAL-XCTEST-CMD":{"bundleId":"com.example.driver","driverVersion":"\(IOSUseCLI.version)"}}}
        """.write(toFile: "\(root)/config.json", atomically: true, encoding: .utf8)
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "REAL-XCTEST-CMD",
                deviceName: "Phone",
                deviceVersion: "26.0",
                deviceType: "real",
                startedAt: 1,
                holderPid: 999_999,
                runnerPid: 123,
                startMode: "full-xctest",
                sessionIdentifier: "STALE",
                bundleId: "com.example.driver"
            ),
            paths: paths
        )
        DriverLifecycleService.holderLauncherForTesting = { _, _, _, _ in
            XCTFail("direct command must not preflight or relaunch before sending the target command")
            throw CLIParseError.invalidValue("unexpected relaunch")
        }
        var clientSessions: [SessionService.Info] = []
        IOSUseCLI.driverClientFactoryForTesting = { session in
            clientSessions.append(session)
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
        XCTAssertEqual(clientSessions.map(\.holderPid), [999_999])
        let lock = try XCTUnwrap(try SessionService.readDriverLockInfo(paths: paths))
        XCTAssertEqual(lock.holderPid, 999_999)
        XCTAssertEqual(lock.sessionIdentifier, "STALE")
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

    func testRealDeviceActivateAppUsesHostSideRunner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-real-activate-\(UUID().uuidString)")
            .path
        var calls: [(AppLifecycleOptions, String)] = []
        AppLifecycleService.realDeviceRunnerForTesting = { options, udid in
            calls.append((options, udid))
            return AppLifecycleService.Result(message: "App \(options.bundleID) activated")
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("host-side activateApp must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            AppLifecycleService.realDeviceRunnerForTesting = nil
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["activateApp", "com.apple.Preferences", "--udid", "REAL-ACTIVE"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "App com.apple.Preferences activated\n")
        XCTAssertEqual(calls.map { [$0.0.action.commandName, $0.0.bundleID, $0.1, "\($0.0.terminateExisting)", "\($0.0.log)"] }, [["activateApp", "com.apple.Preferences", "REAL-ACTIVE", "false", "false"]])
    }

    func testMutatingCommandCanAppendFreshDom() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-post-dom-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-POST-DOM", deviceType: "simulator", paths: paths)
        var calls: [String] = []
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(
                domHandler: { raw, fresh, waitQuiescence in
                    calls.append("dom raw=\(raw) fresh=\(fresh) waitQuiescence=\(waitQuiescence)")
                    return ForyDomPayload(
                        app: "com.example",
                        elements: [ForyDomElement(traits: ["Text"], label: "Ready", rect: ForyRect(x: 1, y: 2, w: 3, h: 4))]
                    )
                },
                tapHandler: { target, _, _, _, _ in
                    calls.append("tap \(target.label)")
                    return ForyElementPayload(elemType: 9, label: target.label, rect: ForyRect(x: 10, y: 20, w: 30, h: 40))
                }
            )
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["tap", "Continue", "--dom", "100"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(calls, ["tap Continue", "dom raw=false fresh=true waitQuiescence=false"])
        XCTAssertTrue(result.stdout.contains("Tap\nButton \"Continue\" (10,20,30,40)"))
        XCTAssertTrue(result.stdout.contains("DOM after 100ms\nApp: com.example"))
        XCTAssertTrue(result.stdout.contains("App: com.example"))
        XCTAssertTrue(result.stdout.contains("- Ready [Text] (1,2,3,4)"))
    }

    func testMutatingCommandBareDomWaitsForQuiescence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-post-dom-quiescence-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-POST-DOM-QUIET", deviceType: "simulator", paths: paths)
        var calls: [String] = []
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FakeDriverCommandClient(
                domHandler: { raw, fresh, waitQuiescence in
                    calls.append("dom raw=\(raw) fresh=\(fresh) waitQuiescence=\(waitQuiescence)")
                    return ForyDomPayload(app: "com.example")
                },
                tapHandler: { target, _, _, _, _ in
                    calls.append("tap \(target.label)")
                    return ForyElementPayload(elemType: 9, label: target.label, rect: ForyRect(x: 10, y: 20, w: 30, h: 40))
                }
            )
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["tap", "Continue", "--dom"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(calls, ["tap Continue", "dom raw=false fresh=true waitQuiescence=true"])
        XCTAssertTrue(result.stdout.contains("DOM after quiescence\nApp: com.example"))
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

    func testRealDeviceTerminateAppUsesActiveLockAndHostSideRunner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-real-terminate-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "REAL-TERM", deviceType: "real", paths: paths)
        var calls: [(AppLifecycleOptions, String)] = []
        AppLifecycleService.realDeviceRunnerForTesting = { options, udid in
            calls.append((options, udid))
            return AppLifecycleService.Result(message: "App \(options.bundleID) not running, skipped terminate")
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("host-side terminateApp must not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            AppLifecycleService.realDeviceRunnerForTesting = nil
            try? FileManager.default.removeItem(atPath: root)
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["terminateApp", "com.apple.Preferences"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "App com.apple.Preferences not running, skipped terminate\n")
        XCTAssertEqual(calls.map { [$0.0.action.commandName, $0.0.bundleID, $0.1] }, [["terminateApp", "com.apple.Preferences", "REAL-TERM"]])
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
        XCTAssertTrue(result.stderr.contains("activateApp requires --udid or an active driver"))
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

    func testRealDeviceUsbmuxConnectFailureIsRecoverable() {
        DriverClient.usbmuxConnectorForTesting = { _, _ in
            throw UsbmuxError.connectFailed(response: "code 2")
        }
        addTeardownBlock {
            DriverClient.usbmuxConnectorForTesting = nil
        }

        let client = DriverClient(udid: "REAL-CMD", deviceType: "real")

        XCTAssertThrowsError(try client.dom(raw: false, fresh: false)) { error in
            let driverError = error as? DriverClientError
            XCTAssertEqual(driverError?.isRecoverableConnectFailure, true)
            XCTAssertTrue(String(describing: error).contains("usbmux Connect failed: code 2"))
        }
    }

    func testRealDeviceMissingFromUsbmuxIsNotRecoverable() {
        DriverClient.usbmuxConnectorForTesting = { _, _ in
            throw UsbmuxError.deviceNotFound("REAL-CMD")
        }
        addTeardownBlock {
            DriverClient.usbmuxConnectorForTesting = nil
        }

        let client = DriverClient(udid: "REAL-CMD", deviceType: "real")

        XCTAssertThrowsError(try client.dom(raw: false, fresh: false)) { error in
            let driverError = error as? DriverClientError
            XCTAssertEqual(driverError?.isRecoverableConnectFailure, false)
            XCTAssertTrue(String(describing: error).contains("Device REAL-CMD not found via usbmux"))
        }
    }

    func testOpenURLActiveSimulatorUsesSimctlWithoutDriver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-active-sim-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "SIM-1", deviceType: "simulator", paths: paths)
        var shellCalls: [(String, [String])] = []
        Shell.runResultOverrideForTesting = { executable, arguments, _ in
            shellCalls.append((executable, arguments))
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("open URL for active simulator should not create a driver client")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            Shell.runResultOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "retouch://debug"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Opened URL: retouch://debug\n")
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertEqual(shellCalls.count, 1)
        XCTAssertEqual(shellCalls.first?.0, "xcrun")
        XCTAssertEqual(shellCalls.first?.1, ["simctl", "openurl", "SIM-1", "retouch://debug"])
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

    func testOpenURLInvalidURLFailsBeforeDriverOrShell() {
        Shell.runOverrideForTesting = { _, _, _, _ in
            XCTFail("invalid URL should fail before shell")
            return ""
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("invalid URL should fail before driver")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI().run(arguments: ["open", "://missing"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Invalid URL: ://missing"))
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

    func testOpenURLActiveRealDriverLockUsesNativeLauncherWithoutDevicectl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-active-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try writeDriverLock(udid: "REAL-LOCK", deviceType: "real", paths: paths)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("active real-device open must not inspect USB devices")
            return []
        }
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
            XCTFail("open URL for active real device should not create a driver client, got session \(String(describing: session))")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Opened URL: https://example.com (handler: com.apple.mobilesafari)"))
        XCTAssertEqual(nativeLaunches.map(\.0), ["https://example.com"])
        XCTAssertEqual(nativeLaunches.map(\.1), ["REAL-LOCK"])
        XCTAssertTrue(shellCalls.isEmpty)
    }

    func testOpenURLDoesNotAutoSelectDefaultUsbRealDevice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-default-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("open without --udid or driver.lock must not auto-select a USB device")
            return [IOSDevice(name: "iPhone", version: "26.0", udid: "REAL-DEFAULT", kind: .real)]
        }
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
            XCTFail("open URL for default real device should not create a driver client, got session \(String(describing: session))")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("open requires --udid or an active driver"))
        XCTAssertTrue(nativeLaunches.isEmpty)
        XCTAssertTrue(shellCalls.isEmpty)
    }

    func testOpenURLWithoutHostSideTargetFailsWithoutDriverFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-no-target-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in [] }
        Shell.runOverrideForTesting = { _, _, _, _ in
            XCTFail("open URL without a host-side target should fail before shell")
            return ""
        }
        IOSUseCLI.driverClientFactoryForTesting = { session in
            XCTFail("open URL without a host-side target should not fall back to driver, got session \(String(describing: session))")
            return FakeDriverCommandClient()
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("open requires --udid or an active driver"))
    }

    func testOpenURLSimulatorUnregisteredSchemeReportsError() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-sim-unregistered-\(UUID().uuidString)")
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try? writeDriverLock(udid: "SIM-1", deviceType: "simulator", paths: paths)
        Shell.runResultOverrideForTesting = { _, _, _ in
            Shell.RunResult(stdout: "", stderr: "Simulator device failed to open notexist://test", exitCode: 194)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            Shell.runResultOverrideForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "notexist://test"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("URL scheme \"notexist\" not registered on device"))
    }

    func testOpenURLRealDeviceUnregisteredSchemeReportsError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-real-unregistered-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("explicit real-device open must not inspect Simulator devices")
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-1"] }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "notexist" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: [], lookupFailed: false)
            }
            return nil
        }
        Shell.runOverrideForTesting = { _, _, _, _ in
            XCTFail("unregistered scheme should not invoke devicectl")
            return ""
        }
        OpenURLService.realDeviceURLLauncherForTesting = { _, _ in
            XCTFail("unregistered scheme should not invoke native launcher")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "notexist://test", "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("URL scheme \"notexist\" not registered on device"))
    }

    func testOpenURLRealDeviceLookupFailureStillUsesNativeLauncherWithoutDevicectl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-open-url-real-lookup-fail-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { simulatorOnly, _ in
            XCTAssertTrue(simulatorOnly)
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-1"] }
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { _, _ in
            OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: [], lookupFailed: true)
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
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            Shell.runOverrideForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["open", "https://example.com", "--udid", "REAL-1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Sent URL request: https://example.com (unable to verify scheme registration)"))
        XCTAssertEqual(nativeLaunches.map(\.0), ["https://example.com"])
        XCTAssertEqual(nativeLaunches.map(\.1), ["REAL-1"])
        XCTAssertTrue(shellCalls.isEmpty)
    }

    func testOSLogExplicitRealDeviceUsesOSTraceWithoutSimulatorProbe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-oslog-real-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        DeviceService.listDevicesOverrideForTesting = { _, _ in
            XCTFail("explicit real-device oslog must not inspect Simulator devices")
            return []
        }
        DeviceService.usbDeviceUdidsOverrideForTesting = { ["REAL-LOG"] }
        RealDeviceOSTraceService.collectorForTesting = { udid, timeout, source in
            XCTAssertEqual(udid, "REAL-LOG")
            XCTAssertEqual(timeout, 1)
            XCTAssertEqual(source, OSLogOptions.SourceFilter())
            return ["May 29 10:00:00 IOSUseDriverRunner[1] <Notice>: ready com.example.app"]
        }
        Shell.runOverrideForTesting = { executable, _, _, _ in
            if executable == "xcrun" {
                XCTFail("explicit real-device oslog must not call xcrun")
            }
            return ""
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: root)
            DeviceService.listDevicesOverrideForTesting = nil
            DeviceService.usbDeviceUdidsOverrideForTesting = nil
            DeviceService.resetCacheForTesting()
            RealDeviceOSTraceService.collectorForTesting = nil
            Shell.runOverrideForTesting = nil
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root]).run(arguments: ["oslog", "--udid", "REAL-LOG", "--pattern", "ready", "--timeout", "1"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("ready"))
    }

    func testDriverCommandNamesMatchWireCommands() {
        let commands = Set(DriverCommand.allCases.map(\.rawValue))

        XCTAssertTrue(commands.contains("dom"))
        XCTAssertTrue(commands.contains("waitFor"))
        XCTAssertTrue(commands.contains("dismissAlert"))
        XCTAssertFalse(commands.contains("health"))
        XCTAssertEqual(commands.count, 12)
    }

    func testDriverCommandMetadataBindsArgsAndPayloadTypes() {
        XCTAssertEqual(DriverCommand.tap.metadata.argsTypeName, "ForyTapArgs")
        XCTAssertEqual(DriverCommand.tap.metadata.payloadTypeName, "ForyElementPayload")
        XCTAssertTrue(DriverCommand.tap.metadata.mutatesUI)

        XCTAssertNil(DriverCommand.home.metadata.argsTypeName)
        XCTAssertNil(DriverCommand.home.metadata.payloadTypeName)
    }

    // MARK: - SchemeRegistry.parseSchemeHandlers

    func testParseSchemeHandlersFindsRegisteredBundleIDs() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.apple.mobilesafari": [
                    "CFBundleIdentifier": "com.apple.mobilesafari",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["https", "http"]],
                    ],
                ],
                "com.example.app": [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["myapp"]],
                    ],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "https", response: response)
        XCTAssertEqual(handlers, ["com.apple.mobilesafari"])
    }

    func testParseSchemeHandlersIsCaseInsensitive() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.example.App": [
                    "CFBundleIdentifier": "com.example.App",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["MyApp"]],
                    ],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "myapp", response: response)
        XCTAssertEqual(handlers, ["com.example.App"])
    }

    func testParseSchemeHandlersReturnsEmptyForUnregisteredScheme() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.apple.mobilesafari": [
                    "CFBundleIdentifier": "com.apple.mobilesafari",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["https"]],
                    ],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "notexist", response: response)
        XCTAssertEqual(handlers, [])
    }

    func testParseSchemeHandlersReturnsEmptyForMissingLookupResult() {
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "https", response: [:])
        XCTAssertEqual(handlers, [])
    }

    func testParseSchemeHandlersSkipsAppsMissingURLTypes() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.example.no-urltypes": [
                    "CFBundleIdentifier": "com.example.no-urltypes",
                ],
                "com.example.empty": [
                    "CFBundleIdentifier": "com.example.empty",
                    "CFBundleURLTypes": [],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "https", response: response)
        XCTAssertEqual(handlers, [])
    }

    func testParseSchemeHandlersDeduplicatesBundleIDs() {
        let response: [String: Any] = [
            "LookupResult": [
                "com.example.app": [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleURLTypes": [
                        ["CFBundleURLSchemes": ["myapp"]],
                        ["CFBundleURLSchemes": ["myapp", "other"]],
                    ],
                ],
            ],
        ]
        let handlers = OpenURLService.SchemeRegistry.parseSchemeHandlers(scheme: "myapp", response: response)
        XCTAssertEqual(handlers, ["com.example.app"])
    }

    func testPathsRespectIOSUseHomeOverrideWithoutWritingFiles() {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": "/tmp/ios-use-swift-test-home",
            "HOME": "/tmp/real-home-should-not-be-used"
        ])

        XCTAssertEqual(paths.root, "/tmp/ios-use-swift-test-home")
        XCTAssertEqual(paths.config, "/tmp/ios-use-swift-test-home/config.json")
        XCTAssertEqual(paths.session, "/tmp/ios-use-swift-test-home/state/session.json")
        XCTAssertEqual(paths.driverLock, "/tmp/ios-use-swift-test-home/state/driver.lock")
        XCTAssertEqual(paths.nslogLock, "/tmp/ios-use-swift-test-home/state/nslog.lock")
        XCTAssertEqual(paths.appLogState, "/tmp/ios-use-swift-test-home/state/app-log.json")
        XCTAssertEqual(paths.logs, "/tmp/ios-use-swift-test-home/logs")
        XCTAssertEqual(paths.artifacts, "/tmp/ios-use-swift-test-home/artifacts")
    }

    func testPathsDefaultToHomeDotIOSUse() {
        let paths = IOSUsePaths.resolve(environment: [
            "HOME": "/tmp/ios-use-swift-home"
        ])

        XCTAssertEqual(paths.root, "/tmp/ios-use-swift-home/.ios-use")
        XCTAssertEqual(paths.config, "/tmp/ios-use-swift-home/.ios-use/config.json")
    }

    func testCLIStoresResolvedPathsForFutureCommands() {
        let cli = IOSUseCLI(environment: [
            "IOS_USE_HOME": "/tmp/ios-use-swift-env"
        ])

        XCTAssertEqual(cli.paths.root, "/tmp/ios-use-swift-env")
    }

    func testErrorEnvelopeUsesStableExitCodeAndPrefix() {
        let result = CLIErrorEnvelope(message: "example failure").render()

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.stderr, "error: example failure\n")
        XCTAssertTrue(result.stdout.isEmpty)
    }

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
    private let tapHandler: (ForyTarget, String?, Int32?, ForyPoint?, ForyPoint) throws -> ForyElementPayload
    private let activateHandler: (String) throws -> Void
    private let terminateHandler: (String) throws -> Void

    init(
        domHandler: @escaping (Bool, Bool, Bool) throws -> ForyDomPayload = { _, _, _ in
            throw CLIParseError.invalidValue("unexpected dom")
        },
        tapHandler: @escaping (ForyTarget, String?, Int32?, ForyPoint?, ForyPoint) throws -> ForyElementPayload = { _, _, _, _, _ in
            throw CLIParseError.invalidValue("unexpected tap")
        },
        activateHandler: @escaping (String) throws -> Void = { _ in
            throw CLIParseError.invalidValue("unexpected activateApp")
        },
        terminateHandler: @escaping (String) throws -> Void = { _ in
            throw CLIParseError.invalidValue("unexpected terminateApp")
        }
    ) {
        self.domHandler = domHandler
        self.tapHandler = tapHandler
        self.activateHandler = activateHandler
        self.terminateHandler = terminateHandler
    }

    func close() {}

    func dom(raw: Bool, fresh: Bool, waitQuiescence: Bool) throws -> ForyDomPayload {
        try domHandler(raw, fresh, waitQuiescence)
    }

    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload {
        throw CLIParseError.invalidValue("unexpected waitFor")
    }

    func screenshot() throws -> Data {
        throw CLIParseError.invalidValue("unexpected screenshot")
    }

    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload {
        try tapHandler(target, traits, cindex, offset, ratio)
    }

    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload {
        throw CLIParseError.invalidValue("unexpected longPress")
    }

    func input(tap: ForyTarget?, content: String) throws {
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

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        throw CLIParseError.invalidValue("unexpected dismissAlert")
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        throw CLIParseError.invalidValue("unexpected proxyCAPush")
    }
}
