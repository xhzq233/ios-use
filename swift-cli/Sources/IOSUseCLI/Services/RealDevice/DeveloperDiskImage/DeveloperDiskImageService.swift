import CryptoKit
import Foundation

enum DeveloperDiskImageError: Error, CustomStringConvertible, Equatable {
    case notFound([String])
    case invalidPath(String)
    case commandFailed(String)
    case missingBuildIdentity(boardID: Int, chipID: Int)
    case missingManifestEntry(String)
    case missingTSSField(String)

    var description: String {
        switch self {
        case .notFound(let searched):
            return "Developer Disk Image not found. Pass `--path <Restore|iOS_DDI|iOS_DDI.dmg>` or install/update host DDIs. Searched: \(searched.joined(separator: ", "))"
        case .invalidPath(let path):
            return "Invalid Developer Disk Image path: \(path)"
        case .commandFailed(let message):
            return message
        case .missingBuildIdentity(let boardID, let chipID):
            return "DDI BuildManifest has no identity for BoardId \(boardID), ChipID \(chipID)"
        case .missingManifestEntry(let name):
            return "DDI BuildManifest missing \(name)"
        case .missingTSSField(let name):
            return "Apple TSS response missing \(name)"
        }
    }
}

struct ResolvedDeveloperDiskImage {
    let restoreURL: URL
    let buildManifestURL: URL
    let imageURL: URL
    let trustCacheURL: URL
    let sourceDescription: String
    let cleanup: () -> Void
}

enum DeveloperDiskImageResolver {
    static let defaultSearchPaths = [
        "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore",
        "/Library/Developer/DeveloperDiskImages/iOS_DDI.dmg",
        "/Library/Developer/CoreDevice/CandidateDDIs/iOS_DDI.dmg",
        "/Library/Developer/CoreDevice/CandidateDDIs/iOS",
        "~/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore",
        "~/Library/Developer/DeveloperDiskImages/iOS_DDI.dmg",
    ]

    static func resolve(path: String?, identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage {
        if let path, !path.isEmpty {
            return try resolveCandidate(expandHome(path), identifiers: identifiers)
        }
        var searched: [String] = []
        for candidate in defaultSearchPaths.map(expandHome) {
            searched.append(candidate)
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            do {
                return try resolveCandidate(candidate, identifiers: identifiers)
            } catch DeveloperDiskImageError.invalidPath {
                continue
            }
        }
        throw DeveloperDiskImageError.notFound(searched)
    }

    private static func resolveCandidate(_ path: String, identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw DeveloperDiskImageError.invalidPath(path)
        }
        let url = URL(fileURLWithPath: path)
        if isDirectory.boolValue {
            if let resolved = try resolveDirectory(url, identifiers: identifiers, cleanup: {}) {
                return resolved
            }
            throw DeveloperDiskImageError.invalidPath(path)
        }
        guard url.pathExtension.lowercased() == "dmg" else {
            throw DeveloperDiskImageError.invalidPath(path)
        }
        return try withAttachedDMG(url, identifiers: identifiers)
    }

