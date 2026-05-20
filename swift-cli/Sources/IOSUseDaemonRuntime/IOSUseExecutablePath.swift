import Darwin
import Foundation

public enum IOSUseExecutablePath {
    public static func current(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        if let dyldPath = dyldExecutablePath() {
            return dyldPath
        }
        return resolve(
            arguments.first ?? "ios-use",
            environment: environment,
            currentDirectory: currentDirectory
        )
    }

    public static func resolve(
        _ executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        if executablePath.hasPrefix("/") {
            return URL(fileURLWithPath: executablePath).standardized.path
        }
        if executablePath.contains("/") {
            return URL(fileURLWithPath: currentDirectory)
                .appendingPathComponent(executablePath)
                .standardized
                .path
        }
        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":", omittingEmptySubsequences: false) {
                let searchDirectory = directory.isEmpty ? currentDirectory : String(directory)
                let candidate = URL(fileURLWithPath: searchDirectory)
                    .appendingPathComponent(executablePath)
                    .standardized
                    .path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return URL(fileURLWithPath: currentDirectory)
            .appendingPathComponent(executablePath)
            .standardized
            .path
    }

    private static func dyldExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        guard _NSGetExecutablePath(buffer, &size) == 0 else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath()
            .standardized
            .path
    }
}
