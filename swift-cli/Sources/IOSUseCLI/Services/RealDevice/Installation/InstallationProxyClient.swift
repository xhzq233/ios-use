import Foundation
import IOSUseProtocol

enum InstallationProxyError: Error, CustomStringConvertible, Equatable {
    case invalidResponseSize(Int)
    case commandFailed(String)
    case installFailed(String)

    var description: String {
        switch self {
        case .invalidResponseSize(let size): return "installation_proxy invalid response size: \(size)"
        case .commandFailed(let message): return "installation_proxy command failed: \(message)"
        case .installFailed(let message): return "App install failed: \(message)"
        }
    }
}

final class InstallationProxyClient {
    private let stream: DeviceStream

    init(stream: DeviceStream) {
        self.stream = stream
    }

    static func withClient<T>(udid: String, _ body: (InstallationProxyClient) throws -> T) throws -> T {
        let stream = try LockdownSession.connectToService(IOSUseProtocol.XCConstants.installationProxyServiceName, udid: udid)
        defer { stream.close() }
        return try body(InstallationProxyClient(stream: stream))
    }

    func lookup(attributes: [String] = [], bundleIDs: [String]? = nil) throws -> [String: Any] {
        var options: [String: Any] = ["ApplicationType": "Any"]
        if !attributes.isEmpty {
            options["ReturnAttributes"] = attributes
        }
        var body: [String: Any] = [
            "Command": "Lookup",
            "ClientOptions": options,
        ]
        if let bundleIDs, !bundleIDs.isEmpty {
            body["BundleIDs"] = bundleIDs
        }
        return try sendPlist(body)
    }

    func browse(includeSystem: Bool, attributes: [String]) throws -> [[String: Any]] {
        var options: [String: Any] = [
            "ApplicationType": includeSystem ? "Any" : "User",
        ]
        if !attributes.isEmpty {
            options["ReturnAttributes"] = attributes
        }
        try sendPlistWithoutResponse([
            "Command": "Browse",
            "ClientOptions": options,
        ])

        var result: [[String: Any]] = []
        while true {
            let response = try readPlistFrame(timeoutSeconds: IOSUseProtocol.XCConstants.installationProxyProgressTimeoutSeconds)
            if let currentList = response["CurrentList"] as? [[String: Any]] {
                result.append(contentsOf: currentList)
            }
            if let lookupResult = response["LookupResult"] as? [String: [String: Any]] {
                result.append(contentsOf: lookupResult.values)
            }
            guard let status = response["Status"] as? String else {
                return result
            }
            if status == "Complete" {
                return result
            }
        }
    }

    func install(packagePath: String, bundleID: String? = nil, developer: Bool = false, responseObserver: (([String: Any]) -> Void)? = nil) throws {
        var options: [String: Any] = [:]
        if developer {
            options["PackageType"] = "Developer"
        }
        if let bundleID, !bundleID.isEmpty {
            options["CFBundleIdentifier"] = bundleID
        }
        try install(packagePath: packagePath, clientOptions: options, responseObserver: responseObserver)
    }

    func install(packagePath: String, clientOptions options: [String: Any], responseObserver: (([String: Any]) -> Void)? = nil) throws {
        try runProgressCommand([
            "Command": "Install",
            "PackagePath": packagePath,
            "ClientOptions": options,
        ], responseObserver: responseObserver)
    }

    func uninstall(bundleID: String, responseObserver: (([String: Any]) -> Void)? = nil) throws {
        try runProgressCommand([
            "Command": "Uninstall",
            "ApplicationIdentifier": bundleID,
        ], responseObserver: responseObserver)
    }

    func installedAppInfo(bundleID: String, attributes: [String]) throws -> [String: Any]? {
        let response = try lookup(attributes: attributes, bundleIDs: [bundleID])
        return Self.installedAppInfo(response: response, bundleID: bundleID)
    }

    @discardableResult
    func sendPlist(_ body: [String: Any], timeoutSeconds: Double = IOSUseProtocol.XCConstants.installationProxyDefaultTimeoutSeconds) throws -> [String: Any] {
        try sendPlistWithoutResponse(body)
        return try readPlistFrame(timeoutSeconds: timeoutSeconds)
    }

    private func sendPlistWithoutResponse(_ body: [String: Any]) throws {
        let xml = try serializePlist(body)
        try stream.write(uint32BE(UInt32(xml.count)) + xml)
    }

