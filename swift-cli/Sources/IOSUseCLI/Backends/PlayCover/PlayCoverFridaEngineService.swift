import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif
import PlayCoverUpstream

/// Resolves the optional, pinned Catalyst Engine installed beside ios-use.
/// The normal Runtime never calls this service, and only a Frida preparation
/// copies the verified framework into a prepared App generation.
enum PlayCoverFridaEngineService {
    static let frameworkName = "IOSUseFridaEngine.framework"
    static let descriptorVersion = "16.5.6"
    static let descriptorSourceCommit =
        "0afeb85fcdeae1d995a55bc07f0fe57b197aecae"
    static let descriptorEngineABI =
        "ios-use-frida-engine-cabi-v2"
    static let descriptorAgentSHA256 =
        "caea6087cd5d346f9cf7a258248306f607348475f992fc08f7a55eddc9e93a1d"
    static let descriptorSourceClosureSHA256 =
        "a865265e7ffffb83ef1101fb921a5d8ea7f7c4734d724f802088bd1aa979988e"

    private struct FrameworkEvidence {
        let sha256: String
        let size: UInt64
        let platform: UInt32
        let cpuType: Int32
    }

    /// The verified immutable Engine object selected for one prepare.  The
    /// digest is part of the prepared generation identity; callers must pass
    /// this value through the preparation plan instead of recomputing it from
    /// the framework after publication.
    struct Resolved: Equatable, Sendable {
        let path: String
        let sha256: String
        let size: UInt64
        let platform: UInt32
        let cpuType: Int32
    }

    static var frameworkPathOverrideForTesting: (() throws -> String)?

    static func ensureAvailable() throws -> Resolved {
        let framework = try resolveInstalledFramework()
        let publishedEvidence = try validateFramework(framework)
        return Resolved(
            path: framework.path,
            sha256: publishedEvidence.sha256,
            size: publishedEvidence.size,
            platform: publishedEvidence.platform,
            cpuType: publishedEvidence.cpuType
        )
    }

