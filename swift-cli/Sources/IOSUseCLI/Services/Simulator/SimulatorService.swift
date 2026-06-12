import Darwin
import Foundation
import IOSUseProtocol

enum SimulatorService {
    static var xcodebuildLauncherForTesting: ((String, IOSUsePaths, Bool, (() -> Bool)?) throws -> DriverLifecycleService.LaunchMetadata)?

    struct ConfigureResult: Equatable {
        let udid: String
        let ipaPath: String
        let launchOutput: String
    }

    static func listBooted(paths _: IOSUsePaths) throws -> [IOSDevice] {
        let output = try Shell.run("xcrun", arguments: ["simctl", "list", "devices", "booted"])
        return parseBootedSimulators(output)
    }

    static func parseBootedSimulators(_ output: String) -> [IOSDevice] {
        var devices: [IOSDevice] = []
        var currentVersion = ""

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("-- ") {
                if let match = firstMatch(line, regex: Regexes.runtimeHeader) {
                    currentVersion = match[1].replacingOccurrences(of: #"^iOS\s+"#, with: "", options: .regularExpression)
                }
                continue
            }
            guard let match = firstMatch(line, regex: Regexes.bootedSimulator) else {
                continue
            }
            devices.append(IOSDevice(name: match[1].trimmingCharacters(in: .whitespacesAndNewlines), version: currentVersion, udid: match[2], kind: .simulator))
        }

        return devices
    }

