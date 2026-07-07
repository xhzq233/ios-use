import Foundation

public struct DeviceConfigEntry: Equatable, Sendable {
    public let udid: String
    public let bundleId: String
    public let driverVersion: String
    public let signingExpiresAt: Date?

    public init(udid: String, bundleId: String, driverVersion: String = "(missing)", signingExpiresAt: Date? = nil) {
        self.udid = udid
        self.bundleId = bundleId
        self.driverVersion = driverVersion
        self.signingExpiresAt = signingExpiresAt
    }
}

public enum ConfigService {
    public enum DriverSigningStatus: Equatable, Sendable {
        case notApplicable
        case unknown
        case valid(daysRemaining: Int)
        case expiresSoon
        case expired
    }

    public static let simulatorBundleId = "com.iosuse.xcuidriver.xctrunner"
    private static let devRunnerBundleId = "com.iosuse.xcuidriver.xctrunner"
    private static let devXCTestBundleId = "com.iosuse.xcuidriver"
    private static let defaultDriverBundlePrefix = "com.ios-use.driver"
    private static let cachedAppleIdPattern = #"Using cached session for ([^\s]+)"#
    private static let signingExpirationWarningInterval: TimeInterval = 24 * 60 * 60
    private static let secondsPerDay: TimeInterval = 24 * 60 * 60
    static var altsignRunnerForTesting: ((String, [String]) throws -> Void)?
    static var realDeviceInstallerForTesting: ((String, String, String) throws -> Void)?
    static var driverIPAPathProviderForTesting: ((String, IOSUsePaths) -> String)?
    static var signedDriverPreflightInspectorForTesting: ((String, String, String, String, IOSUsePaths) throws -> SignedDriverPreflightResult)?
    static var nowProviderForTesting: (() -> Date)?

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
        if let appleId = options.appleId {
            signArgs += ["--apple-id", appleId]
            let password: String
            if let p = options.password {
                password = p
            } else {
                guard let p = Shell.readSecureInput(prompt: "App-specific password for \(appleId): "), !p.isEmpty else {
                    throw CLIParseError.invalidValue("Password is required for signing. Provide via interactive prompt or --password.")
                }
                password = p
            }
            signArgs += ["--password", password]
        }
        if options.verbose { signArgs.append("--verbose") }
        if let altsignRunnerForTesting {
            try altsignRunnerForTesting(altsign, signArgs)
        } else {
            try Shell.runInheriting(altsign, arguments: signArgs)
        }

        guard FileManager.default.fileExists(atPath: signedIpa) else {
            throw CLIParseError.invalidValue("altsign-cli sign did not produce a signed IPA. Run with --verbose for full altsign output.")
        }
        let signingPreflight = signedDriverPreflight(
            signedIpa: signedIpa,
            udid: udid,
            runnerBundleId: bundleId,
            xctestBundleId: xctestBundleId,
            paths: paths
        )
        if let realDeviceInstallerForTesting {
            try realDeviceInstallerForTesting(signedIpa, udid, bundleId)
        } else {
            try RealDevicePackageInstaller.installIpa(ipaPath: signedIpa, udid: udid, bundleID: bundleId, preferDevicectl: false)
        }
        let installMessage = "Driver installed to device"

        try saveConfig(
            udid: udid,
            bundleId: bundleId,
            driverVersion: IOSUseCLI.version,
            signingExpiresAt: signingPreflight.signingExpiresAt,
            paths: paths
        )

