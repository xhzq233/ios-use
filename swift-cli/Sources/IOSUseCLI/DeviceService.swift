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
    public let metadata: IOSDeviceMetadata?

    public init(name: String, version: String, udid: String, kind: Kind, metadata: IOSDeviceMetadata? = nil) {
        self.name = name
        self.version = version
        self.udid = udid
        self.kind = kind
        self.metadata = metadata
    }
}

public struct IOSDeviceMetadata: Equatable, Sendable {
    public let productType: String?
    public let productName: String?
    public let buildVersion: String?
    public let batteryCurrentCapacity: Int?
    public let status: String?
    public let detail: String?

    public init(productType: String? = nil, productName: String? = nil, buildVersion: String? = nil, batteryCurrentCapacity: Int? = nil, status: String? = nil, detail: String? = nil) {
        self.productType = productType
        self.productName = productName
        self.buildVersion = buildVersion
        self.batteryCurrentCapacity = batteryCurrentCapacity
        self.status = status
        self.detail = detail
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
    static var realDeviceResolverForTesting: ((String) -> IOSDevice)?
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
            devices = try SimulatorService.listBooted(paths: paths)
        } else {
            let usbUdids = try usbDeviceUdidsOverrideForTesting?() ?? Usbmux.listUsbDeviceUdids()
            devices = usbUdids.map { loadRealDeviceInfo(udid: $0) }
        }
        listDevicesCache[cacheKey] = devices
        return devices
    }

    static func resetCacheForTesting() {
        listDevicesCache.removeAll(keepingCapacity: true)
    }

    private static func loadRealDeviceInfo(udid: String) -> IOSDevice {
        if let resolved = realDeviceResolverForTesting?(udid) {
            return resolved
        }
        do {
            let values = try LockdownSession.getValue(udid: udid)
            let battery = try? LockdownSession.getValue(udid: udid, domain: "com.apple.mobile.battery", key: "BatteryCurrentCapacity")
            let batteryCapacity = (battery?["BatteryCurrentCapacity"] as? Int)
                ?? (battery?["Value"] as? Int)
                ?? (battery?["BatteryCurrentCapacity"] as? NSNumber).map(\.intValue)
                ?? (battery?["Value"] as? NSNumber).map(\.intValue)
            return IOSDevice(
                name: values["DeviceName"] as? String ?? "Unknown",
                version: values["ProductVersion"] as? String ?? "",
                udid: values["UniqueDeviceID"] as? String ?? udid,
                kind: .real,
                metadata: IOSDeviceMetadata(
                    productType: values["ProductType"] as? String,
                    productName: values["ProductName"] as? String,
                    buildVersion: values["BuildVersion"] as? String,
                    batteryCurrentCapacity: batteryCapacity,
                    status: "paired",
                    detail: nil
                )
            )
        } catch {
            return IOSDevice(
                name: "Unknown",
                version: "",
                udid: udid,
                kind: .real,
                metadata: IOSDeviceMetadata(status: "pair required", detail: "\(error)")
            )
        }
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

    static func looksLikeSimulatorUDID(_ udid: String) -> Bool {
        UUID(uuidString: udid) != nil
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
        SimulatorService.parseBootedSimulators(output)
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

    public static func format(_ device: IOSDevice, configuredDevices: [String: ConfiguredDevice], verbose: Bool = false) -> String {
        let typeLabel = device.kind == .simulator ? "Simulator" : "Device"
        let version = device.version.isEmpty ? "unknown" : device.version
        let config = configuredDevices[device.udid]
        var tag = config == nil ? "" : " | configured"
        if let config, config.needsDriverUpdate {
            tag += " | driver update required: run ios-use config --udid \(device.udid)"
        }
        if let status = device.metadata?.status, status != "paired" {
            tag += " | \(status)"
        }
        var line = "\(device.name.isEmpty ? "Unknown" : device.name) | iOS \(version) | \(typeLabel) | UDID: \(device.udid)\(tag)"
        if verbose, let metadata = device.metadata {
            var parts: [String] = []
            if let productName = metadata.productName, !productName.isEmpty {
                parts.append("product: \(productName)")
            }
            if let productType = metadata.productType, !productType.isEmpty {
                parts.append("type: \(productType)")
            }
            if let buildVersion = metadata.buildVersion, !buildVersion.isEmpty {
                parts.append("build: \(buildVersion)")
            }
            if let battery = metadata.batteryCurrentCapacity {
                parts.append("battery: \(battery)%")
            }
            if let detail = metadata.detail, !detail.isEmpty {
                parts.append("detail: \(detail)")
            }
            if !parts.isEmpty {
                line += "\n    " + parts.joined(separator: " | ")
            }
        }
        return line
    }

    private enum Regexes {
        static let deviceLine = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+(?:\((\d+\.\d+(?:\.\d+)?)\)\s+)?\(([0-9A-Fa-f-]+)\)\s*$"#)
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