    private static func resolveInstalledFramework() throws -> URL {
        if let frameworkPathOverrideForTesting {
            return URL(
                fileURLWithPath: try frameworkPathOverrideForTesting(),
                isDirectory: true
            ).standardizedFileURL
        }
        let candidates = frameworkCandidates(
            executablePath: try currentExecutablePath()
        )
        if let installed = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return installed
        }
        throw PlayCoverBackendError.capabilityUnavailable(
            "frida-engine (pinned \(descriptorVersion) installed resource "
                + "is missing; searched: "
                + candidates.map(\.path).joined(separator: ", ")
        )
    }

    static func frameworkCandidates(
        executablePath: String
    ) -> [URL] {
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .standardizedFileURL.deletingLastPathComponent()
        return [
            executableDirectory
                .appendingPathComponent(".ios-use", isDirectory: true)
                .appendingPathComponent("playcover", isDirectory: true)
                .appendingPathComponent(frameworkName, isDirectory: true),
            executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("ios-use", isDirectory: true)
                .appendingPathComponent("mac", isDirectory: true)
                .appendingPathComponent(frameworkName, isDirectory: true),
        ]
    }

    private static func currentExecutablePath() throws -> String {
        if let value = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: value) {
            return value
        }
        guard let argument = ProcessInfo.processInfo.arguments.first,
              !argument.isEmpty else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (cannot resolve the ios-use executable)"
            )
        }
        if argument.hasPrefix("/") {
            return URL(fileURLWithPath: argument)
                .standardizedFileURL.path
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(argument).standardizedFileURL.path
    }

    private static func validateFramework(
        _ url: URL
    ) throws -> FrameworkEvidence {
        try rejectSymbolicLink(
            at: url,
            label: "Frida Engine framework"
        )
        var isDirectory: ObjCBool = false
        guard url.lastPathComponent == frameworkName,
              FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (framework directory is invalid)"
            )
        }
        let executable = url.appendingPathComponent("IOSUseFridaEngine")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (framework executable is missing)"
            )
        }
        let inspection: PlayCoverUpstreamMachOInspection
        do {
            inspection = try PlayCoverUpstreamEngine.inspectMachO(
                at: executable,
                relativePath: executable.lastPathComponent
            )
        } catch {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (Mach-O inspection failed: \(error))"
            )
        }
        guard inspection.platform == PlayCoverUpstreamEngine.platformMacCatalyst,
              inspection.cpuType == 0x0100_000c,
              !inspection.encrypted else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (requires unencrypted arm64 Mac Catalyst code)"
            )
        }
        try validateFrameworkMetadata(url)
        try validateABISymbols(executable)
        let digest = try digestFramework(url)
        return FrameworkEvidence(
            sha256: digest.sha256,
            size: digest.size,
            platform: inspection.platform ?? 0,
            cpuType: inspection.cpuType
        )
    }

    static func validateFrameworkMetadata(_ url: URL) throws {
        let infoURL = url.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              object["CFBundleShortVersionString"] as? String
                == descriptorVersion,
              object["IOSUseFridaEngineABI"] as? String
                == descriptorEngineABI,
              object["IOSUseFridaSourceCommit"] as? String
                == descriptorSourceCommit,
              object["IOSUseFridaAgentSHA256"] as? String
                == descriptorAgentSHA256,
              object["IOSUseFridaSourceClosureSHA256"] as? String
                == descriptorSourceClosureSHA256 else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (framework metadata does not match the pinned ABI/agent)"
            )
        }
    }

    private static func validateABISymbols(_ executable: URL) throws {
        let result: Shell.RunResult
        do {
            result = try Shell.runWithResult(
                "/usr/bin/nm",
                arguments: ["-gU", executable.path]
            )
        } catch {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (ABI symbol inspection failed: \(error))"
            )
        }
        let symbols = result.stdout
        for symbol in [
            "_IOSUseFridaEngineCreate",
            "_IOSUseFridaEngineReset",
            "_IOSUseFridaEngineSetEventCallback",
            "_IOSUseFridaEngineClearEventCallback",
            "_IOSUseFridaEngineEvaluate",
        ] where !symbols.contains(symbol) {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (missing pinned ABI symbol \(symbol))"
            )
        }
    }

    private static func digestFramework(
        _ url: URL
    ) throws -> (sha256: String, size: UInt64) {
        var files: [(String, URL, UInt64)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: []
        ) else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (framework inventory could not be read)"
            )
        }
        for case let child as URL in enumerator {
            let relative = String(
                child.path.dropFirst(url.path.count + 1)
            )
            let values = try child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isSymbolicLink != true else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (framework contains a symbolic link)"
                )
            }
            if values.isDirectory == true {
                continue
            }
            guard let size = values.fileSize else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (framework file has no size)"
                )
            }
            files.append((relative, child, UInt64(size)))
        }
        files.sort { $0.0 < $1.0 }
        var hasher = SHA256()
        var total: UInt64 = 0
        func append(_ data: Data) {
            hasher.update(data: data)
        }
        func appendLength(_ length: UInt64) {
            var value = length.bigEndian
            append(Data(bytes: &value, count: MemoryLayout<UInt64>.size))
        }
        for (relative, file, size) in files {
            let pathData = Data(relative.utf8)
            appendLength(UInt64(pathData.count))
            append(pathData)
            appendLength(size)
            let content = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard UInt64(content.count) == size else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (framework file changed while hashing)"
                )
            }
            append(content)
            total += size
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return (digest, total)
    }

    private static func rejectSymbolicLink(
        at url: URL,
        label: String
    ) throws {
        #if canImport(Darwin)
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (cannot inspect \(label): errno \(errno))"
                )
            }
            return
        }
        guard status.st_mode & S_IFMT != S_IFLNK else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (\(label) is a symbolic link)"
            )
        }
        #else
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (\(label) is a symbolic link)"
            )
        }
        #endif
    }
}
