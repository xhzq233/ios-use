import Foundation

enum AppManagementService {
    struct AppInfo: Equatable {
        let bundleID: String
        let displayName: String
        let version: String
        let applicationType: String
    }

    struct InstallReceipt: Equatable {
        let sourcePath: String
        let packageKind: AppPackageKind
        let deviceUdid: String
        let bundleId: String
        let version: String?
        let build: String?
        let installer: RealDevicePackageInstaller.InstallerRoute
        let verifiedOnDevice: Bool
        let elapsed: Double
    }

    struct InstallCommandResult {
        let receipt: InstallReceipt
        let installerResponses: [String]
    }

    struct AppListResult {
        let deviceUdid: String
        let apps: [AppInfo]
    }

    static var installerForTesting: ((String, String, String?) throws -> RealDevicePackageInstaller.InstallResult)?
    static var uninstallerForTesting: ((String, String) throws -> Void)?
    static var appsProviderForTesting: ((String, Bool) throws -> [AppInfo])?

    static func install(options: AppInstallOptions, paths: IOSUsePaths) throws -> String {
        let result = try installResult(options: options, paths: paths)
        return formatInstallResult(result, verbose: options.verbose)
    }

    static func installResult(options: AppInstallOptions, paths: IOSUsePaths) throws -> InstallCommandResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let packageKind = try AppPackageKind(path: options.ipaPath)
        let targetUdid = try resolveRealDeviceTargetUdid(
            explicitUdid: options.udid,
            paths: paths,
            command: "install",
            missingMessage: "install requires --udid or an active driver. Run `ios-use start` or pass `--udid <UDID>`."
        )
        guard FileManager.default.fileExists(atPath: options.ipaPath) else {
            throw CLIParseError.invalidValue("App package not found: \(options.ipaPath)")
        }
        let bundleID = try? extractBundleID(packagePath: options.ipaPath, kind: packageKind)
        var responseFrames: [[String: Any]] = []
        do {
            if let bundleID, !bundleID.isEmpty {
                try AppLogCaptureService.stopCaptureForInstall(bundleID: bundleID, udid: targetUdid, paths: paths)
            }
            let installed: RealDevicePackageInstaller.InstallResult
            if let installerForTesting {
                installed = try installerForTesting(options.ipaPath, targetUdid, bundleID)
            } else {
                installed = try RealDevicePackageInstaller.installPackageWithResult(packagePath: options.ipaPath, kind: packageKind, udid: targetUdid, bundleID: bundleID) { response in
                    if options.verbose {
                        responseFrames.append(response)
                    }
                }
            }
            let receipt = InstallReceipt(
                sourcePath: URL(fileURLWithPath: options.ipaPath).standardizedFileURL.path,
                packageKind: packageKind,
                deviceUdid: targetUdid,
                bundleId: installed.bundleID,
                version: installed.installedVersion.shortVersion,
                build: installed.installedVersion.bundleVersion,
                installer: installed.installer,
                verifiedOnDevice: true,
                elapsed: ((CFAbsoluteTimeGetCurrent() - startedAt) * 10_000).rounded() / 10_000
            )
            return InstallCommandResult(
                receipt: receipt,
                installerResponses: responseFrames.map(InstallationProxyClient.responseSummary)
            )
        } catch {
            throw errorWithVerboseResponses(error, frames: responseFrames, verbose: options.verbose)
        }
    }

    static func formatInstallResult(_ result: InstallCommandResult, verbose: Bool) -> String {
        let receipt = result.receipt
        let version = receipt.version.flatMap { $0.isEmpty ? nil : $0 }
        let build = receipt.build.flatMap { $0.isEmpty ? nil : $0 }
        let identity: String
        switch (version, build) {
        case (.some(let version), .some(let build)):
            identity = "\(receipt.bundleId) \(version) (\(build))"
        case (.some(let version), nil):
            identity = "\(receipt.bundleId) \(version) (build unknown)"
        case (nil, .some(let build)):
            identity = "\(receipt.bundleId) (version unknown) (\(build))"
        case (nil, nil):
            identity = "\(receipt.bundleId) (version/build unknown)"
        }
        var output = ""
        if verbose, !result.installerResponses.isEmpty {
            output += "installer responses:\n" + result.installerResponses.joined(separator: "\n") + "\n"
        }
        output += "Installed \(identity) on \(receipt.deviceUdid)\n"
        output += "Package: \(receipt.packageKind.machineName) via \(receipt.installer.rawValue)\n"
        output += "Verified: device lookup matched\n"
        output += String(format: "Elapsed: %.4fs\n", locale: Locale(identifier: "en_US_POSIX"), receipt.elapsed)
        return output
    }

    static func machineInstallData(_ result: InstallCommandResult) -> MachineValue {
        let receipt = result.receipt
        return .object([
            "sourcePath": .string(receipt.sourcePath),
            "packageKind": .string(receipt.packageKind.machineName),
            "deviceUdid": .string(receipt.deviceUdid),
            "bundleId": .string(receipt.bundleId),
            "version": receipt.version.map(MachineValue.string) ?? .null,
            "build": receipt.build.map(MachineValue.string) ?? .null,
            "installer": .string(receipt.installer.rawValue),
            "verifiedOnDevice": .boolean(receipt.verifiedOnDevice),
            "elapsed": .double(receipt.elapsed),
            "installerResponses": .array(result.installerResponses.map(MachineValue.string)),
        ])
    }

    static func uninstall(options: AppUninstallOptions, paths: IOSUsePaths) throws -> String {
        let targetUdid = try resolveRealDeviceTargetUdid(
            explicitUdid: options.udid,
            paths: paths,
            command: "uninstall",
            missingMessage: "uninstall requires --udid or an active driver. Run `ios-use start` or pass `--udid <UDID>`."
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
        return "installer responses:\n" + lines.joined(separator: "\n") + "\n"
    }

    private static func errorWithVerboseResponses(_ error: Error, frames: [[String: Any]], verbose: Bool) -> Error {
        guard verbose, !frames.isEmpty else { return error }
        return CLIParseError.invalidValue(verboseResponsePrefix(frames) + "\(error)")
    }

    static func list(options: AppsOptions, paths: IOSUsePaths) throws -> String {
        let result = try listResult(options: options, paths: paths)
        return try formatListResult(result, json: options.json)
    }

    static func listResult(options: AppsOptions, paths: IOSUsePaths) throws -> AppListResult {
        let targetUdid = try resolveRealDeviceTargetUdid(
            explicitUdid: options.udid,
            paths: paths,
            command: "apps",
            missingMessage: "apps requires --udid or an active driver. Run `ios-use start` or pass `--udid <UDID>`."
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
        return AppListResult(deviceUdid: targetUdid, apps: sorted)
    }

    static func formatListResult(_ result: AppListResult, json: Bool) throws -> String {
        if json {
            let rows = result.apps.map {
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
        guard !result.apps.isEmpty else {
            return "No apps found on \(result.deviceUdid)\n"
        }
        return result.apps.map { app in
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

    static func machineAppsData(_ result: AppListResult) -> MachineValue {
        .object([
            "deviceUdid": .string(result.deviceUdid),
            "apps": .array(result.apps.map { app in
                .object([
                    "bundleId": .string(app.bundleID),
                    "name": .string(app.displayName),
                    "version": .string(app.version),
                    "applicationType": .string(app.applicationType),
                ])
            }),
        ])
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

    enum AppPackageKind: Equatable {
        case ipa
        case app

        init(path: String) throws {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            switch ext {
            case "ipa": self = .ipa
            case "app": self = .app
            default:
                throw CLIParseError.invalidValue("install supports .ipa and .app packages only: \(path)")
            }
        }

        var displayName: String {
            switch self {
            case .ipa: return "IPA"
            case .app: return "app"
            }
        }

        var machineName: String {
            switch self {
            case .ipa: return "ipa"
            case .app: return "app"
            }
        }
    }

    static func extractBundleID(packagePath: String, kind: AppPackageKind) throws -> String {
        switch kind {
        case .ipa:
            return try extractBundleIDFromIpa(ipaPath: packagePath)
        case .app:
            return try extractBundleIDFromApp(appPath: packagePath)
        }
    }

    private static func extractBundleIDFromIpa(ipaPath: String) throws -> String {
        let entries = try Shell.run("unzip", arguments: ["-Z1", ipaPath])
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let infoEntry = entries.first(where: { entry in
            entry.hasPrefix("Payload/")
                && entry.hasSuffix(".app/Info.plist")
                && entry.dropFirst("Payload/".count).split(separator: "/").count == 2
        }) else {
            throw CLIParseError.invalidValue("No Payload/*.app/Info.plist found in IPA")
        }
        let infoData = try Shell.runData("unzip", arguments: ["-p", ipaPath, infoEntry])
        guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty else {
            throw CLIParseError.invalidValue("No CFBundleIdentifier found in IPA Info.plist")
        }
        return bundleID
    }

    private static func extractBundleIDFromApp(appPath: String) throws -> String {
        try Shell.run("plutil", arguments: ["-extract", "CFBundleIdentifier", "raw", "-o", "-", "\(appPath)/Info.plist"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
