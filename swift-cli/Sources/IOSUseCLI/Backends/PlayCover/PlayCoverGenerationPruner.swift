import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum PlayCoverGenerationPruner {
    static let recentInactiveRetentionCount = 3
    static let corruptGenerationQuarantineLimit = 8
    static var afterProtectedStateForTesting: (() throws -> Void)?
    static var afterInventoryForTesting: (() throws -> Void)?
    static var inventorySidecarReadObserverForTesting:
        ((InventorySidecarReadEvent) -> Void)?

    struct InventorySidecarReadEvent: Equatable, Sendable {
        let generationKey: String
        let filename: String
    }

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
        let identity: AnchoredIdentity
    }

    private struct CorruptCandidate {
        let generationKey: String
        let reason: String
        let identity: AnchoredIdentity
    }

    private struct AnchoredIdentity {
        let device: UInt64
        let inode: UInt64
    }

    private struct Inventory {
        let complete: [Candidate]
        let corrupt: [CorruptCandidate]
        let warnings: [String]
    }

    static func pruneAfterSuccessfulStart(
        paths: IOSUsePaths,
        currentGenerationKey: String,
        currentGenerationToken:
            PlayCoverFastVerifiedGenerationToken? = nil
    ) -> Result {
        guard isGenerationKey(currentGenerationKey) else {
            return skipped(
                "current generation key is invalid"
            )
        }
        if let currentGenerationToken,
           currentGenerationToken.generationKey
            != currentGenerationKey {
            return skipped(
                "fast-verified current generation token does not match "
                    + "the started generation"
            )
        }

        do {
            return try PlayCoverManagedAppService
                .withSecureManagedDirectories(paths: paths) {
                    try pruneAnchored(
                        paths: paths,
                        currentGenerationKey: currentGenerationKey,
                        currentGenerationToken:
                            currentGenerationToken,
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
        currentGenerationToken:
            PlayCoverFastVerifiedGenerationToken?,
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws -> Result {
        let protectedState = try protectedGenerationKeys(
            paths: paths,
            currentGenerationKey: currentGenerationKey,
            preparedRoot: access.prepared,
            preparedDescriptor: access.preparedDescriptor
        )
        try afterProtectedStateForTesting?()
        let names = try preparedDirectoryNames(
            preparedRoot: access.prepared,
            preparedDescriptor: access.preparedDescriptor
        )
        let inventory = loadInventory(
            names: names,
            preparedRoot: access.prepared,
            preparedDescriptor: access.preparedDescriptor,
            currentGenerationToken: currentGenerationToken
        )
        try afterInventoryForTesting?()
        var warnings = inventory.warnings
        warnings += removeTransientDirectories(
            names: names,
            preparedRoot: access.prepared,
            preparedDescriptor: access.preparedDescriptor
        )
        let recentInactive = inventory.complete
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

        let protectedCorrupt = inventory.corrupt.filter {
            protectedState.contains($0.generationKey)
        }
        for candidate in protectedCorrupt.sorted(by: {
            $0.generationKey < $1.generationKey
        }) {
            warnings.append(
                "protected corrupt generation \(candidate.generationKey) "
                    + "was retained: \(candidate.reason)"
            )
        }
        let corruptEligible = inventory.corrupt.filter {
            !protectedState.contains($0.generationKey)
        }.sorted {
            $0.generationKey < $1.generationKey
        }
        let corruptBudget = min(
            corruptGenerationQuarantineLimit,
            corruptEligible.count
        )
        for candidate in corruptEligible.prefix(corruptBudget) {
            do {
                if let removalWarning = try removeGeneration(
                    generationKey: candidate.generationKey,
                    identity: candidate.identity,
                    preparedRoot: access.prepared,
                    preparedDescriptor: access.preparedDescriptor
                ) {
                    warnings.append(removalWarning)
                }
                removed.append(candidate.generationKey)
                warnings.append(
                    "corrupt generation \(candidate.generationKey) was "
                        + "quarantined: \(candidate.reason)"
                )
            } catch {
                warnings.append(
                    "corrupt generation \(candidate.generationKey) was not "
                        + "quarantined: \(error)"
                )
            }
        }
        if corruptEligible.count > corruptBudget {
            warnings.append(
                "corrupt generation quarantine budget "
                    + "\(corruptGenerationQuarantineLimit) was reached; "
                    + "\(corruptEligible.count - corruptBudget) generation(s) "
                    + "were deferred"
            )
        }

        for candidate in inventory.complete where
            !keep.contains(candidate.generationKey)
        {
            do {
                if let removalWarning = try removeGeneration(
                    generationKey: candidate.generationKey,
                    identity: candidate.identity,
                    preparedRoot: access.prepared,
                    preparedDescriptor: access.preparedDescriptor
                ) {
                    warnings.append(removalWarning)
                }
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
        names: [String],
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) -> [String] {
        #if canImport(Darwin)
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

    private static func preparedDirectoryNames(
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) throws -> [String] {
        #if canImport(Darwin)
        return try PlayCoverManagedAppService.anchoredDirectoryNames(
            descriptor: preparedDescriptor,
            label: "managed prepared root"
        )
        #else
        return try FileManager.default.contentsOfDirectory(
            atPath: preparedRoot.path
        )
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
        var protected: Set<String> = [
            currentGenerationKey,
            reference.generationKey,
            activeGeneration,
        ]
        if let pending = try PlayCoverPendingLaunchStore.load(
            paths: paths
        ) {
            protected.insert(pending.generationKey)
        }
        return protected
    }

    private static func loadInventory(
        names: [String],
        preparedRoot: URL,
        preparedDescriptor: Int32,
        currentGenerationToken:
            PlayCoverFastVerifiedGenerationToken?
    ) -> Inventory {
        var complete: [Candidate] = []
        var corrupt: [CorruptCandidate] = []
        var warnings: [String] = []
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
                warnings.append(
                    "generation \(name) was not inspected or quarantined "
                        + "because anchored ownership could not be validated: "
                        + "\(error)"
                )
                continue
            }
            defer { Darwin.close(generationDescriptor) }
            var status = stat()
            guard fstat(generationDescriptor, &status) == 0 else {
                warnings.append(
                    "generation \(name) was not inspected or quarantined "
                        + "because its anchored identity could not be read"
                )
                continue
            }
            let identity = AnchoredIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
            let completedResult = readSidecar(
                generationKey: name,
                parentDescriptor: generationDescriptor,
                filename: PlayCoverService.completedFilename,
                maximumBytes:
                    PlayCoverService.completedMarkerMaximumBytes
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
                warnings.append(
                    "generation \(name) was not inspected or quarantined "
                        + "because anchored ownership could not be validated"
                )
                continue
            }
            let identity = AnchoredIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
            let completedResult = readSidecar(
                generationKey: name,
                at: url.appendingPathComponent(
                    PlayCoverService.completedFilename
                ),
                filename: PlayCoverService.completedFilename,
                maximumBytes:
                    PlayCoverService.completedMarkerMaximumBytes
            )
            #endif

            if let token = currentGenerationToken,
               token.generationKey == name {
                guard token.directoryIdentity.device
                        == identity.device,
                      token.directoryIdentity.inode
                        == identity.inode else {
                    corrupt.append(
                        CorruptCandidate(
                            generationKey: name,
                            reason:
                                "generation vnode changed after fast "
                                + "verification",
                            identity: identity
                        )
                    )
                    continue
                }
                let completedData: Data
                switch completedResult {
                case .success(let data):
                    completedData = data
                case .failure(let reason):
                    corrupt.append(
                        CorruptCandidate(
                            generationKey: name,
                            reason: reason,
                            identity: identity
                        )
                    )
                    continue
                }
                guard let completed = try? JSONDecoder().decode(
                    PlayCoverCompletedGeneration.self,
                    from: completedData
                ), completed == token.completed else {
                    corrupt.append(
                        CorruptCandidate(
                            generationKey: name,
                            reason:
                                "completed sidecar changed after fast "
                                + "verification",
                            identity: identity
                        )
                    )
                    continue
                }
                guard let completedAt = ISO8601DateFormatter().date(
                    from: token.completedAt
                ) else {
                    corrupt.append(
                        CorruptCandidate(
                            generationKey: name,
                            reason: "manifest completedAt is malformed",
                            identity: identity
                        )
                    )
                    continue
                }
                complete.append(
                    Candidate(
                        generationKey: name,
                        completedAt: completedAt,
                        identity: identity
                    )
                )
                continue
            }

            #if canImport(Darwin)
            let manifestResult = readSidecar(
                generationKey: name,
                parentDescriptor: generationDescriptor,
                filename: PlayCoverService.manifestFilename,
                maximumBytes:
                    PlayCoverService.generationManifestMaximumBytes
            )
            #else
            let manifestResult = readSidecar(
                generationKey: name,
                at: url.appendingPathComponent(
                    PlayCoverService.manifestFilename
                ),
                filename: PlayCoverService.manifestFilename,
                maximumBytes:
                    PlayCoverService.generationManifestMaximumBytes
            )
            #endif

            let manifestData: Data
            switch manifestResult {
            case .success(let data):
                manifestData = data
            case .failure(let reason):
                corrupt.append(
                    CorruptCandidate(
                        generationKey: name,
                        reason: reason,
                        identity: identity
                    )
                )
                continue
            }
            let completedData: Data
            switch completedResult {
            case .success(let data):
                completedData = data
            case .failure(let reason):
                corrupt.append(
                    CorruptCandidate(
                        generationKey: name,
                        reason: reason,
                        identity: identity
                    )
                )
                continue
            }
            guard let manifest = try? JSONDecoder().decode(
                ManifestIdentity.self,
                from: manifestData
            ) else {
                corrupt.append(
                    CorruptCandidate(
                        generationKey: name,
                        reason: "manifest sidecar is malformed",
                        identity: identity
                    )
                )
                continue
            }
            guard let completed = try? JSONDecoder().decode(
                CompletedIdentity.self,
                from: completedData
            ) else {
                corrupt.append(
                    CorruptCandidate(
                        generationKey: name,
                        reason: "completed sidecar is malformed",
                        identity: identity
                    )
                )
                continue
            }
            guard manifest.schemaVersion == 4,
                  manifest.backend == "mac",
                  manifest.generationKey == name else {
                corrupt.append(
                    CorruptCandidate(
                        generationKey: name,
                        reason:
                            "manifest sidecar identity does not match its "
                            + "generation namespace",
                        identity: identity
                    )
                )
                continue
            }
            guard completed.schemaVersion == 4,
                  completed.generationKey == name else {
                corrupt.append(
                    CorruptCandidate(
                        generationKey: name,
                        reason:
                            "completed sidecar identity does not match its "
                            + "generation namespace",
                        identity: identity
                    )
                )
                continue
            }
            guard let completedAt = ISO8601DateFormatter().date(
                from: manifest.completedAt
            ) else {
                corrupt.append(
                    CorruptCandidate(
                        generationKey: name,
                        reason: "manifest completedAt is malformed",
                        identity: identity
                    )
                )
                continue
            }
            complete.append(
                Candidate(
                    generationKey: name,
                    completedAt: completedAt,
                    identity: identity
                )
            )
        }
        return Inventory(
            complete: complete,
            corrupt: corrupt,
            warnings: warnings
        )
    }

    private enum SidecarRead {
        case success(Data)
        case failure(String)
    }

    #if canImport(Darwin)
    private static func readSidecar(
        generationKey: String,
        parentDescriptor: Int32,
        filename: String,
        maximumBytes: Int
    ) -> SidecarRead {
        inventorySidecarReadObserverForTesting?(
            InventorySidecarReadEvent(
                generationKey: generationKey,
                filename: filename
            )
        )
        do {
            return .success(
                try PlayCoverManagedAppService.readOwnedRegularFile(
                    parentDescriptor: parentDescriptor,
                    name: filename,
                    maximumBytes: maximumBytes
                )
            )
        } catch {
            return .failure(
                "\(filename) is missing, oversized, or unsafe: \(error)"
            )
        }
    }
    #else
    private static func readSidecar(
        generationKey: String,
        at url: URL,
        filename: String,
        maximumBytes: Int
    ) -> SidecarRead {
        inventorySidecarReadObserverForTesting?(
            InventorySidecarReadEvent(
                generationKey: generationKey,
                filename: filename
            )
        )
        do {
            return .success(
                try readOwnedRegularFile(
                    at: url,
                    maximumBytes: maximumBytes
                )
            )
        } catch {
            return .failure(
                "\(filename) is missing, oversized, or unsafe: \(error)"
            )
        }
    }
    #endif

    private static func removeGeneration(
        generationKey: String,
        identity: AnchoredIdentity,
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) throws -> String? {
        #if canImport(Darwin)
        var status = stat()
        guard fstatat(
                preparedDescriptor,
                generationKey,
                &status,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              UInt64(status.st_dev) == identity.device,
              UInt64(status.st_ino) == identity.inode else {
            throw PlayCoverBackendError.cacheTampered(
                "anchored generation identity changed before tombstone"
            )
        }
        let tombstoneName =
            ".gc-\(generationKey)-\(UUID().uuidString)"
        guard Darwin.renameatx_np(
                preparedDescriptor,
                generationKey,
                preparedDescriptor,
                tombstoneName,
                UInt32(RENAME_EXCL)
              ) == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot tombstone anchored generation: errno \(errno)"
            )
        }
        do {
            try PlayCoverManagedAppService.removeAnchoredDirectoryTree(
                parentDescriptor: preparedDescriptor,
                name: tombstoneName,
                label: "generation tombstone"
            )
            return nil
        } catch {
            return "generation \(generationKey) was quarantined as "
                + "\(tombstoneName), but the tombstone was not removed: "
                + "\(error)"
        }
        #else
        let directory = preparedRoot.appendingPathComponent(
            generationKey,
            isDirectory: true
        )
        var status = stat()
        let canonicalRoot = preparedRoot.standardizedFileURL.path
        let canonicalCandidate = directory.standardizedFileURL.path
        guard lstat(directory.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              UInt64(status.st_dev) == identity.device,
              UInt64(status.st_ino) == identity.inode,
              canonicalCandidate
                == preparedRoot.appendingPathComponent(
                    generationKey,
                    isDirectory: true
                ).standardizedFileURL.path,
              canonicalCandidate.hasPrefix(canonicalRoot + "/") else {
            throw PlayCoverBackendError.cacheTampered(
                "generation path escaped the prepared root"
            )
        }

        let tombstone = preparedRoot.appendingPathComponent(
            ".gc-\(generationKey)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: directory,
            to: tombstone
        )
        do {
            try FileManager.default.removeItem(at: tombstone)
            return nil
        } catch {
            return "generation \(generationKey) was quarantined as "
                + "\(tombstone.lastPathComponent), but the tombstone was not "
                + "removed: \(error)"
        }
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