    private static func resolveDirectory(
        _ url: URL,
        identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers,
        cleanup: @escaping () -> Void
    ) throws -> ResolvedDeveloperDiskImage? {
        let restoreURL: URL
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("BuildManifest.plist").path) {
            restoreURL = url
        } else if FileManager.default.fileExists(atPath: url.appendingPathComponent("Restore/BuildManifest.plist").path) {
            restoreURL = url.appendingPathComponent("Restore", isDirectory: true)
        } else {
            return nil
        }
        let manifest = try DeveloperDiskImageBuildManifest(url: restoreURL.appendingPathComponent("BuildManifest.plist"))
        let identity = try manifest.identity(for: identifiers)
        return ResolvedDeveloperDiskImage(
            restoreURL: restoreURL,
            buildManifestURL: restoreURL.appendingPathComponent("BuildManifest.plist"),
            imageURL: restoreURL.appendingPathComponent(identity.imageRelativePath),
            trustCacheURL: restoreURL.appendingPathComponent(identity.trustCacheRelativePath),
            sourceDescription: restoreURL.path,
            cleanup: cleanup
        )
    }

    private static func withAttachedDMG(_ dmgURL: URL, identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-ddi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            _ = try Shell.run("hdiutil", arguments: ["attach", dmgURL.path, "-readonly", "-nobrowse", "-mountpoint", mountPoint.path])
            guard let resolved = try resolveDirectory(mountPoint, identifiers: identifiers, cleanup: {
                _ = try? Shell.run("hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
                try? FileManager.default.removeItem(at: mountPoint)
            }) else {
                _ = try? Shell.run("hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
                try? FileManager.default.removeItem(at: mountPoint)
                throw DeveloperDiskImageError.invalidPath(dmgURL.path)
            }
            return resolved
        } catch {
            _ = try? Shell.run("hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
            throw error
        }
    }

    private static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
    }
}

struct DeveloperDiskImageBuildManifest {
    struct DeviceIdentifiers: Equatable {
        let boardID: Int
        let chipID: Int
        let securityDomain: Int
        let apTags: [String: Any]

        static func == (lhs: DeviceIdentifiers, rhs: DeviceIdentifiers) -> Bool {
            lhs.boardID == rhs.boardID
                && lhs.chipID == rhs.chipID
                && lhs.securityDomain == rhs.securityDomain
        }
    }

    struct Identity {
        let raw: [String: Any]
        let manifest: [String: Any]
        let imageRelativePath: String
        let trustCacheRelativePath: String
    }