        return """
        Using device: \(DeviceService.format(device, configuredDevices: DeviceService.configuredDevices(paths: paths)))
        Driver Bundle ID: \(bundleId)
        XCTest Bundle ID: \(xctestBundleId)
        Using prebuilt driver: \(ipaPath)
        Driver signed
        \(formatSigningWarnings(signingPreflight.warnings))\
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
            let signing = value["signing"] as? [String: Any]
            let signingExpiresAt = parseSigningExpiresAt(signing?["expiresAt"] as? String)
            return DeviceConfigEntry(udid: udid, bundleId: bundleId, driverVersion: driverVersion, signingExpiresAt: signingExpiresAt)
        }
    }

    public static func formatList(_ entries: [DeviceConfigEntry]) -> String {
        guard !entries.isEmpty else { return "No configured devices.\n" }
        let lines = entries.map { entry in
            var line = "  \(entry.udid) → bundleId: \(entry.bundleId), driverVersion: \(entry.driverVersion)"
            if let signing = signingStatusText(for: entry) {
                line += ", \(signing)"
            }
            return line
        }.joined(separator: "\n")
        return "Configured devices:\n\(lines)\n"
    }

    public static func configureSimulator(udid requestedUdid: String?, paths: IOSUsePaths) throws -> String {
        let result = try SimulatorService.configureDriver(udid: requestedUdid, paths: paths)
        try saveConfig(udid: result.udid, bundleId: simulatorBundleId, driverVersion: IOSUseCLI.version, signingExpiresAt: nil, paths: paths)
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
        do {
            let entries = try Shell.run("unzip", arguments: ["-Z1", ipaPath])
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            guard let infoEntry = entries.first(where: { entry in
                entry.hasPrefix("Payload/")
                    && entry.hasSuffix(".app/Info.plist")
                    && entry.dropFirst("Payload/".count).split(separator: "/").count == 2
            }) else {
                return nil
            }
            let infoData = try Shell.runData("unzip", arguments: ["-p", ipaPath, infoEntry])
            guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] else {
                return nil
            }
            return (info["CFBundleShortVersionString"] as? String)?.nonEmpty
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

    static func startSigningWarning(udid: String, paths: IOSUsePaths) -> String? {
        guard let entry = listEntries(paths: paths).first(where: { $0.udid == udid }) else {
            return nil
        }
        switch signingStatus(for: entry) {
        case .expired:
            return "warning: driver signing is expired; run `ios-use config --udid \(udid)` to re-sign and reinstall the driver if launch fails.\n"
        case .expiresSoon:
            return "warning: driver signing expires soon; run `ios-use config --udid \(udid)` before it expires.\n"
        case .notApplicable, .unknown, .valid:
            return nil
        }
    }

    public static func signingStatusText(udid: String, signingExpiresAt: Date?) -> String {
        formatSigningStatus(status: signingStatus(signingExpiresAt: signingExpiresAt), udid: udid)
    }

    static func signingStatusText(for entry: DeviceConfigEntry) -> String? {
        guard entry.bundleId != simulatorBundleId else { return nil }
        return formatSigningStatus(status: signingStatus(for: entry), udid: entry.udid)
    }

    static func signingStatus(for entry: DeviceConfigEntry) -> DriverSigningStatus {
        guard entry.bundleId != simulatorBundleId else { return .notApplicable }
        return signingStatus(signingExpiresAt: entry.signingExpiresAt)
    }

    static func signingStatus(signingExpiresAt: Date?) -> DriverSigningStatus {
        guard let signingExpiresAt else { return .unknown }
        let remaining = signingExpiresAt.timeIntervalSince(currentDate())
        if remaining <= 0 {
            return .expired
        }
        if remaining <= signingExpirationWarningInterval {
            return .expiresSoon
        }
        let days = max(1, Int(ceil(remaining / secondsPerDay)))
        return .valid(daysRemaining: days)
    }

    static func parseSigningExpiresAt(_ value: String?) -> Date? {
        guard let value else { return nil }
        return makeSigningDateFormatter().date(from: value)
    }

    static func formatSigningExpiresAt(_ date: Date) -> String {
        makeSigningDateFormatter().string(from: date)
    }

    private static func formatSigningStatus(status: DriverSigningStatus, udid: String) -> String {
        switch status {
        case .notApplicable:
            return "signing not applicable"
        case .unknown:
            return "signing unknown: run ios-use config --udid \(udid) to enable expiry reminders"
        case .valid(let daysRemaining):
            return "signing expires in \(daysRemaining)d"
        case .expiresSoon:
            return "signing expires soon: run ios-use config --udid \(udid)"
        case .expired:
            return "signing expired: run ios-use config --udid \(udid)"
        }
    }

    private static func currentDate() -> Date {
        nowProviderForTesting?() ?? Date()
    }

    private static func makeSigningDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
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

    private static func signedDriverPreflight(
        signedIpa: String,
        udid: String,
        runnerBundleId: String,
        xctestBundleId: String,
        paths: IOSUsePaths
    ) -> SignedDriverPreflightResult {
        if let signedDriverPreflightInspectorForTesting {
            do {
                return try signedDriverPreflightInspectorForTesting(signedIpa, udid, runnerBundleId, xctestBundleId, paths)
            } catch {
                return SignedDriverPreflightResult(warnings: ["signed IPA preflight could not inspect \(signedIpa): \(error)"], signingExpiresAt: nil)
            }
        }
        do {
            return try inspectSignedDriverIpa(
                signedIpa: signedIpa,
                udid: udid,
                runnerBundleId: runnerBundleId,
                xctestBundleId: xctestBundleId,
                paths: paths
            )
        } catch {
            return SignedDriverPreflightResult(warnings: ["signed IPA preflight could not inspect \(signedIpa): \(error)"], signingExpiresAt: nil)
        }
    }

    private static func inspectSignedDriverIpa(
        signedIpa: String,
        udid: String,
        runnerBundleId: String,
        xctestBundleId: String,
        paths: IOSUsePaths
    ) throws -> SignedDriverPreflightResult {
        let tmpDir = "\(paths.root)/signed-preflight-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: tmpDir)
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        _ = try Shell.run("unzip", arguments: ["-q", "-o", signedIpa, "-d", tmpDir])
        let payloadDir = "\(tmpDir)/Payload"
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            return SignedDriverPreflightResult(warnings: ["signed IPA preflight found no Payload/*.app bundle"], signingExpiresAt: nil)
        }
        let appPath = "\(payloadDir)/\(appEntry)"
        var bundles = [
            SignedBundlePreflightTarget(label: "runner", path: appPath, expectedBundleId: runnerBundleId, requireEntitlements: true),
        ]
        let pluginsDir = "\(appPath)/PlugIns"
        if let plugins = try? FileManager.default.contentsOfDirectory(atPath: pluginsDir),
           let xctest = plugins.first(where: { $0.hasSuffix(".xctest") }) {
            bundles.append(SignedBundlePreflightTarget(label: "xctest", path: "\(pluginsDir)/\(xctest)", expectedBundleId: xctestBundleId, requireEntitlements: false))
        } else {
            bundles.append(SignedBundlePreflightTarget(label: "xctest", path: "\(pluginsDir)/IOSUseDriver.xctest", expectedBundleId: xctestBundleId, requireEntitlements: false))
        }

        var warnings: [String] = []
        var expirations: [Date] = []
        warnings.append(contentsOf: codesignVerifyWarnings(appPath: appPath))
        for bundle in bundles {
            let inspection = inspectSignedBundle(bundle, udid: udid)
            warnings.append(contentsOf: inspection.warnings)
            if let expirationDate = inspection.expirationDate {
                expirations.append(expirationDate)
            }
        }
        return SignedDriverPreflightResult(warnings: warnings, signingExpiresAt: expirations.min())
    }

    private static func codesignVerifyWarnings(appPath: String) -> [String] {
        guard let result = try? Shell.runWithResult("codesign", arguments: ["--verify", "--deep", "--strict", "--verbose=2", appPath]) else {
            return ["signed IPA preflight could not run local codesign verification"]
        }
        guard result.exitCode != 0 else { return [] }
        let output = (result.stderr + "\n" + result.stdout)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "codesign verify failed with exit \(result.exitCode)"
        return ["signed IPA preflight local codesign verification failed: \(output)"]
    }

    private static func inspectSignedBundle(_ target: SignedBundlePreflightTarget, udid: String) -> SignedBundleInspection {
        var warnings: [String] = []
        let label = target.label
        guard FileManager.default.fileExists(atPath: target.path) else {
            return SignedBundleInspection(warnings: ["signed IPA preflight \(label) bundle is missing at \(target.path)"], expirationDate: nil)
        }

        let infoPath = "\(target.path)/Info.plist"
        let actualBundleId = plistDictionary(at: infoPath)?["CFBundleIdentifier"] as? String
        if actualBundleId != target.expectedBundleId {
            warnings.append("signed IPA preflight \(label) bundle id is \(actualBundleId ?? "(missing)"), expected \(target.expectedBundleId)")
        }

        let profilePath = "\(target.path)/embedded.mobileprovision"
        guard FileManager.default.fileExists(atPath: profilePath) else {
            warnings.append("signed IPA preflight \(label) is missing embedded.mobileprovision")
            return SignedBundleInspection(warnings: warnings, expirationDate: nil)
        }
        guard let profile = provisioningProfileSummary(path: profilePath) else {
            warnings.append("signed IPA preflight \(label) embedded.mobileprovision could not be decoded")
            return SignedBundleInspection(warnings: warnings, expirationDate: nil)
        }

        if let expirationDate = profile.expirationDate, expirationDate <= Date() {
            warnings.append("signed IPA preflight \(label) provisioning profile is expired: \(expirationDate)")
        }
        if let provisionedDevices = profile.provisionedDevices, !provisionedDevices.contains(udid) {
            warnings.append("signed IPA preflight \(label) provisioning profile does not include target UDID \(udid)")
        }
        if let profileAppId = profile.applicationIdentifier {
            let expectedSuffix = ".\(target.expectedBundleId)"
            if !profileAppId.hasSuffix(expectedSuffix) {
                warnings.append("signed IPA preflight \(label) profile application-identifier is \(profileAppId), expected suffix \(expectedSuffix)")
            }
        } else {
            warnings.append("signed IPA preflight \(label) profile is missing application-identifier")
        }

        let codesign = codesignSummary(path: target.path)
        if target.requireEntitlements, codesign.entitlements == nil {
            warnings.append("signed IPA preflight \(label) codesign entitlements could not be read")
        }
        if let profileTeamId = profile.teamIdentifier,
           let codesignTeamId = codesign.teamIdentifier,
           profileTeamId != codesignTeamId {
            warnings.append("signed IPA preflight \(label) profile team \(profileTeamId) does not match codesign team \(codesignTeamId)")
        }
        if let profileAppId = profile.applicationIdentifier,
           let signedAppId = codesign.entitlements?["application-identifier"] as? String,
           profileAppId != signedAppId {
            warnings.append("signed IPA preflight \(label) profile application-identifier \(profileAppId) does not match signed entitlement \(signedAppId)")
        }
        if let profileTeamId = profile.teamIdentifier,
           let signedTeamId = codesign.entitlements?["com.apple.developer.team-identifier"] as? String,
           profileTeamId != signedTeamId {
            warnings.append("signed IPA preflight \(label) profile team \(profileTeamId) does not match signed entitlement team \(signedTeamId)")
        }

        return SignedBundleInspection(warnings: warnings, expirationDate: profile.expirationDate)
    }

    private static func provisioningProfileSummary(path: String) -> ProvisioningProfileSummary? {
        guard let data = try? Shell.runData("security", arguments: ["cms", "-D", "-i", path]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let entitlements = plist["Entitlements"] as? [String: Any]
        let teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first
        return ProvisioningProfileSummary(
            expirationDate: plist["ExpirationDate"] as? Date,
            provisionedDevices: plist["ProvisionedDevices"] as? [String],
            teamIdentifier: teamIdentifier,
            applicationIdentifier: entitlements?["application-identifier"] as? String
        )
    }

    private static func codesignSummary(path: String) -> CodesignSummary {
        let display = (try? Shell.runCombined("codesign", arguments: ["-dvvv", path])) ?? ""
        let entitlementsData = try? Shell.runData("codesign", arguments: ["-d", "--entitlements", ":-", path])
        let entitlements = entitlementsData.flatMap { data -> [String: Any]? in
            guard !data.isEmpty else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        }
        return CodesignSummary(
            teamIdentifier: firstRegexCapture(pattern: #"TeamIdentifier=([A-Z0-9]+)"#, in: display),
            entitlements: entitlements
        )
    }

    private static func firstRegexCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func plistDictionary(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    private static func formatSigningWarnings(_ warnings: [String]) -> String {
        guard !warnings.isEmpty else { return "" }
        return "Driver signing warnings:\n" + warnings.map { "  - \($0)" }.joined(separator: "\n") + "\n"
    }

    private static func saveConfig(udid: String, bundleId: String, driverVersion: String, signingExpiresAt: Date?, paths: IOSUsePaths) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var devices = root["devices"] as? [String: Any] ?? [:]
        var deviceEntry: [String: Any] = [
            "bundleId": bundleId,
            "driverVersion": driverVersion,
        ]
        if let signingExpiresAt {
            deviceEntry["signing"] = [
                "expiresAt": formatSigningExpiresAt(signingExpiresAt),
                "source": "embedded.mobileprovision",
            ]
        }
        devices[udid] = deviceEntry
        root["devices"] = devices

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let configDir = URL(fileURLWithPath: paths.config).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: URL(fileURLWithPath: paths.config), options: .atomic)
    }

}

struct SignedDriverPreflightResult {
    let warnings: [String]
    let signingExpiresAt: Date?
}

private struct SignedBundleInspection {
    let warnings: [String]
    let expirationDate: Date?
}

private struct SignedBundlePreflightTarget {
    let label: String
    let path: String
    let expectedBundleId: String
    let requireEntitlements: Bool
}

private struct ProvisioningProfileSummary {
    let expirationDate: Date?
    let provisionedDevices: [String]?
    let teamIdentifier: String?
    let applicationIdentifier: String?
}

private struct CodesignSummary {
    let teamIdentifier: String?
    let entitlements: [String: Any]?
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
