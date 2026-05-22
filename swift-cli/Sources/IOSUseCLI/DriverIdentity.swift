import Foundation

public struct DriverIdentity: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public static var legacyCurrent: DriverIdentity {
        DriverIdentity(version: IOSUseCLI.version, build: "")
    }

    public var description: String {
        var parts = ["version=\(version)"]
        if !build.isEmpty { parts.append("build=\(build)") }
        return parts.joined(separator: ", ")
    }

    public init?(json: [String: Any]) {
        guard let version = json["version"] as? String else { return nil }
        self.version = version
        self.build = json["build"] as? String ?? ""
    }

    public var json: [String: Any] {
        [
            "version": version,
            "build": build,
        ]
    }
}
