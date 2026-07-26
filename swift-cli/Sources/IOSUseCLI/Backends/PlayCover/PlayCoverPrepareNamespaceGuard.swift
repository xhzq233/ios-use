import Foundation
#if canImport(Darwin)
import Darwin

/// Prevents prepare staging from leaving the retained ios-use managed tree.
///
/// macOS does not expose the BSD `UF_NOUNLINK` user flag. `UF_APPEND` on the
/// ios-use-owned `playcover` and `prepared` directories provides the needed
/// kernel behavior: prepare may continue mutating descendants, but rename or
/// unlink of either protected directory or an existing child is rejected.
///
/// The IOS_USE_HOME root vnode is the capability boundary. A malicious process
/// with the same uid can deliberately clear user flags, so this is an integrity
/// guard for normal filesystem races and cooperating ios-use processes, not a
/// privilege boundary.
final class PlayCoverPrepareNamespaceGuard {
    struct Directory {
        let descriptor: Int32
        let label: String
    }

    struct AnchoredLink {
        let parentDescriptor: Int32
        let childName: String
        let childDescriptor: Int32
        let label: String
    }

    private struct ProtectedDirectory {
        let descriptor: Int32
        let label: String
        let device: dev_t
        let inode: ino_t
        let originalFlags: UInt32
    }

    private static let appendOnlyFlag = UInt32(UF_APPEND)

    private let directories: [ProtectedDirectory]
    private let links: [AnchoredLink]
    private var active = true

    static func withProtection<T>(
        directories: [Directory],
        links: [AnchoredLink],
        operation: () throws -> T
    ) throws -> T {
        let guardState = try PlayCoverPrepareNamespaceGuard(
            directories: directories,
            links: links
        )
        let result: Result<T, Error>
        do {
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }

        do {
            try guardState.release()
        } catch {
            if case .failure(let operationError) = result {
                throw PlayCoverBackendError.prepareFailed(
                    "prepare failed (\(operationError)); namespace guard "
                        + "release also failed (\(error))"
                )
            }
            throw error
        }
        return try result.get()
    }

    init(
        directories requestedDirectories: [Directory],
        links: [AnchoredLink]
    ) throws {
        guard !requestedDirectories.isEmpty else {
            throw PlayCoverBackendError.prepareFailed(
                "prepare namespace guard has no protected directories"
            )
        }
        var protected: [ProtectedDirectory] = []
        do {
            for directory in requestedDirectories {
                var status = stat()
                guard fstat(directory.descriptor, &status) == 0,
                      status.st_mode & S_IFMT == S_IFDIR,
                      status.st_uid == geteuid() else {
                    throw PlayCoverBackendError.cacheTampered(
                        "cannot inspect \(directory.label) for prepare "
                            + "namespace protection"
                    )
                }

                // Only ios-use-owned namespace directories are passed here.
                // A surviving UF_APPEND therefore belongs to a process that
                // died before its defer ran. The global lifecycle lock makes
                // recovery safe in production.
                if status.st_flags & Self.appendOnlyFlag != 0 {
                    guard fchflags(
                            directory.descriptor,
                            status.st_flags & ~Self.appendOnlyFlag
                          ) == 0,
                          fstat(directory.descriptor, &status) == 0,
                          status.st_flags & Self.appendOnlyFlag == 0 else {
                        throw PlayCoverBackendError.prepareFailed(
                            "cannot recover stale namespace protection for "
                                + "\(directory.label): errno \(errno)"
                        )
                    }
                }
                let entry = ProtectedDirectory(
                    descriptor: directory.descriptor,
                    label: directory.label,
                    device: status.st_dev,
                    inode: status.st_ino,
                    originalFlags: status.st_flags
                )
                protected.append(entry)
                guard fchflags(
                        directory.descriptor,
                        status.st_flags | Self.appendOnlyFlag
                      ) == 0 else {
                    throw PlayCoverBackendError.prepareFailed(
                        "cannot protect \(directory.label) from namespace "
                            + "mutation: errno \(errno)"
                    )
                }
                try Self.validateProtectedDirectory(entry)
            }
            self.directories = protected
            self.links = links
            try validateLinks()
        } catch {
            for directory in protected.reversed() {
                _ = fchflags(
                    directory.descriptor,
                    directory.originalFlags
                )
            }
            throw error
        }
    }

    deinit {
        if active {
            for directory in directories.reversed() {
                _ = fchflags(
                    directory.descriptor,
                    directory.originalFlags
                )
            }
        }
    }

    func release() throws {
        guard active else {
            return
        }
        var firstError: Error?
        do {
            try validateLinks()
        } catch {
            firstError = error
        }
        for directory in directories {
            do {
                try Self.validateProtectedDirectory(directory)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        for directory in directories.reversed() {
            guard fchflags(
                    directory.descriptor,
                    directory.originalFlags
                  ) == 0 else {
                if firstError == nil {
                    firstError = PlayCoverBackendError.prepareFailed(
                        "cannot restore namespace flags for "
                            + "\(directory.label): errno \(errno)"
                    )
                }
                continue
            }
            var status = stat()
            if (fstat(directory.descriptor, &status) != 0
                    || status.st_dev != directory.device
                    || status.st_ino != directory.inode
                    || status.st_flags != directory.originalFlags),
               firstError == nil {
                firstError = PlayCoverBackendError.prepareFailed(
                    "namespace flags were not restored for \(directory.label)"
                )
            }
        }
        active = false
        if let firstError {
            throw firstError
        }
    }

    private func validateLinks() throws {
        for link in links {
            guard !link.childName.isEmpty,
                  link.childName != ".",
                  link.childName != "..",
                  !link.childName.contains("/") else {
                throw PlayCoverBackendError.cacheTampered(
                    "\(link.label) has an unsafe child name"
                )
            }
            var expected = stat()
            var actual = stat()
            guard fstat(link.childDescriptor, &expected) == 0,
                  expected.st_mode & S_IFMT == S_IFDIR,
                  fstatat(
                    link.parentDescriptor,
                    link.childName,
                    &actual,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  actual.st_mode & S_IFMT == S_IFDIR,
                  actual.st_dev == expected.st_dev,
                  actual.st_ino == expected.st_ino else {
                throw PlayCoverBackendError.cacheTampered(
                    "\(link.label) left its anchored parent during prepare"
                )
            }
        }
    }

    private static func validateProtectedDirectory(
        _ directory: ProtectedDirectory
    ) throws {
        var status = stat()
        guard fstat(directory.descriptor, &status) == 0,
              status.st_dev == directory.device,
              status.st_ino == directory.inode,
              status.st_flags & appendOnlyFlag != 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "namespace protection changed for \(directory.label)"
            )
        }
    }
}
#endif
