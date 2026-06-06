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
    static var packagePathPrefix = "PublicStaging/ios-use"

    static func installedVersion(udid: String, bundleID: String) throws -> String? {
        try InstallationProxyClient.withClient(udid: udid) { client in
            try client.installedAppInfo(
                bundleID: bundleID,
                attributes: ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]
            )?["CFBundleShortVersionString"] as? String
        }
    }

    static func installIpa(ipaPath: String, udid: String, bundleID: String?, developer: Bool = false, responseObserver: (([String: Any]) -> Void)? = nil) throws {
        let expectedVersion = ConfigService.driverIPAVersion(at: ipaPath)
        let remoteName = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "\(UUID().uuidString).ipa"
        let remotePath = "\(packagePathPrefix)/\(remoteName)"
        let packagePath = installationProxyPackagePath(forAfcPath: remotePath)
        try AfcClient.withClient(udid: udid) { afc in
            try? afc.removePath(remotePath)
            try afc.uploadFile(localPath: ipaPath, remotePath: remotePath)
            defer {
                try? afc.removePath(remotePath)
            }

            try InstallationProxyClient.withClient(udid: udid) { client in
                try client.install(packagePath: packagePath, bundleID: bundleID, developer: developer, responseObserver: responseObserver)
            }
        }

        if let bundleID, !bundleID.isEmpty {
            let response = try InstallationProxyClient.withClient(udid: udid) { client in
                try client.lookup(attributes: ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"], bundleIDs: [bundleID])
            }
            try validateInstalledApp(response: response, bundleID: bundleID, expectedVersion: expectedVersion)
        }
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
            try installIpa(ipaPath: packagePath, udid: udid, bundleID: bundleID, responseObserver: responseObserver)
        case .app:
            try withTemporaryIpaFromApp(appPath: packagePath) { ipaPath in
                try installIpa(ipaPath: ipaPath, udid: udid, bundleID: bundleID, responseObserver: responseObserver)
            }
        }
    }

    static func withTemporaryIpaFromApp<T>(appPath: String, _ body: (String) throws -> T) throws -> T {
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-app-ipa-\(UUID().uuidString)", isDirectory: true)
        let payloadURL = tmpURL.appendingPathComponent("Payload", isDirectory: true)
        let stagedAppURL = payloadURL.appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
        let ipaURL = tmpURL.appendingPathComponent("app.ipa")
        try FileManager.default.createDirectory(at: payloadURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: appURL, to: stagedAppURL)
        _ = try Shell.run("zip", arguments: ["-qry", ipaURL.path, "Payload"], cwd: tmpURL.path)
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        return try body(ipaURL.path)
    }

    static func installationProxyPackagePath(forAfcPath path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    static func validateInstalledApp(response: [String: Any], bundleID: String, expectedVersion: String?) throws {
        guard let app = InstallationProxyClient.installedAppInfo(response: response, bundleID: bundleID) else {
            throw InstallationProxyError.installFailed("installed app \(bundleID) was not found by installation_proxy Lookup; response: \(InstallationProxyClient.responseSummary(response))")
        }
        guard let expectedVersion, !expectedVersion.isEmpty else { return }
        guard let installedVersion = app["CFBundleShortVersionString"] as? String, !installedVersion.isEmpty else {
            throw InstallationProxyError.installFailed("installed app \(bundleID) did not report CFBundleShortVersionString; response: \(InstallationProxyClient.responseSummary(response))")
        }
        guard installedVersion == expectedVersion else {
            throw InstallationProxyError.installFailed("installed app \(bundleID) version \(installedVersion) does not match IPA version \(expectedVersion); response: \(InstallationProxyClient.responseSummary(response))")
        }
    }

}
