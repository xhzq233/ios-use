import Foundation

public struct DeviceConfigEntry: Equatable, Sendable {
    public let udid: String
    public let bundleId: String
    public let port: String

    public init(udid: String, bundleId: String, port: String) {
        self.udid = udid
        self.bundleId = bundleId
        self.port = port
    }
}

public enum ConfigService {
    public static func listEntries(paths: IOSUsePaths) -> [DeviceConfigEntry] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else {
            return []
        }

        return devices.keys.sorted().map { udid in
            let value = devices[udid] as? [String: Any] ?? [:]
            let bundleId = value["bundleId"] as? String ?? "(missing)"
            let portValue = value["port"].map { String(describing: $0) } ?? "(missing)"
            return DeviceConfigEntry(udid: udid, bundleId: bundleId, port: portValue)
        }
    }

    public static func formatList(_ entries: [DeviceConfigEntry]) -> String {
        guard !entries.isEmpty else { return "No configured devices.\n" }
        let lines = entries.map { "  \($0.udid) → bundleId: \($0.bundleId), port: \($0.port)" }.joined(separator: "\n")
        return "Configured devices:\n\(lines)\n"
    }
}

public enum SessionService {
    public static func clear(paths: IOSUsePaths) {
        try? FileManager.default.removeItem(atPath: paths.session)
    }
}
