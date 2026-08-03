import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import PlayCoverUpstream

/// Loads the exact pinned sandbox rules used while preparing a Mac App.
/// Release installs provide the file beside the Runtime resources; source
/// checkouts use the vendored upstream file directly.
enum PlayCoverRulesService {
    static let installedFilename = "default-sandbox-rules.yaml"
    static let maximumBytes = 64 * 1_024

    static var rulesPathOverrideForTesting: (() throws -> String)?

    static func ensureAvailable() throws -> Data {
        let url: URL
        if let rulesPathOverrideForTesting {
            url = URL(fileURLWithPath: try rulesPathOverrideForTesting())
                .standardizedFileURL
        } else {
            let candidates = rulesCandidates(
                executablePath: try currentExecutablePath(),
                currentDirectory: FileManager.default.currentDirectoryPath
            )
            guard let candidate = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "mac sandbox rules (installed resource is missing; "
                        + "searched: "
                        + candidates.map(\.path).joined(separator: ", ")
                )
            }
            url = candidate
        }

        #if canImport(Darwin)
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= maximumBytes else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "mac sandbox rules (resource must be one bounded regular file)"
            )
        }
        #endif

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PlayCoverBackendError.capabilityUnavailable(
                "mac sandbox rules (cannot read installed resource: \(error))"
            )
        }
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        guard digest == PlayCoverUpstreamEngine.defaultRulesRevision else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "mac sandbox rules (resource digest does not match the "
                    + "pinned Mac backend source)"
            )
        }
        return data
    }

    static func rulesCandidates(
        executablePath: String,
        currentDirectory: String
    ) -> [URL] {
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .standardizedFileURL.deletingLastPathComponent()
        let workingDirectory = URL(
            fileURLWithPath: currentDirectory,
            isDirectory: true
        ).standardizedFileURL
        let sourceSuffix = "ThirdParty/PlayCover/PlayCover/Rules/default.yaml"
        let candidates = [
            executableDirectory
                .appendingPathComponent(sourceSuffix),
            workingDirectory
                .appendingPathComponent(sourceSuffix),
            workingDirectory
                .deletingLastPathComponent()
                .appendingPathComponent(sourceSuffix),
            executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("ios-use", isDirectory: true)
                .appendingPathComponent("mac", isDirectory: true)
                .appendingPathComponent(installedFilename),
        ]
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.path).inserted }
    }

    private static func currentExecutablePath() throws -> String {
        if let value = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: value) {
            return value
        }
        guard let argument = ProcessInfo.processInfo.arguments.first,
              !argument.isEmpty else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "mac sandbox rules (cannot resolve the ios-use executable)"
            )
        }
        return URL(fileURLWithPath: argument).standardizedFileURL.path
    }
}
