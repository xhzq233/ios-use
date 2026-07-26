import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct SessionOperationLockError:
    Error,
    CustomStringConvertible,
    Sendable
{
    let message: String

    var description: String {
        "Session operation lock failed: \(message)"
    }
}

enum SessionOperationLock {
    private static let processLock = NSLock()
    private static let lockFilename = "operation.lock"

    static func withExclusiveLock<T>(
        paths: IOSUsePaths,
        _ operation: () throws -> T
    ) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }

        #if canImport(Darwin)
        return try PlayCoverManagedAppService
            .withSecureManagedDirectories(paths: paths) { access in
                try withDarwinLock(
                    directoryDescriptor: access.playcoverDescriptor,
                    lockPath: access.playcover.appendingPathComponent(
                        lockFilename,
                        isDirectory: false
                    ).path,
                    operation
                )
            }
        #else
        return try operation()
        #endif
    }

    #if canImport(Darwin)
    private static func withDarwinLock<T>(
        directoryDescriptor: Int32,
        lockPath: String,
        _ operation: () throws -> T
    ) throws -> T {
        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o7777 == 0o700 else {
            throw SessionOperationLockError(
                message: "managed directory is not an owner-only directory"
            )
        }

        var created = false
        var descriptor = Darwin.openat(
            directoryDescriptor,
            lockFilename,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = Darwin.openat(
                directoryDescriptor,
                lockFilename,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw SessionOperationLockError(
                message: "cannot open \(lockPath): errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }

        try validateLockDescriptor(
            descriptor,
            created: created
        )

        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            guard errno == EINTR else {
                throw SessionOperationLockError(
                    message: "cannot acquire \(lockPath): errno \(errno)"
                )
            }
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }

        try validateNamedLock(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            lockPath: lockPath
        )
        return try operation()
    }

    private static func validateLockDescriptor(
        _ descriptor: Int32,
        created: Bool
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            throw SessionOperationLockError(
                message: "lock file is not a singly-linked owned regular file"
            )
        }

        if created {
            guard fchmod(descriptor, 0o600) == 0 else {
                throw SessionOperationLockError(
                    message: "cannot secure newly-created lock file: "
                        + "errno \(errno)"
                )
            }
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & 0o7777 == 0o600 else {
                throw SessionOperationLockError(
                    message: "new lock file did not retain its secure identity"
                )
            }
        } else {
            guard status.st_mode & 0o7777 == 0o600 else {
                throw SessionOperationLockError(
                    message: "existing lock file permissions must be 0600"
                )
            }
        }
    }

    private static func validateNamedLock(
        descriptor: Int32,
        directoryDescriptor: Int32,
        lockPath: String
    ) throws {
        var descriptorStatus = stat()
        var namedStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              Darwin.fstatat(
                directoryDescriptor,
                lockFilename,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              descriptorStatus.st_dev == namedStatus.st_dev,
              descriptorStatus.st_ino == namedStatus.st_ino,
              namedStatus.st_mode & S_IFMT == S_IFREG,
              namedStatus.st_uid == geteuid(),
              namedStatus.st_nlink == 1,
              namedStatus.st_mode & 0o7777 == 0o600 else {
            throw SessionOperationLockError(
                message: "\(lockPath) changed while acquiring the lock"
            )
        }
    }
    #endif
}
