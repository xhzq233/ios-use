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
        "Invalid Mac pending launch: \(message)"
    }
}

enum PlayCoverPendingLaunchStore {
    static let maximumBytes = 64 * 1_024

    enum Phase: String, Equatable, Sendable {
        case intent
        case owned
        case driverLockCommitted
    }

    enum OwnerSource: String, Equatable, Sendable {
        case workspaceCallback
        case authenticatedRuntime
    }

    struct Owner: Equatable, Sendable {
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

    struct Record: Equatable, Sendable {
        let phase: Phase
        let sessionID: String
        let runtimeSocketPath: String
        let generationKey: String
        let appPath: String
        let bundleIdentifier: String
        let executablePath: String
        let aliasPath: String
        let owner: Owner?
    }

    private static let processLock = NSLock()
    private static let journalFilename = "pending-launch.json"
    private static let lockFilename = "pending-launch.lock"

    static func createIntent(
        _ intent: Intent,
        paths: IOSUsePaths
    ) throws -> Record {
        let record = Record(
            phase: .intent,
            sessionID: intent.sessionID,
            runtimeSocketPath: intent.runtimeSocketPath,
            generationKey: intent.generationKey,
            appPath: intent.appPath,
            bundleIdentifier: intent.bundleIdentifier,
            executablePath: intent.executablePath,
            aliasPath: intent.aliasPath,
            owner: nil
        )
        try validate(record, paths: paths)
        return try withWritableStore(paths: paths) { parent in
            guard try readUnlocked(parent, paths: paths) == nil else {
                throw storeError(
                    "a pending launch already exists"
                )
            }
            try writeUnlocked(record, parent: parent)
            return record
        }
    }

    static func markOwned(
        sessionID: String,
        owner: Owner,
        paths: IOSUsePaths
    ) throws -> Record {
        try update(sessionID: sessionID, paths: paths) { current in
            switch current.phase {
            case .intent:
                return Record(
                    phase: .owned,
                    sessionID: current.sessionID,
                    runtimeSocketPath: current.runtimeSocketPath,
                    generationKey: current.generationKey,
                    appPath: current.appPath,
                    bundleIdentifier: current.bundleIdentifier,
                    executablePath: current.executablePath,
                    aliasPath: current.aliasPath,
                    owner: owner
                )
            case .owned, .driverLockCommitted:
                guard current.owner == owner else {
                    throw storeError(
                        "ownership was replayed for another process"
                    )
                }
                return current
            }
        }
    }

    static func markDriverLockCommitted(
        sessionID: String,
        paths: IOSUsePaths
    ) throws -> Record {
        try update(sessionID: sessionID, paths: paths) { current in
            switch current.phase {
            case .owned:
                return Record(
                    phase: .driverLockCommitted,
                    sessionID: current.sessionID,
                    runtimeSocketPath: current.runtimeSocketPath,
                    generationKey: current.generationKey,
                    appPath: current.appPath,
                    bundleIdentifier: current.bundleIdentifier,
                    executablePath: current.executablePath,
                    aliasPath: current.aliasPath,
                    owner: current.owner
                )
            case .driverLockCommitted:
                return current
            case .intent:
                throw storeError(
                    "driver.lock cannot commit an unowned launch"
                )
            }
        }
    }

    static func remove(
        sessionID: String,
        expectedPhase: Phase,
        paths: IOSUsePaths
    ) throws {
        try withWritableStore(paths: paths) { parent in
            guard let current = try readUnlocked(
                parent,
                paths: paths
            ) else {
                return
            }
            guard current.sessionID == sessionID,
                  current.phase == expectedPhase else {
                throw storeError(
                    "journal removal identity or phase changed"
                )
            }
            #if canImport(Darwin)
            guard Darwin.unlinkat(
                    parent,
                    journalFilename,
                    0
                  ) == 0 else {
                throw storeError(
                    "cannot remove pending-launch.json: errno \(errno)"
                )
            }
            try syncDirectory(parent)
            #else
            try FileManager.default.removeItem(
                atPath: paths.playcoverPendingLaunch
            )
            #endif
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
                "cannot open Mac state directory: errno \(errno)"
            )
        }
        defer { Darwin.close(parent) }
        try validateParent(parent)
        return try withFileLock(parent: parent, create: false) {
            try readUnlocked(parent, paths: paths)
        }
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
        return try decode(data, paths: paths)
        #endif
    }

    private static func update(
        sessionID: String,
        paths: IOSUsePaths,
        _ transform: (Record) throws -> Record
    ) throws -> Record {
        try withWritableStore(paths: paths) { parent in
            guard let current = try readUnlocked(
                parent,
                paths: paths
            ) else {
                throw storeError(
                    "pending launch disappeared before transition"
                )
            }
            guard current.sessionID == sessionID else {
                throw storeError(
                    "pending launch belongs to another session"
                )
            }
            let updated = try transform(current)
            try validate(updated, paths: paths)
            if updated != current {
                try writeUnlocked(updated, parent: parent)
            }
            return updated
        }
    }

