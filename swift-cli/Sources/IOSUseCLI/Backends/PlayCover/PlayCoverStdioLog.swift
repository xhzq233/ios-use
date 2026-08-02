import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverStdioLogIdentity: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let descriptor: Int32

    init(
        path: String,
        device: UInt64,
        inode: UInt64,
        descriptor: Int32 = -1
    ) {
        self.path = path
        self.device = device
        self.inode = inode
        self.descriptor = descriptor
    }
}

enum PlayCoverStdioLogService {
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
        try ensureOwnerOnlyLogDirectory(paths.playcoverLogs)
        let directoryDescriptor = Darwin.open(
            paths.playcoverLogs,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw logError(
                "cannot open the Home-local Mac log directory",
                errorNumber: errno
            )
        }
        defer { Darwin.close(directoryDescriptor) }
        var parentStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              Darwin.fchmod(directoryDescriptor, 0o700) == 0,
              Darwin.fstat(directoryDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & 0o7777 == 0o700 else {
            throw PlayCoverBackendError.stdioLogFailed(
                "the Home-local Mac log directory is not owner-only"
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
            if removeCreatedFile {
                Darwin.close(descriptor)
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
            inode: UInt64(descriptorStatus.st_ino),
            descriptor: descriptor
        )
        #else
        throw PlayCoverBackendError.stdioLogFailed(
            "Mac stdio logs are supported only on macOS"
        )
        #endif
    }

    private static func ensureOwnerOnlyLogDirectory(
        _ path: String
    ) throws {
        let components = URL(
            fileURLWithPath: path,
            isDirectory: true
        ).standardizedFileURL.pathComponents
        guard components.first == "/" else {
            throw PlayCoverBackendError.stdioLogFailed(
                "the Home-local Mac log directory path is invalid"
            )
        }
        var current = "/"
        for component in components.dropFirst() {
            current = current == "/"
                ? "/\(component)"
                : "\(current)/\(component)"
            var status = stat()
            if Darwin.lstat(current, &status) == 0 {
                // macOS exposes /tmp as the system /private/tmp symlink. It
                // is an account-independent platform alias, not a Home
                // component that this service may redirect.
                if (current == "/tmp" || current == "/var")
                        && status.st_mode & S_IFMT == S_IFLNK {
                    guard let canonical = current
                            .withCString({
                                Darwin.realpath($0, nil)
                            }) else {
                        throw PlayCoverBackendError.stdioLogFailed(
                            "the Home-local Mac log directory system "
                                + "prefix cannot be resolved"
                        )
                    }
                    defer { Darwin.free(canonical) }
                    current = String(cString: canonical)
                    continue
                }
                guard status.st_mode & S_IFMT == S_IFDIR else {
                    throw PlayCoverBackendError.stdioLogFailed(
                        "the Home-local Mac log directory contains "
                            + "a non-directory component"
                    )
                }
                continue
            }
            guard errno == ENOENT else {
                throw logError(
                    "cannot inspect the Home-local Mac log directory",
                    errorNumber: errno
                )
            }
            guard Darwin.mkdir(current, 0o700) == 0
                    || errno == EEXIST else {
                throw logError(
                    "cannot create the Home-local Mac log directory",
                    errorNumber: errno
                )
            }
        }
        var finalStatus = stat()
        guard Darwin.lstat(path, &finalStatus) == 0,
              finalStatus.st_mode & S_IFMT == S_IFDIR,
              finalStatus.st_uid == geteuid(),
              Darwin.chmod(path, 0o700) == 0 else {
            throw PlayCoverBackendError.stdioLogFailed(
                "the Home-local Mac log directory is not owner-only"
            )
        }
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
                canonicalExistingPath(
                    paths.playcoverLogs
                ) else {
            throw invalidSessionLog()
        }
        let expected =
            "\(canonicalPlayCover)/stdio-"
                + "\(sessionUUID.uuidString.lowercased()).log"
        guard path == expected else {
            throw invalidSessionLog()
        }
        #else
        throw invalidSessionLog()
        #endif
    }

    /// Pass the already-open Home-local log descriptor to the injected
    /// Runtime. The Runtime receives a capability with SCM_RIGHTS and never
    /// reopens the path from its environment.
    static func sendBootstrap(
        _ identity: PlayCoverStdioLogIdentity,
        sessionID: String,
        runtimeSocketPath: String,
        expectedPID: Int32,
        expectedExecutablePath: String,
        deadline: TimeInterval
    ) throws {
        #if canImport(Darwin)
        guard identity.descriptor >= 0 else {
            throw PlayCoverBackendError.stdioLogFailed(
                "Mac stdio log descriptor is not available"
            )
        }
        guard deadline.isFinite else {
            throw PlayCoverBackendError.stdioLogFailed(
                "Mac stdio bootstrap deadline is invalid"
            )
        }
        guard expectedPID > 0,
              !expectedExecutablePath.isEmpty else {
            throw PlayCoverBackendError.stdioLogFailed(
                "Mac stdio bootstrap Runtime identity is incomplete"
            )
        }
        let payloadObject: [String: Any] = [
            "sessionID": sessionID,
            "path": identity.path,
            "device": identity.device,
            "inode": identity.inode,
        ]
        let payload = try JSONSerialization.data(
            withJSONObject: payloadObject,
            options: [.sortedKeys]
        )
        guard !payload.isEmpty, payload.count <= 4096 else {
            throw PlayCoverBackendError.stdioLogFailed(
                "Mac stdio bootstrap metadata is too large"
            )
        }
        let pathBytes = Array(runtimeSocketPath.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !pathBytes.contains(0), pathBytes.count + 1 <= capacity else {
            throw PlayCoverBackendError.stdioLogFailed(
                "Runtime socket path is invalid for stdio bootstrap"
            )
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        var lastError = ENOENT
        while ProcessInfo.processInfo.systemUptime < deadline {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                lastError = errno
                break
            }
            _ = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var noSignal: Int32 = 1
            _ = Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )
            var mutableAddress = address
            let connectResult = withUnsafePointer(to: &mutableAddress) {
                pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            if connectResult != 0 {
                lastError = errno
                Darwin.close(descriptor)
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            // The socket path is a capability, not the authentication
            // boundary by itself.  A same-UID process must not be able to
            // consume the log descriptor before the launched Runtime does.
            var peerPID: pid_t = 0
            var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
            guard Darwin.getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEERPID,
                &peerPID,
                &peerPIDSize
            ) == 0,
            peerPID == expectedPID,
            let peerExecutablePath = PlayCoverRuntimeClient
                .executablePath(for: peerPID),
            PlayCoverRuntimeClient.canonicalPath(peerExecutablePath)
                == PlayCoverRuntimeClient.canonicalPath(
                    expectedExecutablePath
                ) else {
                lastError = EPERM
                Darwin.close(descriptor)
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            var control = [UInt8](
                repeating: 0,
                count: alignedControlSize(
                    MemoryLayout<cmsghdr>.size
                ) + MemoryLayout<Int32>.size
            )
            var vector = iovec()
            let sent = payload.withUnsafeBytes { payloadBytes in
                control.withUnsafeMutableBytes { controlBytes in
                    let header = controlBytes
                        .bindMemory(to: cmsghdr.self)
                        .baseAddress!
                    let dataOffset = alignedControlSize(
                        MemoryLayout<cmsghdr>.size
                    )
                    header.pointee.cmsg_len = socklen_t(
                        dataOffset + MemoryLayout<Int32>.size
                    )
                    header.pointee.cmsg_level = SOL_SOCKET
                    header.pointee.cmsg_type = SCM_RIGHTS
                    controlBytes.storeBytes(
                        of: identity.descriptor,
                        toByteOffset: dataOffset,
                        as: Int32.self
                    )
                    vector.iov_base = UnsafeMutableRawPointer(
                        mutating: payloadBytes.baseAddress
                    )
                    vector.iov_len = payloadBytes.count
                    var message = msghdr()
                    return withUnsafeMutablePointer(to: &vector) {
                        vectorPointer in
                        message.msg_iov = vectorPointer
                        message.msg_iovlen = 1
                        message.msg_control = controlBytes.baseAddress
                        message.msg_controllen = socklen_t(
                            controlBytes.count
                        )
                        return Darwin.sendmsg(descriptor, &message, 0)
                    }
                }
            }
            if sent == payload.count {
                Darwin.close(descriptor)
                return
            }
            lastError = sent < 0 ? errno : EIO
            Darwin.close(descriptor)
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw PlayCoverBackendError.stdioLogFailed(
            "Runtime did not accept the stdio descriptor: errno \(lastError)"
        )
        #else
        throw PlayCoverBackendError.stdioLogFailed(
            "Mac stdio bootstrap is supported only on macOS"
        )
        #endif
    }

    #if canImport(Darwin)
    private static func alignedControlSize(_ size: Int) -> Int {
        (size + 3) & ~3
    }

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
                + "match this session's Runtime namespace."
        )
    }
}
