import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum PlayCoverGenerationPruner {
    static let recentInactiveRetentionCount = 3
    static var afterProtectedStateForTesting: (() throws -> Void)?

    struct Result: Equatable, Sendable {
        let removedGenerationKeys: [String]
        let warnings: [String]

        static let empty = Result(
            removedGenerationKeys: [],
            warnings: []
        )
    }

    private struct ManifestIdentity: Decodable {
        let schemaVersion: Int
        let backend: String
        let generationKey: String
        let completedAt: String
    }

    private struct CompletedIdentity: Decodable {
        let schemaVersion: Int
        let generationKey: String
    }

    private struct Candidate {
        let generationKey: String
        let completedAt: Date
    }

    static func pruneAfterSuccessfulStart(
        paths: IOSUsePaths,
        currentGenerationKey: String
    ) -> Result {
        guard isGenerationKey(currentGenerationKey) else {
            return skipped(
                "current generation key is invalid"
            )
        }

        do {
            return try PlayCoverManagedAppService
                .withSecureManagedDirectories(paths: paths) {
                    try pruneAnchored(
                        paths: paths,
                        currentGenerationKey: currentGenerationKey,
                        access: $0
                    )
                }
        } catch {
            return skipped(
                "prepared cache could not be safely pruned: \(error)"
            )
        }
    }

    private static func pruneAnchored(
        paths: IOSUsePaths,
        currentGenerationKey: String,
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws -> Result {
        let protectedState = try protectedGenerationKeys(
            paths: paths,
            currentGenerationKey: currentGenerationKey,
            preparedRoot: access.prepared,
            preparedDescriptor: access.preparedDescriptor
        )
        try afterProtectedStateForTesting?()
        let candidates = try loadCandidates(
            preparedRoot: access.prepared,
            preparedDescriptor: access.preparedDescriptor
        )
        var warnings = removeTransientDirectories(
            preparedRoot: access.prepared,
            preparedDescriptor: access.preparedDescriptor
        )
        let recentInactive = candidates
            .filter {
                !protectedState.contains($0.generationKey)
            }
            .sorted {
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.generationKey > $1.generationKey
            }
            .prefix(recentInactiveRetentionCount)
            .map(\.generationKey)
        let keep = protectedState.union(recentInactive)
        var removed: [String] = []

        for candidate in candidates where
            !keep.contains(candidate.generationKey)
        {
            do {
                try removeCandidate(
                    candidate,
                    preparedRoot: access.prepared,
                    preparedDescriptor: access.preparedDescriptor
                )
                removed.append(candidate.generationKey)
            } catch {
                warnings.append(
                    "generation \(candidate.generationKey) was not "
                        + "removed: \(error)"
                )
            }
        }
        return Result(
            removedGenerationKeys: removed.sorted(),
            warnings: warnings
        )
    }

    private static func removeTransientDirectories(
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) -> [String] {
        #if canImport(Darwin)
        let names: [String]
        do {
            names = try PlayCoverManagedAppService
                .anchoredDirectoryNames(
                    descriptor: preparedDescriptor,
                    label: "managed prepared root"
                )
        } catch {
            return [
                "transient generation inventory could not be read: \(error)",
            ]
        }
        var warnings: [String] = []
        for name in names where isTransientDirectoryName(name) {
            do {
                try PlayCoverManagedAppService
                    .removeAnchoredDirectoryTree(
                        parentDescriptor: preparedDescriptor,
                        name: name,
                        label: "transient generation"
                    )
            } catch {
                warnings.append(
                    "transient generation \(name) was not removed: \(error)"
                )
            }
        }
        return warnings
        #else
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: preparedRoot.path
        ) else {
            return [
                "transient generation inventory could not be read",
            ]
        }
        var warnings: [String] = []
        for name in names where isTransientDirectoryName(name) {
            do {
                try FileManager.default.removeItem(
                    at: preparedRoot.appendingPathComponent(
                        name,
                        isDirectory: true
                    )
                )
            } catch {
                warnings.append(
                    "transient generation \(name) was not removed: \(error)"
                )
            }
        }
        return warnings
        #endif
    }

    private static func protectedGenerationKeys(
        paths: IOSUsePaths,
        currentGenerationKey: String,
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) throws -> Set<String> {
        guard let reference = try PlayCoverSessionService
            .readPreparedReference(paths: paths),
              isGenerationKey(reference.generationKey),
              generationKey(
                appPath: reference.appPath,
                paths: paths,
                preparedRoot: preparedRoot,
                preparedDescriptor: preparedDescriptor
              ) == reference.generationKey else {
            throw PlayCoverBackendError.cacheTampered(
                "last-prepared reference is missing or invalid"
            )
        }
        guard let active = try SessionService.readDriverLockInfo(
            paths: paths
        ),
              active.deviceType == PlayCoverSessionService.deviceType,
              let activeGeneration = active.playCoverGenerationKey,
              isGenerationKey(activeGeneration),
              let activeAppPath = active.playCoverAppPath,
              generationKey(
                appPath: activeAppPath,
                paths: paths,
                preparedRoot: preparedRoot,
                preparedDescriptor: preparedDescriptor
              ) == activeGeneration else {
            throw PlayCoverBackendError.cacheTampered(
                "active PlayCover session is missing or invalid"
            )
        }
        return [
            currentGenerationKey,
            reference.generationKey,
            activeGeneration,
        ]
    }

    private static func loadCandidates(
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) throws -> [Candidate] {
        #if canImport(Darwin)
        let names = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: preparedDescriptor,
                label: "managed prepared root"
            )
        #else
        let urls = try FileManager.default.contentsOfDirectory(
            at: preparedRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        let names = urls.map(\.lastPathComponent)
        #endif
        var result: [Candidate] = []
        for name in names {
            guard isGenerationKey(name) else {
                continue
            }
            #if canImport(Darwin)
            let generationDescriptor: Int32
            do {
                generationDescriptor = try PlayCoverManagedAppService
                    .openOwnedDirectory(
                        parentDescriptor: preparedDescriptor,
                        name: name,
                        label: "generation \(name)"
                    )
            } catch {
                continue
            }
            defer { Darwin.close(generationDescriptor) }
            let manifestData = try? PlayCoverManagedAppService
                .readOwnedRegularFile(
                    parentDescriptor: generationDescriptor,
                    name: PlayCoverService.manifestFilename
                )
            let completedData = try? PlayCoverManagedAppService
                .readOwnedRegularFile(
                    parentDescriptor: generationDescriptor,
                    name: PlayCoverService.completedFilename
                )
            #else
            let url = preparedRoot.appendingPathComponent(
                name,
                isDirectory: true
            )
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o077 == 0 else {
                continue
            }
            let manifestData = try? readOwnedRegularFile(
                at: url.appendingPathComponent(
                    PlayCoverService.manifestFilename
                )
            )
            let completedData = try? readOwnedRegularFile(
                at: url.appendingPathComponent(
                    PlayCoverService.completedFilename
                )
            )
            #endif
            guard let manifestData,
                  let completedData,
                  let manifest = try? JSONDecoder().decode(
                    ManifestIdentity.self,
                    from: manifestData
                  ),
                  let completed = try? JSONDecoder().decode(
                    CompletedIdentity.self,
                    from: completedData
                  ),
                  manifest.schemaVersion == 3,
                  manifest.backend == "playcover-headless",
                  manifest.generationKey == name,
                  completed.schemaVersion == 2,
                  completed.generationKey == name,
                  let completedAt = ISO8601DateFormatter().date(
                    from: manifest.completedAt
                  ) else {
                continue
            }
            result.append(
                Candidate(
                    generationKey: name,
                    completedAt: completedAt
                )
            )
        }
        return result
    }

    private static func removeCandidate(
        _ candidate: Candidate,
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) throws {
        #if canImport(Darwin)
        let tombstoneName =
            ".gc-\(candidate.generationKey)-\(UUID().uuidString)"
        guard Darwin.renameatx_np(
                preparedDescriptor,
                candidate.generationKey,
                preparedDescriptor,
                tombstoneName,
                UInt32(RENAME_EXCL)
              ) == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot tombstone anchored generation: errno \(errno)"
            )
        }
        try PlayCoverManagedAppService.removeAnchoredDirectoryTree(
            parentDescriptor: preparedDescriptor,
            name: tombstoneName,
            label: "generation tombstone"
        )
        #else
        let directory = preparedRoot.appendingPathComponent(
            candidate.generationKey,
            isDirectory: true
        )
        let canonicalRoot = preparedRoot.standardizedFileURL.path
        let canonicalCandidate = directory.standardizedFileURL.path
        guard canonicalCandidate
                == preparedRoot.appendingPathComponent(
                    candidate.generationKey,
                    isDirectory: true
                ).standardizedFileURL.path,
              canonicalCandidate.hasPrefix(canonicalRoot + "/") else {
            throw PlayCoverBackendError.cacheTampered(
                "generation path escaped the prepared root"
            )
        }

        let tombstone = preparedRoot.appendingPathComponent(
            ".gc-\(candidate.generationKey)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: directory,
            to: tombstone
        )
        try FileManager.default.removeItem(at: tombstone)
        #endif
    }

    private static func generationKey(
        appPath: String,
        paths: IOSUsePaths,
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) -> String? {
        guard let validated = try? PlayCoverManagedAppService
            .validatedManagedPreparedAppPath(
                appPath,
                paths: paths
            ) else {
            return nil
        }
        let app = URL(
            fileURLWithPath: validated,
            isDirectory: true
        )
        let generation = app.deletingLastPathComponent()
        guard generation.deletingLastPathComponent().path
                == preparedRoot.path,
              app.pathExtension == "app",
              isGenerationKey(generation.lastPathComponent) else {
            return nil
        }
        #if canImport(Darwin)
        guard (try? PlayCoverManagedAppService.ownedDirectoryExists(
            parentDescriptor: preparedDescriptor,
            name: generation.lastPathComponent,
            label: "protected generation"
        )) == true else {
            return nil
        }
        #endif
        return generation.lastPathComponent
    }

    private static func readOwnedRegularFile(
        at url: URL,
        maximumBytes: Int = 1_048_576
    ) throws -> Data {
        #if canImport(Darwin)
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open generation metadata without following links"
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_size >= 0,
              status.st_size <= Int64(maximumBytes) else {
            throw PlayCoverBackendError.cacheTampered(
                "generation metadata is not a bounded owned regular file"
            )
        }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw PlayCoverBackendError.cacheTampered(
                    "generation metadata could not be read completely"
                )
            }
        }
        return data
        #else
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "generation metadata is too large"
            )
        }
        return data
        #endif
    }

    private static func isGenerationKey(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isTransientDirectoryName(
        _ value: String
    ) -> Bool {
        for prefix in [".gc-", ".staging-"] where value.hasPrefix(prefix) {
            let suffix = String(value.dropFirst(prefix.count))
            guard suffix.count > 65 else {
                continue
            }
            let key = String(suffix.prefix(64))
            let separator = suffix.index(
                suffix.startIndex,
                offsetBy: 64
            )
            let identifier = String(suffix.suffix(from: suffix.index(
                after: separator
            )))
            if suffix[separator] == "-",
               isGenerationKey(key),
               UUID(uuidString: identifier) != nil {
                return true
            }
        }
        return false
    }

    private static func skipped(_ reason: String) -> Result {
        Result(
            removedGenerationKeys: [],
            warnings: [
                "PlayCover generation cleanup skipped because \(reason).",
            ]
        )
    }
}