    let root: [String: Any]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw DeveloperDiskImageError.invalidPath(url.path)
        }
        self.root = root
    }

    func identity(for identifiers: DeviceIdentifiers) throws -> Identity {
        guard let identities = root["BuildIdentities"] as? [[String: Any]] else {
            throw DeveloperDiskImageError.missingManifestEntry("BuildIdentities")
        }
        guard let match = identities.first(where: { identity in
            Self.integer(identity["ApBoardID"]) == identifiers.boardID
                && Self.integer(identity["ApChipID"]) == identifiers.chipID
        }) else {
            throw DeveloperDiskImageError.missingBuildIdentity(boardID: identifiers.boardID, chipID: identifiers.chipID)
        }
        guard let manifest = match["Manifest"] as? [String: Any] else {
            throw DeveloperDiskImageError.missingManifestEntry("Manifest")
        }
        let imageEntryName = manifest["PersonalizedDMG"] != nil ? "PersonalizedDMG" : "PersonalizedDmg"
        let imagePath = try Self.path(for: imageEntryName, manifest: manifest)
        let trustCachePath = try Self.path(for: "LoadableTrustCache", manifest: manifest)
        return Identity(raw: match, manifest: manifest, imageRelativePath: imagePath, trustCacheRelativePath: trustCachePath)
    }

    static func tssRequest(identity: Identity, identifiers: DeviceIdentifiers, ecid: Int64, nonce: Data) -> [String: Any] {
        var request: [String: Any] = [
            "@ApImg4Ticket": true,
            "@BBTicket": true,
            "@HostPlatformInfo": "mac",
            "@VersionInfo": "libauthinstall-1104.0.9",
            "@UUID": UUID().uuidString.uppercased(),
            "ApBoardID": identifiers.boardID,
            "ApChipID": identifiers.chipID,
            "ApECID": ecid,
            "ApNonce": nonce,
            "ApProductionMode": true,
            "ApSecurityDomain": identifiers.securityDomain,
            "ApSecurityMode": true,
            "SepNonce": Data(repeating: 0, count: 20),
            "UID_MODE": false,
        ]
        for (key, value) in identifiers.apTags {
            request[key] = value
        }
        let ruleParameters: [String: Any] = [
            "ApProductionMode": true,
            "ApSecurityMode": true,
            "ApSupportsImg4": true,
        ]
        for (key, rawEntry) in identity.manifest {
            guard let entry = rawEntry as? [String: Any],
                  entry["Info"] is [String: Any],
                  (entry["Trusted"] as? Bool) == true || (entry["Trusted"] as? Int) == 1 else {
                continue
            }
            var tssEntry = entry
            let info = (tssEntry.removeValue(forKey: "Info") as? [String: Any]) ?? [:]
            let rules = (info["RestoreRequestRules"] as? [[String: Any]])
                ?? (((identity.manifest["LoadableTrustCache"] as? [String: Any])?["Info"] as? [String: Any])?["RestoreRequestRules"] as? [[String: Any]])
            if let rules {
                tssEntry = applyRestoreRequestRules(tssEntry, parameters: ruleParameters, rules: rules)
            }
            if tssEntry["Digest"] == nil {
                tssEntry["Digest"] = Data()
            }
            request[key] = tssEntry
        }
        return request
    }

    private static func path(for entryName: String, manifest: [String: Any]) throws -> String {
        guard let entry = manifest[entryName] as? [String: Any],
              let info = entry["Info"] as? [String: Any],
              let path = info["Path"] as? String,
              !path.isEmpty else {
            throw DeveloperDiskImageError.missingManifestEntry("\(entryName).Info.Path")
        }
        return path
    }

    private static func applyRestoreRequestRules(_ entry: [String: Any], parameters: [String: Any], rules: [[String: Any]]) -> [String: Any] {
        var result = entry
        for rule in rules {
            guard let conditions = rule["Conditions"] as? [String: Any],
                  let actions = rule["Actions"] as? [String: Any] else {
                continue
            }
            let fulfilled = conditions.allSatisfy { key, value in
                let actual: Any?
                switch key {
                case "ApRawProductionMode", "ApCurrentProductionMode":
                    actual = parameters["ApProductionMode"]
                case "ApRawSecurityMode":
                    actual = parameters["ApSecurityMode"]
                case "ApRequiresImage4":
                    actual = parameters["ApSupportsImg4"]
                case "ApDemotionPolicyOverride":
                    actual = parameters["DemotionPolicy"]
                case "ApInRomDFU":
                    actual = parameters["ApInRomDFU"]
                default:
                    actual = nil
                }
                return valuesEqual(actual, value)
            }
            guard fulfilled else { continue }
            for (key, value) in actions where integer(value) != 255 {
                result[key] = value
            }
        }
        return result
    }

    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as UInt: return Int(value)
        case let value as Int64: return Int(value)
        case let value as UInt64: return Int(value)
        case let value as NSNumber: return value.intValue
        case let value as String:
            if value.lowercased().hasPrefix("0x") {
                return Int(value.dropFirst(2), radix: 16)
            }
            return Int(value)
        default:
            return nil
        }
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if let lhs = integer(lhs), let rhs = integer(rhs) {
            return lhs == rhs
        }
        if let lhs = lhs as? Bool, let rhs = rhs as? Bool {
            return lhs == rhs
        }
        if let lhs = lhs as? Bool, let rhs = integer(rhs) {
            return (lhs ? 1 : 0) == rhs
        }
        if let rhs = rhs as? Bool, let lhs = integer(lhs) {
            return lhs == (rhs ? 1 : 0)
        }
        return String(describing: lhs ?? "") == String(describing: rhs ?? "")
    }
}

enum MobileImageMounterError: Error, CustomStringConvertible, Equatable {
    case invalidResponseSize(Int)
    case commandFailed(String)
    case missingManifest

    var description: String {
        switch self {
        case .invalidResponseSize(let size): return "mobile_image_mounter invalid response size: \(size)"
        case .commandFailed(let message): return "mobile_image_mounter command failed: \(message)"
        case .missingManifest: return "mobile_image_mounter returned no personalization manifest"
        }
    }
}

