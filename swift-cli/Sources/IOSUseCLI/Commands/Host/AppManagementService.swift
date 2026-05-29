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

    static func install(options: AppInstallOptions, paths: IOSUsePaths) throws -> String {
        let targetUdid = try resolveRealDeviceTargetUdid(
            explicitUdid: options.udid,
            paths: paths,
            command: "install",
            missingMessage: "install requires --udid or an active driver. Run `ios-use start <UDID>` or pass `--udid <UDID>`."
        )
        guard FileManager.default.fileExists(atPath: options.ipaPath) else {
            throw CLIParseError.invalidValue("IPA not found: \(options.ipaPath)")
        }
        let bundleID = try? extractBundleID(ipaPath: options.ipaPath)
        var responseFrames: [[String: Any]] = []
        do {
            if let installerForTesting {
                try installerForTesting(options.ipaPath, targetUdid, bundleID)
            } else {
                try RealDevicePackageInstaller.installIpa(ipaPath: options.ipaPath, udid: targetUdid, bundleID: bundleID) { response in
                    if options.verbose {
                        responseFrames.append(response)
                    }
                }
            }
        } catch {
            throw errorWithVerboseResponses(error, frames: responseFrames, verbose: options.verbose)
        }
        let suffix = bundleID.map { " (\($0))" } ?? ""
        return verboseResponsePrefix(responseFrames) + "Installed IPA on \(targetUdid)\(suffix)\n"
    }

    static func uninstall(options: AppUninstallOptions, paths: IOSUsePaths) throws -> String {
        let targetUdid = try resolveRealDeviceTargetUdid(
            explicitUdid: options.udid,
            paths: paths,
            command: "uninstall",
            missingMessage: "uninstall requires --udid or an active driver. Run `ios-use start <UDID>` or pass `--udid <UDID>`."
        )
        var responseFrames: [[String: Any]] = []
        do {
            if let uninstallerForTesting {
                try uninstallerForTesting(options.bundleID, targetUdid)
            } else {
                try InstallationProxyClient.withClient(udid: targetUdid) { client in
                    try client.uninstall(bundleID: options.bundleID) { response in
                        if options.verbose {
                            responseFrames.append(response)
                        }
                    }
                }
            }
        } catch {
            throw errorWithVerboseResponses(error, frames: responseFrames, verbose: options.verbose)
        }
        return verboseResponsePrefix(responseFrames) + "Uninstalled \(options.bundleID) from \(targetUdid)\n"
    }

    private static func verboseResponsePrefix(_ frames: [[String: Any]]) -> String {
        guard !frames.isEmpty else { return "" }
        let lines = frames.map { InstallationProxyClient.responseSummary($0) }
        return "installation_proxy responses:\n" + lines.joined(separator: "\n") + "\n"
    }

    private static func errorWithVerboseResponses(_ error: Error, frames: [[String: Any]], verbose: Bool) -> Error {
        guard verbose, !frames.isEmpty else { return error }
        return CLIParseError.invalidValue(verboseResponsePrefix(frames) + "\(error)")
    }

    static func list(options: AppsOptions, paths: IOSUsePaths) throws -> String {
        let targetUdid = try resolveRealDeviceTargetUdid(
            explicitUdid: options.udid,
            paths: paths,
            command: "apps",
            missingMessage: "apps requires --udid or an active driver. Run `ios-use start <UDID>` or pass `--udid <UDID>`."
        )
        let apps: [AppInfo]
        if let appsProviderForTesting {
            apps = try appsProviderForTesting(targetUdid, options.includeSystem)
        } else {
            apps = try InstallationProxyClient.withClient(udid: targetUdid) { client in
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
            return "No apps found on \(targetUdid)\n"
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

    private static func resolveRealDeviceTargetUdid(
        explicitUdid: String?,
        paths: IOSUsePaths,
        command: String,
        missingMessage: String
    ) throws -> String {
        let targetUdid = try SessionService.resolveTargetUdid(
            explicitUdid: explicitUdid,
            paths: paths,
            missingMessage: missingMessage
        )
        if let explicitUdid, !explicitUdid.isEmpty {
            if DeviceService.looksLikeSimulatorUDID(targetUdid) {
                throw CLIParseError.invalidValue("\(command) supports USB real devices only; Simulator app management is not implemented.")
            }
            return targetUdid
        }
        guard let current = SessionService.read(paths: paths),
              current.udid == targetUdid,
              current.deviceType == "real" else {
            throw CLIParseError.invalidValue("\(command) supports USB real devices only. Pass a real device --udid or start a real device.")
        }
        return targetUdid
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