    private func readPlistFrame(timeoutSeconds: Double) throws -> [String: Any] {
        let response = try readRawPlistFrame(timeoutSeconds: timeoutSeconds)
        if let error = response["Error"] {
            let description = response["ErrorDescription"].map { String(describing: $0) } ?? String(describing: error)
            throw InstallationProxyError.commandFailed("\(description); response: \(Self.responseSummary(response))")
        }
        return response
    }

    private func readRawPlistFrame(timeoutSeconds: Double) throws -> [String: Any] {
        let header = try stream.readExact(
            byteCount: IOSUseProtocol.XCConstants.installationProxyFrameHeaderByteCount,
            timeoutSeconds: timeoutSeconds
        )
        let size = Int(readUInt32BE(header, 0))
        guard size > 0, size <= IOSUseProtocol.XCConstants.installationProxyMaxResponseBytes else {
            throw InstallationProxyError.invalidResponseSize(size)
        }
        return try parsePlist(try stream.readExact(byteCount: size, timeoutSeconds: timeoutSeconds))
    }

    private func runProgressCommand(_ body: [String: Any], responseObserver: (([String: Any]) -> Void)? = nil) throws {
        try sendPlistWithoutResponse(body)
        while true {
            let response = try readRawPlistFrame(timeoutSeconds: IOSUseProtocol.XCConstants.installationProxyProgressTimeoutSeconds)
            responseObserver?(response)
            if let error = response["Error"] {
                let description = response["ErrorDescription"].map { String(describing: $0) } ?? String(describing: error)
                throw InstallationProxyError.installFailed("\(description); response: \(Self.responseSummary(response))")
            }
            let status = response["Status"] as? String
            if status == "Complete" {
                return
            }
        }
    }

    static func installedAppInfo(response: [String: Any], bundleID: String) -> [String: Any]? {
        guard let lookup = response["LookupResult"] as? [String: Any] else {
            return nil
        }
        return lookup[bundleID] as? [String: Any]
    }

    static func responseSummary(_ response: [String: Any]) -> String {
        if JSONSerialization.isValidJSONObject(response),
           let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: response)
    }
}

enum RealDevicePackageInstaller {
    enum UploadMode: Equatable {
        case file
        case directory
    }

    struct PreparedInstallPackage {
        let localPath: String
        let remotePath: String
        let packagePath: String
        let bundleID: String
        let expectedVersion: AppVersionInfo
        let clientOptions: [String: Any]
        let uploadMode: UploadMode
        let packageKind: AppManagementService.AppPackageKind
    }

    static var packagePathPrefix = "PublicStaging"
    static var preparedPackageInstallerForTesting: ((PreparedInstallPackage, String, (([String: Any]) -> Void)?) throws -> Void)?
    static var nativePackageInstallerForTesting: ((PreparedInstallPackage, String, (([String: Any]) -> Void)?) throws -> Void)?
    static var installedAppLookupForTesting: ((String, String) throws -> [String: Any])?
    static var devicectlRunnerForTesting: (([String]) throws -> Shell.RunResult)?