final class MobileImageMounterClient {
    static let serviceName = "com.apple.mobile.mobile_image_mounter"
    private let stream: DeviceStream

    init(stream: DeviceStream) {
        self.stream = stream
    }

    static func withClient<T>(udid: String, _ body: (MobileImageMounterClient) throws -> T) throws -> T {
        let stream = try LockdownSession.connectToService(serviceName, udid: udid)
        defer { stream.close() }
        return try body(MobileImageMounterClient(stream: stream))
    }

    func isPersonalizedImageMounted() throws -> Bool {
        do {
            let response = try sendPlist(["Command": "LookupImage", "ImageType": "Personalized"])
            if let present = response["ImagePresent"] as? Bool {
                return present
            }
            if let signatures = response["ImageSignature"] as? [Data] {
                return !signatures.isEmpty
            }
            return response["ImageSignature"] is Data
        } catch {
            let message = String(describing: error)
            if message.contains("NotMounted") || message.contains("NoImageMounted") || message.contains("ImagePresent") {
                return false
            }
            return try copyDevicesContainsPersonalizedDeveloperDiskImage()
        }
    }

    private func copyDevicesContainsPersonalizedDeveloperDiskImage() throws -> Bool {
        let response = try sendPlist(["Command": "CopyDevices"])
        guard let entries = response["EntryList"] as? [[String: Any]] else {
            return false
        }
        return entries.contains { entry in
            let isMounted = (entry["IsMounted"] as? Bool) ?? true
            guard isMounted else { return false }
            if entry["PersonalizedImageType"] as? String == "DeveloperDiskImage" {
                return true
            }
            if entry["DiskImageType"] as? String == "Personalized",
               entry["MountPath"] as? String == "/System/Developer" {
                return true
            }
            return false
        }
    }

    func queryPersonalizationIdentifiers() throws -> DeveloperDiskImageBuildManifest.DeviceIdentifiers {
        let response = try sendPlist([
            "Command": "QueryPersonalizationIdentifiers",
            "PersonalizedImageType": "DeveloperDiskImage",
        ])
        guard let raw = response["PersonalizationIdentifiers"] as? [String: Any] else {
            throw MobileImageMounterError.commandFailed("missing PersonalizationIdentifiers; response: \(plistResponseSummary(response))")
        }
        guard let boardID = DeveloperDiskImageBuildManifest.integer(raw["BoardId"]),
              let chipID = DeveloperDiskImageBuildManifest.integer(raw["ChipID"]) else {
            throw MobileImageMounterError.commandFailed("missing BoardId/ChipID; response: \(plistResponseSummary(response))")
        }
        let securityDomain = DeveloperDiskImageBuildManifest.integer(raw["SecurityDomain"]) ?? 1
        let apTags = raw.filter { key, _ in key.hasPrefix("Ap,") }
        return DeveloperDiskImageBuildManifest.DeviceIdentifiers(
            boardID: boardID,
            chipID: chipID,
            securityDomain: securityDomain,
            apTags: apTags
        )
    }

    func queryPersonalizationManifest(imageDigest: Data) throws -> Data {
        let response = try sendPlist([
            "Command": "QueryPersonalizationManifest",
            "PersonalizedImageType": "DeveloperDiskImage",
            "ImageType": "DeveloperDiskImage",
            "ImageSignature": imageDigest,
        ])
        guard let signature = response["ImageSignature"] as? Data else {
            throw MobileImageMounterError.missingManifest
        }
        return signature
    }

    func queryNonce() throws -> Data {
        let response = try sendPlist([
            "Command": "QueryNonce",
            "HostProcessName": "CoreDeviceService",
            "PersonalizedImageType": "DeveloperDiskImage",
        ])
        guard let nonce = response["PersonalizationNonce"] as? Data else {
            throw MobileImageMounterError.commandFailed("missing PersonalizationNonce; response: \(plistResponseSummary(response))")
        }
        return nonce
    }

