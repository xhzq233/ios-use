import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Home-local selection for `start --mac --reuse`.
///
/// The Home selects one Bundle ID. The account-global slot is the only source
/// of App/executable identity and is never copied into this record.
enum PlayCoverHomeStore {
    private struct CurrentBundle: Codable, Equatable, Sendable {
        let bundleIdentifier: String
    }

    private static let maximumRecordBytes = 32 * 1_024
    private static let processLock = NSLock()

    static func readCurrentBundle(paths: IOSUsePaths) throws -> String? {
        processLock.lock()
        defer { processLock.unlock() }
        guard let data = try readOwnerOnlyFile(
            at: paths.playcoverCurrentBundle
        ) else {
            return nil
        }
        do {
            guard let object = try JSONSerialization
                    .jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["bundleIdentifier"]) else {
                throw PlayCoverBackendError.cacheTampered(
                    "Mac current-bundle reference has unknown fields"
                )
            }
            let record = try JSONDecoder().decode(
                CurrentBundle.self,
                from: data
            )
            try PlayCoverSlotService.validateBundleIdentifier(
                record.bundleIdentifier
            )
            return record.bundleIdentifier
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "Mac current-bundle reference is not valid JSON"
            )
        }
    }

    static func updateCurrentBundle(
        _ bundleIdentifier: String,
        paths: IOSUsePaths
    ) throws {
        try PlayCoverSlotService.validateBundleIdentifier(
            bundleIdentifier
        )
        processLock.lock()
        defer { processLock.unlock() }
        let parent = URL(fileURLWithPath: paths.playcoverCurrentBundle)
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if canImport(Darwin)
        guard chmod(parent.path, 0o700) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot secure Mac current-bundle directory: errno \(errno)"
            )
        }
        var existing = stat()
        if lstat(paths.playcoverCurrentBundle, &existing) == 0,
           existing.st_mode & S_IFMT != S_IFREG {
            throw PlayCoverBackendError.cacheTampered(
                "Mac current-bundle path is not a regular file"
            )
        }
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            CurrentBundle(bundleIdentifier: bundleIdentifier)
        )
        guard data.count <= maximumRecordBytes else {
            throw PlayCoverBackendError.prepareFailed(
                "Mac current-bundle reference exceeds its size limit"
            )
        }
        try data.write(
            to: URL(fileURLWithPath: paths.playcoverCurrentBundle),
            options: .atomic
        )
        #if canImport(Darwin)
        guard chmod(paths.playcoverCurrentBundle, 0o600) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot secure Mac current-bundle reference: errno \(errno)"
            )
        }
        #endif
    }

    private static func readOwnerOnlyFile(at path: String) throws -> Data? {
        #if canImport(Darwin)
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect Mac current-bundle reference: errno \(errno)"
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumRecordBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac current-bundle reference is not a bounded owner-only file"
            )
        }
        #else
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        #endif
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= maximumRecordBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac current-bundle reference exceeds its size limit"
            )
        }
        return data
    }
}
