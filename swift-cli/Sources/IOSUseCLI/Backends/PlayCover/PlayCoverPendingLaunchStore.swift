import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverPendingLaunchStoreError:
    Error,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    let message: String

    var description: String {
        "Invalid PlayCover pending launch: \(message)"
    }
}

enum PlayCoverPendingLaunchStore {
    static let schemaVersion = 1
    static let maximumBytes = 64 * 1_024

    enum Phase: String, Codable, Equatable, Sendable {
        case intent
        case aliasReady
        case submissionArmed
        case terminalCallback
        case owned
        case driverLockCommitted
        case confirmedStopped
    }

    enum OwnerSource: String, Codable, Equatable, Sendable {
        case workspaceCallback
        case authenticatedRuntime
    }

    enum CallbackOutcome: String, Codable, Equatable, Sendable {
        case success
        case failure
    }

    enum CleanupProof: String, Codable, Equatable, Sendable {
        case neverSubmitted
        case ownedProcessExited
        case ownedPIDReused
        case terminalCallbackAndEmptyCensus
        case newBootAndEmptyCensus
        case stoppedExactOwner
        case driverLockRetired
    }

    struct AliasEntry: Codable, Equatable, Sendable {
        let name: String
        let destination: String
    }

    struct TerminalCallback: Codable, Equatable, Sendable {
        let outcome: CallbackOutcome
        let errorDescription: String?
    }

    struct Owner: Codable, Equatable, Sendable {
        let pid: Int32
        let processBirthMicroseconds: UInt64
        let source: OwnerSource
    }

    struct Intent: Equatable, Sendable {
        let sessionID: String
        let runtimeSocketPath: String
        let generationKey: String
        let appPath: String
        let bundleIdentifier: String
        let executablePath: String
        let aliasPath: String
    }

    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let phase: Phase
        let sessionID: String
        let runtimeSocketPath: String
        let generationKey: String
        let appPath: String
        let bundleIdentifier: String
        let executablePath: String
        let aliasPath: String
        let aliasDevice: UInt64?
        let aliasInode: UInt64?
        let aliasInventory: [AliasEntry]?
        let submissionBootSessionUUID: String?
        let terminalCallback: TerminalCallback?
        let owner: Owner?
        let cleanupProof: CleanupProof?

