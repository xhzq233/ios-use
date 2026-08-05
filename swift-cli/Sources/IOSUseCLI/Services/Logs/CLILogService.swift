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
        let descriptor = Darwin.open(
            logPath,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            return
        }
        defer { flock(descriptor, LOCK_UN) }
        let data = Data(content.utf8)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
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
