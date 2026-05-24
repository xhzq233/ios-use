import Darwin
import Foundation
import IOSUseProtocol

public struct DeviceConfigEntry: Equatable, Sendable {
    public let udid: String
    public let bundleId: String
    public let driverVersion: String
    public let driverIdentity: DriverIdentity?

    public init(udid: String, bundleId: String, driverVersion: String = "(missing)", driverIdentity: DriverIdentity? = nil) {
        self.udid = udid
        self.bundleId = bundleId
        self.driverVersion = driverVersion
        self.driverIdentity = driverIdentity
    }
}

public enum ConfigService {
    public static let simulatorBundleId = "com.iosuse.xcuidriver.xctrunner"
    private static let devRunnerBundleId = "com.iosuse.xcuidriver.xctrunner"
    private static let devXCTestBundleId = "com.iosuse.xcuidriver"
    private static let defaultDriverBundlePrefix = "com.ios-use.driver"
    private static let cachedAppleIdPattern = #"Using cached session for ([^\s]+)"#
    public static func configureDevice(options: ConfigOptions, paths: IOSUsePaths) throws -> String {
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
        try Shell.runInheriting(altsign, arguments: signArgs)

        guard FileManager.default.fileExists(atPath: signedIpa) else {
            throw CLIParseError.invalidValue("altsign-cli sign did not produce a signed IPA. Run with --verbose for full altsign output.")
        }
        let expectedIdentity = try validateDriverIdentityFromArtifact(try readDriverIdentityFromIPA(signedIpa), source: "signed driver IPA")

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
        let installedIdentity = try readRealDeviceInstalledDriverIdentity(udid: udid, bundleId: bundleId)
        try assertInstalledDriverIdentity(installed: installedIdentity, expected: expectedIdentity, source: "devicectl")
        try saveConfig(udid: udid, bundleId: bundleId, driverIdentity: installedIdentity, paths: paths)

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
            let driverVersion = value["driverVersion"] as? String ?? "(missing)"
            let identity = (value["driverIdentity"] as? [String: Any]).flatMap(DriverIdentity.init(json:))
            return DeviceConfigEntry(udid: udid, bundleId: bundleId, driverVersion: driverVersion, driverIdentity: identity)
        }
    }

    public static func formatList(_ entries: [DeviceConfigEntry]) -> String {
        guard !entries.isEmpty else { return "No configured devices.\n" }
        let lines = entries.map { "  \($0.udid) → bundleId: \($0.bundleId), driverVersion: \($0.driverVersion)" }.joined(separator: "\n")
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
        let expectedIdentity = try validateDriverIdentityFromArtifact(try readDriverIdentityFromIPA(ipaPath), source: "Simulator driver IPA")

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
        let installedIdentity = try readSimulatorInstalledDriverIdentity(udid: udid, bundleId: simulatorBundleId)
        try assertInstalledDriverIdentity(installed: installedIdentity, expected: expectedIdentity, source: "Simulator app Info.plist")
        try saveConfig(udid: udid, bundleId: simulatorBundleId, driverIdentity: installedIdentity, paths: paths)
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

    static func assertDriverInstallCurrent(udid: String, paths: IOSUsePaths) throws {
        guard let config = DeviceService.configuredDevices(paths: paths)[udid], config.needsDriverUpdate else {
            return
        }
        let installed = config.driverVersion ?? "unknown"
        throw CLIParseError.invalidValue("Driver for device \(udid) is out of date (installed: \(installed); expected: \(IOSUseCLI.version)). Run `ios-use config --udid \(udid)` to update the driver.")
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

    static func readDriverIdentityFromIPA(_ ipaPath: String) throws -> DriverIdentity {
        let tmpDir = "\(NSTemporaryDirectory())ios-use-driver-identity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        _ = try Shell.run("unzip", arguments: ["-q", "-o", ipaPath, "-d", tmpDir])
        return try readDriverIdentityFromExtractedPayload(payloadDir: "\(tmpDir)/Payload")
    }

    static func readRealDeviceInstalledDriverIdentity(udid: String, bundleId: String) throws -> DriverIdentity {
        do {
            let identity = try readDevicectlInstalledDriverIdentity(udid: udid, bundleId: bundleId)
            return try validateInstalledDriverIdentity(identity, source: "devicectl")
        } catch {
            throw CLIParseError.invalidValue("Unable to verify installed driver identity for \(bundleId) on \(udid). \(error)")
        }
    }

    private static func readDevicectlInstalledDriverIdentity(udid: String, bundleId: String) throws -> DriverIdentity {
        let jsonPath = "\(NSTemporaryDirectory())ios-use-devicectl-apps-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: jsonPath) }
        let output = try Shell.run("xcrun", arguments: [
            "devicectl", "device", "info", "apps",
            "--device", udid,
            "--bundle-id", bundleId,
            "--columns", "*",
            "--json-output", jsonPath,
        ])
        if let identity = parseDriverIdentity(fromDevicectlAppsJSONAtPath: jsonPath, bundleId: bundleId) {
            return identity
        }
        if let identity = parseDriverIdentity(fromDeviceInfoAppsOutput: output, bundleId: bundleId) {
            return identity
        }
        throw CLIParseError.invalidValue("devicectl did not return installed app identity for \(bundleId)")
    }

    static func readSimulatorInstalledDriverIdentity(udid: String, bundleId: String) throws -> DriverIdentity {
        if let appContainer = try? Shell.run("xcrun", arguments: ["simctl", "get_app_container", udid, bundleId, "app"]).trimmingCharacters(in: .whitespacesAndNewlines),
           !appContainer.isEmpty,
           let identity = try? readDriverIdentityFromInfoPlist("\(appContainer)/Info.plist") {
            return try validateInstalledDriverIdentity(identity, source: "Simulator app Info.plist")
        }
        throw CLIParseError.invalidValue("Unable to verify installed Simulator driver identity for \(bundleId) on \(udid).")
    }

    private static func readDriverIdentityFromExtractedPayload(payloadDir: String) throws -> DriverIdentity {
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            throw CLIParseError.invalidValue("No .app found in IPA payload")
        }
        return try readDriverIdentityFromInfoPlist("\(payloadDir)/\(appEntry)/Info.plist")
    }

    static func readDriverIdentityFromInfoPlist(_ plistPath: String) throws -> DriverIdentity {
        let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CLIParseError.invalidValue("Invalid driver Info.plist at \(plistPath)")
        }
        guard let version = plist["CFBundleShortVersionString"] as? String,
              let build = plist["CFBundleVersion"] as? String else {
            throw CLIParseError.invalidValue("Driver Info.plist missing version fields at \(plistPath)")
        }
        return DriverIdentity(
            version: version,
            build: build
        )
    }

    static func parseDriverIdentity(fromDevicectlAppsJSONAtPath path: String, bundleId: String) -> DriverIdentity? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return appDictionaries(in: root)
            .filter { dictionary in
                ["bundleIdentifier", "CFBundleIdentifier", "identifier"].contains { key in
                    stringValue(dictionary[key]) == bundleId
                }
            }
            .compactMap(identityFromAppDictionary)
            .first
    }

    private static func appDictionaries(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            var out = [dictionary]
            for child in dictionary.values {
                out.append(contentsOf: appDictionaries(in: child))
            }
            return out
        }
        if let array = value as? [Any] {
            return array.flatMap(appDictionaries(in:))
        }
        return []
    }

    private static func identityFromAppDictionary(_ app: [String: Any]) -> DriverIdentity? {
        guard let version = firstString(in: app, keys: ["CFBundleShortVersionString", "version", "shortVersionString", "bundleShortVersionString"]) else {
            return nil
        }
        return DriverIdentity(
            version: version,
            build: firstString(in: app, keys: ["CFBundleVersion", "bundleVersion", "build"]) ?? ""
        )
    }

    private static func validateInstalledDriverIdentity(_ identity: DriverIdentity, source: String) throws -> DriverIdentity {
        var missing: [String] = []
        if identity.version.isEmpty { missing.append("CFBundleShortVersionString") }
        if identity.build.isEmpty { missing.append("CFBundleVersion") }
        guard missing.isEmpty else {
            throw CLIParseError.invalidValue("\(source) driver identity is incomplete (missing: \(missing.joined(separator: ", "))). Rebuild or reinstall a current driver IPA.")
        }
        guard identity.version == IOSUseCLI.version else {
            throw CLIParseError.invalidValue("\(source) driver version \(identity.version) does not match CLI version \(IOSUseCLI.version). Rebuild or reinstall a current driver IPA.")
        }
        guard isStampedBuild(identity.build) else {
            throw CLIParseError.invalidValue("\(source) driver build \(identity.build) is not stamped as yyyyMMddHHmmss-<12 char git sha>. Rebuild or reinstall a current driver IPA.")
        }
        return identity
    }

    private static func validateDriverIdentityFromArtifact(_ identity: DriverIdentity, source: String) throws -> DriverIdentity {
        try validateInstalledDriverIdentity(identity, source: source)
    }

    private static func assertInstalledDriverIdentity(installed: DriverIdentity, expected: DriverIdentity, source: String) throws {
        guard installed == expected else {
            throw CLIParseError.invalidValue("\(source) installed driver identity mismatch (installed: \(installed.description); expected: \(expected.description)). Rebuild or reinstall a current driver IPA.")
        }
    }

    private static func isStampedBuild(_ build: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: #"^\d{14}-[0-9A-Fa-f]{12}$"#)
        let range = NSRange(build.startIndex..<build.endIndex, in: build)
        return regex?.firstMatch(in: build, range: range) != nil
    }

    static func parseDriverIdentity(fromDeviceInfoAppsOutput output: String, bundleId: String) -> DriverIdentity? {
        let records = appRecordCandidates(fromDeviceInfoAppsOutput: output, bundleId: bundleId)
        for record in records {
            if let identity = parseDriverIdentity(fromAppRecord: record) {
                return identity
            }
        }
        return nil
    }

    private static func appRecordCandidates(fromDeviceInfoAppsOutput output: String, bundleId: String) -> [String] {
        let paragraphs = output.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains(bundleId) }
        if !paragraphs.isEmpty {
            return paragraphs
        }

        let lines = output.components(separatedBy: .newlines)
        var records: [String] = []
        for index in lines.indices where lines[index].contains(bundleId) {
            let end = min(lines.endIndex, index + 21)
            records.append(lines[index..<end].joined(separator: "\n"))
        }
        return records
    }

    private static func parseDriverIdentity(fromAppRecord record: String) -> DriverIdentity? {
        func capture(_ key: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: #"\b\#(key)\b\s*[:=]\s*"?([^",\n]+)"?"#) else { return nil }
            let range = NSRange(record.startIndex..<record.endIndex, in: record)
            guard let match = regex.firstMatch(in: record, range: range),
                  let swiftRange = Range(match.range(at: 1), in: record) else { return nil }
            return String(record[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let version = capture("CFBundleShortVersionString") ?? capture("version") else { return nil }
        let build = capture("CFBundleVersion") ?? capture("build") ?? ""
        return DriverIdentity(
            version: version,
            build: build
        )
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key]), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func saveConfig(udid: String, bundleId: String, driverIdentity: DriverIdentity, paths: IOSUsePaths) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var devices = root["devices"] as? [String: Any] ?? [:]
        devices[udid] = [
            "bundleId": bundleId,
            "driverVersion": driverIdentity.version,
            "driverIdentity": driverIdentity.json,
        ]
        root["devices"] = devices

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let configDir = URL(fileURLWithPath: paths.config).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: URL(fileURLWithPath: paths.config), options: .atomic)
    }

    private static func waitForSimulatorDriver() {
        for _ in 0..<50 {
            let driver = DriverClient()
            defer { driver.close() }
            if (try? driver.dom(raw: false, fresh: false)) != nil {
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

public enum SessionService {
    public struct Info: Equatable, Sendable {
        public let udid: String
        public let deviceName: String
        public let deviceVersion: String
        public let deviceType: String
        public let startedAt: Int

        public init(udid: String, deviceName: String, deviceVersion: String, deviceType: String, startedAt: Int = Int(Date().timeIntervalSince1970 * 1000)) {
            self.udid = udid
            self.deviceName = deviceName
            self.deviceVersion = deviceVersion
            self.deviceType = deviceType
            self.startedAt = startedAt
        }
    }

    static var simulatorDriverReachableForTesting: (() -> Bool)?
    static var simulatorDriverLauncherForTesting: ((String) throws -> Void)?
    static var simulatorDriverTerminatorForTesting: ((String) throws -> Bool)?
    static var realDriverReachableForTesting: ((String) -> Bool)?
    static var realDriverLauncherForTesting: ((String, String) throws -> Void)?
    static var realDriverTerminatorForTesting: ((String) throws -> Bool)?

    public static func clear(paths: IOSUsePaths) {
        clearDriverLock(paths: paths)
    }

    public static func readDriverLock(paths: IOSUsePaths) -> String? {
        try? readDriverLockInfo(paths: paths)?.udid
    }

    public static func readDriverLockInfo(paths: IOSUsePaths) throws -> Info? {
        guard FileManager.default.fileExists(atPath: paths.driverLock) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: paths.driverLock))
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIParseError.invalidValue("Invalid driver.lock: expected JSON object.")
        }
        guard let udid = raw["udid"] as? String, !udid.isEmpty,
              let deviceType = raw["deviceType"] as? String, !deviceType.isEmpty else {
            throw CLIParseError.invalidValue("Invalid driver.lock: missing udid/deviceType.")
        }
        guard deviceType == "real" || deviceType == "simulator" else {
            throw CLIParseError.invalidValue("Invalid driver.lock: unknown deviceType \(deviceType).")
        }
        guard let startedAt = raw["startedAt"] as? Int else {
            throw CLIParseError.invalidValue("Invalid driver.lock: missing startedAt.")
        }
        return Info(
            udid: udid,
            deviceName: raw["deviceName"] as? String ?? "",
            deviceVersion: raw["deviceVersion"] as? String ?? "",
            deviceType: deviceType,
            startedAt: startedAt
        )
    }

    public static func requireDriverLock(paths: IOSUsePaths) throws -> Info {
        guard let info = try readDriverLockInfo(paths: paths) else {
            throw CLIParseError.invalidValue("No active driver. Run `ios-use start <UDID>` first.")
        }
        return info
    }

    public static func writeDriverLock(info: Info, paths: IOSUsePaths) throws {
        let root: [String: Any] = [
            "udid": info.udid,
            "deviceName": info.deviceName,
            "deviceVersion": info.deviceVersion,
            "deviceType": info.deviceType,
            "startedAt": info.startedAt,
        ]
        let lockDir = URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: paths.driverLock), options: .atomic)
    }

    public static func clearDriverLock(paths: IOSUsePaths) {
        try? FileManager.default.removeItem(atPath: paths.driverLock)
    }

    public static func start(udid: String, paths: IOSUsePaths, verbose: Bool) throws -> String {
        if let current = try readDriverLockInfo(paths: paths) {
            throw CLIParseError.invalidValue("Driver already started for \(current.udid). Run `ios-use stop` before starting another driver.")
        }
        let info = try resolveDriverInfo(udid: udid, paths: paths)
        try launchDriver(for: info, paths: paths, verbose: verbose)
        try writeDriverLock(info: info, paths: paths)
        return "Driver started for \(udid)\n"
    }

    public static func stop(paths: IOSUsePaths) throws -> String {
        let current = try requireDriverLock(paths: paths)
        var output = ""
        if current.deviceType == "simulator" {
            let terminate = simulatorDriverTerminatorForTesting ?? terminateSimulatorDriver
            guard try terminate(current.udid) else {
                throw CLIParseError.invalidValue("Driver app was not terminated for \(current.udid).")
            }
            output += "Driver app terminated on simulator\n"
        } else {
            let terminate = realDriverTerminatorForTesting ?? terminateRealDriverProcesses
            guard try terminate(current.udid) else {
                throw CLIParseError.invalidValue("Driver app was not terminated for \(current.udid).")
            }
            output += "Driver app terminated on device\n"
        }

        clearDriverLock(paths: paths)
        output += "Driver stopped\n"
        return output
    }

    public static func read(paths: IOSUsePaths) -> Info? {
        try? readDriverLockInfo(paths: paths)
    }

    public static func resolveDriverInfo(udid: String, paths: IOSUsePaths) throws -> Info {
        let configured = DeviceService.configuredUdids(paths: paths)
        guard configured.contains(udid) else {
            throw CLIParseError.invalidValue("No signing config found for device \(udid). Run `ios-use config --udid \(udid)` first.")
        }
        try ConfigService.assertDriverInstallCurrent(udid: udid, paths: paths)
        if let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).first(where: { $0.udid == udid }) {
            return Info(
                udid: udid,
                deviceName: simulator.name,
                deviceVersion: simulator.version,
                deviceType: "simulator"
            )
        }
        if try DeviceService.isUsbDeviceConnected(udid: udid) {
            let device = try DeviceService.listDevices(simulatorOnly: false, paths: paths).first { $0.udid == udid }
            return Info(
                udid: udid,
                deviceName: device?.name ?? "Unknown",
                deviceVersion: device?.version ?? "",
                deviceType: "real"
            )
        }
        if let device = try DeviceService.listDevices(simulatorOnly: false, paths: paths).first(where: { $0.udid == udid }) {
            return Info(
                udid: udid,
                deviceName: device.name,
                deviceVersion: device.version,
                deviceType: "real"
            )
        }
        throw CLIParseError.invalidValue("Device \(udid) not found.")
    }

    public static func launchDriver(for info: Info, paths: IOSUsePaths, verbose: Bool) throws {
        try ConfigService.assertDriverInstallCurrent(udid: info.udid, paths: paths)
        switch info.deviceType {
        case "simulator":
            try ensureSimulatorDriverRunning(udid: info.udid, allowExistingDriver: false)
        case "real":
            try ensureRealDriverRunning(udid: info.udid, paths: paths, verbose: verbose, checkFirst: false)
        default:
            throw CLIParseError.invalidValue("Invalid driver.lock: unknown deviceType \(info.deviceType).")
        }
    }

    private static func ensureRealDriverRunning(udid: String, paths: IOSUsePaths, verbose: Bool, checkFirst: Bool = true) throws {
        let isReachable = realDriverReachableForTesting ?? { targetUdid in
            isDriverPortReachable(udid: targetUdid)
        }
        let launch = realDriverLauncherForTesting ?? { targetUdid, bundleId in
            try launchRealDriverDetached(udid: targetUdid, bundleId: bundleId, paths: paths, verbose: verbose)
        }
        if checkFirst && isReachable(udid) {
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
            FileHandle.standardError.write(Data("Driver console log: \(logPath)\n".utf8))
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

    private static func ensureSimulatorDriverRunning(udid: String, allowExistingDriver: Bool) throws {
        let isReachable = simulatorDriverReachableForTesting ?? {
            isLocalDriverPortReachable()
        }
        let launch = simulatorDriverLauncherForTesting ?? { targetUdid in
            _ = try Shell.run("xcrun", arguments: ["simctl", "launch", targetUdid, ConfigService.simulatorBundleId])
        }
        if allowExistingDriver, isReachable() {
            return
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
