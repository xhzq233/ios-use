import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif
import PlayCoverUpstream

/// Resolves the optional, pinned Catalyst Engine object used by a Frida
/// generation. The normal Runtime never calls this service. In production the
/// release asset is supplied through the updater; the environment override is
/// intentionally only a developer/test acquisition input and is never read by
/// Runtime or from a Home config file.
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
    static let descriptorFrameworkSHA256 =
        "9e6d4844b76f71cb2fd46ef3e827b33df5fca4674be9a054395f0331f9bc6e3b"
    static let descriptorFrameworkSize: UInt64 = 8_973_197
    static let descriptorRevision =
        "+frida-engine-\(descriptorVersion)-\(descriptorSourceCommit)"
        + "+agent-\(descriptorAgentSHA256)"
        + "+engine-\(descriptorFrameworkSHA256)"

    private static let completedFilename = "completed.json"

    private struct Completed: Codable {
        let descriptorVersion: String
        let descriptorSourceCommit: String
        let agentSHA256: String
        let sourceClosureSHA256: String
        let frameworkSHA256: String
        let frameworkSize: UInt64
        let platform: UInt32
        let cpuType: Int32

        static let keys = Set([
            "descriptorVersion",
            "descriptorSourceCommit",
            "agentSHA256",
            "sourceClosureSHA256",
            "frameworkSHA256",
            "frameworkSize",
            "platform",
            "cpuType",
        ])
    }

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

    static func ensureAvailable(
        paths: IOSUsePaths
    ) throws -> Resolved {
        let objectDirectory = URL(
            fileURLWithPath: paths.playcoverFridaEngineObjects,
            isDirectory: true
        ).appendingPathComponent(
            descriptorFrameworkSHA256,
            isDirectory: true
        )
        let object = objectDirectory.appendingPathComponent(
            frameworkName,
            isDirectory: true
        )
        let marker = objectDirectory.appendingPathComponent(
            completedFilename
        )
        try ensureDirectory(paths.playcoverFridaEngineRoot)
        try ensureDirectory(paths.playcoverFridaEngineObjects)
        try ensureDirectory(paths.playcoverFridaEngineLocks)
        try rejectSymbolicLink(
            at: objectDirectory,
            label: "Frida Engine object directory"
        )
        try rejectSymbolicLink(
            at: marker,
            label: "Frida Engine completion marker"
        )
        let lockURL = URL(
            fileURLWithPath: paths.playcoverFridaEngineLocks,
            isDirectory: true
        ).appendingPathComponent(
            "\(descriptorFrameworkSHA256).lock"
        )
        #if canImport(Darwin)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "Frida Engine lock could not be opened: errno \(errno)"
            )
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "Frida Engine lock could not be acquired: errno \(errno)"
            )
        }
        #endif
        if FileManager.default.fileExists(atPath: object.path) {
            guard FileManager.default.fileExists(atPath: marker.path) else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (existing object has no completed marker)"
                )
            }
            let completed = try readCompleted(marker)
            guard completed.descriptorVersion == descriptorVersion,
                  completed.descriptorSourceCommit
                    == descriptorSourceCommit,
                  completed.frameworkSHA256 == descriptorFrameworkSHA256,
                  completed.frameworkSize == descriptorFrameworkSize,
                  completed.agentSHA256 == descriptorAgentSHA256,
                  completed.sourceClosureSHA256
                    == descriptorSourceClosureSHA256 else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (completed marker does not match the "
                        + "pinned descriptor)"
                )
            }
            let evidence = try validateFramework(object)
            guard evidence.sha256 == completed.frameworkSHA256,
                  evidence.size == completed.frameworkSize,
                  evidence.platform == completed.platform,
                  evidence.cpuType == completed.cpuType else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (completed object integrity mismatch)"
                )
            }
            return Resolved(
                path: object.path,
                sha256: evidence.sha256,
                size: evidence.size,
                platform: evidence.platform,
                cpuType: evidence.cpuType
            )
        }
        guard let sourcePath = ProcessInfo.processInfo.environment[
            "IOS_USE_FRIDA_ENGINE_PATH"
        ], !sourcePath.isEmpty else {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (pinned \(descriptorVersion) Catalyst asset is not installed)"
            )
        }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
            .standardizedFileURL
        _ = try validateFramework(source)
        let staging = objectDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                ".staging-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let stagedFramework = staging.appendingPathComponent(
                frameworkName,
                isDirectory: true
            )
            try FileManager.default.copyItem(at: source, to: stagedFramework)
            let evidence = try validateFramework(stagedFramework)
            guard evidence.sha256 == descriptorFrameworkSHA256,
                  evidence.size == descriptorFrameworkSize else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (asset digest/size does not match the "
                        + "pinned release descriptor)"
                )
            }
            try writeCompleted(
                Completed(
                    descriptorVersion: descriptorVersion,
                    descriptorSourceCommit: descriptorSourceCommit,
                    agentSHA256: descriptorAgentSHA256,
                    sourceClosureSHA256: descriptorSourceClosureSHA256,
                    frameworkSHA256: evidence.sha256,
                    frameworkSize: evidence.size,
                    platform: evidence.platform,
                    cpuType: evidence.cpuType
                ),
                to: staging.appendingPathComponent(completedFilename)
            )
            try FileManager.default.moveItem(at: staging, to: objectDirectory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        let publishedEvidence = try validateFramework(object)
        return Resolved(
            path: object.path,
            sha256: publishedEvidence.sha256,
            size: publishedEvidence.size,
            platform: publishedEvidence.platform,
            cpuType: publishedEvidence.cpuType
        )
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

    private static func validateFrameworkMetadata(_ url: URL) throws {
        let infoURL = url.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              object["IOSUseFridaEngineABI"] as? String
                == descriptorEngineABI,
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

    private static func readCompleted(_ url: URL) throws -> Completed {
        do {
            let data = try Data(
                contentsOf: url,
                options: [.mappedIfSafe]
            )
            guard let object = try JSONSerialization
                    .jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Completed.keys else {
                throw PlayCoverBackendError.capabilityUnavailable(
                    "frida-engine (completed marker has unknown fields)"
                )
            }
            return try JSONDecoder().decode(
                Completed.self,
                from: data
            )
        } catch {
            throw PlayCoverBackendError.capabilityUnavailable(
                "frida-engine (completed marker is invalid: \(error))"
            )
        }
    }

    private static func writeCompleted(
        _ completed: Completed,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(completed)
        try data.write(to: url, options: [.atomic])
        #if canImport(Darwin)
        guard chmod(url.path, 0o600) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "Frida Engine completed marker permissions could not be "
                    + "secured: errno \(errno)"
            )
        }
        #endif
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

    private static func ensureDirectory(_ path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try rejectSymbolicLink(at: url, label: "Frida Engine directory")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try rejectSymbolicLink(at: url, label: "Frida Engine directory")
        #if canImport(Darwin)
        guard chmod(url.path, 0o700) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "Frida Engine directory permissions could not be secured: errno \(errno)"
            )
        }
        #endif
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
