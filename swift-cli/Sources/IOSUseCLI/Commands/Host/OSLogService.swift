import Foundation
import IOSUseProtocol

public enum OSLogService {
    typealias SimulatorLogCollector = (_ udid: String, _ lastSec: Double, _ source: OSLogOptions.SourceFilter) throws -> [String]
    static var simulatorLogCollector: SimulatorLogCollector = collectSimulatorLog

    public static func fetchSimulator(
        udid: String,
        pattern: String?,
        flags: String?,
        source: OSLogOptions.SourceFilter,
        timeout: Double?,
        paths: IOSUsePaths
    ) throws -> String {
        let lastSec = timeout ?? IOSUseProtocol.oslogDefaultSimulatorLastSeconds
        let shouldPoll = timeout != nil && !(pattern ?? "").isEmpty
        let deadline = Date().addingTimeInterval(timeout ?? 0)
        var totalLines: [String] = []
        var seenLines = Set<String>()
        var lines: [String] = []
        repeat {
            let newLines = try simulatorLogCollector(udid, lastSec, source)
            for line in newLines {
                let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !seenLines.contains(normalized) else { continue }
                seenLines.insert(normalized)
                totalLines.append(line)
            }
            lines = filterBySource(totalLines, source: source)
            lines = try filter(lines, pattern: pattern, flags: flags)
            if !shouldPoll || !lines.isEmpty {
                break
            }
            usleep(useconds_t(IOSUseProtocol.flowNSLogConnectPollMilliseconds * IOSUseProtocol.microsecondsPerMillisecond))
        } while Date() < deadline
        return formatLogOutput(lines)
    }

    public static func fetch(
        udid: String,
        pattern: String?,
        flags: String?,
        source: OSLogOptions.SourceFilter,
        timeout: Double?,
        paths: IOSUsePaths,
        deviceTypeHint: String? = nil,
        outputSink: ((String) -> Void)? = nil
    ) throws -> String {
        let simulator: Bool
        if deviceTypeHint == "simulator" {
            simulator = true
        } else if deviceTypeHint == "real" {
            simulator = false
        } else if DeviceService.looksLikeSimulatorUDID(udid) {
            let normalized = normalizeUdid(udid)
            let booted = try DeviceService.listDevices(simulatorOnly: true, paths: paths)
                .contains { normalizeUdid($0.udid) == normalized }
            guard booted else {
                throw CLIParseError.invalidValue("Simulator \(udid) is not booted or not found.")
            }
            simulator = true
        } else {
            simulator = false
        }
        if simulator {
            return try fetchSimulator(
                udid: udid,
                pattern: pattern,
                flags: flags,
                source: source,
                timeout: timeout,
                paths: paths
            )
        }

        let regex = try patternRegex(pattern: pattern, flags: flags)
        var output = ""
        let emit: (String) -> Void = { line in
            let rendered = line.hasSuffix("\n") ? line : "\(line)\n"
            output += rendered
            outputSink?(rendered)
        }

        if RealDeviceOSTraceService.collectorForTesting != nil {
            let lines = try RealDeviceOSTraceService.collectActivity(udid: udid, timeoutSeconds: timeout, source: source)
            for line in try filter(lines, regex: regex) {
                emit(line)
            }
            return outputSink == nil ? output : ""
        }

        try RealDeviceOSTraceService.streamActivity(udid: udid, timeoutSeconds: timeout, source: source) { event in
            if matches(event.rawLine, regex: regex) {
                emit(event.rawLine)
            }
        }
        return outputSink == nil ? output : ""
    }

    static func resetSimulatorLogCollectorForTesting() {
        simulatorLogCollector = collectSimulatorLog
    }

    private static func filterBySource(_ lines: [String], source: OSLogOptions.SourceFilter) -> [String] {
        guard source.process != nil || source.pid != nil else { return lines }
        let processRegex = try? NSRegularExpression(pattern: #"^\S+\s+\d+\s+\d+:\d+:\d+(?:\.\d+)?\s+\S+\s+([\w.-]+)(?:\([^)]*\))?\[(\d+)\]"#)
        return lines.filter { line in
            guard let processRegex,
                  let found = processRegex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                  found.numberOfRanges > 2,
                  let processRange = Range(found.range(at: 1), in: line),
                  let pidRange = Range(found.range(at: 2), in: line) else {
                return false
            }
            if let process = source.process, String(line[processRange]) != process {
                return false
            }
            if let pid = source.pid, Int(line[pidRange]) != pid {
                return false
            }
            return true
        }
    }

    private static func filter(_ lines: [String], pattern: String?, flags: String?) throws -> [String] {
        try filter(lines, regex: patternRegex(pattern: pattern, flags: flags))
    }

    private static func filter(_ lines: [String], regex: NSRegularExpression?) throws -> [String] {
        guard let regex else { return lines }
        return lines.filter { matches($0, regex: regex) }
    }

    private static func patternRegex(pattern: String?, flags: String?) throws -> NSRegularExpression? {
        guard let pattern, !pattern.isEmpty else { return nil }
        let options = try regexOptions(flags ?? "")
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ line: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return true }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, range: range) != nil
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

    private static func collectSimulatorLog(udid: String, lastSec: Double, source: OSLogOptions.SourceFilter) throws -> [String] {
        _ = source
        let args = ["simctl", "spawn", udid, "log", "show", "--style", "compact", "--last", "\(lastSec)s"]
        let output = (try? Shell.run("xcrun", arguments: args)) ?? ""
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func formatLogOutput(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func normalizeUdid(_ udid: String) -> String {
        udid.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

enum OSLogCommandService {
    static func run(options: OSLogOptions, paths: IOSUsePaths, hostDeviceTypeHint: String? = nil, outputSink: ((String) -> Void)? = nil) throws -> String {
        let activeDriver = SessionService.read(paths: paths)
        let udid = try SessionService.resolveTargetUdid(
            explicitUdid: options.session.udid,
            paths: paths,
            missingMessage: "oslog requires --udid or an active driver. Run `ios-use start <UDID>` or pass `--udid <UDID>`."
        )
        return try OSLogService.fetch(
            udid: udid,
            pattern: options.pattern,
            flags: options.flags,
            source: options.source,
            timeout: options.timeout,
            paths: paths,
            deviceTypeHint: hostDeviceTypeHint ?? (activeDriver?.udid == udid ? activeDriver?.deviceType : nil),
            outputSink: outputSink
        )
    }
}
