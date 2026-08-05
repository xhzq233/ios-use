import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Home-local reuse selection. Lifecycle commands never enumerate other Homes.
enum PlayCoverHomeStore {
    private struct LastGeneration: Codable, Equatable, Sendable {
        let generationKey: String
    }

    private static let maximumRecordBytes = 32 * 1_024
    private static let processLock = NSLock()

    static func readLast(paths: IOSUsePaths) throws -> String? {
        processLock.lock()
        defer { processLock.unlock() }
        guard let data = try readOwnerOnlyFile(
            at: paths.playcoverLastGeneration,
            maximumBytes: maximumRecordBytes,
            label: "Mac last-generation reference"
        ) else {
            return nil
        }
        let record: LastGeneration
        do {
            guard let object = try JSONSerialization
                    .jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["generationKey"]) else {
                throw PlayCoverBackendError.cacheTampered(
                    "Mac last-generation reference has unknown fields"
                )
            }
            record = try JSONDecoder().decode(
                LastGeneration.self,
                from: data
            )
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "Mac last-generation reference is not valid JSON"
            )
        }
        try validateGenerationKey(record.generationKey)
        return record.generationKey
    }

    static func updateLast(
        generationKey: String,
        paths: IOSUsePaths
    ) throws {
        try validateGenerationKey(generationKey)
        processLock.lock()
        defer { processLock.unlock() }
        try writeOwnerOnlyJSON(
            LastGeneration(generationKey: generationKey),
            to: paths.playcoverLastGeneration,
            label: "Mac last-generation reference"
        )
    }

    private static func writeOwnerOnlyJSON<T: Encodable>(
        _ value: T,
        to path: String,
        label: String
    ) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if canImport(Darwin)
        guard chmod(parent.path, 0o700) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot secure \(label) directory: errno \(errno)"
            )
        }
        var existing = stat()
        if lstat(path, &existing) == 0,
           existing.st_mode & S_IFMT != S_IFREG {
            throw PlayCoverBackendError.cacheTampered(
                "\(label) path is not a regular file"
            )
        }
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumRecordBytes else {
            throw PlayCoverBackendError.prepareFailed(
                "\(label) exceeds its size limit"
            )
        }
        try data.write(to: url, options: .atomic)
        #if canImport(Darwin)
        guard chmod(path, 0o600) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot secure \(label): errno \(errno)"
            )
        }
        #endif
    }

    private static func readOwnerOnlyFile(
        at path: String,
        maximumBytes: Int,
        label: String
    ) throws -> Data? {
        #if canImport(Darwin)
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect \(label): errno \(errno)"
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "\(label) is not a bounded owner-only regular file"
            )
        }
        #else
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        #endif
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= maximumBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "\(label) exceeds its size limit"
            )
        }
        return data
    }

    private static func validateGenerationKey(_ value: String) throws {
        guard isLowercaseSHA256(value) else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac last-generation key is invalid"
            )
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (97...102).contains($0.value)
        }
    }
}