    static func defaultBootedUdid(paths: IOSUsePaths) throws -> String {
        guard let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).first else {
            throw CLIParseError.invalidValue("No --udid and no booted Simulators found.")
        }
        return simulator.udid
    }

    static func configureDriver(udid requestedUdid: String?, paths: IOSUsePaths) throws -> ConfigureResult {
        let udid = try requestedUdid ?? defaultBootedUdid(paths: paths)
        let ipaPath = ConfigService.simulatorIPAPath(paths: paths)
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            throw CLIParseError.invalidValue("Prebuilt Simulator driver IPA not found at \(ipaPath)")
        }

        let extracted = try extractSimulatorApp(ipaPath: ipaPath, udid: udid, paths: paths)
        defer { try? FileManager.default.removeItem(atPath: extracted.directory) }
        _ = try? Shell.run("xcrun", arguments: ["simctl", "terminate", udid, ConfigService.simulatorBundleId])
        do {
            _ = try Shell.run("xcrun", arguments: ["simctl", "install", udid, extracted.appPath])
        } catch {
            _ = try? Shell.run("xcrun", arguments: ["simctl", "boot", udid])
            _ = try Shell.run("xcrun", arguments: ["simctl", "bootstatus", udid, "-b"])
            _ = try Shell.run("xcrun", arguments: ["simctl", "install", udid, extracted.appPath])
        }

        return ConfigureResult(udid: udid, ipaPath: ipaPath, launchOutput: "")
    }

    static func ensureDriverRunning(
        udid: String,
        allowExistingDriver: Bool,
        isReachable: (() -> Bool)? = nil,
        launcher: ((String) throws -> Void)? = nil
    ) throws {
        let isReachable = isReachable ?? isLocalDriverPortReachable
        let launch = launcher ?? { targetUdid in
            _ = try Shell.run("xcrun", arguments: ["simctl", "launch", targetUdid, ConfigService.simulatorBundleId])
        }
        if allowExistingDriver, isReachable() {
            return
        }
        try launch(udid)
        let deadline = Date().addingTimeInterval(IOSUseProtocol.simulatorDriverStartTimeoutSeconds)
        while Date() < deadline {
            if isReachable() {
                return
            }
            usleep(useconds_t(IOSUseProtocol.simulatorDriverStartPollIntervalMicroseconds))
        }
        throw CLIParseError.invalidValue("Simulator driver launched but port \(IOSUseProtocol.defaultDriverPort) did not become reachable for \(udid)")
    }

    static func launchDriverWithXcodebuild(
        udid: String,
        paths: IOSUsePaths,
        verbose: Bool,
        isReachable: (() -> Bool)? = nil
    ) throws -> DriverLifecycleService.LaunchMetadata {
        if let xcodebuildLauncherForTesting {
            return try xcodebuildLauncherForTesting(udid, paths, verbose, isReachable)
        }
        let isReachable = isReachable ?? isLocalDriverPortReachable
        if isReachable() {
            return DriverLifecycleService.LaunchMetadata(
                holderPid: nil,
                runnerPid: nil,
                sessionIdentifier: nil,
                bundleId: ConfigService.simulatorBundleId
            )
        }

        let ipaPath = ConfigService.simulatorIPAPath(paths: paths)
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            throw CLIParseError.invalidValue("Prebuilt Simulator driver IPA not found at \(ipaPath)")
        }

        let launchDir = simulatorXcodebuildLaunchDirectory(udid: udid, paths: paths)
        try? FileManager.default.removeItem(atPath: launchDir)
        try FileManager.default.createDirectory(atPath: launchDir, withIntermediateDirectories: true, attributes: nil)

        do {
            let extracted = try extractSimulatorApp(ipaPath: ipaPath, udid: "xcodebuild-\(udid)", paths: paths, destinationDirectory: "\(launchDir)/app")
            let payloadDir = URL(fileURLWithPath: extracted.appPath).deletingLastPathComponent().path
            let xctestrunPath = "\(launchDir)/IOSUseDriver.xctestrun"
            try writeXCTestRunFile(appPath: extracted.appPath, builtProductsDir: payloadDir, xctestrunPath: xctestrunPath)

            try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true, attributes: nil)
            let holderLogPath = CLILogService.holderLogPath(paths: paths)
            if !FileManager.default.fileExists(atPath: holderLogPath) {
                FileManager.default.createFile(atPath: holderLogPath, contents: nil)
            }
            let holderLogHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: holderLogPath))
            _ = try? holderLogHandle.seekToEnd()
            defer { try? holderLogHandle.close() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "xcodebuild",
                "test-without-building",
                "-xctestrun", xctestrunPath,
                "-destination", "platform=iOS Simulator,id=\(udid)",
            ]
            process.standardOutput = holderLogHandle
            process.standardError = holderLogHandle
            try process.run()

            do {
                try waitForSimulatorDriverStart(process: process, udid: udid, paths: paths, isReachable: isReachable)
            } catch {
                _ = terminateProcess(pid: process.processIdentifier, force: true)
                try? FileManager.default.removeItem(atPath: launchDir)
                throw error
            }

            if verbose {
                FileHandle.standardError.write(Data("CLI log: \(CLILogService.logPath(paths: paths))\n".utf8))
            }
            return DriverLifecycleService.LaunchMetadata(
                holderPid: Int(process.processIdentifier),
                runnerPid: nil,
                sessionIdentifier: nil,
                bundleId: ConfigService.simulatorBundleId
            )
        } catch {
            try? FileManager.default.removeItem(atPath: launchDir)
            throw error
        }
    }

    static func terminateDriver(udid: String, terminator: ((String) throws -> Bool)? = nil) throws -> Bool {
        if let terminator {
            return try terminator(udid)
        }
        do {
            _ = try Shell.run("xcrun", arguments: ["simctl", "terminate", udid, ConfigService.simulatorBundleId])
            return true
        } catch {
            return false
        }
    }

    static func cleanupXcodebuildLaunchArtifacts(udid: String, paths: IOSUsePaths) {
        try? FileManager.default.removeItem(atPath: simulatorXcodebuildLaunchDirectory(udid: udid, paths: paths))
    }

    static func openURL(_ url: String, udid: String) throws {
        let result = try Shell.runWithResult("xcrun", arguments: ["simctl", "openurl", udid, url])
        switch result.exitCode {
        case 0:
            break
        case 194:
            let scheme = URLComponents(string: url)?.scheme ?? url
            throw CLIParseError.invalidValue("URL scheme \"\(scheme)\" not registered on device")
        default:
            throw CLIParseError.invalidValue(result.stderr.isEmpty
                ? "simctl openurl failed with exit \(result.exitCode)"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func activateApp(bundleID: String, udid: String, terminateExisting: Bool = false) throws {
        var arguments = ["simctl", "launch"]
        if terminateExisting {
            arguments.append("--terminate-running-process")
        }
        arguments += [udid, bundleID]
        let result = try Shell.runWithResult("xcrun", arguments: arguments)
        guard result.exitCode == 0 else {
            throw CLIParseError.invalidValue(result.stderr.isEmpty
                ? "simctl launch failed with exit \(result.exitCode)"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func terminateApp(bundleID: String, udid: String) throws -> Bool {
        let result = try Shell.runWithResult("xcrun", arguments: ["simctl", "terminate", udid, bundleID])
        switch result.exitCode {
        case 0:
            return true
        default:
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if IOSUseCLI.isAppNotRunningErrorMessage(message) {
                return false
            }
            throw CLIParseError.invalidValue(message.isEmpty
                ? "simctl terminate failed with exit \(result.exitCode)"
                : message)
        }
    }

    static func isLocalDriverPortReachable() -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(IOSUseProtocol.defaultDriverPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private static func extractSimulatorApp(
        ipaPath: String,
        udid: String,
        paths: IOSUsePaths,
        destinationDirectory: String? = nil
    ) throws -> (appPath: String, directory: String) {
        let extractDir = destinationDirectory ?? "\(paths.root)/driver-sim-install-\(udid)"
        try? FileManager.default.removeItem(atPath: extractDir)
        try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true, attributes: nil)

        _ = try Shell.run("unzip", arguments: ["-q", "-o", ipaPath, "-d", extractDir])
        let payloadDir = "\(extractDir)/Payload"
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            throw CLIParseError.invalidValue("No .app found in Simulator IPA")
        }
        return ("\(payloadDir)/\(appEntry)", extractDir)
    }

    private static func writeXCTestRunFile(appPath: String, builtProductsDir: String, xctestrunPath: String) throws {
        let testingEnvironment: [String: Any] = [
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": builtProductsDir,
            "__XPC_DYLD_FRAMEWORK_PATH": builtProductsDir,
            "__XPC_DYLD_LIBRARY_PATH": builtProductsDir,
            "DYLD_FRAMEWORK_PATH": "\(builtProductsDir):__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks",
            "DYLD_LIBRARY_PATH": "\(builtProductsDir):__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib",
            "XCODE_SCHEME_NAME": "IOSUseDriver",
        ]
        let uiTargetEnvironment: [String: Any] = [
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": builtProductsDir,
            "__XPC_DYLD_FRAMEWORK_PATH": builtProductsDir,
            "__XPC_DYLD_LIBRARY_PATH": builtProductsDir,
            "DYLD_FRAMEWORK_PATH": builtProductsDir,
            "DYLD_LIBRARY_PATH": builtProductsDir,
            "XCODE_SCHEME_NAME": "IOSUseDriver",
        ]
        let root: [String: Any] = [
            "__xctestrun_metadata__": [
                "ContainerInfo": [
                    "ContainerName": "IOSUseDriver",
                    "SchemeName": "IOSUseDriver",
                ],
                "FormatVersion": 1,
            ],
            "IOSUseDriver": [
                "BlueprintName": "IOSUseDriver",
                "BlueprintProviderName": "IOSUseDriver",
                "CommandLineArguments": [],
                "DependentProductPaths": [
                    appPath,
                    "\(appPath)/PlugIns/IOSUseDriver.xctest",
                ],
                "EnvironmentVariables": [
                    "OS_ACTIVITY_DT_MODE": "YES",
                    "TERM": "dumb",
                ],
                "IsUITestBundle": true,
                "IsXCTRunnerHostedTestBundle": true,
                "ProductModuleName": "IOSUseDriver",
                "TestBundlePath": "__TESTHOST__/PlugIns/IOSUseDriver.xctest",
                "TestHostBundleIdentifier": ConfigService.simulatorBundleId,
                "TestHostPath": appPath,
                "TestingEnvironmentVariables": testingEnvironment,
                "TestTimeoutsEnabled": false,
                "UITargetAppCommandLineArguments": [],
                "UITargetAppEnvironmentVariables": uiTargetEnvironment,
                "UseUITargetAppProvidedByTests": true,
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: xctestrunPath), options: .atomic)
    }

    private static func waitForSimulatorDriverStart(process: Process, udid: String, paths: IOSUsePaths, isReachable: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(IOSUseProtocol.simulatorDriverStartTimeoutSeconds)
        while Date() < deadline {
            if isReachable() {
                return
            }
            if !process.isRunning {
                throw CLIParseError.invalidValue("xcodebuild exited before Simulator driver became reachable for \(udid) with status \(process.terminationStatus). Check \(CLILogService.holderLogPath(paths: paths)).")
            }
            usleep(useconds_t(IOSUseProtocol.simulatorDriverStartPollIntervalMicroseconds))
        }
        throw CLIParseError.invalidValue("Simulator driver launched through xcodebuild but port \(IOSUseProtocol.defaultDriverPort) did not become reachable for \(udid)")
    }

    private static func simulatorXcodebuildLaunchDirectory(udid: String, paths: IOSUsePaths) -> String {
        let stateDir = URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent().path
        let safeUdid = udid.replacingOccurrences(of: #"[^A-Za-z0-9.-]"#, with: "-", options: .regularExpression)
        return "\(stateDir)/simulator-xctest-\(safeUdid)"
    }

    private static func terminateProcess(pid: Int32, force: Bool) -> Bool {
        guard pid > 0 else { return true }
        _ = Darwin.kill(pid, SIGTERM)
        if waitForProcessExit(pid: pid, timeoutSeconds: IOSUseProtocol.XCConstants.xctestProcessTerminateWaitSeconds) {
            return true
        }
        guard force else { return false }
        _ = Darwin.kill(pid, SIGKILL)
        return waitForProcessExit(pid: pid, timeoutSeconds: IOSUseProtocol.XCConstants.xctestProcessKillWaitSeconds)
    }

    private static func waitForProcessExit(pid: Int32, timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Darwin.kill(pid, 0) != 0 {
                return true
            }
            usleep(useconds_t(IOSUseProtocol.XCConstants.xctestProcessExitPollMicroseconds))
        }
        return Darwin.kill(pid, 0) != 0
    }

    private static func waitForDriver() {
        let deadline = Date().addingTimeInterval(IOSUseProtocol.simulatorDriverConfigureProbeTimeoutSeconds)
        while Date() < deadline {
            let driver = DriverClient()
            defer { driver.close() }
            if (try? driver.dom(raw: false, fresh: false, waitQuiescence: false)) != nil {
                return
            }
            usleep(useconds_t(IOSUseProtocol.simulatorDriverConfigureProbePollMicroseconds))
        }
    }

    private enum Regexes {
        static let runtimeHeader = try! NSRegularExpression(pattern: #"^--\s+(.+?)\s+--"#)
        static let bootedSimulator = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+\(([0-9A-Fa-f-]+)\)\s+\(Booted\)"#)
    }

    private static func firstMatch(_ text: String, regex: NSRegularExpression) -> [String]? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
