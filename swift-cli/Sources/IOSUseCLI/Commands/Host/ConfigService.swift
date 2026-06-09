import Foundation

public struct DeviceConfigEntry: Equatable, Sendable {
    public let udid: String
    public let bundleId: String
    public let driverVersion: String

    public init(udid: String, bundleId: String, driverVersion: String = "(missing)") {
        self.udid = udid
        self.bundleId = bundleId
        self.driverVersion = driverVersion
    }
}

public enum ConfigService {
    public static let simulatorBundleId = "com.iosuse.xcuidriver.xctrunner"
    private static let devRunnerBundleId = "com.iosuse.xcuidriver.xctrunner"
    private static let devXCTestBundleId = "com.iosuse.xcuidriver"
    private static let defaultDriverBundlePrefix = "com.ios-use.driver"
    private static let cachedAppleIdPattern = #"Using cached session for ([^\s]+)"#
    static var altsignRunnerForTesting: ((String, [String]) throws -> Void)?
    static var realDeviceInstallerForTesting: ((String, String, String) throws -> Void)?
    static var installedDriverVersionProviderForTesting: ((String, String) throws -> String?)?
    static var driverIPAPathProviderForTesting: ((String, IOSUsePaths) -> String)?

    public static func configureDevice(options: ConfigOptions, paths: IOSUsePaths) throws -> String {
        let realDevices = try DeviceService.listDevices(simulatorOnly: false, paths: paths)
        let udid: String
        if let requested = options.udid {
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
        if let driverVersion = driverIPAVersion(at: ipaPath), driverVersion != IOSUseCLI.version {
            throw CLIParseError.invalidValue("Prebuilt driver IPA at \(ipaPath) is out of date (found: \(driverVersion); expected: \(IOSUseCLI.version)). Build or install the current driver IPA first.")
        }

        let rewritten = try rewriteIpaBundleIds(ipaPath: ipaPath, runnerBundleId: bundleId, xctestBundleId: xctestBundleId, paths: paths)
        defer { if rewritten != ipaPath { try? FileManager.default.removeItem(atPath: rewritten) } }

        let signedIpa = "\(paths.root)/driver-signed-\(udid).ipa"
        try? FileManager.default.removeItem(atPath: signedIpa)
        var signArgs = ["sign", "--udid", udid, "--ipa", rewritten, "--output", signedIpa]
        if let appleId = options.appleId { signArgs += ["--apple-id", appleId] }
        if let password = options.password { signArgs += ["--password", password] }
        if options.verbose { signArgs.append("--verbose") }
        if let altsignRunnerForTesting {
            try altsignRunnerForTesting(altsign, signArgs)
        } else {
            try Shell.runInheriting(altsign, arguments: signArgs)
        }

        guard FileManager.default.fileExists(atPath: signedIpa) else {
            throw CLIParseError.invalidValue("altsign-cli sign did not produce a signed IPA. Run with --verbose for full altsign output.")
        }
        let installedVersion = try currentInstalledDriverVersion(udid: udid, bundleId: bundleId)
        let installMessage: String
        if installedVersion == IOSUseCLI.version {
            installMessage = "Driver already installed on device"
        } else {
            if let realDeviceInstallerForTesting {
                try realDeviceInstallerForTesting(signedIpa, udid, bundleId)
            } else {
                try RealDevicePackageInstaller.installIpa(ipaPath: signedIpa, udid: udid, bundleID: bundleId)
            }
            installMessage = "Driver installed to device"
        }

        try saveConfig(udid: udid, bundleId: bundleId, driverVersion: IOSUseCLI.version, paths: paths)

        return """
        Using device: \(DeviceService.format(device, configured: DeviceService.configuredUdids(paths: paths)))
        Driver Bundle ID: \(bundleId)
        XCTest Bundle ID: \(xctestBundleId)
        Using prebuilt driver: \(ipaPath)
        Driver signed
        \(installMessage)
        Device config complete! Run `ios-use start \(udid)` before driver-backed commands.
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
            let driverVersion = value["driverVersion"] as? String ?? "(missing)"
            return DeviceConfigEntry(udid: udid, bundleId: bundleId, driverVersion: driverVersion)
        }
    }

    public static func formatList(_ entries: [DeviceConfigEntry]) -> String {
        guard !entries.isEmpty else { return "No configured devices.\n" }
        let lines = entries.map { "  \($0.udid) → bundleId: \($0.bundleId), driverVersion: \($0.driverVersion)" }.joined(separator: "\n")
        return "Configured devices:\n\(lines)\n"
    }

    public static func configureSimulator(udid requestedUdid: String?, paths: IOSUsePaths) throws -> String {
        let result = try SimulatorService.configureDriver(udid: requestedUdid, paths: paths)
        try saveConfig(udid: result.udid, bundleId: simulatorBundleId, driverVersion: IOSUseCLI.version, paths: paths)
        return "Using prebuilt driver: \(result.ipaPath)\nDriver installed to Simulator\nRun `ios-use start \(result.udid)` to start the Simulator driver\nSimulator config complete!\n"
    }

    static func simulatorIPAPath(paths: IOSUsePaths) -> String {
        ipaPath(assetName: "driver-sim.ipa", paths: paths)
    }

    static func deviceIPAPath(paths: IOSUsePaths) -> String {
        ipaPath(assetName: "driver.ipa", paths: paths)
    }

    private static func ipaPath(assetName: String, paths: IOSUsePaths) -> String {
        if let driverIPAPathProviderForTesting {
            return driverIPAPathProviderForTesting(assetName, paths)
        }
        #if DEBUG
        if paths.hasExplicitHome {
            return installedIPAPath(assetName: assetName, paths: paths)
        }
        return cwdIPAPath(assetName: assetName)
        #else
        return installedIPAPath(assetName: assetName, paths: paths)
        #endif
    }

    static func cwdIPAPath(assetName: String, currentDirectoryPath: String = FileManager.default.currentDirectoryPath) -> String {
        "\(currentDirectoryPath)/.ios-use/\(assetName)"
    }

    private static func installedIPAPath(assetName: String, paths: IOSUsePaths) -> String {
        "\(paths.root)/\(assetName)"
    }

    static func driverIPAVersion(at ipaPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: ipaPath) else { return nil }
        let tmpDir = "\(FileManager.default.temporaryDirectory.path)/ios-use-ipa-version-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }
            _ = try Shell.run("unzip", arguments: ["-q", "-o", ipaPath, "-d", tmpDir])
            let payloadDir = "\(tmpDir)/Payload"
            let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
            guard let appEntry = appEntries.first else { return nil }
            return try Shell.run("plutil", arguments: ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", "\(payloadDir)/\(appEntry)/Info.plist"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        } catch {
            return nil
        }
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

    static func assertDriverInstallCurrent(udid: String, paths: IOSUsePaths) throws {
        guard let entry = listEntries(paths: paths).first(where: { $0.udid == udid }) else {
            throw CLIParseError.invalidValue("No signing config found for device \(udid). Run `ios-use config --udid \(udid)` first.")
        }
        guard entry.driverVersion == IOSUseCLI.version else {
            let installed = entry.driverVersion
            throw CLIParseError.invalidValue("Driver for device \(udid) is out of date (installed: \(installed); expected: \(IOSUseCLI.version)). Run `ios-use config --udid \(udid)` to update the driver.")
        }
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

    private static func currentInstalledDriverVersion(udid: String, bundleId: String) throws -> String? {
        if let installedDriverVersionProviderForTesting {
            return try installedDriverVersionProviderForTesting(udid, bundleId)
        }
        if realDeviceInstallerForTesting != nil {
            return nil
        }
        return try? RealDevicePackageInstaller.installedVersion(udid: udid, bundleID: bundleId)
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

    private static func saveConfig(udid: String, bundleId: String, driverVersion: String, paths: IOSUsePaths) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var devices = root["devices"] as? [String: Any] ?? [:]
        devices[udid] = [
            "bundleId": bundleId,
            "driverVersion": driverVersion,
        ]
        root["devices"] = devices

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let configDir = URL(fileURLWithPath: paths.config).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: URL(fileURLWithPath: paths.config), options: .atomic)
    }

}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
