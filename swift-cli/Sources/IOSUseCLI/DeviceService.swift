import Foundation

public struct IOSDevice: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case real
        case simulator
    }

    public let name: String
    public let version: String
    public let udid: String
    public let kind: Kind

    public init(name: String, version: String, udid: String, kind: Kind) {
        self.name = name
        self.version = version
        self.udid = udid
        self.kind = kind
    }
}

public enum DeviceService {
    static var listDevicesOverrideForTesting: ((Bool, IOSUsePaths) throws -> [IOSDevice])?
    private static var listDevicesCache: [String: [IOSDevice]] = [:]

    public static func listDevices(simulatorOnly: Bool, paths: IOSUsePaths) throws -> [IOSDevice] {
        if let listDevicesOverrideForTesting {
            return try listDevicesOverrideForTesting(simulatorOnly, paths)
        }
        let cacheKey = "\(paths.root)|\(simulatorOnly)"
        if let cached = listDevicesCache[cacheKey] {
            return cached
        }
        let devices: [IOSDevice]
        if simulatorOnly {
            let output = try Shell.run("xcrun", arguments: ["simctl", "list", "devices", "booted"])
            devices = parseBootedSimulators(output)
        } else {
            let output = try Shell.run("xcrun", arguments: ["xctrace", "list", "devices"])
            devices = parseDeviceOutput(output).filter { $0.kind == .real }
        }
        listDevicesCache[cacheKey] = devices
        return devices
    }

    static func resetCacheForTesting() {
        listDevicesCache.removeAll(keepingCapacity: true)
    }

    public static func parseDeviceOutput(_ output: String) -> [IOSDevice] {
        var devices: [IOSDevice] = []
        var section: IOSDevice.Kind?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("== Devices ==") {
                section = .real
                continue
            }
            if line.hasPrefix("== Simulators ==") {
                section = .simulator
                continue
            }
            if line.hasPrefix("== ") {
                section = nil
                continue
            }
            guard let kind = section, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard let match = firstMatch(line, pattern: #"^\s*(.+?)\s+(?:\((\d+\.\d+(?:\.\d+)?)\)\s+)?\(([0-9A-Fa-f-]+)\)\s*$"#) else {
                continue
            }
            devices.append(IOSDevice(
                name: match[1].trimmingCharacters(in: .whitespacesAndNewlines),
                version: match[2],
                udid: match[3],
                kind: kind
            ))
        }

        return devices
    }

    public static func parseBootedSimulators(_ output: String) -> [IOSDevice] {
        var devices: [IOSDevice] = []
        var currentVersion = ""

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("-- ") {
                if let match = firstMatch(line, pattern: #"^--\s+(.+?)\s+--"#) {
                    currentVersion = match[1].replacingOccurrences(of: #"^iOS\s+"#, with: "", options: .regularExpression)
                }
                continue
            }
            guard let match = firstMatch(line, pattern: #"^\s*(.+?)\s+\(([0-9A-Fa-f-]+)\)\s+\(Booted\)"#) else {
                continue
            }
            devices.append(IOSDevice(name: match[1].trimmingCharacters(in: .whitespacesAndNewlines), version: currentVersion, udid: match[2], kind: .simulator))
        }

        return devices
    }

    public static func configuredUdids(paths: IOSUsePaths) -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else {
            return []
        }
        return Set(devices.keys)
    }

    public static func format(_ device: IOSDevice, configured: Set<String>) -> String {
        let typeLabel = device.kind == .simulator ? "Simulator" : "Device"
        let version = device.version.isEmpty ? "unknown" : device.version
        let tag = configured.contains(device.udid) ? " | configured" : ""
        return "\(device.name.isEmpty ? "Unknown" : device.name) | iOS \(version) | \(typeLabel) | UDID: \(device.udid)\(tag)"
    }

    private static func firstMatch(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}

enum Shell {
    static func run(_ executable: String, arguments: [String], cwd: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stdoutURL = tempDir.appendingPathComponent("stdout")
        let stderrURL = tempDir.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        if process.terminationStatus != 0 {
            let error = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw CLIParseError.invalidValue(error.isEmpty ? "\(executable) failed with exit \(process.terminationStatus)" : error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
