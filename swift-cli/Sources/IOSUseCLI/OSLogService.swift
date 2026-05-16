import Foundation
import IOSUseProtocol

public enum OSLogService {
    private static var buffers: [String: [String]] = [:]
    typealias SimulatorLogCollector = (_ udid: String, _ lastSec: Double, _ bundleId: String?) throws -> [String]
    static var simulatorLogCollector: SimulatorLogCollector = collectSimulatorLog

    public static func clear() -> String {
        let cleared = buffers.values.reduce(0) { $0 + $1.count }
        buffers.removeAll(keepingCapacity: true)
        return "  → oslog: cleared=\(cleared)\n"
    }

    public static func clear(udid: String) -> String {
        let keys = ["real:\(udid)", "simulator:\(udid)"]
        let cleared = keys.reduce(0) { total, key in
            total + (buffers.removeValue(forKey: key)?.count ?? 0)
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
        let lastSec = timeout.flatMap { $0 > 0 ? $0 : nil } ?? IOSUseProtocol.oslogDefaultSimulatorLastSeconds
        let newLines = try simulatorLogCollector(udid, lastSec, bundleId)
        let bufferKey = "simulator:\(udid)"
        let totalLines = appendUnique(newLines, key: bufferKey)
        var lines = bundleId.map { filterByBundleId(totalLines, bundleId: $0) } ?? totalLines
        lines = try filter(lines, pattern: pattern, flags: flags)
        let content = lines.joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let outputName = name?.isEmpty == false ? name! : "oslog-\(logTimestamp())"
        let path = "\(paths.artifacts)/\(outputName).log"
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
        paths: IOSUsePaths
    ) throws -> String {
        let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).contains { $0.udid == udid }
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

        let timeoutSeconds = timeout.flatMap { $0 > 0 ? $0 : nil } ?? IOSUseProtocol.oslogDefaultCollectTimeoutSeconds
        let newLines = try RealDeviceOSLogService.collectSyslog(udid: udid, timeoutSeconds: timeoutSeconds)
        let bufferKey = "real:\(udid)"
        let totalLines = appendUnique(newLines, key: bufferKey)
        var lines = bundleId.map { filterByBundleId(totalLines, bundleId: $0) } ?? totalLines
        lines = try filter(lines, pattern: pattern, flags: flags)
        let content = lines.joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let outputName = name?.isEmpty == false ? name! : "oslog-\(logTimestamp())"
        let path = "\(paths.artifacts)/\(outputName).log"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return "  → oslog: matched=\(lines.count) total=\(totalLines.count) → \(path)\n"
    }

    static func resetSimulatorLogCollectorForTesting() {
        simulatorLogCollector = collectSimulatorLog
    }

    private static func appendUnique(_ lines: [String], key: String) -> [String] {
        var buffer = buffers[key] ?? []
        let existing = Set(buffer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        buffer.append(contentsOf: lines.filter { !existing.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        if buffer.count > IOSUseProtocol.oslogMaxBufferLines {
            buffer = Array(buffer.suffix(IOSUseProtocol.oslogMaxBufferLines))
        }
        buffers[key] = buffer
        return buffer
    }

    private static func filterByBundleId(_ lines: [String], bundleId: String) -> [String] {
        guard !bundleId.isEmpty else { return lines }
        return lines.filter { line in
            if let match = try? NSRegularExpression(pattern: #"^\w+\s+\d+\s+\d+:\d+:\d+\s+\S+\s+([\w-]+)"#),
               let found = match.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
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
        var args = ["simctl", "spawn", udid, "log", "show", "--style", "compact", "--last", "\(lastSec)s"]
        if let bundleId, !bundleId.isEmpty {
            args.append(contentsOf: ["--predicate", "process CONTAINS \"\(bundleId)\""])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun"] + args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdoutText + "\n" + stderrText)
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func logTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: #"[:.]"#, with: "-", options: .regularExpression)
    }
}
