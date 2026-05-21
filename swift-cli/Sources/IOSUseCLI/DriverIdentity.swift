import Foundation

public struct DriverIdentity: Equatable, Sendable {
    public let version: String
    public let build: String
    public let gitSHA: String?
    public let protocolID: String?

    public init(version: String, build: String, gitSHA: String? = nil, protocolID: String? = nil) {
        self.version = version
        self.build = build
        self.gitSHA = gitSHA
        self.protocolID = protocolID
    }

    public static var legacyCurrent: DriverIdentity {
        DriverIdentity(version: IOSUseCLI.version, build: "", gitSHA: nil, protocolID: nil)
    }

    public var description: String {
        var parts = ["version=\(version)"]
        if !build.isEmpty { parts.append("build=\(build)") }
        if let gitSHA, !gitSHA.isEmpty { parts.append("git=\(gitSHA)") }
        if let protocolID, !protocolID.isEmpty { parts.append("protocol=\(protocolID)") }
        return parts.joined(separator: ", ")
    }

    public init?(json: [String: Any]) {
        guard let version = json["version"] as? String else { return nil }
        self.version = version
        self.build = json["build"] as? String ?? ""
        self.gitSHA = json["gitSHA"] as? String
        self.protocolID = json["protocolID"] as? String
    }

    public var json: [String: Any] {
        var out: [String: Any] = [
            "version": version,
            "build": build,
        ]
        if let gitSHA { out["gitSHA"] = gitSHA }
        if let protocolID { out["protocolID"] = protocolID }
        return out
    }
}
