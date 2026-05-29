import Foundation
import IOSUseProtocol

public enum OSLogService {
    private static var buffers: [String: [String]] = [:]
    private static var seenLines: [String: Set<String>] = [:]
    typealias SimulatorLogCollector = (_ udid: String, _ lastSec: Double, _ bundleId: String?) throws -> [String]
    static var simulatorLogCollector: SimulatorLogCollector = collectSimulatorLog

    public static func clear() -> String {
        let cleared = buffers.values.reduce(0) { $0 + $1.count }
        buffers.removeAll(keepingCapacity: true)
        seenLines.removeAll(keepingCapacity: true)
        return "  → oslog: cleared=\(cleared)\n"
    }

    public static func clear(udid: String) -> String {
        let keys = ["real:\(udid)", "simulator:\(udid)"]
        let cleared = keys.reduce(0) { total, key in
            seenLines.removeValue(forKey: key)
            return total + (buffers.removeValue(forKey: key)?.count ?? 0)
        }
        return "  → oslog: cleared=\(cleared)\n"
    }

    public static func fetchSimulator(
        udid: String,
        pattern: String?,
        flags: String?,
        bundleId: String?,
        timeout: Double?,
        name: String?,
        paths: IOSUsePaths
    ) throws -> String {
        let bufferKey = "simulator:\(udid)"
        let lastSec = timeout ?? IOSUseProtocol.oslogDefaultSimulatorLastSeconds
        let shouldPoll = timeout != nil && !(pattern ?? "").isEmpty
        let deadline = Date().addingTimeInterval(timeout ?? 0)
        var totalLines: [String] = []
        var lines: [String] = []
        repeat {
            let newLines = try simulatorLogCollector(udid, lastSec, bundleId)
            totalLines = appendUnique(newLines, key: bufferKey)
            lines = bundleId.map { filterByBundleId(totalLines, bundleId: $0) } ?? totalLines
            lines = try filter(lines, pattern: pattern, flags: flags)
            if !shouldPoll || !lines.isEmpty {
                break
            }
            usleep(useconds_t(IOSUseProtocol.flowNSLogConnectPollMilliseconds * IOSUseProtocol.microsecondsPerMillisecond))
        } while Date() < deadline
        let content = lines.joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "oslog-\(logTimestamp())", extension: "log")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return "  → oslog: matched=\(lines.count) total=\(totalLines.count) → \(path)\n"
    }

    public static func fetch(
        udid: String,
        pattern: String?,
        flags: String?,
        bundleId: String?,
        timeout: Double?,
        name: String?,
        paths: IOSUsePaths,
        deviceTypeHint: String? = nil
    ) throws -> String {
        let simulator: Bool
        if deviceTypeHint == "simulator" {
            simulator = true
        } else if deviceTypeHint == "real" {
            simulator = false
        } else if (try? DeviceService.isUsbDeviceConnected(udid: udid)) == true {
            simulator = false
        } else if !DeviceService.looksLikeSimulatorUDID(udid) {
            simulator = false
        } else {
            simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).contains { $0.udid == udid }
        }
        if simulator {
            return try fetchSimulator(
                udid: udid,
                pattern: pattern,
                flags: flags,
                bundleId: bundleId,
                timeout: timeout,
                name: name,
                paths: paths
            )
        }

        let timeoutSeconds = timeout ?? IOSUseProtocol.oslogDefaultCollectTimeoutSeconds
        let newLines = try RealDeviceOSLogService.collectSyslog(udid: udid, timeoutSeconds: timeoutSeconds)
        let bufferKey = "real:\(udid)"
        let totalLines = appendUnique(newLines, key: bufferKey)
        var lines = bundleId.map { filterByBundleId(totalLines, bundleId: $0) } ?? totalLines
        lines = try filter(lines, pattern: pattern, flags: flags)
        let content = lines.joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "oslog-\(logTimestamp())", extension: "log")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return "  → oslog: matched=\(lines.count) total=\(totalLines.count) → \(path)\n"
    }

    static func resetSimulatorLogCollectorForTesting() {
        simulatorLogCollector = collectSimulatorLog
    }

    private static func appendUnique(_ lines: [String], key: String) -> [String] {
        var buffer = buffers[key] ?? []
        var seen = seenLines[key] ?? Set(buffer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        for line in lines {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            buffer.append(line)
        }
        if buffer.count > IOSUseProtocol.oslogMaxBufferLines {
            buffer = Array(buffer.suffix(IOSUseProtocol.oslogMaxBufferLines))
            seen = Set(buffer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        buffers[key] = buffer
        seenLines[key] = seen
        return buffer
    }

    private static func filterByBundleId(_ lines: [String], bundleId: String) -> [String] {
        guard !bundleId.isEmpty else { return lines }
        let processRegex = try? NSRegularExpression(pattern: #"^\w+\s+\d+\s+\d+:\d+:\d+\s+\S+\s+([\w-]+)"#)
        return lines.filter { line in
            if let processRegex,
               let found = processRegex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
               found.numberOfRanges > 1,
               let range = Range(found.range(at: 1), in: line) {
                let process = String(line[range])
                if process == bundleId || bundleId.contains(process) || process.contains(bundleId) {
                    return true
                }
            }
            return line.contains(bundleId)
        }
    }

    private static func filter(_ lines: [String], pattern: String?, flags: String?) throws -> [String] {
        guard let pattern, !pattern.isEmpty else { return lines }
        let options = try regexOptions(flags ?? "")
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        return lines.filter { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return regex.firstMatch(in: line, range: range) != nil
        }
    }

    private static func regexOptions(_ flags: String) throws -> NSRegularExpression.Options {
        var options: NSRegularExpression.Options = []
        for flag in flags {
            switch flag {
            case "i":
                options.insert(.caseInsensitive)
            case "m":
                options.insert(.anchorsMatchLines)
            case "s":
                options.insert(.dotMatchesLineSeparators)
            case "g", "u", "y":
                continue
            default:
                throw CLIParseError.invalidValue("Invalid regex flag: \(flag)")
            }
        }
        return options
    }

    private static func collectSimulatorLog(udid: String, lastSec: Double, bundleId: String?) throws -> [String] {
        _ = bundleId
        let args = ["simctl", "spawn", udid, "log", "show", "--style", "compact", "--last", "\(lastSec)s"]
        let output = (try? Shell.run("xcrun", arguments: args)) ?? ""
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func logTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: #"[:.]"#, with: "-", options: .regularExpression)
    }
}

enum OSLogCommandService {
    static func run(options: OSLogOptions, paths: IOSUsePaths, hostDeviceTypeHint: String? = nil) throws -> String {
        if options.clear {
            if let udid = options.session.udid ?? SessionService.read(paths: paths)?.udid {
                return OSLogService.clear(udid: udid)
            }
            return OSLogService.clear()
        }
        let activeDriver = SessionService.read(paths: paths)
        let defaultUsbUdid = try options.session.udid == nil && activeDriver?.udid == nil
            ? DeviceService.listDevices(simulatorOnly: false, paths: paths).first?.udid
            : nil
        guard let udid = options.session.udid ?? activeDriver?.udid ?? defaultUsbUdid else {
            throw CLIParseError.invalidValue("oslog requires --udid, an active driver, or a connected USB device")
        }
        return try OSLogService.fetch(
            udid: udid,
            pattern: options.pattern,
            flags: options.flags,
            bundleId: options.bundleId,
            timeout: options.timeout,
            name: options.name,
            paths: paths,
            deviceTypeHint: hostDeviceTypeHint ?? (activeDriver?.udid == udid ? activeDriver?.deviceType : (defaultUsbUdid == udid ? "real" : nil))
        )
    }
}
