import Foundation

enum AppManagementService {
    struct AppInfo: Equatable {
        let bundleID: String
        let displayName: String
        let version: String
        let applicationType: String
    }

    static var installerForTesting: ((String, String, String?) throws -> Void)?
    static var uninstallerForTesting: ((String, String) throws -> Void)?
    static var appsProviderForTesting: ((String, Bool) throws -> [AppInfo])?

    static func install(options: AppInstallOptions) throws -> String {
        guard FileManager.default.fileExists(atPath: options.ipaPath) else {
            throw CLIParseError.invalidValue("IPA not found: \(options.ipaPath)")
        }
        let bundleID = try? extractBundleID(ipaPath: options.ipaPath)
        var responseFrames: [[String: Any]] = []
        if let installerForTesting {
            try installerForTesting(options.ipaPath, options.udid, bundleID)
        } else {
            try RealDevicePackageInstaller.installIpa(ipaPath: options.ipaPath, udid: options.udid, bundleID: bundleID) { response in
                if options.verbose {
                    responseFrames.append(response)
                }
            }
        }
        let suffix = bundleID.map { " (\($0))" } ?? ""
        return verboseResponsePrefix(responseFrames) + "Installed IPA on \(options.udid)\(suffix)\n"
    }

    static func uninstall(options: AppUninstallOptions) throws -> String {
        var responseFrames: [[String: Any]] = []
        if let uninstallerForTesting {
            try uninstallerForTesting(options.bundleID, options.udid)
        } else {
            try InstallationProxyClient.withClient(udid: options.udid) { client in
                try client.uninstall(bundleID: options.bundleID) { response in
                    if options.verbose {
                        responseFrames.append(response)
                    }
                }
            }
        }
        return verboseResponsePrefix(responseFrames) + "Uninstalled \(options.bundleID) from \(options.udid)\n"
    }

    private static func verboseResponsePrefix(_ frames: [[String: Any]]) -> String {
        guard !frames.isEmpty else { return "" }
        let lines = frames.map { InstallationProxyClient.responseSummary($0) }
        return "installation_proxy responses:\n" + lines.joined(separator: "\n") + "\n"
    }

    static func list(options: AppsOptions) throws -> String {
        let apps: [AppInfo]
        if let appsProviderForTesting {
            apps = try appsProviderForTesting(options.udid, options.includeSystem)
        } else {
            apps = try InstallationProxyClient.withClient(udid: options.udid) { client in
                let raw = try client.browse(
                    includeSystem: options.includeSystem,
                    attributes: ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", "ApplicationType"]
                )
                return raw.compactMap { item in
                    guard let bundleID = item["CFBundleIdentifier"] as? String else { return nil }
                    let displayName = (item["CFBundleDisplayName"] as? String)
                        ?? (item["CFBundleName"] as? String)
                        ?? bundleID
                    return AppInfo(
                        bundleID: bundleID,
                        displayName: displayName,
                        version: item["CFBundleShortVersionString"] as? String ?? "",
                        applicationType: item["ApplicationType"] as? String ?? ""
                    )
                }
            }
        }
        let sorted = apps.sorted { lhs, rhs in
            lhs.bundleID.localizedStandardCompare(rhs.bundleID) == .orderedAscending
        }
        if options.json {
            let rows = sorted.map {
                [
                    "bundleId": $0.bundleID,
                    "name": $0.displayName,
                    "version": $0.version,
                    "applicationType": $0.applicationType,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8)! + "\n"
        }
        guard !sorted.isEmpty else {
            return "No apps found on \(options.udid)\n"
        }
        return sorted.map { app in
            var line = "\(app.bundleID)"
            if !app.displayName.isEmpty, app.displayName != app.bundleID {
                line += " | \(app.displayName)"
            }
            if !app.version.isEmpty {
                line += " | \(app.version)"
            }
            if !app.applicationType.isEmpty {
                line += " | \(app.applicationType)"
            }
            return line
        }.joined(separator: "\n") + "\n"
    }

    static func extractBundleID(ipaPath: String) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-ipa-info-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        _ = try Shell.run("unzip", arguments: ["-q", "-o", ipaPath, "-d", tmpDir])
        let payloadDir = "\(tmpDir)/Payload"
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            throw CLIParseError.invalidValue("No .app found in IPA")
        }
        return try Shell.run("plutil", arguments: ["-extract", "CFBundleIdentifier", "raw", "-o", "-", "\(payloadDir)/\(appEntry)/Info.plist"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