        fileprivate func replacing(
            phase: Phase? = nil,
            aliasDevice: UInt64?? = nil,
            aliasInode: UInt64?? = nil,
            aliasInventory: [AliasEntry]?? = nil,
            submissionBootSessionUUID: String?? = nil,
            terminalCallback: TerminalCallback?? = nil,
            owner: Owner?? = nil,
            cleanupProof: CleanupProof?? = nil
        ) -> Record {
            Record(
                schemaVersion: schemaVersion,
                phase: phase ?? self.phase,
                sessionID: sessionID,
                runtimeSocketPath: runtimeSocketPath,
                generationKey: generationKey,
                appPath: appPath,
                bundleIdentifier: bundleIdentifier,
                executablePath: executablePath,
                aliasPath: aliasPath,
                aliasDevice: aliasDevice ?? self.aliasDevice,
                aliasInode: aliasInode ?? self.aliasInode,
                aliasInventory:
                    aliasInventory ?? self.aliasInventory,
                submissionBootSessionUUID:
                    submissionBootSessionUUID
                        ?? self.submissionBootSessionUUID,
                terminalCallback:
                    terminalCallback ?? self.terminalCallback,
                owner: owner ?? self.owner,
                cleanupProof: cleanupProof ?? self.cleanupProof
            )
        }
    }

    private static let processLock = NSLock()
    private static let journalFilename = "pending-launch.json"
    private static let lockFilename = "pending-launch.lock"

    static func createIntent(
        _ intent: Intent,
        paths: IOSUsePaths
    ) throws -> Record {
        let record = Record(
            schemaVersion: schemaVersion,
            phase: .intent,
            sessionID: intent.sessionID,
            runtimeSocketPath: intent.runtimeSocketPath,
            generationKey: intent.generationKey,
            appPath: intent.appPath,
            bundleIdentifier: intent.bundleIdentifier,
            executablePath: intent.executablePath,
            aliasPath: intent.aliasPath,
            aliasDevice: nil,
            aliasInode: nil,
            aliasInventory: nil,
            submissionBootSessionUUID: nil,
            terminalCallback: nil,
            owner: nil,
            cleanupProof: nil
        )
        try validate(record, paths: paths)
        return try withExclusiveLock(paths: paths) { parent in
            guard try readUnlocked(
                parentDescriptor: parent,
                paths: paths
            ) == nil else {
                throw storeError(
                    "a pending launch already exists; recover it before "
                        + "allocating another session"
                )
            }
            try writeUnlocked(
                record,
                parentDescriptor: parent,
                paths: paths
            )
            return record
        }
    }

    static func markAliasReady(
        sessionID: String,
        device: UInt64,
        inode: UInt64,
        inventory: [AliasEntry],
        paths: IOSUsePaths
    ) throws -> Record {
        return try update(
            sessionID: sessionID,
            paths: paths
        ) { current in
            if current.phase == .aliasReady {
                guard current.aliasDevice == device,
                      current.aliasInode == inode,
                      current.aliasInventory == inventory else {
                    throw storeError(
                        "aliasReady was replayed with different evidence"
                    )
                }
                return current
            }
            guard current.phase == .intent else {
                throw invalidTransition(current.phase, to: .aliasReady)
            }
            return current.replacing(
                phase: .aliasReady,
                aliasDevice: .some(device),
                aliasInode: .some(inode),
                aliasInventory: .some(inventory)
            )
        }
    }

    static func markSubmissionArmed(
        sessionID: String,
        bootSessionUUID: String,
        paths: IOSUsePaths
    ) throws -> Record {
        guard let normalizedBootSessionUUID =
                canonicalUUID(bootSessionUUID) else {
            throw storeError(
                "submission boot session is not a UUID"
            )
        }
        return try update(
            sessionID: sessionID,
            paths: paths
        ) { current in
            if current.phase == .submissionArmed {
                guard canonicalUUID(
                    current.submissionBootSessionUUID
                ) == normalizedBootSessionUUID else {
                    throw storeError(
                        "submissionArmed was replayed on another boot"
                    )
                }
                return current
            }
            guard current.phase == .aliasReady else {
                throw invalidTransition(
                    current.phase,
                    to: .submissionArmed
                )
            }
            return current.replacing(
                phase: .submissionArmed,
                submissionBootSessionUUID:
                    .some(normalizedBootSessionUUID)
            )
        }
    }

    static func markTerminalCallbackFailure(
        sessionID: String,
        errorDescription: String,
        paths: IOSUsePaths
    ) throws -> Record {
        let callback = TerminalCallback(
            outcome: .failure,
            errorDescription: errorDescription
        )
        return try update(
            sessionID: sessionID,
            paths: paths
        ) { current in
            switch current.phase {
            case .submissionArmed:
                return current.replacing(
                    phase: .terminalCallback,
                    terminalCallback: .some(callback)
                )
            case .terminalCallback:
                guard current.terminalCallback == callback else {
                    throw storeError(
                        "terminal callback was replayed with different "
                            + "evidence"
                    )
                }
                return current
            case .owned, .driverLockCommitted:
                if let existing = current.terminalCallback {
                    guard existing == callback else {
                        throw storeError(
                            "terminal callback conflicts with durable "
                                + "ownership evidence"
                        )
                    }
                    return current
                }
                return current.replacing(
                    terminalCallback: .some(callback)
                )
            case .confirmedStopped:
                return current
            case .intent, .aliasReady:
                throw invalidTransition(
                    current.phase,
                    to: .terminalCallback
                )
            }
        }
    }

    static func markOwned(
        sessionID: String,
        owner: Owner,
        callbackSucceeded: Bool,
        paths: IOSUsePaths
    ) throws -> Record {
        let callback = callbackSucceeded
            ? TerminalCallback(
                outcome: .success,
                errorDescription: nil
            )
            : nil
        return try update(
            sessionID: sessionID,
            paths: paths
        ) { current in
            switch current.phase {
            case .submissionArmed, .terminalCallback:
                if callbackSucceeded,
                   let existing = current.terminalCallback,
                   existing.outcome == .failure {
                    throw storeError(
                        "successful callback conflicts with the durable "
                            + "terminal callback"
                    )
                }
                return current.replacing(
                    phase: .owned,
                    terminalCallback:
                        callback.map(Optional.some),
                    owner: .some(owner)
                )
            case .owned, .driverLockCommitted:
                guard let existingOwner = current.owner,
                      sameProcess(
                        existingOwner,
                        owner
                      ) else {
                    throw storeError(
                        "ownership was replayed for a different process"
                    )
                }
                if callbackSucceeded {
                    if let existing = current.terminalCallback {
                        guard existing == callback else {
                            throw storeError(
                                "callback result conflicts with durable "
                                    + "ownership evidence"
                            )
                        }
                        return current
                    }
                    return current.replacing(
                        terminalCallback: .some(callback)
                    )
                }
                return current
            case .confirmedStopped:
                return current
            case .intent, .aliasReady:
                throw invalidTransition(current.phase, to: .owned)
            }
        }
    }

    static func markDriverLockCommitted(
        sessionID: String,
        paths: IOSUsePaths
    ) throws -> Record {
        try update(sessionID: sessionID, paths: paths) { current in
            if current.phase == .driverLockCommitted {
                return current
            }
            guard current.phase == .owned else {
                throw invalidTransition(
                    current.phase,
                    to: .driverLockCommitted
                )
            }
            return current.replacing(
                phase: .driverLockCommitted
            )
        }
    }

    static func markConfirmedStopped(
        sessionID: String,
        cleanupProof: CleanupProof,
        paths: IOSUsePaths
    ) throws -> Record {
        try update(sessionID: sessionID, paths: paths) { current in
            if current.phase == .confirmedStopped {
                guard current.cleanupProof == cleanupProof else {
                    throw storeError(
                        "confirmed cleanup proof changed"
                    )
                }
                return current
            }
            try validateCleanupTransition(
                current.phase,
                proof: cleanupProof
            )
            return current.replacing(
                phase: .confirmedStopped,
                cleanupProof: .some(cleanupProof)
            )
        }
    }

    static func removeConfirmed(
        sessionID: String,
        paths: IOSUsePaths
    ) throws {
        try withExclusiveLock(paths: paths) { parent in
            guard let current = try readUnlocked(
                parentDescriptor: parent,
                paths: paths
            ) else {
                return
            }
            guard current.sessionID == sessionID,
                  current.phase == .confirmedStopped,
                  current.cleanupProof != nil else {
                throw storeError(
                    "pending launch removal requires the matching "
                        + "confirmedStopped record"
                )
            }
            guard Darwin.unlinkat(
                    parent,
                    journalFilename,
                    0
                  ) == 0 else {
                throw storeError(
                    "cannot remove pending-launch.json: errno \(errno)"
                )
            }
            try syncParent(parent)
        }
    }

    static func load(paths: IOSUsePaths) throws -> Record? {
        processLock.lock()
        defer { processLock.unlock() }
        #if canImport(Darwin)
        let parent = Darwin.open(
            paths.playcover,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if parent < 0, errno == ENOENT {
            return nil
        }
        guard parent >= 0 else {
            throw storeError(
                "cannot open managed PlayCover state: errno \(errno)"
            )
        }
        defer { Darwin.close(parent) }
        try validateParent(parent)
        for _ in 0..<3 {
            if try namedEntryExists(
                lockFilename,
                parentDescriptor: parent
            ) {
                return try withExistingLock(
                    parentDescriptor: parent
                ) {
                    try readUnlocked(
                        parentDescriptor: parent,
                        paths: paths
                    )
                }
            }
            let journalExists = try namedEntryExists(
                journalFilename,
                parentDescriptor: parent,
            )
            if try namedEntryExists(
                lockFilename,
                parentDescriptor: parent
            ) {
                continue
            }
            guard journalExists else {
                return nil
            }
            throw storeError(
                "pending-launch.json exists without its durable lock"
            )
        }
        throw storeError(
            "pending launch state changed while acquiring its lock"
        )
        #else
        guard FileManager.default.fileExists(
            atPath: paths.playcoverPendingLaunch
        ) else {
            return nil
        }
        let data = try Data(
            contentsOf: URL(
                fileURLWithPath: paths.playcoverPendingLaunch
            )
        )
        return try decodeAndValidate(data, paths: paths)
        #endif
    }

    private static func update(
        sessionID: String,
        paths: IOSUsePaths,
        _ body: (Record) throws -> Record
    ) throws -> Record {
        try withExclusiveLock(paths: paths) { parent in
            guard let current = try readUnlocked(
                parentDescriptor: parent,
                paths: paths
            ) else {
                throw storeError(
                    "the pending launch disappeared before its durable "
                        + "transition"
                )
            }
            guard current.sessionID == sessionID else {
                throw storeError(
                    "pending launch belongs to a different session"
                )
            }
            let updated = try body(current)
            try validate(updated, paths: paths)
            if updated != current {
                try writeUnlocked(
                    updated,
                    parentDescriptor: parent,
                    paths: paths
                )
            }
            return updated
        }
    }

    private static func withExclusiveLock<T>(
        paths: IOSUsePaths,
        _ operation: (Int32) throws -> T
    ) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        #if canImport(Darwin)
        return try PlayCoverManagedAppService
            .withSecureManagedDirectories(paths: paths) { access in
                try validateParent(access.playcoverDescriptor)
                return try withLock(
                    parentDescriptor:
                        access.playcoverDescriptor,
                    create: true
                ) {
                    try operation(access.playcoverDescriptor)
                }
            }
        #else
        return try operation(-1)
        #endif
    }

    #if canImport(Darwin)
    private static func withExistingLock<T>(
        parentDescriptor: Int32,
        _ operation: () throws -> T
    ) throws -> T {
        try withLock(
            parentDescriptor: parentDescriptor,
            create: false,
            operation
        )
    }

    private static func withLock<T>(
        parentDescriptor: Int32,
        create: Bool,
        _ operation: () throws -> T
    ) throws -> T {
        var created = false
        var descriptor: Int32
        if create {
            descriptor = Darwin.openat(
                parentDescriptor,
                lockFilename,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC
                    | O_NOFOLLOW,
                0o600
            )
            if descriptor >= 0 {
                created = true
            } else if errno == EEXIST {
                descriptor = Darwin.openat(
                    parentDescriptor,
                    lockFilename,
                    O_RDWR | O_CLOEXEC | O_NOFOLLOW
                )
            }
        } else {
            descriptor = Darwin.openat(
                parentDescriptor,
                lockFilename,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw storeError(
                "cannot open pending-launch.lock: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        if created {
            guard fchmod(descriptor, 0o600) == 0,
                  fsync(descriptor) == 0 else {
                throw storeError(
                    "cannot durably create pending-launch.lock: "
                        + "errno \(errno)"
                )
            }
            try syncParent(parentDescriptor)
        }
        try validateLock(
            descriptor,
            parentDescriptor: parentDescriptor
        )
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            guard errno == EINTR else {
                throw storeError(
                    "cannot acquire pending-launch.lock: errno \(errno)"
                )
            }
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        try validateLock(
            descriptor,
            parentDescriptor: parentDescriptor
        )
        return try operation()
    }

    private static func validateLock(
        _ descriptor: Int32,
        parentDescriptor: Int32
    ) throws {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(
                parentDescriptor,
                lockFilename,
                &named,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameIdentity(opened, named),
              isSafeRegularFile(opened, maximum: 0),
              opened.st_size == 0 else {
            throw storeError(
                "pending-launch.lock is not a stable 0600 "
                    + "singly-linked regular file"
            )
        }
    }

    private static func namedEntryExists(
        _ name: String,
        parentDescriptor: Int32
    ) throws -> Bool {
        var status = stat()
        if fstatat(
            parentDescriptor,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw storeError(
            "cannot inspect \(name): errno \(errno)"
        )
    }

    private static func readUnlocked(
        parentDescriptor: Int32,
        paths: IOSUsePaths
    ) throws -> Record? {
        let descriptor = Darwin.openat(
            parentDescriptor,
            journalFilename,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw storeError(
                "cannot open pending-launch.json: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              isSafeRegularFile(
                before,
                maximum: Int64(maximumBytes)
              ),
              before.st_size > 0 else {
            throw storeError(
                "pending-launch.json is not a bounded 0600 "
                    + "singly-linked regular file"
            )
        }
        var data = Data(count: Int(before.st_size))
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
                    throw storeError(
                        "cannot read pending-launch.json completely"
                    )
                }
            }
        }
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(
                parentDescriptor,
                journalFilename,
                &named,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameStableFile(before, after),
              sameStableFile(before, named) else {
            throw storeError(
                "pending-launch.json changed while it was read"
            )
        }
        return try decodeAndValidate(data, paths: paths)
    }

    private static func writeUnlocked(
        _ record: Record,
        parentDescriptor: Int32,
        paths: IOSUsePaths
    ) throws {
        try validate(record, paths: paths)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw storeError(
                "encoded journal exceeds \(maximumBytes) bytes"
            )
        }
        var existing = stat()
        if fstatat(
            parentDescriptor,
            journalFilename,
            &existing,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard isSafeRegularFile(
                existing,
                maximum: Int64(maximumBytes)
            ) else {
                throw storeError(
                    "refusing to replace unsafe pending-launch.json"
                )
            }
        } else if errno != ENOENT {
            throw storeError(
                "cannot inspect pending-launch.json before publish: "
                    + "errno \(errno)"
            )
        }
        let temporary =
            ".pending-launch-\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(
            parentDescriptor,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw storeError(
                "cannot create pending journal temporary file: "
                    + "errno \(errno)"
            )
        }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                _ = Darwin.unlinkat(
                    parentDescriptor,
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
                    throw storeError(
                        "cannot write pending launch journal: "
                            + "errno \(errno)"
                    )
                }
            }
        }
        guard fchmod(descriptor, 0o600) == 0,
              fsync(descriptor) == 0 else {
            throw storeError(
                "cannot secure pending launch journal: errno \(errno)"
            )
        }
        guard Darwin.renameat(
                parentDescriptor,
                temporary,
                parentDescriptor,
                journalFilename
              ) == 0 else {
            throw storeError(
                "cannot publish pending-launch.json: errno \(errno)"
            )
        }
        removeTemporary = false
        try syncParent(parentDescriptor)
    }

    private static func validateParent(
        _ descriptor: Int32
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o700 else {
            throw storeError(
                "managed PlayCover state is not an owner-only directory"
            )
        }
    }

    private static func syncParent(
        _ descriptor: Int32
    ) throws {
        guard fsync(descriptor) == 0 else {
            throw storeError(
                "cannot fsync managed PlayCover state: errno \(errno)"
            )
        }
    }

    private static func isSafeRegularFile(
        _ status: stat,
        maximum: Int64
    ) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_mode & 0o7777 == 0o600
            && status.st_size >= 0
            && status.st_size <= maximum
    }

    private static func sameIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
    }

    private static func sameStableFile(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        sameIdentity(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec
                == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec
                == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }
    #endif

    private static func decodeAndValidate(
        _ data: Data,
        paths: IOSUsePaths
    ) throws -> Record {
        guard data.count <= maximumBytes,
              let root = try JSONSerialization
                .jsonObject(with: data) as? [String: Any] else {
            throw storeError(
                "journal is oversized or is not a JSON object"
            )
        }
        let allowed = Set([
            "schemaVersion",
            "phase",
            "sessionID",
            "runtimeSocketPath",
            "generationKey",
            "appPath",
            "bundleIdentifier",
            "executablePath",
            "aliasPath",
            "aliasDevice",
            "aliasInode",
            "aliasInventory",
            "submissionBootSessionUUID",
            "terminalCallback",
            "owner",
            "cleanupProof",
        ])
        guard Set(root.keys).isSubset(of: allowed) else {
            throw storeError("journal contains unknown fields")
        }
        if let inventory = root["aliasInventory"] as? [[String: Any]] {
            guard inventory.allSatisfy({
                Set($0.keys) == Set(["name", "destination"])
            }) else {
                throw storeError(
                    "alias inventory contains unknown or missing fields"
                )
            }
        }
        if let callback =
            root["terminalCallback"] as? [String: Any] {
            guard Set(callback.keys).isSubset(
                of: Set(["outcome", "errorDescription"])
            ), callback["outcome"] != nil else {
                throw storeError(
                    "terminal callback fields are invalid"
                )
            }
        }
        if let owner = root["owner"] as? [String: Any] {
            guard Set(owner.keys)
                    == Set([
                        "pid",
                        "processBirthMicroseconds",
                        "source",
                    ]) else {
                throw storeError("owner fields are invalid")
            }
        }
        let record: Record
        do {
            record = try JSONDecoder().decode(
                Record.self,
                from: data
            )
        } catch {
            throw storeError("journal cannot be decoded: \(error)")
        }
        try validate(record, paths: paths)
        return record
    }

    static func validate(
        _ record: Record,
        paths: IOSUsePaths
    ) throws {
        guard record.schemaVersion == schemaVersion,
              UUID(uuidString: record.sessionID) != nil,
              isBundleIdentifier(record.bundleIdentifier),
              isLowercaseSHA256(record.generationKey),
              record.runtimeSocketPath.hasPrefix("/"),
              record.appPath.hasPrefix("/"),
              record.executablePath.hasPrefix("/"),
              record.aliasPath.hasPrefix("/") else {
            throw storeError(
                "journal common identity is incomplete"
            )
        }
        let expectedSocket = try paths.playCoverRuntimeSocketPath(
            sessionID: record.sessionID
        )
        guard record.runtimeSocketPath == expectedSocket else {
            throw storeError(
                "Runtime socket does not match sessionID"
            )
        }
        let app = URL(
            fileURLWithPath: record.appPath,
            isDirectory: true
        ).standardizedFileURL
        let prepared = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).standardizedFileURL
        let executable = URL(
            fileURLWithPath: record.executablePath,
            isDirectory: false
        ).standardizedFileURL
        guard app.pathExtension == "app",
              record.appPath == app.path,
              record.executablePath == executable.path,
              app.deletingLastPathComponent().lastPathComponent
                == record.generationKey,
              app.deletingLastPathComponent()
                .deletingLastPathComponent().path == prepared.path,
              executable.path.hasPrefix(app.path + "/") else {
            throw storeError(
                "journal App/executable does not identify its managed "
                    + "generation"
            )
        }
        let expectedAlias = PlayCoverService.sessionLaunchAlias(
            sessionID: record.sessionID
        ).bundleURL.standardizedFileURL.path
        guard record.aliasPath == expectedAlias else {
            throw storeError(
                "façade path does not match sessionID"
            )
        }
        try validateAliasEvidence(record)
        try validateSubmissionEvidence(record)
        try validatePhase(record)
    }

    private static func validateAliasEvidence(
        _ record: Record
    ) throws {
        let values = (
            record.aliasDevice,
            record.aliasInode,
            record.aliasInventory
        )
        if values.0 == nil, values.1 == nil, values.2 == nil {
            return
        }
        guard let device = values.0,
              let inode = values.1,
              let inventory = values.2,
              device > 0,
              inode > 0,
              !inventory.isEmpty,
              inventory == inventory.sorted(by: {
                $0.name < $1.name
              }) else {
            throw storeError(
                "façade identity/inventory is incomplete"
            )
        }
        var names = Set<String>()
        for entry in inventory {
            guard isSafeName(entry.name),
                  names.insert(entry.name).inserted,
                  entry.destination == URL(
                    fileURLWithPath: record.appPath,
                    isDirectory: true
                  ).appendingPathComponent(entry.name).path else {
                throw storeError(
                    "façade inventory is unsafe or mismatched"
                )
            }
        }
    }

    private static func validateSubmissionEvidence(
        _ record: Record
    ) throws {
        if let boot = record.submissionBootSessionUUID {
            guard UUID(uuidString: boot) != nil else {
                throw storeError(
                    "submission boot session is not a UUID"
                )
            }
        }
        if let callback = record.terminalCallback {
            switch callback.outcome {
            case .success:
                guard callback.errorDescription == nil else {
                    throw storeError(
                        "successful callback cannot contain an error"
                    )
                }
            case .failure:
                guard let error = callback.errorDescription,
                      !error.isEmpty,
                      error.utf8.count <= 4_096 else {
                    throw storeError(
                        "failed callback requires a bounded error"
                    )
                }
            }
        }
        if let owner = record.owner {
            guard owner.pid > 0,
                  owner.processBirthMicroseconds > 0 else {
                throw storeError(
                    "owned process identity is incomplete"
                )
            }
        }
    }

    private static func validatePhase(
        _ record: Record
    ) throws {
        let hasAlias = record.aliasDevice != nil
            && record.aliasInode != nil
            && record.aliasInventory != nil
        switch record.phase {
        case .intent:
            guard !hasAlias,
                  record.submissionBootSessionUUID == nil,
                  record.terminalCallback == nil,
                  record.owner == nil,
                  record.cleanupProof == nil else {
                throw storeError("intent fields are inconsistent")
            }
        case .aliasReady:
            guard hasAlias,
                  record.submissionBootSessionUUID == nil,
                  record.terminalCallback == nil,
                  record.owner == nil,
                  record.cleanupProof == nil else {
                throw storeError("aliasReady fields are inconsistent")
            }
        case .submissionArmed:
            guard hasAlias,
                  record.submissionBootSessionUUID != nil,
                  record.terminalCallback == nil,
                  record.owner == nil,
                  record.cleanupProof == nil else {
                throw storeError(
                    "submissionArmed fields are inconsistent"
                )
            }
        case .terminalCallback:
            guard hasAlias,
                  record.submissionBootSessionUUID != nil,
                  record.terminalCallback?.outcome == .failure,
                  record.owner == nil,
                  record.cleanupProof == nil else {
                throw storeError(
                    "terminalCallback fields are inconsistent"
                )
            }
        case .owned, .driverLockCommitted:
            guard hasAlias,
                  record.submissionBootSessionUUID != nil,
                  record.owner != nil,
                  record.cleanupProof == nil else {
                throw storeError(
                    "\(record.phase.rawValue) fields are inconsistent"
                )
            }
        case .confirmedStopped:
            guard let cleanupProof = record.cleanupProof else {
                throw storeError(
                    "confirmedStopped requires a cleanup proof"
                )
            }
            try validateCleanupEvidence(
                record,
                proof: cleanupProof
            )
        }
    }

    private static func validateCleanupTransition(
        _ phase: Phase,
        proof: CleanupProof
    ) throws {
        let allowed: Set<Phase>
        switch proof {
        case .neverSubmitted:
            allowed = [.intent, .aliasReady]
        case .terminalCallbackAndEmptyCensus:
            allowed = [.terminalCallback]
        case .newBootAndEmptyCensus:
            allowed = [.submissionArmed, .terminalCallback]
        case .ownedProcessExited, .ownedPIDReused,
             .stoppedExactOwner:
            allowed = [.owned, .driverLockCommitted]
        case .driverLockRetired:
            allowed = [.driverLockCommitted]
        }
        guard allowed.contains(phase) else {
            throw storeError(
                "cleanup proof \(proof.rawValue) cannot follow "
                    + phase.rawValue
            )
        }
    }

    private static func validateCleanupEvidence(
        _ record: Record,
        proof: CleanupProof
    ) throws {
        let valid: Bool
        switch proof {
        case .neverSubmitted:
            valid = record.submissionBootSessionUUID == nil
                && record.terminalCallback == nil
                && record.owner == nil
        case .terminalCallbackAndEmptyCensus:
            valid = record.submissionBootSessionUUID != nil
                && record.terminalCallback?.outcome == .failure
                && record.owner == nil
        case .newBootAndEmptyCensus:
            valid = record.submissionBootSessionUUID != nil
                && record.owner == nil
        case .ownedProcessExited, .ownedPIDReused,
             .stoppedExactOwner, .driverLockRetired:
            valid = record.submissionBootSessionUUID != nil
                && record.owner != nil
        }
        guard valid else {
            throw storeError(
                "cleanup proof \(proof.rawValue) conflicts with "
                    + "the durable launch evidence"
            )
        }
    }

    private static func invalidTransition(
        _ from: Phase,
        to: Phase
    ) -> PlayCoverPendingLaunchStoreError {
        storeError(
            "invalid phase transition \(from.rawValue) -> \(to.rawValue)"
        )
    }

    private static func storeError(
        _ message: String
    ) -> PlayCoverPendingLaunchStoreError {
        PlayCoverPendingLaunchStoreError(message: message)
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

    private static func isBundleIdentifier(
        _ value: String
    ) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty
            && bytes.count <= 512
            && bytes.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 45
                    || $0 == 46
            }
    }

    private static func isSafeName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.utf8.contains(0)
    }

    private static func canonicalUUID(
        _ value: String?
    ) -> String? {
        guard let value,
              let uuid = UUID(uuidString: value) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    private static func sameProcess(
        _ lhs: Owner,
        _ rhs: Owner
    ) -> Bool {
        lhs.pid == rhs.pid
            && lhs.processBirthMicroseconds
                == rhs.processBirthMicroseconds
    }
}
