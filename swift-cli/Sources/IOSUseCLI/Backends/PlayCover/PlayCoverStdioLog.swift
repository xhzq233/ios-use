import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverStdioLogIdentity: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
}

enum PlayCoverStdioLogService {
    private static let directoryName = "logs"

    static func create(
        sessionID: String,
        paths: IOSUsePaths
    ) throws -> PlayCoverStdioLogIdentity {
        #if canImport(Darwin)
        guard let sessionUUID = UUID(uuidString: sessionID) else {
            throw PlayCoverBackendError.stdioLogFailed(
                "cannot create a Mac stdio log for an invalid sessionID"
            )
        }
        let parentDescriptor = Darwin.open(
            paths.playcover,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw logError(
                "cannot open the managed Mac directory",
                errorNumber: errno
            )
        }
        defer { Darwin.close(parentDescriptor) }
        var parentStatus = stat()
        guard Darwin.fstat(parentDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              Darwin.fchmod(parentDescriptor, 0o700) == 0,
              Darwin.fstat(parentDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & 0o7777 == 0o700 else {
            throw PlayCoverBackendError.stdioLogFailed(
                "the managed Mac directory is not owner-only"
            )
        }

        if Darwin.mkdirat(
            parentDescriptor,
            directoryName,
            0o700
        ) != 0, errno != EEXIST {
            throw logError(
                "cannot create the Mac log directory",
                errorNumber: errno
            )
        }
        let directoryDescriptor = Darwin.openat(
            parentDescriptor,
            directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw logError(
                "cannot open the Mac log directory",
                errorNumber: errno
            )
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fchmod(directoryDescriptor, 0o700) == 0 else {
            throw logError(
                "cannot secure the Mac log directory",
                errorNumber: errno
            )
        }
        var directoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o7777 == 0o700 else {
            throw PlayCoverBackendError.stdioLogFailed(
                "the Mac log directory is not an owner-only directory"
            )
        }

        let filename =
            "stdio-\(sessionUUID.uuidString.lowercased()).log"
        let descriptor = Darwin.openat(
            directoryDescriptor,
            filename,
            O_WRONLY | O_APPEND | O_CREAT | O_EXCL
                | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw logError(
                "cannot create the per-session Mac stdio log",
                errorNumber: errno
            )
        }
        var removeCreatedFile = true
        defer {
            Darwin.close(descriptor)
            if removeCreatedFile {
                _ = Darwin.unlinkat(
                    directoryDescriptor,
                    filename,
                    0
                )
            }
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw logError(
                "cannot secure the per-session Mac stdio log",
                errorNumber: errno
            )
        }
        var descriptorStatus = stat()
        var namedStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              isOwnedLogFile(descriptorStatus),
              Darwin.fstatat(
                directoryDescriptor,
                filename,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameFile(descriptorStatus, namedStatus) else {
            throw PlayCoverBackendError.stdioLogFailed(
                "the per-session Mac stdio log lost its exact "
                    + "regular-file identity while being created"
            )
        }
        let lexicalPath =
            "\(paths.playcoverLogs)/\(filename)"
        guard let canonicalPath = canonicalExistingPath(lexicalPath) else {
            throw PlayCoverBackendError.stdioLogFailed(
                "cannot resolve the per-session Mac stdio log"
            )
        }
        var canonicalStatus = stat()
        guard Darwin.lstat(canonicalPath, &canonicalStatus) == 0,
              sameFile(descriptorStatus, canonicalStatus) else {
            throw PlayCoverBackendError.stdioLogFailed(
                "the per-session Mac stdio log path does not "
                    + "identify the created file"
            )
        }
        removeCreatedFile = false
        return PlayCoverStdioLogIdentity(
            path: canonicalPath,
            device: UInt64(truncatingIfNeeded: descriptorStatus.st_dev),
            inode: UInt64(descriptorStatus.st_ino)
        )
        #else
        throw PlayCoverBackendError.stdioLogFailed(
            "Mac stdio logs are supported only on macOS"
        )
        #endif
    }

    static func validateSessionPath(
        _ path: String,
        sessionID: String,
        paths: IOSUsePaths
    ) throws {
        #if canImport(Darwin)
        guard let sessionUUID = UUID(uuidString: sessionID),
              !path.isEmpty,
              !path.utf8.contains(0),
              let canonicalPlayCover =
                canonicalExistingPath(paths.playcover) else {
            throw invalidSessionLog()
        }
        let expected =
            "\(canonicalPlayCover)/\(directoryName)/stdio-"
                + "\(sessionUUID.uuidString.lowercased()).log"
        guard path == expected else {
            throw invalidSessionLog()
        }
        #else
        throw invalidSessionLog()
        #endif
    }

    #if canImport(Darwin)
    private static func isOwnedLogFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_mode & 0o7777 == 0o600
    }

    private static func sameFile(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
    }

    private static func canonicalExistingPath(
        _ path: String
    ) -> String? {
        guard let resolved = path.withCString({
            Darwin.realpath($0, nil)
        }) else {
            return nil
        }
        defer { Darwin.free(resolved) }
        return String(cString: resolved)
    }
    #endif

    private static func logError(
        _ message: String,
        errorNumber: Int32
    ) -> PlayCoverBackendError {
        .stdioLogFailed("\(message): errno \(errorNumber)")
    }

    private static func invalidSessionLog()
        -> CLIParseError
    {
        .invalidValue(
            "Invalid driver.lock: Mac stdio log path does not "
                + "match this session under the current IOS_USE_HOME."
        )
    }
}