    static func installedVersion(udid: String, bundleID: String) throws -> String? {
        try InstallationProxyClient.withClient(udid: udid) { client in
            try client.installedAppInfo(
                bundleID: bundleID,
                attributes: ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]
            )?["CFBundleShortVersionString"] as? String
        }
    }

    private static func installedAppVersionInfo(udid: String, bundleID: String) throws -> AppVersionInfo? {
        try InstallationProxyClient.withClient(udid: udid) { client in
            guard let info = try client.installedAppInfo(
                bundleID: bundleID,
                attributes: ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]
            ) else {
                return nil
            }
            return AppVersionInfo(
                bundleVersion: info["CFBundleVersion"] as? String,
                shortVersion: info["CFBundleShortVersionString"] as? String
            )
        }
    }

    static func installIpa(
        ipaPath: String,
        udid: String,
        bundleID: String?,
        developer _: Bool = false,
        preferDevicectl: Bool = true,
        responseObserver: (([String: Any]) -> Void)? = nil
    ) throws {
        let package = try preparedIpaPackage(ipaPath: ipaPath, explicitBundleID: bundleID)
        try installPreparedPackage(package, udid: udid, preferDevicectl: preferDevicectl, responseObserver: responseObserver)
    }

    static func installPackage(
        packagePath: String,
        kind: AppManagementService.AppPackageKind,
        udid: String,
        bundleID: String?,
        responseObserver: (([String: Any]) -> Void)? = nil
    ) throws {
        switch kind {
        case .ipa:
            try installPreparedPackage(
                try preparedIpaPackage(ipaPath: packagePath, explicitBundleID: bundleID),
                udid: udid,
                responseObserver: responseObserver
            )
        case .app:
            try installPreparedPackage(
                try preparedAppPackage(appPath: packagePath, explicitBundleID: bundleID),
                udid: udid,
                responseObserver: responseObserver
            )
        }
    }

    private static func installPreparedPackage(
        _ package: PreparedInstallPackage,
        udid: String,
        preferDevicectl: Bool = true,
        responseObserver: (([String: Any]) -> Void)? = nil
    ) throws {
        if let preparedPackageInstallerForTesting {
            try preparedPackageInstallerForTesting(package, udid, responseObserver)
            return
        }
        if preferDevicectl, try installWithDevicectlIfAvailable(package, udid: udid) {
            return
        }
        if let nativePackageInstallerForTesting {
            try nativePackageInstallerForTesting(package, udid, responseObserver)
            try validateInstalledPackage(package, udid: udid)
            return
        }
        try AfcClient.withClient(udid: udid) { afc in
            try afc.makeDirectories(packagePathPrefix)
            try? afc.removePathRecursive(package.remotePath)
            switch package.uploadMode {
            case .file:
                try afc.uploadFile(localPath: package.localPath, remotePath: package.remotePath)
            case .directory:
                try afc.uploadDirectory(localPath: package.localPath, remotePath: package.remotePath)
            }
            defer {
                try? afc.removePathRecursive(package.remotePath)
            }
            try InstallationProxyClient.withClient(udid: udid) { client in
                try client.install(packagePath: package.packagePath, clientOptions: package.clientOptions, responseObserver: responseObserver)
            }
        }

        try validateInstalledPackage(package, udid: udid)
    }

    static func preparedAppPackage(appPath: String, explicitBundleID: String? = nil) throws -> PreparedInstallPackage {
        let metadata = try appMetadataOrThrow(appPath: appPath, fallbackBundleID: explicitBundleID)
        try validateExplicitBundleID(explicitBundleID, actual: metadata.bundleID)
        let remotePath = "\(packagePathPrefix)/\(URL(fileURLWithPath: appPath, isDirectory: true).lastPathComponent)"
        return PreparedInstallPackage(
            localPath: appPath,
            remotePath: remotePath,
            packagePath: installationProxyPackagePath(forAfcPath: remotePath),
            bundleID: metadata.bundleID,
            expectedVersion: metadata.versionInfo,
            clientOptions: ["PackageType": "Developer"],
            uploadMode: .directory,
            packageKind: .app
        )
    }

    static func preparedIpaPackage(ipaPath: String, explicitBundleID: String? = nil) throws -> PreparedInstallPackage {
        let metadata = try ipaMetadata(ipaPath: ipaPath)
        try validateExplicitBundleID(explicitBundleID, actual: metadata.bundleID)
        let remotePath = "\(packagePathPrefix)/\(metadata.bundleID)"
        var options: [String: Any] = ["CFBundleIdentifier": metadata.bundleID]
        if let sinf = metadata.applicationSINF {
            options["ApplicationSINF"] = sinf
        }
        if let iTunesMetadata = metadata.iTunesMetadata {
            options["iTunesMetadata"] = iTunesMetadata
        }
        return PreparedInstallPackage(
            localPath: ipaPath,
            remotePath: remotePath,
            packagePath: installationProxyPackagePath(forAfcPath: remotePath),
            bundleID: metadata.bundleID,
            expectedVersion: metadata.versionInfo,
            clientOptions: options,
            uploadMode: .file,
            packageKind: .ipa
        )
    }

    private static func installWithDevicectlIfAvailable(_ package: PreparedInstallPackage, udid: String) throws -> Bool {
        let result: Shell.RunResult
        do {
            result = try runDevicectl(["devicectl", "device", "install", "app", "--device", udid, package.localPath])
        } catch {
            return false
        }
        if result.exitCode == 0 {
            try validateInstalledPackage(package, udid: udid)
            return true
        }
        let output = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if devicectlErrorAllowsFallback(output, exitCode: result.exitCode, packageKind: package.packageKind) {
            return false
        }
        throw InstallationProxyError.installFailed("devicectl install failed: \(output.isEmpty ? "exit \(result.exitCode)" : output)")
    }

    private static func runDevicectl(_ arguments: [String]) throws -> Shell.RunResult {
        if let devicectlRunnerForTesting {
            return try devicectlRunnerForTesting(arguments)
        }
        return try Shell.runWithResult("xcrun", arguments: arguments)
    }

    private static func devicectlErrorAllowsFallback(_ output: String, exitCode: Int32, packageKind: AppManagementService.AppPackageKind) -> Bool {
        let lowercased = output.lowercased()
        let packageValidationError = lowercased.contains("provision")
            || lowercased.contains("entitlement")
            || lowercased.contains("signature")
            || lowercased.contains("verification")
            || lowercased.contains("applicationverificationfailed")
            || lowercased.contains("bundle identifier")
        if packageValidationError {
            return false
        }

        let ipaUnsupportedByDevicectl = packageKind == .ipa && (
            lowercased.contains("unsupported")
                || lowercased.contains("not supported")
                || lowercased.contains("invalid package")
                || lowercased.contains("expected .app")
                || lowercased.contains("app bundle")
        )
        let devicectlToolUnavailable = exitCode == 127
            || lowercased.contains("unable to find utility")
            || lowercased.contains("command not found")
            || lowercased.contains("no such file or directory")
        let devicectlDeviceUnavailable = lowercased.contains("device not found")
            || lowercased.contains("unable to find device")
            || lowercased.contains("no device")
        let devicectlEnvironmentUnavailable = lowercased.contains("developer disk image")
            || lowercased.contains("ddi")
            || lowercased.contains("device support")
        return ipaUnsupportedByDevicectl
            || devicectlToolUnavailable
            || devicectlDeviceUnavailable
            || devicectlEnvironmentUnavailable
    }

    private static func validateInstalledPackage(_ package: PreparedInstallPackage, udid: String) throws {
        let response: [String: Any]
        if let installedAppLookupForTesting {
            response = try installedAppLookupForTesting(udid, package.bundleID)
        } else {
            response = try InstallationProxyClient.withClient(udid: udid) { client in
                try client.lookup(attributes: ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"], bundleIDs: [package.bundleID])
            }
        }
        try validateInstalledApp(response: response, bundleID: package.bundleID, expectedVersion: package.expectedVersion)
    }

    static func installationProxyPackagePath(forAfcPath path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    private static func appMetadataOrThrow(appPath: String, fallbackBundleID: String? = nil) throws -> AppBundleMetadata {
        guard let metadata = appMetadata(appPath: appPath, fallbackBundleID: fallbackBundleID) else {
            throw CLIParseError.invalidValue("No CFBundleIdentifier found in \(appPath)/Info.plist")
        }
        return metadata
    }

    static func appMetadata(appPath: String, fallbackBundleID: String? = nil) -> AppBundleMetadata? {
        let infoPath = "\(appPath)/Info.plist"
        let bundleID = plistString(infoPath: infoPath, key: "CFBundleIdentifier") ?? fallbackBundleID
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return AppBundleMetadata(
            bundleID: bundleID,
            versionInfo: AppVersionInfo(
                bundleVersion: plistString(infoPath: infoPath, key: "CFBundleVersion"),
                shortVersion: plistString(infoPath: infoPath, key: "CFBundleShortVersionString")
            )
        )
    }

    private static func ipaMetadata(ipaPath: String) throws -> IpaInstallMetadata {
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
        let infoData = try zipEntryData(archivePath: ipaPath, entry: infoEntry)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] else {
            throw CLIParseError.invalidValue("Invalid Info.plist in IPA at \(infoEntry)")
        }
        guard let bundleID = (info["CFBundleIdentifier"] as? String)?.nonEmpty else {
            throw CLIParseError.invalidValue("No CFBundleIdentifier found in IPA Info.plist")
        }
        guard let executable = (info["CFBundleExecutable"] as? String)?.nonEmpty else {
            throw CLIParseError.invalidValue("No CFBundleExecutable found in IPA Info.plist")
        }

        let appRoot = String(infoEntry.dropLast("Info.plist".count))
        let sinfEntry = "\(appRoot)SC_Info/\(executable).sinf"
        let metadataEntry = "iTunesMetadata.plist"
        return IpaInstallMetadata(
            bundleID: bundleID,
            versionInfo: AppVersionInfo(
                bundleVersion: info["CFBundleVersion"] as? String,
                shortVersion: info["CFBundleShortVersionString"] as? String
            ),
            applicationSINF: entries.contains(sinfEntry) ? try zipEntryData(archivePath: ipaPath, entry: sinfEntry) : nil,
            iTunesMetadata: entries.contains(metadataEntry) ? try zipEntryData(archivePath: ipaPath, entry: metadataEntry) : nil
        )
    }

    private static func zipEntryData(archivePath: String, entry: String) throws -> Data {
        try Shell.runData("unzip", arguments: ["-p", archivePath, entry])
    }

    private static func validateExplicitBundleID(_ explicitBundleID: String?, actual: String) throws {
        guard let explicitBundleID = explicitBundleID?.nonEmpty else { return }
        guard explicitBundleID == actual else {
            throw InstallationProxyError.installFailed("package bundle id \(actual) does not match requested bundle id \(explicitBundleID)")
        }
    }

    private static func plistString(infoPath: String, key: String) -> String? {
        let value = try? Shell.run("plutil", arguments: ["-extract", key, "raw", "-o", "-", infoPath])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func sparseInstallCommands(bundleID: String, sourceVersion: AppVersionInfo, targetVersion: AppVersionInfo) -> Data {
        let source = sourceVersion.manifestVersionString
        let target = targetVersion.manifestVersionString
        let text = """
        ipaD
        1
        \(source)
        +Info.plist
        +_CodeSignature/CodeResources
        xEOF
        #CreateSparseIPA UUID: \(UUID().uuidString)
        #Bundle id: \(bundleID)
        #Old bundle version: \(source)
        #New bundle version: \(target)

        """
        return Data(text.utf8)
    }

    static func validateInstalledApp(response: [String: Any], bundleID: String, expectedVersion: AppVersionInfo) throws {
        guard let app = InstallationProxyClient.installedAppInfo(response: response, bundleID: bundleID) else {
            throw InstallationProxyError.installFailed("installed app \(bundleID) was not found by installation_proxy Lookup; response: \(InstallationProxyClient.responseSummary(response))")
        }
        guard let installedBundleID = app["CFBundleIdentifier"] as? String, installedBundleID == bundleID else {
            throw InstallationProxyError.installFailed("installed app bundle id \(String(describing: app["CFBundleIdentifier"])) does not match expected \(bundleID); response: \(InstallationProxyClient.responseSummary(response))")
        }
        if let expectedShortVersion = expectedVersion.shortVersion?.nonEmpty {
            guard let installedVersion = app["CFBundleShortVersionString"] as? String, !installedVersion.isEmpty else {
                throw InstallationProxyError.installFailed("installed app \(bundleID) did not report CFBundleShortVersionString; response: \(InstallationProxyClient.responseSummary(response))")
            }
            guard installedVersion == expectedShortVersion else {
                throw InstallationProxyError.installFailed("installed app \(bundleID) short version \(installedVersion) does not match expected \(expectedShortVersion); response: \(InstallationProxyClient.responseSummary(response))")
            }
        }
        if let expectedBuildVersion = expectedVersion.bundleVersion?.nonEmpty {
            guard let installedBuildVersion = app["CFBundleVersion"] as? String, !installedBuildVersion.isEmpty else {
                throw InstallationProxyError.installFailed("installed app \(bundleID) did not report CFBundleVersion; response: \(InstallationProxyClient.responseSummary(response))")
            }
            guard installedBuildVersion == expectedBuildVersion else {
                throw InstallationProxyError.installFailed("installed app \(bundleID) build version \(installedBuildVersion) does not match expected \(expectedBuildVersion); response: \(InstallationProxyClient.responseSummary(response))")
            }
        }
    }

    static func validateInstalledApp(response: [String: Any], bundleID: String, expectedVersion: String?) throws {
        try validateInstalledApp(
            response: response,
            bundleID: bundleID,
            expectedVersion: AppVersionInfo(bundleVersion: nil, shortVersion: expectedVersion)
        )
    }

}

private struct IpaInstallMetadata {
    let bundleID: String
    let versionInfo: AppVersionInfo
    let applicationSINF: Data?
    let iTunesMetadata: Data?
}

struct AppBundleMetadata: Equatable {
    let bundleID: String
    let versionInfo: AppVersionInfo
}

struct AppVersionInfo: Equatable {
    let bundleVersion: String?
    let shortVersion: String?

    var manifestVersionString: String {
        [bundleVersion, shortVersion]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func matches(_ other: AppVersionInfo) -> Bool {
        bundleVersion == other.bundleVersion && shortVersion == other.shortVersion
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
