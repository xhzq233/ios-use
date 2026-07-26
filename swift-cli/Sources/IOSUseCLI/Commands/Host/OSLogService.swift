import Foundation
import IOSUseProtocol

public enum OSLogService {
    typealias SimulatorLogCollector = (_ udid: String, _ lastSec: Double, _ source: OSLogOptions.SourceFilter) throws -> [String]
    static var simulatorLogCollector: SimulatorLogCollector = collectSimulatorLog
    typealias PlayCoverLogCollector = (
        _ pid: Int32,
        _ lastSec: Double,
        _ predicate: String
    ) throws -> [String]
    static var playCoverLogCollector: PlayCoverLogCollector =
        collectPlayCoverLog

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
            usleep(useconds_t(IOSUseProtocol.nslogConnectPollMilliseconds * IOSUseProtocol.microsecondsPerMillisecond))
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

    static func resetPlayCoverLogCollectorForTesting() {
        playCoverLogCollector = collectPlayCoverLog
    }

    static func fetchPlayCover(
        session: SessionService.Info,
        pattern: String?,
        flags: String?,
        source: OSLogOptions.SourceFilter,
        timeout: Double?
    ) throws -> String {
        guard let runnerPID = session.runnerPid,
              runnerPID > 0,
              runnerPID <= Int(Int32.max),
              let executablePath =
                session.playCoverExecutablePath,
              !executablePath.isEmpty else {
            throw CLIParseError.invalidValue(
                "active PlayCover session has incomplete PID/executable identity"
            )
        }
        let pid = Int32(runnerPID)
        guard let actualExecutable =
                PlayCoverRuntimeClient.executablePath(for: pid),
              PlayCoverRuntimeClient.canonicalPath(
                  actualExecutable
              ) == PlayCoverRuntimeClient.canonicalPath(
                  executablePath
              ) else {
            throw CLIParseError.invalidValue(
                "active PlayCover PID no longer belongs to the exact App executable"
            )
        }
        if let requestedPID = source.pid,
           requestedPID != runnerPID {
            throw CLIParseError.invalidValue(
                "PlayCover oslog is scoped to active PID \(runnerPID)"
            )
        }
        let executableName = URL(
            fileURLWithPath: executablePath
        ).lastPathComponent
        if let requestedProcess = source.process,
           requestedProcess != executableName {
            throw CLIParseError.invalidValue(
                "PlayCover oslog is scoped to active executable \(executableName)"
            )
        }

        let lastSeconds = min(
            max(
                timeout
                    ?? IOSUseProtocol
                        .oslogDefaultSimulatorLastSeconds,
                0.1
            ),
            60
        )
        let predicate = "processIdentifier == \(runnerPID)"
        var lines = try playCoverLogCollector(
            pid,
            lastSeconds,
            predicate
        )
        if let diagnostics = try boundedRuntimeDiagnostics(
            session: session
        ) {
            lines.append(diagnostics)
        }
        let regex = try patternRegex(
            pattern: pattern,
            flags: flags
        )
        let filtered = try filter(lines, regex: regex)
        let bounded = Array(filtered.prefix(2_000))
        let output = formatLogOutput(bounded)
        guard output.utf8.count <= 1_048_576 else {
            let prefix = String(
                decoding: output.utf8.prefix(1_048_000),
                as: UTF8.self
            )
            return prefix
                + "\n[ios-use] PlayCover log output truncated\n"
        }
        return output
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

    private static func collectPlayCoverLog(
        pid: Int32,
        lastSec: Double,
        predicate: String
    ) throws -> [String] {
        _ = pid
        let output = try Shell.run(
            "/usr/bin/log",
            arguments: [
                "show",
                "--style", "compact",
                "--last", playCoverLogLastArgument(lastSec),
                "--predicate", predicate,
            ]
        )
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func playCoverLogLastArgument(_ lastSec: Double) -> String {
        // macOS `log show` only accepts minute/hour/day suffixes for --last.
        // Round the bounded PlayCover interval up to the smallest supported
        // window; exact PID and the caller's regex still constrain results.
        let minutes = max(1, Int(ceil(lastSec / 60)))
        return "\(minutes)m"
    }

    private static func boundedRuntimeDiagnostics(
        session: SessionService.Info
    ) throws -> String? {
        let client = try PlayCoverDriverClient.runtimeClient(
            for: session,
            timeoutSeconds: 0.75
        )
        let response = try client.diagnostics()
        guard !response.diagnostics.isEmpty else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response.diagnostics)
        let bounded = data.prefix(64 * 1024)
        return "[ios-use-runtime] "
            + String(decoding: bounded, as: UTF8.self)
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
        if let activeDriver,
           activeDriver.deviceType
            == PlayCoverSessionService.deviceType {
            if let explicit = options.session.udid,
               explicit != activeDriver.udid {
                throw CLIParseError.invalidValue(
                    "oslog target \(explicit) does not match active "
                        + "PlayCover target \(activeDriver.udid)"
                )
            }
            let output = try OSLogService.fetchPlayCover(
                session: activeDriver,
                pattern: options.pattern,
                flags: options.flags,
                source: options.source,
                timeout: options.timeout
            )
            if let outputSink {
                outputSink(output)
                return ""
            }
            return output
        }
        let udid = try SessionService.resolveTargetUdid(
            explicitUdid: options.session.udid,
            paths: paths,
            missingMessage: "oslog requires --udid or an active driver. Run `ios-use start` or pass `--udid <UDID>`."
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
