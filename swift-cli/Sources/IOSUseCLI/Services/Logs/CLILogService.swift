import Foundation

enum CLILogService {
    static func logPath(paths: IOSUsePaths) -> String {
        "\(paths.logs)/cli.log"
    }

    static func holderLogPath(paths: IOSUsePaths) -> String {
        "\(paths.logs)/xctest-holder.log"
    }

    static func coreDeviceLogPath(paths: IOSUsePaths) -> String {
        "\(paths.logs)/coredevice.log"
    }

    static func append(paths: IOSUsePaths, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        append(logPath: logPath(paths: paths), lines)
    }

    static func appendHolder(paths: IOSUsePaths, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        append(logPath: holderLogPath(paths: paths), lines)
    }

    static func appendCoreDevice(paths: IOSUsePaths, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        append(logPath: coreDeviceLogPath(paths: paths), lines)
    }

    static func append(logPath: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
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
}