    func uploadPersonalizedImage(image: Data, signature: Data) throws {
        let response = try sendPlist([
            "Command": "ReceiveBytes",
            "ImageType": "Personalized",
            "ImageSize": image.count,
            "ImageSignature": signature,
        ])
        guard response["Status"] as? String == "ReceiveBytesAck" else {
            throw MobileImageMounterError.commandFailed("ReceiveBytes failed: \(plistResponseSummary(response))")
        }
        try stream.write(image)
        let complete = try readPlistFrame(timeoutSeconds: 60)
        guard complete["Status"] as? String == "Complete" else {
            throw MobileImageMounterError.commandFailed("ReceiveBytes upload failed: \(plistResponseSummary(complete))")
        }
    }

    func mountPersonalizedImage(signature: Data, trustCache: Data) throws {
        let response = try sendPlist([
            "Command": "MountImage",
            "ImageType": "Personalized",
            "ImageSignature": signature,
            "ImageTrustCache": trustCache,
        ], timeoutSeconds: 60)
        guard response["Status"] as? String == "Complete" else {
            throw MobileImageMounterError.commandFailed("MountImage failed: \(plistResponseSummary(response))")
        }
    }

    @discardableResult
    func sendPlist(_ body: [String: Any], timeoutSeconds: Double = 30) throws -> [String: Any] {
        let xml = try serializePlist(body)
        try stream.write(uint32BE(UInt32(xml.count)) + xml)
        return try readPlistFrame(timeoutSeconds: timeoutSeconds)
    }

    private func readPlistFrame(timeoutSeconds: Double) throws -> [String: Any] {
        let header = try stream.readExact(byteCount: 4, timeoutSeconds: timeoutSeconds)
        let size = Int(readUInt32BE(header, 0))
        guard size > 0, size <= 64 * 1024 * 1024 else {
            throw MobileImageMounterError.invalidResponseSize(size)
        }
        let response = try parsePlist(try stream.readExact(byteCount: size, timeoutSeconds: timeoutSeconds))
        if let error = response["Error"] {
            let description = (response["DetailedError"] ?? response["ErrorDescription"] ?? error)
            throw MobileImageMounterError.commandFailed("\(description); response: \(plistResponseSummary(response))")
        }
        return response
    }
}

enum AppleTSSClient {
    static var postForTesting: (([String: Any]) throws -> [String: Any])?

    static func requestTicket(_ request: [String: Any]) throws -> Data {
        let response = try postForTesting?(request) ?? post(request)
        guard let ticket = response["ApImg4Ticket"] as? Data else {
            throw DeveloperDiskImageError.missingTSSField("ApImg4Ticket")
        }
        return ticket
    }

    private static func post(_ request: [String: Any]) throws -> [String: Any] {
        var urlRequest = URLRequest(url: URL(string: "http://gs.apple.com/TSS/controller?action=2")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-type")
        urlRequest.setValue("InetURL/1.0", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("", forHTTPHeaderField: "Expect")
        urlRequest.httpBody = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>!
        URLSession.shared.dataTask(with: urlRequest) { data, _, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(data ?? Data())
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 60) == .success, let result else {
            throw DeveloperDiskImageError.commandFailed("Apple TSS request timed out")
        }
        let data = try result.get()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard text.contains("MESSAGE=SUCCESS") else {
            throw DeveloperDiskImageError.commandFailed("Apple TSS request failed: \(text.prefix(300))")
        }
        guard let range = text.range(of: "REQUEST_STRING=") else {
            throw DeveloperDiskImageError.missingTSSField("REQUEST_STRING")
        }
        let plistText = String(text[range.upperBound...])
        guard let plistData = plistText.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw DeveloperDiskImageError.commandFailed("Apple TSS returned an invalid REQUEST_STRING")
        }
        return plist
    }
}

enum DeveloperDiskImageService {
    static var mountForTesting: ((String, String?) throws -> String)?

