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
    public struct ConfiguredDevice: Equatable, Sendable {
        public let driverVersion: String?

        public init(driverVersion: String?) {
            self.driverVersion = driverVersion
        }

        public var needsDriverUpdate: Bool {
            driverVersion != IOSUseCLI.version
        }
    }

    static var listDevicesOverrideForTesting: ((Bool, IOSUsePaths) throws -> [IOSDevice])?
    static var usbDeviceUdidsOverrideForTesting: (() throws -> [String])?
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
            let usbUdids = try usbDeviceUdidsOverrideForTesting?() ?? Usbmux.listUsbDeviceUdids()
            guard !usbUdids.isEmpty else {
                return []
            }
            let output = try Shell.run("xcrun", arguments: ["xctrace", "list", "devices"])
            let realDevices = parseDeviceOutput(output).filter { $0.kind == .real }
            devices = usbOnlyDevices(from: realDevices, usbUdids: usbUdids)
        }
        listDevicesCache[cacheKey] = devices
        return devices
    }

    static func resetCacheForTesting() {
        listDevicesCache.removeAll(keepingCapacity: true)
    }

    static func usbOnlyDevices(from devices: [IOSDevice]) throws -> [IOSDevice] {
        guard !devices.isEmpty else { return [] }
        let usbUdids = try usbDeviceUdidsOverrideForTesting?() ?? Usbmux.listUsbDeviceUdids()
        return usbOnlyDevices(from: devices, usbUdids: usbUdids)
    }

    static func isUsbDeviceConnected(udid: String) throws -> Bool {
        let usbUdids = try usbDeviceUdidsOverrideForTesting?() ?? Usbmux.listUsbDeviceUdids()
        return usbUdids.contains { normalizeUdid($0) == normalizeUdid(udid) }
    }

    private static func usbOnlyDevices(from devices: [IOSDevice], usbUdids: [String]) -> [IOSDevice] {
        guard !devices.isEmpty else { return [] }
        var byNormalizedUdid: [String: IOSDevice] = [:]
        for device in devices {
            byNormalizedUdid[normalizeUdid(device.udid)] = device
        }
        return usbUdids.compactMap { byNormalizedUdid[normalizeUdid($0)] }
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
            guard let match = firstMatch(line, regex: Regexes.deviceLine) else {
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
                if let match = firstMatch(line, regex: Regexes.runtimeHeader) {
                    currentVersion = match[1].replacingOccurrences(of: #"^iOS\s+"#, with: "", options: .regularExpression)
                }
                continue
            }
            guard let match = firstMatch(line, regex: Regexes.bootedSimulator) else {
                continue
            }
            devices.append(IOSDevice(name: match[1].trimmingCharacters(in: .whitespacesAndNewlines), version: currentVersion, udid: match[2], kind: .simulator))
        }

        return devices
    }

    public static func configuredUdids(paths: IOSUsePaths) -> Set<String> {
        Set(configuredDevices(paths: paths).keys)
    }

    public static func configuredDevices(paths: IOSUsePaths) -> [String: ConfiguredDevice] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.config)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else {
            return [:]
        }
        return devices.reduce(into: [:]) { result, item in
            let value = item.value as? [String: Any] ?? [:]
            let driverVersion = value["driverVersion"] as? String
            result[item.key] = ConfiguredDevice(driverVersion: driverVersion)
        }
    }

    public static func format(_ device: IOSDevice, configured: Set<String>) -> String {
        format(device, configuredDevices: configured.reduce(into: [:]) { result, udid in
            result[udid] = ConfiguredDevice(driverVersion: IOSUseCLI.version)
        })
    }

    public static func format(_ device: IOSDevice, configuredDevices: [String: ConfiguredDevice]) -> String {
        let typeLabel = device.kind == .simulator ? "Simulator" : "Device"
        let version = device.version.isEmpty ? "unknown" : device.version
        let config = configuredDevices[device.udid]
        var tag = config == nil ? "" : " | configured"
        if let config, config.needsDriverUpdate {
            tag += " | driver update required: run ios-use config --udid \(device.udid)"
        }
        return "\(device.name.isEmpty ? "Unknown" : device.name) | iOS \(version) | \(typeLabel) | UDID: \(device.udid)\(tag)"
    }

    private enum Regexes {
        static let deviceLine = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+(?:\((\d+\.\d+(?:\.\d+)?)\)\s+)?\(([0-9A-Fa-f-]+)\)\s*$"#)
        static let runtimeHeader = try! NSRegularExpression(pattern: #"^--\s+(.+?)\s+--"#)
        static let bootedSimulator = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+\(([0-9A-Fa-f-]+)\)\s+\(Booted\)"#)
    }

    private static func firstMatch(_ text: String, regex: NSRegularExpression) -> [String]? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private static func normalizeUdid(_ udid: String) -> String {
        udid.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

enum Shell {
    struct RunResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static var runOverrideForTesting: ((String, [String], String?, Bool) throws -> String)?
    static var runResultOverrideForTesting: ((String, [String], String?) throws -> RunResult)?

    static func run(_ executable: String, arguments: [String], cwd: String? = nil) throws -> String {
        try runCaptured(executable, arguments: arguments, cwd: cwd, combineStderr: false)
    }

    static func runCombined(_ executable: String, arguments: [String], cwd: String? = nil) throws -> String {
        try runCaptured(executable, arguments: arguments, cwd: cwd, combineStderr: true)
    }

    static func runWithResult(_ executable: String, arguments: [String], cwd: String? = nil) throws -> RunResult {
        if let override = runResultOverrideForTesting {
            return try override(executable, arguments, cwd)
        }
        return try runCapturedWithResult(executable, arguments: arguments, cwd: cwd)
    }

    static func runInheriting(_ executable: String, arguments: [String], cwd: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CLIParseError.invalidValue("\(executable) failed with exit \(process.terminationStatus)")
        }
    }

    private static func runCaptured(_ executable: String, arguments: [String], cwd: String?, combineStderr: Bool) throws -> String {
        if let runOverrideForTesting {
            return try runOverrideForTesting(executable, arguments, cwd, combineStderr)
        }

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

        var output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        if combineStderr {
            output += error
        }
        if process.terminationStatus != 0 {
            throw CLIParseError.invalidValue(error.isEmpty ? "\(executable) failed with exit \(process.terminationStatus)" : error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func runCapturedWithResult(_ executable: String, arguments: [String], cwd: String?) throws -> RunResult {
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

        let out = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return RunResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }
}