    private static func withWritableStore<T>(
        paths: IOSUsePaths,
        _ operation: (Int32) throws -> T
    ) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        #if canImport(Darwin)
        return try SessionOperationLock.withSecureStateDirectory(
            paths: paths
        ) { parent, _ in
            try validateParent(parent)
            return try withFileLock(parent: parent, create: true) {
                try operation(parent)
            }
        }
        #else
        return try operation(-1)
        #endif
    }

    #if canImport(Darwin)
    private static func withFileLock<T>(
        parent: Int32,
        create: Bool,
        _ operation: () throws -> T
    ) throws -> T {
        var flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        if create {
            flags |= O_CREAT
        }
        let descriptor = Darwin.openat(
            parent,
            lockFilename,
            flags,
            0o600
        )
        if descriptor < 0, !create, errno == ENOENT {
            let journal = Darwin.openat(
                parent,
                journalFilename,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            if journal < 0, errno == ENOENT {
                return try operation()
            }
            if journal >= 0 {
                Darwin.close(journal)
            }
            throw storeError(
                "pending-launch.json exists without its lock"
            )
        }
        guard descriptor >= 0 else {
            throw storeError(
                "cannot open pending-launch.lock: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & S_IFMT == S_IFREG else {
            throw storeError("pending launch lock is not owner-controlled")
        }
        if status.st_mode & 0o777 != 0o600,
           fchmod(descriptor, 0o600) != 0 {
            throw storeError(
                "cannot secure pending launch lock: errno \(errno)"
            )
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw storeError(
                "cannot lock pending launch state: errno \(errno)"
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func readUnlocked(
        _ parent: Int32,
        paths: IOSUsePaths
    ) throws -> Record? {
        let descriptor = Darwin.openat(
            parent,
            journalFilename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
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
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o777 == 0o600,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw storeError(
                "pending-launch.json is not a bounded owner-only file"
            )
        }
        var data = Data(count: Int(status.st_size))
        let dataCount = data.count
        var offset = 0
        while offset < dataCount {
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    dataCount - offset
                )
            }
            if readCount < 0, errno == EINTR {
                continue
            }
            guard readCount > 0 else {
                throw storeError(
                    "pending-launch.json changed while reading"
                )
            }
            offset += readCount
        }
        return try decode(data, paths: paths)
    }

    private static func writeUnlocked(
        _ record: Record,
        parent: Int32
    ) throws {
        let data = try encode(record)
        guard data.count <= maximumBytes else {
            throw storeError("pending launch record is too large")
        }
        let temporary = ".pending-launch-\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(
            parent,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw storeError(
                "cannot create pending launch staging file: errno \(errno)"
            )
        }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published {
                _ = Darwin.unlinkat(parent, temporary, 0)
            }
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            if written < 0, errno == EINTR {
                continue
            }
            guard written > 0 else {
                throw storeError(
                    "cannot write pending launch staging file: errno \(errno)"
                )
            }
            offset += written
        }
        guard fsync(descriptor) == 0,
              Darwin.renameat(
                parent,
                temporary,
                parent,
                journalFilename
              ) == 0 else {
            throw storeError(
                "cannot publish pending launch journal: errno \(errno)"
            )
        }
        published = true
        try syncDirectory(parent)
    }

    private static func validateParent(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_mode & 0o777 == 0o700 else {
            throw storeError(
                "Mac state directory is not owner-only"
            )
        }
    }

    private static func syncDirectory(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else {
            throw storeError(
                "cannot sync Mac state directory: errno \(errno)"
            )
        }
    }
    #else
    private static func readUnlocked(
        _ parent: Int32,
        paths: IOSUsePaths
    ) throws -> Record? {
        guard FileManager.default.fileExists(
            atPath: paths.playcoverPendingLaunch
        ) else {
            return nil
        }
        return try decode(
            Data(
                contentsOf: URL(
                    fileURLWithPath: paths.playcoverPendingLaunch
                )
            ),
            paths: paths
        )
    }

    private static func writeUnlocked(
        _ record: Record,
        parent: Int32
    ) throws {
        _ = parent
        throw storeError("pending launch persistence requires Darwin")
    }
    #endif

    private static func encode(_ record: Record) throws -> Data {
        var object: [String: Any] = [
            "phase": record.phase.rawValue,
            "sessionID": record.sessionID,
            "runtimeSocketPath": record.runtimeSocketPath,
            "generationKey": record.generationKey,
            "appPath": record.appPath,
            "bundleIdentifier": record.bundleIdentifier,
            "executablePath": record.executablePath,
            "aliasPath": record.aliasPath,
        ]
        if let owner = record.owner {
            object["owner"] = [
                "pid": Int(owner.pid),
                "processBirthMicroseconds":
                    String(owner.processBirthMicroseconds),
                "source": owner.source.rawValue,
            ]
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        } catch {
            throw storeError("cannot encode pending launch: \(error)")
        }
    }

    private static func decode(
        _ data: Data,
        paths: IOSUsePaths
    ) throws -> Record {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw storeError("pending launch JSON size is invalid")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(
                with: data,
                options: []
            )
        } catch {
            throw storeError("pending launch JSON is malformed")
        }
        guard let root = value as? [String: Any],
              let phaseText = root["phase"] as? String,
              let phase = Phase(rawValue: phaseText),
              let sessionID = root["sessionID"] as? String,
              let runtimeSocketPath =
                root["runtimeSocketPath"] as? String,
              let generationKey = root["generationKey"] as? String,
              let appPath = root["appPath"] as? String,
              let bundleIdentifier =
                root["bundleIdentifier"] as? String,
              let executablePath = root["executablePath"] as? String,
              let aliasPath = root["aliasPath"] as? String else {
            throw storeError("pending launch JSON fields are invalid")
        }
        let baseKeys: Set<String> = [
            "phase", "sessionID", "runtimeSocketPath", "generationKey",
            "appPath", "bundleIdentifier", "executablePath", "aliasPath",
        ]
        let owner: Owner?
        if phase == .intent {
            guard Set(root.keys) == baseKeys else {
                throw storeError("intent contains unexpected fields")
            }
            owner = nil
        } else {
            guard Set(root.keys) == baseKeys.union(["owner"]),
                  let rawOwner = root["owner"] as? [String: Any],
                  Set(rawOwner.keys) == [
                    "pid", "processBirthMicroseconds", "source",
                  ],
                  let pidNumber = rawOwner["pid"] as? NSNumber,
                  CFGetTypeID(pidNumber) != CFBooleanGetTypeID(),
                  let pid = Int32(exactly: pidNumber.int64Value),
                  let birthText =
                    rawOwner["processBirthMicroseconds"] as? String,
                  let birth = UInt64(birthText),
                  let sourceText = rawOwner["source"] as? String,
                  let source = OwnerSource(rawValue: sourceText) else {
                throw storeError("pending launch owner is invalid")
            }
            owner = Owner(
                pid: pid,
                processBirthMicroseconds: birth,
                source: source
            )
        }
        let record = Record(
            phase: phase,
            sessionID: sessionID,
            runtimeSocketPath: runtimeSocketPath,
            generationKey: generationKey,
            appPath: appPath,
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            aliasPath: aliasPath,
            owner: owner
        )
        try validate(record, paths: paths)
        return record
    }

    private static func validate(
        _ record: Record,
        paths: IOSUsePaths
    ) throws {
        guard UUID(uuidString: record.sessionID)?.uuidString
                == record.sessionID.uppercased(),
              isLowercaseSHA256(record.generationKey),
              isBoundedText(record.bundleIdentifier, maximum: 512),
              !record.bundleIdentifier.contains("/"),
              !record.bundleIdentifier.utf8.contains(0) else {
            throw storeError("pending launch identity is invalid")
        }
        let expectedApp = canonicalExistingPath(URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(
            record.generationKey,
            isDirectory: true
        ).appendingPathComponent(
            "App.app",
            isDirectory: true
        ).path)
        let expectedAlias = PlayCoverService.sessionLaunchAlias(
            sessionID: record.sessionID
        ).bundleURL.standardizedFileURL.path
        let expectedSocket = try paths.macRuntimeSocketPath(
            sessionID: record.sessionID
        )
        guard record.appPath == expectedApp else {
            throw storeError(
                "prepared App path is outside its generation: "
                    + "\(record.appPath) != \(expectedApp)"
            )
        }
        guard record.aliasPath == expectedAlias else {
            throw storeError("launch facade path is not session-derived")
        }
        guard record.runtimeSocketPath == expectedSocket else {
            throw storeError("Runtime socket path is not session-derived")
        }
        guard record.executablePath.hasPrefix(record.appPath + "/"),
              isBoundedAbsolutePath(record.executablePath),
              isBoundedAbsolutePath(record.appPath),
              isBoundedAbsolutePath(record.aliasPath),
              isBoundedAbsolutePath(record.runtimeSocketPath) else {
            throw storeError("pending launch contains a non-canonical path")
        }
        switch record.phase {
        case .intent:
            guard record.owner == nil else {
                throw storeError("intent cannot contain an owner")
            }
        case .owned, .driverLockCommitted:
            guard let owner = record.owner,
                  owner.pid > 0,
                  owner.processBirthMicroseconds > 0 else {
                throw storeError("owned launch has no exact process identity")
            }
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private static func isBoundedText(
        _ value: String,
        maximum: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
    }

    private static func isBoundedAbsolutePath(_ value: String) -> Bool {
        guard isBoundedText(value, maximum: 4_096),
              value.hasPrefix("/"),
              !value.utf8.contains(0),
              !value.contains("//") else {
            return false
        }
        return !value.split(separator: "/", omittingEmptySubsequences: true)
            .contains { $0 == "." || $0 == ".." }
    }

    private static func canonicalExistingPath(_ value: String) -> String {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if value.withCString({ Darwin.realpath($0, &buffer) }) != nil {
            return String(cString: buffer)
        }
        #endif
        return URL(fileURLWithPath: value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func storeError(
        _ message: String
    ) -> PlayCoverPendingLaunchStoreError {
        PlayCoverPendingLaunchStoreError(message: message)
    }
}
