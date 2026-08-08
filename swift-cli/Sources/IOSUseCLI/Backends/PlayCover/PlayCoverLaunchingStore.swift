import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverLaunchingStoreError:
    Error,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    let message: String

    var description: String {
        "Invalid Mac launching record: \(message)"
    }
}

/// One Home-local crash handle for the NSWorkspace submit-to-hello window.
/// It is deliberately not a phase journal and never grants process ownership.
enum PlayCoverLaunchingStore {
    static let maximumBytes = 64 * 1_024

    struct Record: Codable, Equatable, Sendable {
        let sessionID: String
        let runtimeSocketPath: String
        let bundleIdentifier: String
        let executableRelativePath: String
        let submittedAt: Int64
        let logPath: String?
    }

    private static let processLock = NSLock()

    static func create(
        _ record: Record,
        paths: IOSUsePaths
    ) throws {
        try validate(record, paths: paths)
        processLock.lock()
        defer { processLock.unlock() }
        if try readUnlocked(paths: paths) != nil {
            throw PlayCoverLaunchingStoreError(
                message: "another launch is unresolved"
            )
        }
        try write(record, paths: paths)
    }

    static func load(paths: IOSUsePaths) throws -> Record? {
        processLock.lock()
        defer { processLock.unlock() }
        return try readUnlocked(paths: paths)
    }

    static func remove(
        sessionID: String,
        paths: IOSUsePaths
    ) throws {
        processLock.lock()
        defer { processLock.unlock() }
        guard let current = try readUnlocked(paths: paths) else {
            return
        }
        guard current.sessionID == sessionID else {
            throw PlayCoverLaunchingStoreError(
                message: "record belongs to another session"
            )
        }
        do {
            try FileManager.default.removeItem(
                atPath: paths.playcoverLaunching
            )
        } catch {
            if !FileManager.default.fileExists(
                atPath: paths.playcoverLaunching
            ) {
                return
            }
            throw error
        }
    }

    private static func readUnlocked(
        paths: IOSUsePaths
    ) throws -> Record? {
        #if canImport(Darwin)
        var status = stat()
        guard lstat(paths.playcoverLaunching, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw PlayCoverLaunchingStoreError(
                message: "cannot inspect record: errno \(errno)"
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw PlayCoverLaunchingStoreError(
                message: "record is not a bounded owner-only file"
            )
        }
        #else
        guard FileManager.default.fileExists(
            atPath: paths.playcoverLaunching
        ) else { return nil }
        #endif
        let data = try Data(
            contentsOf: URL(fileURLWithPath: paths.playcoverLaunching)
        )
        guard data.count <= maximumBytes else {
            throw PlayCoverLaunchingStoreError(
                message: "record exceeds its size limit"
            )
        }
        let record: Record
        do {
            guard let object = try JSONSerialization
                    .jsonObject(with: data) as? [String: Any] else {
                throw PlayCoverLaunchingStoreError(
                    message: "record is not a JSON object"
                )
            }
            let required = Set([
                "sessionID",
                "runtimeSocketPath",
                "bundleIdentifier",
                "executableRelativePath",
                "submittedAt",
            ])
            let allowed = required.union(["logPath"])
            guard Set(object.keys).isSuperset(of: required),
                  Set(object.keys).isSubset(of: allowed) else {
                throw PlayCoverLaunchingStoreError(
                    message: "record has missing or unknown fields"
                )
            }
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch let error as PlayCoverLaunchingStoreError {
            throw error
        } catch {
            throw PlayCoverLaunchingStoreError(
                message: "record is not valid JSON"
            )
        }
        try validate(record, paths: paths)
        return record
    }

    private static func write(
        _ record: Record,
        paths: IOSUsePaths
    ) throws {
        let parent = URL(fileURLWithPath: paths.playcoverLaunching)
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if canImport(Darwin)
        guard chmod(parent.path, 0o700) == 0 else {
            throw PlayCoverLaunchingStoreError(
                message: "cannot secure record directory: errno \(errno)"
            )
        }
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= maximumBytes else {
            throw PlayCoverLaunchingStoreError(
                message: "record exceeds its size limit"
            )
        }
        try data.write(
            to: URL(fileURLWithPath: paths.playcoverLaunching),
            options: .atomic
        )
        #if canImport(Darwin)
        guard chmod(paths.playcoverLaunching, 0o600) == 0 else {
            throw PlayCoverLaunchingStoreError(
                message: "cannot secure record: errno \(errno)"
            )
        }
        #endif
    }

    private static func validate(
        _ record: Record,
        paths: IOSUsePaths
    ) throws {
        guard UUID(uuidString: record.sessionID) != nil,
              record.submittedAt > 0 else {
            throw PlayCoverLaunchingStoreError(
                message: "session identity or submission time is invalid"
            )
        }
        try PlayCoverSlotService.validateBundleIdentifier(
            record.bundleIdentifier
        )
        guard !record.executableRelativePath.isEmpty,
              !record.executableRelativePath.hasPrefix("/"),
              record.executableRelativePath.utf8.count <= 1_024,
              !record.executableRelativePath.split(separator: "/")
                .contains("..") else {
            throw PlayCoverLaunchingStoreError(
                message: "relative executable path is invalid"
            )
        }
        let expectedSocket = try paths.macRuntimeSocketPath(
            sessionID: record.sessionID
        )
        guard PlayCoverRuntimeClient.canonicalPath(
                record.runtimeSocketPath
              ) == PlayCoverRuntimeClient.canonicalPath(expectedSocket) else {
            throw PlayCoverLaunchingStoreError(
                message: "Runtime socket does not match sessionID"
            )
        }
        if let logPath = record.logPath {
            try PlayCoverStdioLogService.validateSessionPath(
                logPath,
                sessionID: record.sessionID,
                paths: paths
            )
        }
    }
}
