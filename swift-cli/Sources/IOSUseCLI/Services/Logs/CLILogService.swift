import Darwin
import Foundation

enum CLILogService {
    static func logPath(paths: IOSUsePaths) -> String {
        "\(paths.logs)/cli.log"
    }

    static func holderLogPath(paths: IOSUsePaths) -> String {
        "\(paths.logs)/xctest-holder.log"
    }

    static func append(paths: IOSUsePaths, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        append(logPath: logPath(paths: paths), lines)
    }

    static func appendHolder(paths: IOSUsePaths, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        append(logPath: holderLogPath(paths: paths), lines)
    }

    static func append(logPath: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        let timestamp = formatTimestamp(Date())
        let content = lines.map { "\(timestamp) \($0)" }.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(content.utf8))
        try? handle.close()
    }

    static func formatTimestamp(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var seconds = time_t(interval.rounded(.down))
        var milliseconds = Int(((interval - Double(seconds)) * 1000).rounded())
        if milliseconds >= 1000 {
            seconds += 1
            milliseconds = 0
        }
        var tmValue = tm()
        gmtime_r(&seconds, &tmValue)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            tmValue.tm_year + 1900,
            tmValue.tm_mon + 1,
            tmValue.tm_mday,
            tmValue.tm_hour,
            tmValue.tm_min,
            tmValue.tm_sec,
            milliseconds
        )
    }
}
