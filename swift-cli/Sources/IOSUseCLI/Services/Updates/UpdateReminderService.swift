import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum UpdateReminderService {
    struct Release: Decodable {
        let tag_name: String
        let prerelease: Bool
        let draft: Bool
    }

    struct Cache: Codable {
        let checkedAt: Date
        var remindedAt: Date?
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Called by the executable after printing a successful command's result.
    /// Automation never reaches the network or writes the reminder cache.
    public static func reminder(arguments: [String], result: CLIResult, paths: IOSUsePaths) -> String? {
        reminder(arguments: arguments, result: result, paths: paths,
                 environment: ProcessInfo.processInfo.environment,
                 interactive: isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && isatty(STDERR_FILENO) == 1)
    }

    static func reminder(
        arguments: [String], result: CLIResult, paths: IOSUsePaths,
        environment: [String: String], interactive: Bool, now: Date = Date(),
        fetch: () throws -> Release = fetchLatestRelease
    ) -> String? {
        guard interactive, environment["CI"] == nil, result.exitCode == 0,
              let invocation = try? CLIParser.parseInvocation(arguments),
              !invocation.json,
              ["start", "status"].contains(invocation.command.commandName) else { return nil }

        let url = URL(fileURLWithPath: paths.updateReminderCache)
        // Concurrent interactive observations share the daily attempt. Skip an
        // in-flight check rather than wait for another command's network request.
        guard (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { return nil }
        let descriptor = open(url.deletingPathExtension().appendingPathExtension("lock").path,
                              O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        let previous = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        if let previous, now.timeIntervalSince(previous.checkedAt) < checkInterval { return nil }

        var cache = Cache(checkedAt: now, remindedAt: previous?.remindedAt)
        // Record attempts before contacting GitHub, including offline failures.
        // If this Home cannot store the cache, skip rather than query every command.
        guard save(cache, to: url), let release = try? fetch(),
              !release.prerelease, !release.draft,
              isNewerStableRelease(release.tag_name, than: IOSUseCLI.version) else { return nil }
        if let remindedAt = cache.remindedAt, now.timeIntervalSince(remindedAt) < checkInterval { return nil }
        cache.remindedAt = now
        guard save(cache, to: url) else { return nil }

        return """
        Update available: ios-use \(IOSUseCLI.version) → \(release.tag_name).
        When your automation session is finished, run:
          curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/\(release.tag_name)/scripts/install.sh | bash -s -- --version \(release.tag_name)

        """
    }

    static func isNewerStableRelease(_ tag: String, than current: String) -> Bool {
        func parse(_ value: String) -> (numbers: [Int], prerelease: Bool)? {
            let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
            guard !version.isEmpty else { return nil }
            let parts = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3,
                  components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
            let numbers = components.compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            if parts.count == 2 {
                guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            }
            return (numbers, parts.count == 2)
        }
        guard let available = parse(tag), !available.prerelease, let installed = parse(current) else { return false }
        if available.numbers != installed.numbers {
            return installed.numbers.lexicographicallyPrecedes(available.numbers)
        }
        return installed.prerelease
    }

    private static func save(_ cache: Cache, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    private static func fetchLatestRelease() throws -> Release {
        // curl is already required by the installer on both supported hosts.
        // Bound the whole request, and let the caller silently skip any failure.
        let json = try Shell.run("curl", arguments: [
            "--fail", "--silent", "--max-time", "1", "--connect-timeout", "1",
            "--header", "Accept: application/vnd.github+json",
            "--header", "User-Agent: ios-use-update-check",
            "https://api.github.com/repos/xhzq233/ios-use/releases/latest",
        ])
        return try JSONDecoder().decode(Release.self, from: Data(json.utf8))
    }
}
