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

    static func directory(_ url: URL, identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers,
                          cleanup: @escaping () -> Void = {}) throws -> Self? {
        let root: URL
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("BuildManifest.plist").path) {
            root = url
        } else if FileManager.default.fileExists(atPath: url.appendingPathComponent("Restore/BuildManifest.plist").path) {
            root = url.appendingPathComponent("Restore", isDirectory: true)
        } else { return nil }
        let manifestURL = try containedFile("BuildManifest.plist", in: root)
        let identity = try DeveloperDiskImageBuildManifest(url: manifestURL).identity(for: identifiers)
        return Self(restoreURL: root, buildManifestURL: manifestURL,
                    imageURL: try containedFile(identity.imageRelativePath, in: root),
                    trustCacheURL: try containedFile(identity.trustCacheRelativePath, in: root),
                    sourceDescription: root.path, cleanup: cleanup)
    }

    /// Manifest paths are supplied by imported files. Never follow them outside
    /// the selected directory, including through symlinks.
    static func containedFile(_ path: String, in root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw DeveloperDiskImageError.invalidPath(path)
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw DeveloperDiskImageError.invalidPath(path)
        }
        return file
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

    func close() { stream.close() }

    static func withClient<T>(udid: String, _ body: (MobileImageMounterClient) throws -> T) throws -> T {
        let stream = try LockdownSession.connectToService(serviceName, udid: udid)
        defer { stream.close() }
        return try body(MobileImageMounterClient(stream: stream))
    }

    func isPersonalizedImageMounted() throws -> Bool {
        // LookupImage reports cached image/signature availability, which can
        // survive UnmountImage. CopyDevices is the actual mounted-device list.
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
        try beginUpload(size: image.count, signature: signature)
        try stream.write(image)
        try finishUpload()
    }

    func uploadPersonalizedImage(file: URL, signature: Data, progress: (Int, Int) -> Void = { _, _ in }) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0, size <= UInt64(Int.max) else {
            throw MobileImageMounterError.commandFailed("Invalid DDI image size")
        }
        try handle.seek(toOffset: 0)
        try beginUpload(size: Int(size), signature: signature)
        var sent = 0
        while sent < Int(size) {
            let data = try handle.read(upToCount: min(1_048_576, Int(size) - sent)) ?? Data()
            guard !data.isEmpty else { throw MobileImageMounterError.commandFailed("DDI image truncated during upload") }
            try stream.write(data)
            sent += data.count
            progress(sent, Int(size))
        }
        try finishUpload()
    }

    private func beginUpload(size: Int, signature: Data) throws {
        let response = try sendPlist([
            "Command": "ReceiveBytes",
            "ImageType": "Personalized",
            "ImageSize": size,
            "ImageSignature": signature,
        ])
        guard response["Status"] as? String == "ReceiveBytesAck" else {
            throw MobileImageMounterError.commandFailed("ReceiveBytes failed: \(plistResponseSummary(response))")
        }
    }

    private func finishUpload() throws {
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
        var urlRequest = URLRequest(url: URL(string: "https://gs.apple.com/TSS/controller?action=2")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-type")
        urlRequest.setValue("InetURL/1.0", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("", forHTTPHeaderField: "Expect")
        urlRequest.httpBody = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)

        urlRequest.timeoutInterval = 60
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>!
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                result = .failure(DeveloperDiskImageError.commandFailed("Apple TSS HTTP \(response.statusCode)"))
            } else {
                result = .success(data ?? Data())
            }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 60) == .success, let result else {
            task.cancel()
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

/// Shared by the host CLI and the iOS app. No host filesystem or process APIs.
enum PersonalizedDDIMounter {
    @discardableResult
    static func ensureMounted(udid: String,
                              log: (String) -> Void = { _ in },
                              resolve: (DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage) throws -> Bool {
        try mountIfNeeded(connect: {
            MobileImageMounterClient(stream: try LockdownSession.connectToService(MobileImageMounterClient.serviceName, udid: udid))
        }, readECID: {
            let values = try LockdownSession.getValue(udid: udid, key: "UniqueChipID")
            guard let ecid = DeveloperDiskImageBuildManifest.integer(values["UniqueChipID"]) else {
                throw DeveloperDiskImageError.commandFailed("Lockdown returned no UniqueChipID")
            }
            return Int64(ecid)
        }, ticket: AppleTSSClient.requestTicket,
           forceTSS: ProcessInfo.processInfo.environment["IOS_USE_DDI_FORCE_TSS"] == "1",
           log: log, resolve: resolve)
    }

    @discardableResult
    static func mountIfNeeded(connect: () throws -> MobileImageMounterClient,
                              readECID: () throws -> Int64,
                              ticket: ([String: Any]) throws -> Data,
                              forceTSS: Bool = false,
                              log: (String) -> Void = { _ in },
                              resolve: (DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage) throws -> Bool {
        func withClient<T>(_ body: (MobileImageMounterClient) throws -> T) throws -> T {
            let client = try connect()
            defer { client.close() }
            return try body(client)
        }
        log("Checking DDI mount")
        // Check before resolving files or contacting TSS: already-mounted devices
        // need neither an imported image nor an Internet connection.
        if try withClient({ try $0.isPersonalizedImageMounted() }) {
            log("DDI already mounted")
            return false
        }
        log("DDI not mounted; preparing image")
        let identifiers = try withClient { try $0.queryPersonalizationIdentifiers() }
        let resolved = try resolve(identifiers)
        defer { resolved.cleanup() }
        let manifest = try DeveloperDiskImageBuildManifest(url: resolved.buildManifestURL)
        let identity = try manifest.identity(for: identifiers)
        let digest = try sha384(file: resolved.imageURL)
        let trustCache = try Data(contentsOf: resolved.trustCacheURL)
        // Detect incomplete/mismatched imports before sending bytes to the device.
        for (name, actual) in [(identity.manifest["PersonalizedDMG"] != nil ? "PersonalizedDMG" : "PersonalizedDmg", digest),
                               ("LoadableTrustCache", Data(SHA384.hash(data: trustCache)))] {
            if let expected = (identity.manifest[name] as? [String: Any])?["Digest"] as? Data,
               !expected.isEmpty, expected != actual {
                throw DeveloperDiskImageError.commandFailed("DDI \(name) digest does not match BuildManifest; import a complete matching image")
            }
        }
        let signature: Data
        do {
            if forceTSS { throw MobileImageMounterError.missingManifest }
            signature = try withClient { try $0.queryPersonalizationManifest(imageDigest: digest) }
            log("Using device's cached DDI personalization")
        } catch {
            log("Requesting DDI personalization from Apple")
            let nonce = try withClient { try $0.queryNonce() }
            signature = try ticket(DeveloperDiskImageBuildManifest.tssRequest(
                identity: identity, identifiers: identifiers, ecid: try readECID(), nonce: nonce))
        }
        log("Uploading DDI")
        try withClient { client in
            var lastPercent = -1
            try client.uploadPersonalizedImage(file: resolved.imageURL, signature: signature) { sent, total in
                let percent = Int(Double(sent) / Double(total) * 100) / 25 * 25
                if percent != lastPercent { lastPercent = percent; log("DDI upload \(percent)%") }
            }
            log("Mounting DDI")
            try client.mountPersonalizedImage(signature: signature, trustCache: trustCache)
        }
        guard try withClient({ try $0.isPersonalizedImageMounted() }) else {
            throw DeveloperDiskImageError.commandFailed("DDI mount was acknowledged, but the image is not mounted")
        }
        log("DDI mounted and verified")
        return true
    }

    private static func sha384(file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA384()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return Data(hash.finalize())
    }
}
