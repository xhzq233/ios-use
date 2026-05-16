import Foundation
import IOSUseProtocol

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
    public static let simulatorBundleId = "com.iosuse.xcuidriver.xctrunner"

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

    public static func configureSimulator(udid requestedUdid: String?, paths: IOSUsePaths) throws -> String {
        let udid = try requestedUdid ?? defaultBootedSimulatorUdid()
        let ipaPath = simulatorIPAPath(paths: paths)
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            throw CLIParseError.invalidValue("Prebuilt Simulator driver IPA not found. Expected: assets/driver-sim.ipa")
        }

        let extractDir = "\(paths.root)/driver-sim-install-\(udid)"
        try? FileManager.default.removeItem(atPath: extractDir)
        try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: extractDir) }

        _ = try Shell.run("unzip", arguments: ["-q", "-o", ipaPath, "-d", extractDir])
        let payloadDir = "\(extractDir)/Payload"
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            throw CLIParseError.invalidValue("No .app found in Simulator IPA")
        }
        let appPath = "\(payloadDir)/\(appEntry)"

        _ = try? Shell.run("xcrun", arguments: ["simctl", "terminate", udid, simulatorBundleId])
        do {
            _ = try Shell.run("xcrun", arguments: ["simctl", "install", udid, appPath])
        } catch {
            _ = try? Shell.run("xcrun", arguments: ["simctl", "boot", udid])
            _ = try Shell.run("xcrun", arguments: ["simctl", "bootstatus", udid, "-b"])
            _ = try Shell.run("xcrun", arguments: ["simctl", "install", udid, appPath])
        }

        let launchOutput = try Shell.run("xcrun", arguments: ["simctl", "launch", udid, simulatorBundleId]).trimmingCharacters(in: .whitespacesAndNewlines)
        waitForSimulatorDriver()
        try saveConfig(udid: udid, bundleId: simulatorBundleId, port: String(IOSUseProtocol.defaultDriverPort), paths: paths)
        let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).first { $0.udid == udid }
        try SessionService.writeSimulatorSession(
            udid: udid,
            deviceName: simulator?.name ?? "Simulator",
            deviceVersion: simulator?.version ?? "",
            paths: paths
        )
        return "Using prebuilt driver: \(ipaPath)\nDriver installed to Simulator\nDriver launched on Simulator (PID: \(launchOutput))\nSimulator config complete!\n"
    }

    private static func defaultBootedSimulatorUdid() throws -> String {
        guard let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: IOSUsePaths.resolve()).first else {
            throw CLIParseError.invalidValue("No --udid and no booted Simulators found.")
        }
        return simulator.udid
    }

    private static func simulatorIPAPath(paths: IOSUsePaths) -> String {
        let localAsset = "\(FileManager.default.currentDirectoryPath)/assets/driver-sim.ipa"
        if FileManager.default.fileExists(atPath: localAsset) {
            return localAsset
        }
        return "\(paths.root)/driver-sim.ipa"
    }

    private static func saveConfig(udid: String, bundleId: String, port: String, paths: IOSUsePaths) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var devices = root["devices"] as? [String: Any] ?? [:]
        devices[udid] = ["bundleId": bundleId, "port": port]
        root["devices"] = devices

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let configDir = URL(fileURLWithPath: paths.config).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: URL(fileURLWithPath: paths.config), options: .atomic)
    }

    private static func waitForSimulatorDriver() {
        for _ in 0..<50 {
            if (try? DriverClient().dom(raw: false, fresh: false)) != nil {
                return
            }
            usleep(200_000)
        }
    }
}

public enum SessionService {
    public static func clear(paths: IOSUsePaths) {
        try? FileManager.default.removeItem(atPath: paths.session)
    }

    public static func writeSimulatorSession(udid: String, deviceName: String, deviceVersion: String, paths: IOSUsePaths) throws {
        let root: [String: Any] = [
            "sessionId": "session-\(Int(Date().timeIntervalSince1970 * 1000))",
            "udid": udid,
            "port": IOSUseProtocol.defaultDriverPort,
            "deviceName": deviceName,
            "deviceVersion": deviceVersion,
            "deviceType": "simulator",
            "createdAt": Int(Date().timeIntervalSince1970 * 1000),
        ]
        let sessionDir = URL(fileURLWithPath: paths.session).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: paths.session), options: .atomic)
    }
}
