import Foundation
import IOSUseProtocol

enum LogFileReadService {
    static func read(
        logFile: String,
        status: String,
        missingFileMessage: String,
        pattern: String?,
        flags: String,
        timeout: Double,
        clearAfterRead: Bool,
        last: Int?,
        interruptMonitor: InterruptMonitor? = nil
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: logFile) else {
            throw CLIParseError.invalidValue(missingFileMessage)
        }
        let regex = try pattern.flatMap { $0.isEmpty ? nil : try NSRegularExpression(pattern: $0, options: regexOptions(flags)) }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        let canWait = status == "running" && timeout > 0
        var lines: [String] = []
        repeat {
            try interruptMonitor?.throwIfInterrupted()
            lines = try readMatchingLines(logFile: logFile, regex: regex)
            if !lines.isEmpty || !canWait {
                break
            }
            usleep(useconds_t(IOSUseProtocol.flowNSLogConnectPollMilliseconds * IOSUseProtocol.microsecondsPerMillisecond))
        } while Date() < deadline
        try interruptMonitor?.throwIfInterrupted()

        if let last {
            lines = Array(lines.suffix(last))
        }
        if clearAfterRead {
            try Data().write(to: URL(fileURLWithPath: logFile))
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    static func matches(_ entry: String, pattern: String, flags: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern, options: regexOptions(flags))
        return matches(entry, regex: regex)
    }

    static func matches(_ entry: String, regex: NSRegularExpression) -> Bool {
        let range = NSRange(entry.startIndex..<entry.endIndex, in: entry)
        return regex.firstMatch(in: entry, range: range) != nil
    }

    static func regexOptions(_ flags: String) throws -> NSRegularExpression.Options {
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

    private static func readMatchingLines(logFile: String, regex: NSRegularExpression?) throws -> [String] {
        let text = try String(contentsOfFile: logFile, encoding: .utf8)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let regex else {
            return lines.filter { !$0.isEmpty }
        }
        return lines.filter { !$0.isEmpty && matches($0, regex: regex) }
    }
}
