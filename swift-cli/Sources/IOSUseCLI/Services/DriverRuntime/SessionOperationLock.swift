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
        return try withSecureStateDirectory(paths: paths) {
            descriptor,
            stateURL in
            try withDarwinLock(
                directoryDescriptor: descriptor,
                lockPath: stateURL.appendingPathComponent(
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
    static func withSecureStateDirectory<T>(
        paths: IOSUsePaths,
        _ operation: (Int32, URL) throws -> T
    ) throws -> T {
        let stateDirectory = try openManagedStateDirectory(paths: paths)
        defer { Darwin.close(stateDirectory.descriptor) }
        return try operation(
            stateDirectory.descriptor,
            stateDirectory.url
        )
    }

    private static func openManagedStateDirectory(
        paths: IOSUsePaths
    ) throws -> (descriptor: Int32, url: URL) {
        let lexicalRoot = URL(
            fileURLWithPath: paths.root,
            isDirectory: true
        ).standardized.path
        let lexicalState = URL(
            fileURLWithPath: paths.playcover,
            isDirectory: true
        ).standardized.path
        guard lexicalState
                == URL(
                    fileURLWithPath: lexicalRoot,
                    isDirectory: true
                )
                .appendingPathComponent("mac", isDirectory: true)
                .path else {
            throw SessionOperationLockError(
                message: "Mac state directory is outside IOS_USE_HOME"
            )
        }
        try rejectUserOwnedSymlinkComponents(lexicalRoot)
        if isUserOwnedSymbolicLink(lexicalState) {
            throw SessionOperationLockError(
                message: "Mac state directory is a symbolic link"
            )
        }

        let canonicalState = canonicalizingExistingPrefix(lexicalState)
        let components = Array(
            URL(fileURLWithPath: canonicalState)
                .pathComponents
                .dropFirst()
        )
        let ownerControlledStart = max(0, components.count - 2)
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SessionOperationLockError(
                message: "cannot open filesystem root: errno \(errno)"
            )
        }
        var succeeded = false
        defer {
            if !succeeded {
                Darwin.close(descriptor)
            }
        }
        for (index, component) in components.enumerated() {
            var created = false
            var child = Darwin.openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if child < 0, errno == ENOENT {
                guard Darwin.mkdirat(descriptor, component, 0o700) == 0
                        || errno == EEXIST else {
                    throw SessionOperationLockError(
                        message: "cannot create Mac state component "
                            + "\(component): errno \(errno)"
                    )
                }
                child = Darwin.openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                created = true
            }
            guard child >= 0 else {
                throw SessionOperationLockError(
                    message: "Mac state contains a missing, symlink, or "
                        + "non-directory component \(component): errno "
                        + "\(errno)"
                )
            }
            if created || index >= ownerControlledStart {
                var status = stat()
                guard fstat(child, &status) == 0,
                      status.st_uid == geteuid() else {
                    Darwin.close(child)
                    throw SessionOperationLockError(
                        message: "Mac state component is not owner-controlled: "
                            + component
                    )
                }
                if status.st_mode & 0o7777 != 0o700,
                   fchmod(child, 0o700) != 0 {
                    Darwin.close(child)
                    throw SessionOperationLockError(
                        message: "cannot secure Mac state component "
                            + "\(component): errno \(errno)"
                    )
                }
            }
            Darwin.close(descriptor)
            descriptor = child
        }
        succeeded = true
        return (
            descriptor,
            URL(fileURLWithPath: canonicalState, isDirectory: true)
        )
    }

    private static func rejectUserOwnedSymlinkComponents(
        _ path: String
    ) throws {
        var current = URL(fileURLWithPath: "/")
        for component in URL(
            fileURLWithPath: path
        ).standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var status = stat()
            if lstat(current.path, &status) != 0 {
                if errno == ENOENT {
                    return
                }
                throw SessionOperationLockError(
                    message: "cannot inspect Mac state path component "
                        + "\(current.path): errno \(errno)"
                )
            }
            if status.st_mode & S_IFMT == S_IFLNK,
               status.st_uid == geteuid() {
                throw SessionOperationLockError(
                    message: "Mac state path contains a user-owned "
                        + "symbolic link: \(current.path)"
                )
            }
        }
    }

    private static func isUserOwnedSymbolicLink(
        _ path: String
    ) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
            && status.st_mode & S_IFMT == S_IFLNK
            && status.st_uid == geteuid()
    }

    private static func canonicalizingExistingPrefix(
        _ path: String
    ) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = existing.path.withCString {
            Darwin.realpath($0, &buffer)
        }
        var result = resolved == nil
            ? existing.path
            : String(cString: buffer)
        for component in suffix {
            result = (result as NSString)
                .appendingPathComponent(component)
        }
        return result
    }

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