    static func mount(options: DDIMountOptions, paths: IOSUsePaths) throws -> String {
        let udid = try resolveRealDeviceTargetUdid(
            explicitUdid: options.udid,
            paths: paths,
            missingMessage: "ddi-mount requires --udid, an active real-device driver, or exactly one connected USB real device."
        )
        if let mountForTesting {
            return try mountForTesting(udid, options.path)
        }
        return try mount(udid: udid, path: options.path)
    }

    static func mount(udid: String, path: String?) throws -> String {
        let ecid = try readECID(udid: udid)
        let identifiers = try MobileImageMounterClient.withClient(udid: udid) { client in
            try client.queryPersonalizationIdentifiers()
        }
        let resolved = try DeveloperDiskImageResolver.resolve(path: path, identifiers: identifiers)
        defer { resolved.cleanup() }

        let image = try Data(contentsOf: resolved.imageURL)
        let trustCache = try Data(contentsOf: resolved.trustCacheURL)
        let digest = Data(SHA384.hash(data: image))
        if try MobileImageMounterClient.withClient(udid: udid, { try $0.isPersonalizedImageMounted() }) {
            return "Developer Disk Image already mounted on \(udid)\n"
        }

        let signature: Data
        let forceTSS = ProcessInfo.processInfo.environment["IOS_USE_DDI_FORCE_TSS"] == "1"
        do {
            if forceTSS {
                throw MobileImageMounterError.missingManifest
            }
            signature = try MobileImageMounterClient.withClient(udid: udid) { client in
                try client.queryPersonalizationManifest(imageDigest: digest)
            }
        } catch {
            let nonce = try MobileImageMounterClient.withClient(udid: udid) { client in
                try client.queryNonce()
            }
            let manifest = try DeveloperDiskImageBuildManifest(url: resolved.buildManifestURL)
            let identity = try manifest.identity(for: identifiers)
            let request = DeveloperDiskImageBuildManifest.tssRequest(
                identity: identity,
                identifiers: identifiers,
                ecid: ecid,
                nonce: nonce
            )
            signature = try AppleTSSClient.requestTicket(request)
        }

        try MobileImageMounterClient.withClient(udid: udid) { client in
            try client.uploadPersonalizedImage(image: image, signature: signature)
            try client.mountPersonalizedImage(signature: signature, trustCache: trustCache)
        }
        return "Mounted Developer Disk Image on \(udid) from \(resolved.sourceDescription)\n"
    }

    private static func resolveRealDeviceTargetUdid(
        explicitUdid: String?,
        paths: IOSUsePaths,
        missingMessage: String
    ) throws -> String {
        try SessionService.resolveTargetUdid(
            explicitUdid: explicitUdid,
            paths: paths,
            missingMessage: missingMessage,
            fallbackUdid: {
                let realDevices = try DeviceService.listDevices(simulatorOnly: false, paths: paths).filter { $0.kind == .real }
                return realDevices.count == 1 ? realDevices[0].udid : nil
            }
        )
    }

    private static func readECID(udid: String) throws -> Int64 {
        let values = try LockdownSession.getValue(udid: udid, key: "UniqueChipID")
        guard let value = values["UniqueChipID"],
              let ecid = int64(value) else {
            throw DeveloperDiskImageError.commandFailed("lockdown returned no UniqueChipID for \(udid)")
        }
        return ecid
    }

    private static func int64(_ value: Any) -> Int64? {
        switch value {
        case let value as Int64: return value
        case let value as UInt64: return Int64(value)
        case let value as Int: return Int64(value)
        case let value as UInt: return Int64(value)
        case let value as NSNumber: return value.int64Value
        case let value as String:
            if value.lowercased().hasPrefix("0x") {
                return Int64(value.dropFirst(2), radix: 16)
            }
            return Int64(value)
        default:
            return nil
        }
    }
}
