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

    private struct StagingCandidate {
        let name: String
        let generationKey: String
        let identity: AnchoredIdentity
    }

    private struct Tombstone {
        let name: String
        let removalFailureDescription: String
    }

    private struct AnchoredIdentity {
        let device: UInt64
        let inode: UInt64
    }

    private struct Inventory {
        let complete: [Candidate]
        let corrupt: [CorruptCandidate]
        let staging: [StagingCandidate]
        let existingTombstones: [Tombstone]
        let warnings: [String]
    }

    private struct PruneTransaction {
        let result: Result
        let tombstones: [Tombstone]
        let preparedRoot: URL
        let preparedDescriptor: Int32
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
            let inventory = try PlayCoverManagedAppService
                .withSecureManagedDirectories(paths: paths) { access in
                    let names = try preparedDirectoryNames(
                        preparedRoot: access.prepared,
                        preparedDescriptor: access.preparedDescriptor
                    )
                    return loadInventory(
                        names: names,
                        preparedRoot: access.prepared,
                        preparedDescriptor: access.preparedDescriptor,
                        currentGenerationToken:
                            currentGenerationToken
                    )
                }
            try afterInventoryForTesting?()
            let transaction = try PlayCoverGlobalReferenceStore
                .withLockedProtectedGenerationKeys(
                    paths: paths
                ) { protectedGenerationKeys, access in
                    var protected = protectedGenerationKeys
                    protected.insert(currentGenerationKey)
                    try afterProtectedStateForTesting?()
                    return try preparePruneTransaction(
                        inventory: inventory,
                        protectedState: protected,
                        currentGenerationKey: currentGenerationKey,
                        currentGenerationToken:
                            currentGenerationToken,
                        access: access
                    )
                }
            #if canImport(Darwin)
            defer {
                if transaction.preparedDescriptor >= 0 {
                    Darwin.close(transaction.preparedDescriptor)
                }
            }
            #endif
            let removalWarnings = removeTombstones(
                transaction.tombstones,
                preparedRoot: transaction.preparedRoot,
                preparedDescriptor: transaction.preparedDescriptor
            )
            return Result(
                removedGenerationKeys:
                    transaction.result.removedGenerationKeys,
                warnings:
                    transaction.result.warnings + removalWarnings
            )
        } catch {
            return skipped(
                "prepared cache could not be safely pruned: \(error)"
            )
        }
    }

    private static func preparePruneTransaction(
        inventory: Inventory,
        protectedState: Set<String>,
        currentGenerationKey: String,
        currentGenerationToken:
            PlayCoverFastVerifiedGenerationToken?,
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws -> PruneTransaction {
        var warnings = inventory.warnings
        let recentInactive = inventory.complete
            .filter {
                !protectedState.contains($0.generationKey)
            }
            .prefix(recentInactiveRetentionCount)
            .map(\.generationKey)
        let keep = protectedState.union(recentInactive)
        var removed: [String] = []
        var tombstones = inventory.existingTombstones
        var didRename = false

        let protectedCorrupt = inventory.corrupt.filter {
            protectedState.contains($0.generationKey)
        }
        for candidate in protectedCorrupt {
            warnings.append(
                "protected corrupt generation \(candidate.generationKey) "
                    + "was retained: \(candidate.reason)"
            )
        }
        if currentGenerationToken != nil,
           let current = inventory.complete.first(where: {
               $0.generationKey == currentGenerationKey
           }),
           !matchesAnchoredIdentity(
               name: currentGenerationKey,
               identity: current.identity,
               preparedRoot: access.prepared,
               preparedDescriptor: access.preparedDescriptor
           ) {
            warnings.append(
                "protected corrupt generation \(currentGenerationKey) "
                    + "was retained: generation vnode changed after fast "
                    + "verification"
            )
        }

        for candidate in inventory.staging where
            !protectedState.contains(candidate.generationKey)
        {
            do {
                let tombstoneName = try tombstoneDirectory(
                    name: candidate.name,
                    generationKey: candidate.generationKey,
                    identity: candidate.identity,
                    identityLabel: "transient generation",
                    preparedRoot: access.prepared,
                    preparedDescriptor: access.preparedDescriptor
                )
                didRename = true
                tombstones.append(
                    Tombstone(
                        name: tombstoneName,
                        removalFailureDescription:
                            "transient generation \(candidate.name) was "
                            + "quarantined as \(tombstoneName), but the "
                            + "tombstone was not removed"
                    )
                )
            } catch {
                warnings.append(
                    "transient generation \(candidate.name) was not "
                        + "quarantined: \(error)"
                )
            }
        }

        let corruptEligible = inventory.corrupt.filter {
            !protectedState.contains($0.generationKey)
        }
        let corruptBudget = min(
            corruptGenerationQuarantineLimit,
            corruptEligible.count
        )
        for candidate in corruptEligible.prefix(corruptBudget) {
            do {
                let tombstoneName = try tombstoneDirectory(
                    name: candidate.generationKey,
                    generationKey: candidate.generationKey,
                    identity: candidate.identity,
                    identityLabel: "generation",
                    preparedRoot: access.prepared,
                    preparedDescriptor: access.preparedDescriptor
                )
                didRename = true
                tombstones.append(
                    Tombstone(
                        name: tombstoneName,
                        removalFailureDescription:
                            "generation \(candidate.generationKey) was "
                            + "quarantined as \(tombstoneName), but the "
                            + "tombstone was not removed"
                    )
                )
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
                let tombstoneName = try tombstoneDirectory(
                    name: candidate.generationKey,
                    generationKey: candidate.generationKey,
                    identity: candidate.identity,
                    identityLabel: "generation",
                    preparedRoot: access.prepared,
                    preparedDescriptor: access.preparedDescriptor
                )
                didRename = true
                tombstones.append(
                    Tombstone(
                        name: tombstoneName,
                        removalFailureDescription:
                            "generation \(candidate.generationKey) was "
                            + "quarantined as \(tombstoneName), but the "
                            + "tombstone was not removed"
                    )
                )
                removed.append(candidate.generationKey)
            } catch {
                warnings.append(
                    "generation \(candidate.generationKey) was not "
                        + "removed: \(error)"
                )
            }
        }

        if didRename {
            try syncPreparedDirectory(
                preparedRoot: access.prepared,
                preparedDescriptor: access.preparedDescriptor
            )
        }
        let retainedDescriptor = try retainPreparedDescriptorIfNeeded(
            access.preparedDescriptor,
            hasTombstones: !tombstones.isEmpty
        )
        return PruneTransaction(
            result: Result(
                removedGenerationKeys: removed.sorted(),
                warnings: warnings
            ),
            tombstones: tombstones,
            preparedRoot: access.prepared,
            preparedDescriptor: retainedDescriptor
        )
    }

    private static func removeTombstones(
        _ tombstones: [Tombstone],
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) -> [String] {
        #if canImport(Darwin)
        var warnings: [String] = []
        for tombstone in tombstones {
            do {
                try PlayCoverManagedAppService
                    .removeAnchoredDirectoryTree(
                        parentDescriptor: preparedDescriptor,
                        name: tombstone.name,
                        label: "generation tombstone"
                    )
            } catch {
                if !anchoredEntryExists(
                    name: tombstone.name,
                    preparedDescriptor: preparedDescriptor
                ) {
                    continue
                }
                warnings.append(
                    "\(tombstone.removalFailureDescription): \(error)"
                )
            }
        }
        return warnings
        #else
        var warnings: [String] = []
        for tombstone in tombstones {
            let url = preparedRoot.appendingPathComponent(
                tombstone.name,
                isDirectory: true
            )
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if !FileManager.default.fileExists(atPath: url.path) {
                    continue
                }
                warnings.append(
                    "\(tombstone.removalFailureDescription): \(error)"
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

    private static func loadInventory(
        names: [String],
        preparedRoot: URL,
        preparedDescriptor: Int32,
        currentGenerationToken:
            PlayCoverFastVerifiedGenerationToken?
    ) -> Inventory {
        let stagingInventory = loadStagingCandidates(
            names: names,
            preparedRoot: preparedRoot,
            preparedDescriptor: preparedDescriptor
        )
        let existingTombstones = names.compactMap { name -> Tombstone? in
            guard transientGenerationKey(
                name,
                prefix: ".gc-"
            ) != nil else {
                return nil
            }
            return Tombstone(
                name: name,
                removalFailureDescription:
                    "transient generation \(name) was not removed"
            )
        }
        var complete: [Candidate] = []
        var corrupt: [CorruptCandidate] = []
        var warnings = stagingInventory.warnings
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
            guard manifest.schemaVersion == 5,
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
            guard completed.schemaVersion == 5,
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
            complete: complete.sorted {
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.generationKey > $1.generationKey
            },
            corrupt: corrupt.sorted {
                $0.generationKey < $1.generationKey
            },
            staging: stagingInventory.candidates.sorted {
                $0.name < $1.name
            },
            existingTombstones: existingTombstones.sorted {
                $0.name < $1.name
            },
            warnings: warnings
        )
    }

    private static func loadStagingCandidates(
        names: [String],
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) -> (
        candidates: [StagingCandidate],
        warnings: [String]
    ) {
        var candidates: [StagingCandidate] = []
        var warnings: [String] = []
        for name in names {
            guard let generationKey = transientGenerationKey(
                name,
                prefix: ".staging-"
            ) else {
                continue
            }
            #if canImport(Darwin)
            do {
                let descriptor = try PlayCoverManagedAppService
                    .openOwnedDirectory(
                        parentDescriptor: preparedDescriptor,
                        name: name,
                        label: "transient generation \(name)"
                    )
                var status = stat()
                let inspected = fstat(descriptor, &status) == 0
                Darwin.close(descriptor)
                guard inspected else {
                    throw PlayCoverBackendError.cacheTampered(
                        "cannot inspect anchored transient generation"
                    )
                }
                candidates.append(
                    StagingCandidate(
                        name: name,
                        generationKey: generationKey,
                        identity: AnchoredIdentity(
                            device: UInt64(status.st_dev),
                            inode: UInt64(status.st_ino)
                        )
                    )
                )
            } catch {
                warnings.append(
                    "transient generation \(name) was not inspected or "
                        + "quarantined because anchored ownership could not "
                        + "be validated: \(error)"
                )
            }
            #else
            let url = preparedRoot.appendingPathComponent(
                name,
                isDirectory: true
            )
            var status = stat()
            let canonicalRoot = preparedRoot.standardizedFileURL.path
            let canonicalCandidate = url.standardizedFileURL.path
            guard lstat(url.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o077 == 0,
                  canonicalCandidate
                    == preparedRoot.appendingPathComponent(
                        name,
                        isDirectory: true
                    ).standardizedFileURL.path,
                  canonicalCandidate.hasPrefix(canonicalRoot + "/") else {
                warnings.append(
                    "transient generation \(name) was not inspected or "
                        + "quarantined because anchored ownership could not "
                        + "be validated"
                )
                continue
            }
            candidates.append(
                StagingCandidate(
                    name: name,
                    generationKey: generationKey,
                    identity: AnchoredIdentity(
                        device: UInt64(status.st_dev),
                        inode: UInt64(status.st_ino)
                    )
                )
            )
            #endif
        }
        return (candidates, warnings)
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

    private static func tombstoneDirectory(
        name: String,
        generationKey: String,
        identity: AnchoredIdentity,
        identityLabel: String,
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) throws -> String {
        guard matchesAnchoredIdentity(
            name: name,
            identity: identity,
            preparedRoot: preparedRoot,
            preparedDescriptor: preparedDescriptor
        ) else {
            throw PlayCoverBackendError.cacheTampered(
                "anchored \(identityLabel) identity changed before tombstone"
            )
        }

        #if canImport(Darwin)
        for _ in 0..<8 {
            let tombstoneName =
                ".gc-\(generationKey)-\(UUID().uuidString)"
            if Darwin.renameatx_np(
                preparedDescriptor,
                name,
                preparedDescriptor,
                tombstoneName,
                UInt32(RENAME_EXCL)
            ) == 0 {
                return tombstoneName
            }
            let renameError = errno
            if renameError == EEXIST {
                continue
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot tombstone anchored \(identityLabel): "
                    + "errno \(renameError)"
            )
        }
        #else
        let directory = preparedRoot.appendingPathComponent(
            name,
            isDirectory: true
        )
        for _ in 0..<8 {
            let tombstone = preparedRoot.appendingPathComponent(
                ".gc-\(generationKey)-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try FileManager.default.moveItem(
                    at: directory,
                    to: tombstone
                )
                return tombstone.lastPathComponent
            } catch {
                if FileManager.default.fileExists(
                    atPath: tombstone.path
                ) {
                    continue
                }
                throw PlayCoverBackendError.cacheTampered(
                    "cannot tombstone anchored \(identityLabel): \(error)"
                )
            }
        }
        #endif
        throw PlayCoverBackendError.cacheTampered(
            "cannot allocate a unique tombstone for anchored "
                + "\(identityLabel)"
        )
    }

    private static func matchesAnchoredIdentity(
        name: String,
        identity: AnchoredIdentity,
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) -> Bool {
        #if canImport(Darwin)
        var status = stat()
        return fstatat(
            preparedDescriptor,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0
            && status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == geteuid()
            && status.st_mode & 0o077 == 0
            && UInt64(status.st_dev) == identity.device
            && UInt64(status.st_ino) == identity.inode
        #else
        let directory = preparedRoot.appendingPathComponent(
            name,
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
                    name,
                    isDirectory: true
                ).standardizedFileURL.path,
              canonicalCandidate.hasPrefix(canonicalRoot + "/") else {
            return false
        }
        return true
        #endif
    }

    private static func syncPreparedDirectory(
        preparedRoot: URL,
        preparedDescriptor: Int32
    ) throws {
        #if canImport(Darwin)
        try PlayCoverManagedAppService.syncDirectoryDescriptor(
            preparedDescriptor,
            label: "managed prepared root after generation tombstone"
        )
        #else
        _ = preparedRoot
        #endif
    }

    private static func retainPreparedDescriptorIfNeeded(
        _ preparedDescriptor: Int32,
        hasTombstones: Bool
    ) throws -> Int32 {
        guard hasTombstones else {
            return -1
        }
        #if canImport(Darwin)
        let retained = Darwin.fcntl(
            preparedDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard retained >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot retain the prepared generation directory for "
                    + "tombstone cleanup: errno \(errno)"
            )
        }
        return retained
        #else
        return -1
        #endif
    }

    #if canImport(Darwin)
    private static func anchoredEntryExists(
        name: String,
        preparedDescriptor: Int32
    ) -> Bool {
        var status = stat()
        if fstatat(
            preparedDescriptor,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return true
        }
        return errno != ENOENT
    }
    #endif

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
        let bytes = value.utf8
        return bytes.count == 64
            && bytes.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 97 && $0 <= 102)
            }
    }

    private static func transientGenerationKey(
        _ value: String,
        prefix: String
    ) -> String? {
        guard value.hasPrefix(prefix) else {
            return nil
        }
        let suffix = String(value.dropFirst(prefix.count))
        guard suffix.count > 65 else {
            return nil
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
            return key
        }
        return nil
    }

    private static func skipped(_ reason: String) -> Result {
        Result(
            removedGenerationKeys: [],
            warnings: [
                "Mac generation cleanup skipped because \(reason).",
            ]
        )
    }
}
