import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The account-global cache pin registry.
///
/// This is deliberately not a second session state machine. `driver.lock` and
/// `pending-launch.json` continue to own process recovery. These records are a
/// conservative, durable deletion barrier for immutable generations.
enum PlayCoverGlobalReferenceStore {
    static let schemaVersion = 1
    private static let maximumReferenceBytes = 32 * 1_024
    private static let maximumRegistryBytes = 1_024 * 1_024
    private static let registryFilename = "registry-v1.json"
    private static let processLock = NSLock()

    private enum RegistrationState: String, Codable, Sendable {
        case creating
        case ready
    }

    private struct RegistryEntry: Codable, Equatable, Sendable {
        let homeID: String
        var state: RegistrationState
    }

    private struct RegistryIndex: Codable, Equatable, Sendable {
        let schemaVersion: Int
        var homes: [RegistryEntry]
    }

    struct SessionPin: Codable, Equatable, Sendable {
        let sessionID: String
        let generationKey: String
    }

    struct HomeReference: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let homeID: String
        var lastGenerationKey: String?
        var preparingGenerationKey: String?
        var preparationID: String?
        var pending: SessionPin?
        var active: SessionPin?

        var protectedGenerationKeys: Set<String> {
            Set(
                [
                    lastGenerationKey,
                    preparingGenerationKey,
                    pending?.generationKey,
                    active?.generationKey,
                ].compactMap { $0 }
            )
        }
    }

    struct ForeignSessionPin: Hashable, Sendable {
        let homeID: String
        let sessionID: String
        let generationKey: String
    }

    static func read(paths: IOSUsePaths) throws -> HomeReference? {
        try withLockedRegistry(paths: paths) { access in
            try completeRegistrySnapshot(access: access)[
                paths.playcoverHomeID
            ]
        }
    }

    static func updateLast(
        generationKey: String,
        paths: IOSUsePaths
    ) throws {
        try validateGenerationKey(generationKey)
        try update(paths: paths) {
            $0.lastGenerationKey = generationKey
        }
    }

    static func beginPreparation(
        generationKey: String,
        paths: IOSUsePaths
    ) throws -> String {
        try validateGenerationKey(generationKey)
        let preparationID = UUID().uuidString
        try update(paths: paths) {
            // Production preparation runs while holding the per-Home start
            // operation lock. A surviving value therefore belongs to a
            // crashed prior invocation and is atomically superseded. The
            // transaction ID prevents a late cleanup from that invocation
            // from clearing this new pin.
            $0.preparingGenerationKey = generationKey
            $0.preparationID = preparationID
        }
        return preparationID
    }

    static func finishPreparation(
        generationKey: String,
        preparationID: String,
        paths: IOSUsePaths
    ) throws {
        try validateGenerationKey(generationKey)
        try validatePreparationID(preparationID)
        try update(paths: paths) {
            guard $0.preparingGenerationKey == generationKey,
                  $0.preparationID == preparationID else {
                throw PlayCoverBackendError.cacheTampered(
                    "global cache preparation pin changed before publication"
                )
            }
            $0.lastGenerationKey = generationKey
            $0.preparingGenerationKey = nil
            $0.preparationID = nil
        }
    }

    static func abandonPreparation(
        generationKey: String,
        preparationID: String,
        paths: IOSUsePaths
    ) throws {
        try validateGenerationKey(generationKey)
        try validatePreparationID(preparationID)
        try update(paths: paths) {
            guard $0.preparingGenerationKey == generationKey,
                  $0.preparationID == preparationID else {
                return
            }
            $0.preparingGenerationKey = nil
            $0.preparationID = nil
        }
    }

    /// Called only while the caller holds this Home's session-operation
    /// lock. Any surviving transaction belongs to a process that died before
    /// its defer could run, so it cannot represent a concurrent preparation.
    static func clearStalePreparationBeforeStart(
        paths: IOSUsePaths
    ) throws {
        try withLockedRegistry(paths: paths) { access in
            let references = try completeRegistrySnapshot(
                access: access
            )
            guard var reference = references[
                paths.playcoverHomeID
            ] else {
                return
            }
            guard reference.preparingGenerationKey != nil else {
                return
            }
            reference.preparingGenerationKey = nil
            reference.preparationID = nil
            try validate(
                reference,
                expectedHomeID: paths.playcoverHomeID
            )
            try writeReference(reference, access: access)
        }
    }

    static func setPending(
        sessionID: String,
        generationKey: String,
        paths: IOSUsePaths
    ) throws {
        let pin = try validatedPin(
            sessionID: sessionID,
            generationKey: generationKey
        )
        try update(paths: paths) {
            if let pending = $0.pending, pending != pin {
                throw PlayCoverBackendError.cacheTampered(
                    "global cache already has a different pending pin "
                        + "for this Home"
                )
            }
            if let active = $0.active, active != pin {
                throw PlayCoverBackendError.cacheTampered(
                    "global cache already has a different active pin "
                        + "for this Home"
                )
            }
            $0.pending = pin
        }
    }

    /// Driver-lock durability is established by the caller before this write.
    /// Keep pending until the durable pending journal has been retired.
    static func markActive(
        sessionID: String,
        generationKey: String,
        paths: IOSUsePaths
    ) throws {
        let pin = try validatedPin(
            sessionID: sessionID,
            generationKey: generationKey
        )
        try update(paths: paths) {
            if let active = $0.active, active != pin {
                throw PlayCoverBackendError.cacheTampered(
                    "refusing to replace a different active cache pin"
                )
            }
            if $0.pending == nil,
               $0.active == pin {
                return
            }
            guard $0.pending == pin else {
                throw PlayCoverBackendError.cacheTampered(
                    "active cache pin does not match the durable pending pin"
                )
            }
            $0.active = pin
        }
    }

    static func clearPending(
        sessionID: String,
        generationKey: String,
        paths: IOSUsePaths
    ) throws {
        let pin = try validatedPin(
            sessionID: sessionID,
            generationKey: generationKey
        )
        try update(paths: paths) {
            guard $0.pending == nil || $0.pending == pin else {
                throw PlayCoverBackendError.cacheTampered(
                    "refusing to clear a different pending cache pin"
                )
            }
            $0.pending = nil
        }
    }

    static func clearActive(
        sessionID: String,
        generationKey: String,
        paths: IOSUsePaths
    ) throws {
        let pin = try validatedPin(
            sessionID: sessionID,
            generationKey: generationKey
        )
        try update(paths: paths) {
            guard $0.active == nil || $0.active == pin else {
                throw PlayCoverBackendError.cacheTampered(
                    "refusing to clear a different active cache pin"
                )
            }
            $0.active = nil
        }
    }

    /// Holds the one registry/maintenance lock through the caller's entire GC
    /// transaction. Any malformed or unsafe Home ref fails the whole snapshot.
    static func withLockedProtectedGenerationKeys<T>(
        paths: IOSUsePaths,
        _ body: (
            Set<String>,
            PlayCoverManagedAppService.ManagedDirectoryAccess
        ) throws -> T
    ) throws -> T {
        try withLockedRegistry(paths: paths) { access in
            let references = try completeRegistrySnapshot(
                access: access
            )
            var protected = Set<String>()
            for reference in references.values {
                protected.formUnion(
                    reference.protectedGenerationKeys
                )
            }
            return try body(protected, access)
        }
    }

    static func foreignSessionPins(
        paths: IOSUsePaths,
        generationKey: String
    ) throws -> [ForeignSessionPin] {
        try validateGenerationKey(generationKey)
        return try withLockedRegistry(paths: paths) { access in
            let references = try completeRegistrySnapshot(
                access: access
            )
            var result = Set<ForeignSessionPin>()
            for (homeID, reference) in references {
                if homeID == paths.playcoverHomeID {
                    continue
                }
                for pin in [
                    reference.pending,
                    reference.active,
                ].compactMap({ $0 }) where
                    pin.generationKey == generationKey
                {
                    result.insert(
                        ForeignSessionPin(
                            homeID: homeID,
                            sessionID: pin.sessionID,
                            generationKey: pin.generationKey
                        )
                    )
                }
            }
            return result.sorted {
                if $0.homeID != $1.homeID {
                    return $0.homeID < $1.homeID
                }
                return $0.sessionID < $1.sessionID
            }
        }
    }

    static func withGenerationLock<T>(
        generationKey: String,
        paths: IOSUsePaths,
        _ body: () throws -> T
    ) throws -> T {
        try validateGenerationKey(generationKey)
        return try PlayCoverManagedAppService
            .withSecureManagedDirectories(paths: paths) { access in
                try withFileLock(
                    parentDescriptor: access.locksDescriptor,
                    filename: "\(generationKey).lock",
                    body
                )
            }
    }

    private static func update(
        paths: IOSUsePaths,
        _ mutation: (inout HomeReference) throws -> Void
    ) throws {
        try withLockedRegistry(paths: paths) { access in
            var registry = try registryForUpdate(
                homeID: paths.playcoverHomeID,
                access: access
            )
            let entryIndex = try registryEntryIndex(
                homeID: paths.playcoverHomeID,
                registry: registry
            )
            let existing = try readReference(
                homeID: paths.playcoverHomeID,
                access: access
            )
            if registry.homes[entryIndex].state == .ready,
               existing == nil {
                throw PlayCoverBackendError.cacheTampered(
                    "registered global Home reference is missing"
                )
            }
            var reference = existing ?? HomeReference(
                schemaVersion: schemaVersion,
                homeID: paths.playcoverHomeID,
                lastGenerationKey: nil,
                preparingGenerationKey: nil,
                preparationID: nil,
                pending: nil,
                active: nil
            )
            try mutation(&reference)
            try validate(reference, expectedHomeID: paths.playcoverHomeID)
            try writeReference(reference, access: access)
            if registry.homes[entryIndex].state != .ready {
                registry.homes[entryIndex].state = .ready
                try writeRegistryIndex(registry, access: access)
            }
        }
    }

    /// Registration is intentionally two phase. The durable `creating`
    /// entry is published before the first Home ref, so a crash can never
    /// leave an unrecorded ref whose later disappearance would make GC
    /// silently incomplete. A surviving `creating` entry keeps GC closed
    /// until that exact Home finishes or retries registration.
    private static func registryForUpdate(
        homeID: String,
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws -> RegistryIndex {
        try validateHomeID(homeID)
        var registry: RegistryIndex
        if let existing = try readRegistryIndex(access: access) {
            registry = existing
        } else {
            let names = try referenceHomeIDs(access: access)
            guard names.isEmpty else {
                throw PlayCoverBackendError.cacheTampered(
                    "global Home registry index is missing"
                )
            }
            try requireEmptyObjectsForMissingRegistry(access: access)
            registry = RegistryIndex(
                schemaVersion: schemaVersion,
                homes: []
            )
        }
        if !registry.homes.contains(where: { $0.homeID == homeID }) {
            registry.homes.append(
                RegistryEntry(homeID: homeID, state: .creating)
            )
            registry.homes.sort { $0.homeID < $1.homeID }
            try writeRegistryIndex(registry, access: access)
        }
        return registry
    }

    private static func registryEntryIndex(
        homeID: String,
        registry: RegistryIndex
    ) throws -> Int {
        guard let index = registry.homes.firstIndex(where: {
            $0.homeID == homeID
        }) else {
            throw PlayCoverBackendError.cacheTampered(
                "global Home registry entry disappeared"
            )
        }
        return index
    }

    /// Returns only a complete registry snapshot. Unknown refs, missing refs,
    /// incomplete registrations, and a missing index all fail closed.
    private static func completeRegistrySnapshot(
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws -> [String: HomeReference] {
        let names = try referenceHomeIDs(access: access)
        guard let registry = try readRegistryIndex(access: access) else {
            guard names.isEmpty else {
                throw PlayCoverBackendError.cacheTampered(
                    "global Home registry index is missing"
                )
            }
            try requireEmptyObjectsForMissingRegistry(access: access)
            return [:]
        }
        guard registry.homes.allSatisfy({ $0.state == .ready }) else {
            throw PlayCoverBackendError.cacheTampered(
                "global Home registry contains an incomplete registration"
            )
        }
        let registered = Set(registry.homes.map(\.homeID))
        guard registered == Set(names) else {
            throw PlayCoverBackendError.cacheTampered(
                "global Home registry and reference namespace differ"
            )
        }
        var result: [String: HomeReference] = [:]
        for homeID in names.sorted() {
            guard let reference = try readReference(
                homeID: homeID,
                access: access
            ) else {
                throw PlayCoverBackendError.cacheTampered(
                    "registered global Home reference disappeared"
                )
            }
            result[homeID] = reference
        }
        return result
    }

    private static func requireEmptyObjectsForMissingRegistry(
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws {
        let names = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: access.preparedDescriptor,
                label: "global prepared objects"
            )
        guard names.isEmpty else {
            throw PlayCoverBackendError.cacheTampered(
                "global Home registry index is missing while prepared "
                    + "objects exist"
            )
        }
    }

    private static func referenceHomeIDs(
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws -> [String] {
        let names = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: access.homesDescriptor,
                label: "global home references"
            )
        return try names.map { name in
            guard name.count == 69,
                  name.hasSuffix(".json") else {
                throw PlayCoverBackendError.cacheTampered(
                    "global home reference namespace contains an "
                        + "unknown entry"
                )
            }
            let homeID = String(name.dropLast(5))
            try validateHomeID(homeID)
            return homeID
        }
    }

    private static func withLockedRegistry<T>(
        paths: IOSUsePaths,
        _ body: (
            PlayCoverManagedAppService.ManagedDirectoryAccess
        ) throws -> T
    ) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return try PlayCoverManagedAppService
            .withSecureManagedDirectories(paths: paths) { access in
                try withFileLock(
                    parentDescriptor: access.locksDescriptor,
                    filename: "registry.lock"
                ) {
                    try removeAbandonedTemporaryReferences(
                        access: access
                    )
                    try removeAbandonedRegistryTemporaries(
                        access: access
                    )
                    return try body(access)
                }
            }
    }

    /// A writer can die after creating its same-directory temporary file but
    /// before the atomic rename. Once the registry lock is acquired, no live
    /// writer can own such a file. Remove only our exact UUID namespace after
    /// validating the inode; every other unknown entry remains fail-closed.
    private static func removeAbandonedTemporaryReferences(
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws {
        #if canImport(Darwin)
        let names = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: access.homesDescriptor,
                label: "global home references"
            )
        var removedAny = false
        for name in names {
            guard name.hasPrefix(".home-"),
                  name.hasSuffix(".tmp") else {
                continue
            }
            let uuidStart = name.index(
                name.startIndex,
                offsetBy: 6
            )
            let uuidEnd = name.index(
                name.endIndex,
                offsetBy: -4
            )
            let uuidText = String(name[uuidStart..<uuidEnd])
            guard name.count == 46,
                  let uuid = UUID(uuidString: uuidText),
                  uuid.uuidString == uuidText else {
                continue
            }

            var status = stat()
            guard fstatat(
                access.homesDescriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o077 == 0,
                  status.st_nlink == 1,
                  status.st_size >= 0,
                  status.st_size <= maximumReferenceBytes else {
                throw PlayCoverBackendError.cacheTampered(
                    "abandoned global home reference is not a bounded "
                        + "owner-only file"
                )
            }
            guard Darwin.unlinkat(
                access.homesDescriptor,
                name,
                0
            ) == 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "cannot remove abandoned global home reference: "
                        + "errno \(errno)"
                )
            }
            removedAny = true
        }
        if removedAny {
            try PlayCoverManagedAppService.syncDirectoryDescriptor(
                access.homesDescriptor,
                label: "global home references"
            )
        }
        #endif
    }

    private static func removeAbandonedRegistryTemporaries(
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws {
        #if canImport(Darwin)
        let names = try PlayCoverManagedAppService
            .anchoredDirectoryNames(
                descriptor: access.locksDescriptor,
                label: "global cache locks"
            )
        var removedAny = false
        for name in names {
            guard name.hasPrefix(".registry-"),
                  name.hasSuffix(".tmp") else {
                continue
            }
            let uuidStart = name.index(
                name.startIndex,
                offsetBy: 10
            )
            let uuidEnd = name.index(
                name.endIndex,
                offsetBy: -4
            )
            let uuidText = String(name[uuidStart..<uuidEnd])
            guard name.count == 50,
                  let uuid = UUID(uuidString: uuidText),
                  uuid.uuidString == uuidText else {
                continue
            }

            var status = stat()
            guard fstatat(
                access.locksDescriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o077 == 0,
                  status.st_nlink == 1,
                  status.st_size >= 0,
                  status.st_size <= maximumRegistryBytes else {
                throw PlayCoverBackendError.cacheTampered(
                    "abandoned global Home registry is not a bounded "
                        + "owner-only file"
                )
            }
            guard Darwin.unlinkat(
                access.locksDescriptor,
                name,
                0
            ) == 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "cannot remove abandoned global Home registry: "
                        + "errno \(errno)"
                )
            }
            removedAny = true
        }
        if removedAny {
            try PlayCoverManagedAppService.syncDirectoryDescriptor(
                access.locksDescriptor,
                label: "global cache locks"
            )
        }
        #endif
    }

    private static func readRegistryIndex(
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws -> RegistryIndex? {
        #if canImport(Darwin)
        var status = stat()
        if fstatat(
            access.locksDescriptor,
            registryFilename,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect global Home registry: errno \(errno)"
            )
        }
        let descriptor = Darwin.openat(
            access.locksDescriptor,
            registryFilename,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open global Home registry: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_mode & 0o077 == 0,
              opened.st_nlink == 1,
              opened.st_size >= 0,
              opened.st_size <= maximumRegistryBytes,
              opened.st_dev == status.st_dev,
              opened.st_ino == status.st_ino else {
            throw PlayCoverBackendError.cacheTampered(
                "global Home registry is not a bounded owner-only file"
            )
        }
        var data = Data(count: Int(opened.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw PlayCoverBackendError.cacheTampered(
                        "global Home registry could not be read completely"
                    )
                }
            }
        }
        #else
        let url = access.locks.appendingPathComponent(
            registryFilename
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumRegistryBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "global Home registry is oversized"
            )
        }
        #endif
        let registry: RegistryIndex
        do {
            registry = try JSONDecoder().decode(
                RegistryIndex.self,
                from: data
            )
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "global Home registry is malformed: \(error)"
            )
        }
        try validate(registry)
        return registry
    }

    private static func writeRegistryIndex(
        _ registry: RegistryIndex,
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws {
        var normalized = registry
        normalized.homes.sort { $0.homeID < $1.homeID }
        try validate(normalized)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(normalized)
        guard data.count <= maximumRegistryBytes else {
            throw PlayCoverBackendError.prepareFailed(
                "global Home registry exceeds its size bound"
            )
        }
        let temporary = ".registry-\(UUID().uuidString).tmp"
        #if canImport(Darwin)
        var existing = stat()
        if fstatat(
            access.locksDescriptor,
            registryFilename,
            &existing,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG,
                  existing.st_uid == geteuid(),
                  existing.st_mode & 0o077 == 0,
                  existing.st_nlink == 1,
                  existing.st_size >= 0,
                  existing.st_size <= maximumRegistryBytes else {
                throw PlayCoverBackendError.cacheTampered(
                    "existing global Home registry is not a bounded "
                        + "owner-only file"
                )
            }
        } else if errno != ENOENT {
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect existing global Home registry: errno "
                    + "\(errno)"
            )
        }
        let descriptor = Darwin.openat(
            access.locksDescriptor,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot create global Home registry: errno \(errno)"
            )
        }
        var installed = false
        defer {
            Darwin.close(descriptor)
            if !installed {
                _ = Darwin.unlinkat(
                    access.locksDescriptor,
                    temporary,
                    0
                )
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw PlayCoverBackendError.prepareFailed(
                        "cannot write global Home registry: errno \(errno)"
                    )
                }
            }
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0,
              Darwin.fsync(descriptor) == 0,
              Darwin.renameat(
                access.locksDescriptor,
                temporary,
                access.locksDescriptor,
                registryFilename
              ) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot publish global Home registry: errno \(errno)"
            )
        }
        installed = true
        try PlayCoverManagedAppService.syncDirectoryDescriptor(
            access.locksDescriptor,
            label: "global cache locks"
        )
        #else
        let temporaryURL = access.locks.appendingPathComponent(
            temporary
        )
        let finalURL = access.locks.appendingPathComponent(
            registryFilename
        )
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(
            at: temporaryURL,
            to: finalURL
        )
        #endif
    }

    private static func readReference(
        homeID: String,
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws -> HomeReference? {
        try validateHomeID(homeID)
        let filename = "\(homeID).json"
        #if canImport(Darwin)
        var status = stat()
        if fstatat(
            access.homesDescriptor,
            filename,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect global home reference: errno \(errno)"
            )
        }
        let descriptor = Darwin.openat(
            access.homesDescriptor,
            filename,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open global home reference: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_mode & 0o077 == 0,
              opened.st_nlink == 1,
              opened.st_size >= 0,
              opened.st_size <= maximumReferenceBytes,
              opened.st_dev == status.st_dev,
              opened.st_ino == status.st_ino else {
            throw PlayCoverBackendError.cacheTampered(
                "global home reference is not a bounded owner-only file"
            )
        }
        var data = Data(count: Int(opened.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw PlayCoverBackendError.cacheTampered(
                        "global home reference could not be read completely"
                    )
                }
            }
        }
        #else
        let url = access.homes.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumReferenceBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "global home reference is oversized"
            )
        }
        #endif
        let reference: HomeReference
        do {
            reference = try JSONDecoder().decode(
                HomeReference.self,
                from: data
            )
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "global home reference is malformed: \(error)"
            )
        }
        try validate(reference, expectedHomeID: homeID)
        return reference
    }

    private static func writeReference(
        _ reference: HomeReference,
        access: PlayCoverManagedAppService.ManagedDirectoryAccess
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(reference)
        guard data.count <= maximumReferenceBytes else {
            throw PlayCoverBackendError.prepareFailed(
                "global home reference exceeds its size bound"
            )
        }
        let filename = "\(reference.homeID).json"
        let temporary = ".home-\(UUID().uuidString).tmp"
        #if canImport(Darwin)
        var existing = stat()
        if fstatat(
            access.homesDescriptor,
            filename,
            &existing,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG,
                  existing.st_uid == geteuid(),
                  existing.st_mode & 0o077 == 0,
                  existing.st_nlink == 1,
                  existing.st_size >= 0,
                  existing.st_size <= maximumReferenceBytes else {
                throw PlayCoverBackendError.cacheTampered(
                    "existing global home reference is not a bounded "
                        + "owner-only file"
                )
            }
        } else if errno != ENOENT {
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect existing global home reference: errno "
                    + "\(errno)"
            )
        }
        let descriptor = Darwin.openat(
            access.homesDescriptor,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot create global home reference: errno \(errno)"
            )
        }
        var installed = false
        defer {
            Darwin.close(descriptor)
            if !installed {
                _ = Darwin.unlinkat(
                    access.homesDescriptor,
                    temporary,
                    0
                )
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw PlayCoverBackendError.prepareFailed(
                        "cannot write global home reference: errno \(errno)"
                    )
                }
            }
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0,
              Darwin.fsync(descriptor) == 0,
              Darwin.renameat(
                access.homesDescriptor,
                temporary,
                access.homesDescriptor,
                filename
              ) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot publish global home reference: errno \(errno)"
            )
        }
        installed = true
        try PlayCoverManagedAppService.syncDirectoryDescriptor(
            access.homesDescriptor,
            label: "global home references"
        )
        #else
        let temporaryURL = access.homes.appendingPathComponent(temporary)
        let finalURL = access.homes.appendingPathComponent(filename)
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        #endif
    }

    private static func withFileLock<T>(
        parentDescriptor: Int32,
        filename: String,
        _ body: () throws -> T
    ) throws -> T {
        #if canImport(Darwin)
        let descriptor = Darwin.openat(
            parentDescriptor,
            filename,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot open global cache lock: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              flock(descriptor, LOCK_EX) == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "global cache lock is not an owner-only regular file"
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
        #else
        return try body()
        #endif
    }

    private static func validate(
        _ reference: HomeReference,
        expectedHomeID: String
    ) throws {
        try validateHomeID(expectedHomeID)
        guard reference.schemaVersion == schemaVersion,
              reference.homeID == expectedHomeID else {
            throw PlayCoverBackendError.cacheTampered(
                "global home reference identity is invalid"
            )
        }
        if let value = reference.lastGenerationKey {
            try validateGenerationKey(value)
        }
        if let value = reference.preparingGenerationKey {
            try validateGenerationKey(value)
        }
        guard (reference.preparingGenerationKey == nil)
                == (reference.preparationID == nil) else {
            throw PlayCoverBackendError.cacheTampered(
                "global cache preparation pin is incomplete"
            )
        }
        if let preparationID = reference.preparationID {
            try validatePreparationID(preparationID)
        }
        for pin in [reference.pending, reference.active].compactMap({ $0 }) {
            _ = try validatedPin(
                sessionID: pin.sessionID,
                generationKey: pin.generationKey
            )
        }
        if let pending = reference.pending,
           let active = reference.active,
           pending != active {
            throw PlayCoverBackendError.cacheTampered(
                "global cache pending and active pins conflict"
            )
        }
    }

    private static func validate(
        _ registry: RegistryIndex
    ) throws {
        guard registry.schemaVersion == schemaVersion else {
            throw PlayCoverBackendError.cacheTampered(
                "global Home registry schema is invalid"
            )
        }
        var seen = Set<String>()
        for entry in registry.homes {
            try validateHomeID(entry.homeID)
            guard seen.insert(entry.homeID).inserted else {
                throw PlayCoverBackendError.cacheTampered(
                    "global Home registry contains a duplicate Home"
                )
            }
        }
    }

    private static func validatedPin(
        sessionID: String,
        generationKey: String
    ) throws -> SessionPin {
        try validateGenerationKey(generationKey)
        guard let parsed = UUID(uuidString: sessionID),
              parsed.uuidString.caseInsensitiveCompare(sessionID)
                == .orderedSame else {
            throw PlayCoverBackendError.cacheTampered(
                "global cache session pin is not a canonical UUID"
            )
        }
        return SessionPin(
            sessionID: parsed.uuidString,
            generationKey: generationKey
        )
    }

    private static func validateHomeID(_ value: String) throws {
        guard isLowercaseSHA256(value) else {
            throw PlayCoverBackendError.cacheTampered(
                "global cache Home ID is invalid"
            )
        }
    }

    private static func validateGenerationKey(_ value: String) throws {
        guard isLowercaseSHA256(value) else {
            throw PlayCoverBackendError.cacheTampered(
                "global generation key is invalid"
            )
        }
    }

    private static func isLowercaseSHA256(
        _ value: String
    ) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64
            && bytes.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 97 && $0 <= 102)
            }
    }

    private static func validatePreparationID(_ value: String) throws {
        guard let parsed = UUID(uuidString: value),
              parsed.uuidString == value else {
            throw PlayCoverBackendError.cacheTampered(
                "global cache preparation transaction ID is invalid"
            )
        }
    }
}
