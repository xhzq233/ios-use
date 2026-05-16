import Foundation

public enum OSLogService {
    public static func clear() -> String {
        // Swift CLI is process-per-command, so there is no durable in-memory buffer yet.
        // Keep the user-visible contract stable for clear commands.
        "  → oslog: cleared=0\n"
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
        let lastSec = timeout.flatMap { $0 > 0 ? $0 : nil } ?? 60
        var args = ["simctl", "spawn", udid, "log", "show", "--style", "compact", "--last", "\(lastSec)s"]
        if let bundleId, !bundleId.isEmpty {
            args.append(contentsOf: ["--predicate", "process CONTAINS \"\(bundleId)\""])
        }
        let output = (try? Shell.run("xcrun", arguments: args)) ?? ""
        let lines = try filter(output.split(separator: "\n").map(String.init), pattern: pattern, flags: flags)
        let content = lines.joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let outputName = name?.isEmpty == false ? name! : "oslog"
        let path = "\(paths.artifacts)/\(outputName).log"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return "  → oslog: matched=\(lines.count) total=\(output.split(separator: "\n").count) → \(path)\n"
    }

    private static func filter(_ lines: [String], pattern: String?, flags: String?) throws -> [String] {
        guard let pattern, !pattern.isEmpty else { return lines }
        var options: NSRegularExpression.Options = []
        if flags?.contains("i") == true {
            options.insert(.caseInsensitive)
        }
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        return lines.filter { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return regex.firstMatch(in: line, range: range) != nil
        }
    }
}
