import Darwin
import Foundation
import IOSUseProtocol

public struct DeviceConfigEntry: Equatable, Sendable {
    public let udid: String
    public let bundleId: String
    public let port: String
    public let driverVersion: String

    public init(udid: String, bundleId: String, port: String, driverVersion: String = "(missing)") {
        self.udid = udid
        self.bundleId = bundleId
        self.port = port
        self.driverVersion = driverVersion
    }
}

public enum ConfigService {
    public static let simulatorBundleId = "com.iosuse.xcuidriver.xctrunner"
    private static let devRunnerBundleId = "com.iosuse.xcuidriver.xctrunner"
    private static let devXCTestBundleId = "com.iosuse.xcuidriver"
    private static let defaultDriverBundlePrefix = "com.ios-use.driver"
    private static let cachedAppleIdPattern = #"Using cached session for ([^\s]+)"#

    public static func configureDevice(
        options: ConfigOptions,
        paths: IOSUsePaths,
        outputSink: (@Sendable (String) -> Void)? = nil,
        errorSink: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
        let realDevices = try DeviceService.listDevices(simulatorOnly: false, paths: paths)
        let udid: String
        if let requested = options.udid {
            if try DeviceService.listDevices(simulatorOnly: true, paths: paths).contains(where: { $0.udid == requested }) {
                return try configureSimulator(udid: requested, paths: paths)
            }
            udid = requested
        } else if let device = realDevices.first {
            udid = device.udid
        } else {
            throw CLIParseError.invalidValue("No --udid and no USB devices detected.")
        }

        guard let device = realDevices.first(where: { $0.udid == udid }) else {
            throw CLIParseError.invalidValue("Device \(udid) not found.")
        }

        let altsign = "\(paths.root)/altsign-cli/altsign-cli"
        guard FileManager.default.isExecutableFile(atPath: altsign) else {
            throw CLIParseError.invalidValue("altsign-cli not found at \(altsign). Run: cd altsign-cli && ./build.sh")
        }

        let saved = listEntries(paths: paths).first { $0.udid == udid }
        let bundleId = try reusableBundleId(from: saved) ?? dynamicBundleId(options: options, altsign: altsign)
        let xctestBundleId = bundleId.replacingOccurrences(of: #"\.xctrunner$"#, with: "", options: .regularExpression)
        let ipaPath = deviceIPAPath(paths: paths)
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            throw CLIParseError.invalidValue("Prebuilt driver IPA not found at \(ipaPath)\nBuild it first: ./scripts/build_driver.sh")
        }

        let rewritten = try rewriteIpaBundleIds(ipaPath: ipaPath, runnerBundleId: bundleId, xctestBundleId: xctestBundleId, paths: paths)
        defer { if rewritten != ipaPath { try? FileManager.default.removeItem(atPath: rewritten) } }

        let signedIpa = "\(paths.root)/driver-signed-\(udid).ipa"
        try? FileManager.default.removeItem(atPath: signedIpa)
        var signArgs = ["sign", "--udid", udid, "--ipa", rewritten, "--output", signedIpa]
        if let appleId = options.appleId { signArgs += ["--apple-id", appleId] }
        if let password = options.password { signArgs += ["--password", password] }
        if options.verbose { signArgs.append("--verbose") }
        try Shell.runStreaming(altsign, arguments: signArgs, stdoutSink: outputSink, stderrSink: errorSink)

        guard FileManager.default.fileExists(atPath: signedIpa) else {
            throw CLIParseError.invalidValue("altsign-cli sign did not produce a signed IPA. Run with --verbose for full altsign output.")
        }

        let extractDir = "\(paths.root)/driver-install-\(udid)"
        try? FileManager.default.removeItem(atPath: extractDir)
        try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: extractDir) }
        _ = try Shell.run("unzip", arguments: ["-q", "-o", signedIpa, "-d", extractDir])
        let payloadDir = "\(extractDir)/Payload"
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            throw CLIParseError.invalidValue("No .app found in signed IPA at \(payloadDir)")
        }

        _ = try Shell.run("xcrun", arguments: ["devicectl", "device", "install", "app", "--device", udid, "\(payloadDir)/\(appEntry)"])
        try saveConfig(udid: udid, bundleId: bundleId, port: String(IOSUseProtocol.defaultDriverPort), paths: paths)

        return """
        Using device: \(DeviceService.format(device, configured: DeviceService.configuredUdids(paths: paths)))
        Driver Bundle ID: \(bundleId)
        XCTest Bundle ID: \(xctestBundleId)
        Using prebuilt driver: \(ipaPath)
        Driver signed
        Driver installed to device
        Device config complete! Run `ios-use activateApp <bundleId>` to start, or just use any action command.
        """ + "\n"
    }

    public static func listEntries(paths: IOSUsePaths) -> [DeviceConfigEntry] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else {
            return []
        }

        return devices.keys.sorted().map { udid in
            let value = devices[udid] as? [String: Any] ?? [:]
            let bundleId = value["bundleId"] as? String ?? "(missing)"
            let portValue = value["port"].map { String(describing: $0) } ?? "(missing)"
            let driverVersion = value["driverVersion"] as? String ?? "(missing)"
            return DeviceConfigEntry(udid: udid, bundleId: bundleId, port: portValue, driverVersion: driverVersion)
        }
    }

    public static func formatList(_ entries: [DeviceConfigEntry]) -> String {
        guard !entries.isEmpty else { return "No configured devices.\n" }
        let lines = entries.map { "  \($0.udid) → bundleId: \($0.bundleId), port: \($0.port), driverVersion: \($0.driverVersion)" }.joined(separator: "\n")
        return "Configured devices:\n\(lines)\n"
    }

    public static func configureSimulator(udid requestedUdid: String?, paths: IOSUsePaths) throws -> String {
        let udid = try requestedUdid ?? defaultBootedSimulatorUdid()
        let ipaPath = simulatorIPAPath(paths: paths)
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            throw CLIParseError.invalidValue("Prebuilt Simulator driver IPA not found. Expected: assets/driver-sim.ipa")
        }

        let extractDir = "\(paths.root)/driver-sim-install-\(udid)"
        try? FileManager.default.removeItem(atPath: extractDir)
        try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: extractDir) }

        _ = try Shell.run("unzip", arguments: ["-q", "-o", ipaPath, "-d", extractDir])
        let payloadDir = "\(extractDir)/Payload"
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            throw CLIParseError.invalidValue("No .app found in Simulator IPA")
        }
        let appPath = "\(payloadDir)/\(appEntry)"

        _ = try? Shell.run("xcrun", arguments: ["simctl", "terminate", udid, simulatorBundleId])
        do {
            _ = try Shell.run("xcrun", arguments: ["simctl", "install", udid, appPath])
        } catch {
            _ = try? Shell.run("xcrun", arguments: ["simctl", "boot", udid])
            _ = try Shell.run("xcrun", arguments: ["simctl", "bootstatus", udid, "-b"])
            _ = try Shell.run("xcrun", arguments: ["simctl", "install", udid, appPath])
        }

        let launchOutput = try Shell.run("xcrun", arguments: ["simctl", "launch", udid, simulatorBundleId]).trimmingCharacters(in: .whitespacesAndNewlines)
        waitForSimulatorDriver()
        try saveConfig(udid: udid, bundleId: simulatorBundleId, port: String(IOSUseProtocol.defaultDriverPort), paths: paths)
        return "Using prebuilt driver: \(ipaPath)\nDriver installed to Simulator\nDriver launched on Simulator (PID: \(launchOutput))\nSimulator config complete!\n"
    }

    private static func defaultBootedSimulatorUdid() throws -> String {
        guard let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: IOSUsePaths.resolve()).first else {
            throw CLIParseError.invalidValue("No --udid and no booted Simulators found.")
        }
        return simulator.udid
    }

    static func simulatorIPAPath(paths: IOSUsePaths) -> String {
        ipaPath(assetName: "driver-sim.ipa", paths: paths)
    }

    static func deviceIPAPath(paths: IOSUsePaths) -> String {
        ipaPath(assetName: "driver.ipa", paths: paths)
    }

    private static func ipaPath(assetName: String, paths: IOSUsePaths) -> String {
        let installedAsset = "\(paths.root)/\(assetName)"
        #if DEBUG
        let cwd = FileManager.default.currentDirectoryPath
        let localAsset = "\(cwd)/assets/\(assetName)"
        if FileManager.default.fileExists(atPath: localAsset) {
            return localAsset
        }
        #endif
        return installedAsset
    }

    private static func dynamicBundleId(options: ConfigOptions, altsign: String) throws -> String {
        let appleId = try options.appleId ?? cachedAppleId(altsign: altsign)
        guard let appleId, !appleId.isEmpty else {
            throw CLIParseError.invalidValue("No signing config found for this device and no cached altsign session. Please run with --apple-id <email> --password <pwd> to log in.")
        }
        return "\(defaultDriverBundlePrefix).\(sanitizeForBundleId(appleId)).xctrunner"
    }

    static func reusableBundleId(from entry: DeviceConfigEntry?) -> String? {
        guard let bundleId = entry?.bundleId.nonEmpty, bundleId != "(missing)" else {
            return nil
        }
        return bundleId
    }

    static func assertDriverVersionCurrent(udid: String, paths: IOSUsePaths) throws {
        guard let config = DeviceService.configuredDevices(paths: paths)[udid], config.needsDriverUpdate else {
            return
        }
        let installed = config.driverVersion ?? "unknown"
        throw CLIParseError.invalidValue("Driver for device \(udid) was installed by ios-use \(installed), but current CLI is \(IOSUseCLI.version). Run `ios-use config --udid \(udid)` to update the driver.")
    }

    private static func cachedAppleId(altsign: String) throws -> String? {
        guard let output = try? Shell.runCombined(altsign, arguments: ["list"]) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: cachedAppleIdPattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[range])
    }

    private static func sanitizeForBundleId(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: #"[^a-z0-9]"#, with: "-", options: .regularExpression)
    }

    private static func rewriteIpaBundleIds(ipaPath: String, runnerBundleId: String, xctestBundleId: String, paths: IOSUsePaths) throws -> String {
        let tmpDir = "\(paths.root)/ipa-rewrite-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: tmpDir)
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        _ = try Shell.run("unzip", arguments: ["-q", "-o", ipaPath, "-d", tmpDir])
        let payloadDir = "\(tmpDir)/Payload"
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            throw CLIParseError.invalidValue("No .app found in IPA")
        }
        let appPath = "\(payloadDir)/\(appEntry)"
        try rewritePlistBundleId(plistPath: "\(appPath)/Info.plist", oldId: devRunnerBundleId, newId: runnerBundleId)
        let pluginsDir = "\(appPath)/PlugIns"
        if let plugins = try? FileManager.default.contentsOfDirectory(atPath: pluginsDir) {
            for plugin in plugins where plugin.hasSuffix(".xctest") {
                try rewritePlistBundleId(plistPath: "\(pluginsDir)/\(plugin)/Info.plist", oldId: devXCTestBundleId, newId: xctestBundleId)
            }
        }
        let outPath = ipaPath.replacingOccurrences(of: #"\.ipa$"#, with: "-rewritten.ipa", options: .regularExpression)
        try? FileManager.default.removeItem(atPath: outPath)
        _ = try Shell.run("zip", arguments: ["-r", "-q", outPath, "Payload"], cwd: tmpDir)
        return outPath
    }

    private static func rewritePlistBundleId(plistPath: String, oldId: String, newId: String) throws {
        guard FileManager.default.fileExists(atPath: plistPath) else { return }
        let current = try Shell.run("plutil", arguments: ["-extract", "CFBundleIdentifier", "raw", "-o", "-", plistPath]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == oldId, current != newId else { return }
        _ = try Shell.run("plutil", arguments: ["-replace", "CFBundleIdentifier", "-string", newId, plistPath])
    }

    private static func saveConfig(udid: String, bundleId: String, port: String, paths: IOSUsePaths) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var devices = root["devices"] as? [String: Any] ?? [:]
        devices[udid] = ["bundleId": bundleId, "port": port, "driverVersion": IOSUseCLI.version]
        root["devices"] = devices

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let configDir = URL(fileURLWithPath: paths.config).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: URL(fileURLWithPath: paths.config), options: .atomic)
    }

    private static func waitForSimulatorDriver() {
        for _ in 0..<50 {
            if (try? DriverClient().dom(raw: false, fresh: false)) != nil {
                return
            }
            usleep(200_000)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

public struct DriverEndpoint: Equatable, Sendable {
    public let udid: String
    public let port: Int
    public let deviceName: String
    public let deviceVersion: String
    public let deviceType: String

    public init(udid: String, port: Int = Int(IOSUseProtocol.defaultDriverPort), deviceName: String, deviceVersion: String, deviceType: String) {
        self.udid = udid
        self.port = port
        self.deviceName = deviceName
        self.deviceVersion = deviceVersion
        self.deviceType = deviceType
    }

    public var isSimulator: Bool {
        deviceType == "simulator"
    }
}

public enum DriverBootstrap {
    static var endpointResolverForTesting: ((SessionOptions, DriverEndpoint?, IOSUsePaths) throws -> DriverEndpoint)?
    static var simulatorDriverReachableForTesting: (() -> Bool)?
    static var simulatorDriverLauncherForTesting: ((String) throws -> Void)?
    static var simulatorDriverTerminatorForTesting: ((String) throws -> Bool)?
    static var realDriverReachableForTesting: ((String) -> Bool)?
    static var realDriverLauncherForTesting: ((String, String) throws -> Void)?
    static var realDriverTerminatorForTesting: ((String) throws -> Bool)?

    public static func resolveEndpoint(session: SessionOptions, current: DriverEndpoint?, paths: IOSUsePaths) throws -> DriverEndpoint {
        if let endpointResolverForTesting {
            return try endpointResolverForTesting(session, current, paths)
        }
        if let current, session.udid == nil {
            try ConfigService.assertDriverVersionCurrent(udid: current.udid, paths: paths)
            if current.isSimulator {
                try ensureSimulatorDriverRunning(udid: current.udid, allowExistingDriver: true, paths: paths)
                return current
            }
            if isDriverPortReachable(udid: current.udid) {
                return current
            }
        }

        let udid: String
        if let requested = session.udid {
            udid = requested
        } else {
            let devices = try DeviceService.listDevices(simulatorOnly: false, paths: paths)
            guard let device = devices.first else {
                throw CLIParseError.invalidValue("No --udid and no USB devices detected. Simulator requires explicit --udid.")
            }
            udid = device.udid
        }

        let configured = DeviceService.configuredUdids(paths: paths)
        guard configured.contains(udid) else {
            throw CLIParseError.invalidValue("No signing config found for device \(udid). Run `ios-use config --udid \(udid)` first.")
        }
        try ConfigService.assertDriverVersionCurrent(udid: udid, paths: paths)

        if let current, current.udid == udid {
            if current.isSimulator {
                try ensureSimulatorDriverRunning(udid: udid, allowExistingDriver: true, paths: paths)
                return current
            }
            if isDriverPortReachable(udid: udid) {
                return current
            }
        }

        if let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).first(where: { $0.udid == udid }) {
            try ensureSimulatorDriverRunning(udid: udid, allowExistingDriver: false, paths: paths)
            return DriverEndpoint(
                udid: udid,
                deviceName: simulator.name,
                deviceVersion: simulator.version,
                deviceType: "simulator"
            )
        }
        if session.udid != nil, try DeviceService.isUsbDeviceConnected(udid: udid) {
            try ensureRealDriverRunning(udid: udid, paths: paths, verbose: session.verbose)
            return DriverEndpoint(
                udid: udid,
                deviceName: "Unknown",
                deviceVersion: "",
                deviceType: "real"
            )
        }
        if let device = try DeviceService.listDevices(simulatorOnly: false, paths: paths).first(where: { $0.udid == udid }) {
            try ensureRealDriverRunning(udid: udid, paths: paths, verbose: session.verbose)
            return DriverEndpoint(
                udid: udid,
                deviceName: device.name,
                deviceVersion: device.version,
                deviceType: "real"
            )
        }
        throw CLIParseError.invalidValue("Device \(udid) not found.")
    }

    public static func terminateDriverIfNeeded(endpoint: DriverEndpoint?) throws -> Bool {
        guard let endpoint else { return false }
        if endpoint.isSimulator {
            let terminate = simulatorDriverTerminatorForTesting ?? terminateSimulatorDriver
            return try terminate(endpoint.udid)
        }
        let terminate = realDriverTerminatorForTesting ?? terminateRealDriverProcesses
        return try terminate(endpoint.udid)
    }

    public static func deleteResidualSessionFile(paths: IOSUsePaths) {
        try? FileManager.default.removeItem(atPath: "\(paths.root)/state/session.json")
    }

    private static func ensureRealDriverRunning(udid: String, paths: IOSUsePaths, verbose: Bool) throws {
        let isReachable = realDriverReachableForTesting ?? { targetUdid in
            isDriverPortReachable(udid: targetUdid)
        }
        let launch = realDriverLauncherForTesting ?? { targetUdid, bundleId in
            try launchRealDriverDetached(udid: targetUdid, bundleId: bundleId, paths: paths, verbose: verbose)
        }
        if isReachable(udid) {
            return
        }
        guard let bundleId = ConfigService.listEntries(paths: paths).first(where: { $0.udid == udid })?.bundleId,
              !bundleId.isEmpty,
              bundleId != "(missing)" else {
            throw CLIParseError.invalidValue("No driver bundle ID found for device \(udid). Run `ios-use config --udid \(udid)` first.")
        }
        try launch(udid, bundleId)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if isReachable(udid) {
                return
            }
            usleep(250_000)
        }
        throw CLIParseError.invalidValue("Driver launched but port \(IOSUseProtocol.defaultDriverPort) did not become reachable on device \(udid). Check \(driverLogPath(paths: paths))")
    }

    private static func launchRealDriverDetached(udid: String, bundleId: String, paths: IOSUsePaths, verbose: Bool) throws {
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true, attributes: nil)
        let logPath = driverLogPath(paths: paths)
        rotateDriverLogIfNeeded(logPath)
        let separator = "\n--- session start \(ISO8601DateFormatter().string(from: Date())) ---\n"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            _ = try? handle.seekToEnd()
            if let data = separator.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            try? handle.close()
        }

        let args = [
            "xcrun", "devicectl", "device", "process", "launch",
            "--device", udid,
            "--terminate-existing",
            "--console",
            bundleId,
        ]
        let command = "exec \(args.map(shellQuote).joined(separator: " ")) >> \(shellQuote(logPath)) 2>&1"
        if verbose {
            DaemonLogger(paths: paths).info("driver console log: \(logPath)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func driverLogPath(paths: IOSUsePaths) -> String {
        "\(paths.logs)/driver.log"
    }

    private static func rotateDriverLogIfNeeded(_ logPath: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 2 * 1024 * 1024 else {
            return
        }
        try? FileManager.default.removeItem(atPath: "\(logPath).1")
        try? FileManager.default.moveItem(atPath: logPath, toPath: "\(logPath).1")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func ensureSimulatorDriverRunning(udid: String, allowExistingDriver: Bool, paths: IOSUsePaths) throws {
        let isReachable = simulatorDriverReachableForTesting ?? {
            isLocalDriverPortReachable()
        }
        let launch = simulatorDriverLauncherForTesting ?? { targetUdid in
            _ = try Shell.run("xcrun", arguments: ["simctl", "launch", targetUdid, ConfigService.simulatorBundleId])
        }
        if allowExistingDriver, isReachable() {
            return
        }
        if !allowExistingDriver {
            terminateBootedSimulatorDrivers(paths: paths)
        }
        try launch(udid)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if isReachable() {
                return
            }
            usleep(250_000)
        }
        throw CLIParseError.invalidValue("Simulator driver launched but port \(IOSUseProtocol.defaultDriverPort) did not become reachable for \(udid)")
    }

    private static func terminateBootedSimulatorDrivers(paths: IOSUsePaths) {
        let terminate = simulatorDriverTerminatorForTesting ?? terminateSimulatorDriver
        let simulators = (try? DeviceService.listDevices(simulatorOnly: true, paths: paths)) ?? []
        var seen = Set<String>()
        for simulator in simulators where seen.insert(simulator.udid).inserted {
            _ = try? terminate(simulator.udid)
        }
    }

    private static func isDriverPortReachable(udid: String) -> Bool {
        guard let fd = try? Usbmux.connect(udid: udid, port: Int(IOSUseProtocol.defaultDriverPort)) else {
            return false
        }
        Darwin.close(fd)
        return true
    }

    private static func isLocalDriverPortReachable() -> Bool {
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

    private static func terminateSimulatorDriver(udid: String) throws -> Bool {
        do {
            _ = try Shell.run("xcrun", arguments: ["simctl", "terminate", udid, ConfigService.simulatorBundleId])
            return true
        } catch {
            return false
        }
    }

    private static func terminateRealDriverProcesses(udid: String) throws -> Bool {
        let output = (try? Shell.run("xcrun", arguments: ["devicectl", "device", "info", "processes", "--device", udid, "--quiet", "--json-output", "-"])) ?? ""
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else {
            return false
        }
        let processes = (result["runningProcesses"] as? [[String: Any]]) ?? (result["processTokens"] as? [[String: Any]]) ?? []
        var terminated = false
        for process in processes {
            let executable = process["executable"].map { String(describing: $0) } ?? ""
            let basename = URL(fileURLWithPath: executable).lastPathComponent
            let pidValue = process["processIdentifier"]
            let pid = (pidValue as? Int) ?? (pidValue as? NSNumber).map(\.intValue)
            guard basename == "IOSUseDriver-Runner", let pid else { continue }
            do {
                _ = try Shell.run("xcrun", arguments: ["devicectl", "device", "process", "terminate", "--device", udid, "--pid", String(pid), "--kill"])
                terminated = true
            } catch {
                // The process may already have exited between listing and termination.
            }
        }
        return terminated
    }
}
