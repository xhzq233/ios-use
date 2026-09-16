import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum DriverSessionStore {
    static let maximumDriverLockBytes = 1_048_576

    static func clear(paths: IOSUsePaths) {
        clearDriverLock(paths: paths)
    }

    static func readDriverLock(paths: IOSUsePaths) -> String? {
        try? readInfo(paths: paths)?.udid
    }

    static func readInfo(paths: IOSUsePaths) throws -> SessionService.Info? {
        guard let data = try readPrivateDriverLock(
            at: paths.driverLock
        ) else {
            return nil
        }
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIParseError.invalidValue("Invalid driver.lock: expected JSON object.")
        }
        guard let udid = raw["udid"] as? String, !udid.isEmpty,
              let deviceType = raw["deviceType"] as? String, !deviceType.isEmpty else {
            throw CLIParseError.invalidValue("Invalid driver.lock: missing udid/deviceType.")
        }
        guard deviceType == "real"
                || deviceType == "simulator"
                || deviceType == TCPAttachService.deviceType
                || deviceType == DeviceContextStore.macDeviceID else {
            throw CLIParseError.invalidValue("Invalid driver.lock: unknown deviceType \(deviceType).")
        }
        guard let startedAt = raw["startedAt"] as? Int else {
            throw CLIParseError.invalidValue("Invalid driver.lock: missing startedAt.")
        }
        let info = SessionService.Info(
            udid: udid,
            deviceName: raw["deviceName"] as? String ?? "",
            deviceVersion: raw["deviceVersion"] as? String ?? "",
            deviceType: deviceType,
            driverHost: raw["driverHost"] as? String,
            driverPort: raw["driverPort"] as? Int,
            remoteConnection: try RemoteDeviceConnection.decode(raw["remoteConnection"]),
            startedAt: startedAt,
            holderPid: raw["holderPid"] as? Int,
            runnerPid: raw["runnerPid"] as? Int,
            startMode: raw["startMode"] as? String,
            sessionIdentifier: raw["sessionIdentifier"] as? String,
            bundleId: raw["bundleId"] as? String,
            controlSocketPath: raw["controlSocketPath"] as? String,
            macAppPath: raw["macAppPath"] as? String,
            macExecutablePath:
                raw["macExecutablePath"] as? String,
            macInstallRevision:
                raw["macInstallRevision"] as? String,
            macRuntimeSocketPath:
                raw["macRuntimeSocketPath"] as? String,
            macLogPath:
                raw["macLogPath"] as? String,
            macDevicePreset: raw["macDevicePreset"] as? String
        )
        if info.isAttached {
            guard let host = info.driverHost, let port = info.driverPort else {
                throw CLIParseError.invalidValue("Invalid driver.lock: missing TCP endpoint.")
            }
            try TCPAttachService.validateEndpoint(host: host, port: port)
        }
#if os(macOS)
        if deviceType == DeviceContextStore.macDeviceID {
            guard let appPath = info.macAppPath, !appPath.isEmpty,
                  let executablePath = info.macExecutablePath,
                  !executablePath.isEmpty,
                  let installRevision = info.macInstallRevision,
                  !installRevision.isEmpty,
                  let bundleId = info.bundleId, !bundleId.isEmpty,
                  let sessionID = info.sessionIdentifier,
                  !sessionID.isEmpty,
                  let runtimeSocket = info.macRuntimeSocketPath,
                  !runtimeSocket.isEmpty,
                  let runnerPid = info.runnerPid, runnerPid > 0 else {
                throw CLIParseError.invalidValue(
                    "Invalid driver.lock: incomplete Mac session."
                )
            }
            let expectedSocket: String
            do {
                expectedSocket = try paths.macRuntimeSocketPath(
                    sessionID: sessionID
                )
            } catch {
                throw CLIParseError.invalidValue(
                    "Invalid driver.lock: Mac sessionID cannot "
                        + "derive its Runtime socket."
                )
            }
            guard canonicalPath(runtimeSocket)
                    == canonicalPath(expectedSocket) else {
                throw CLIParseError.invalidValue(
                    "Invalid driver.lock: Mac Runtime socket does "
                        + "not match its sessionID."
                )
            }
            if let logPath = info.macLogPath {
                try PlayCoverStdioLogService.validateSessionPath(
                    logPath,
                    sessionID: sessionID,
                    paths: paths
                )
            }
            guard let slot = try? PlayCoverSlotService.read(
                    bundleIdentifier: bundleId,
                    paths: paths,
                    expectedInstallRevision: installRevision
                  ),
                  canonicalPath(slot.appPath) == canonicalPath(appPath),
                  canonicalPath(slot.executablePath)
                    == canonicalPath(executablePath) else {
                throw CLIParseError.invalidValue(
                    "Invalid driver.lock: Mac App does not match the "
                        + "recorded Bundle slot."
                )
            }
            guard canonicalPath(executablePath).hasPrefix(
                canonicalPath(appPath) + "/"
            ) else {
                throw CLIParseError.invalidValue(
                    "Invalid driver.lock: Mac executable is outside "
                        + "the managed App."
                )
            }
            try validateOwnedRunDirectory(paths.playcoverRun)
        }
#endif
        return info
    }

    private static func readPrivateDriverLock(
        at path: String
    ) throws -> Data? {
        #if os(macOS) || os(Linux)
        let descriptor = open(
            path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return nil
            }
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: cannot open private state without "
                    + "following links (errno \(errno))."
            )
        }
        defer { close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              isSafeDriverLock(initial) else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: expected an owner-only bounded "
                    + "regular file."
            )
        }

        var data = Data(count: Int(initial.st_size))
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let count = read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw CLIParseError.invalidValue(
                    "Invalid driver.lock: could not read private state "
                        + "completely."
                )
            }
        }

        var finalDescriptor = stat()
        var finalPath = stat()
        guard fstat(descriptor, &finalDescriptor) == 0,
              lstat(path, &finalPath) == 0,
              isSafeDriverLock(finalDescriptor),
              isSafeDriverLock(finalPath),
              sameDriverLockIdentity(initial, finalDescriptor),
              sameDriverLockIdentity(initial, finalPath) else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: private state changed while it "
                    + "was read."
            )
        }
        return data
        #else
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let handle = try FileHandle(
            forReadingFrom: URL(fileURLWithPath: path)
        )
        defer { try? handle.close() }
        let data = try handle.read(
            upToCount: maximumDriverLockBytes + 1
        ) ?? Data()
        guard data.count <= maximumDriverLockBytes else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: expected a bounded regular file."
            )
        }
        return data
        #endif
    }

    #if os(macOS) || os(Linux)
    private static func isSafeDriverLock(_ status: stat) -> Bool {
        (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && (status.st_mode & 0o077) == 0
            && status.st_size >= 0
            && status.st_size <= Int64(maximumDriverLockBytes)
    }

    private static func sameDriverLockIdentity(
        _ expected: stat,
        _ actual: stat
    ) -> Bool {
        #if os(Linux)
        let modified = (actual.st_mtim.tv_sec, actual.st_mtim.tv_nsec)
        let expectedModified = (expected.st_mtim.tv_sec, expected.st_mtim.tv_nsec)
        let changed = (actual.st_ctim.tv_sec, actual.st_ctim.tv_nsec)
        let expectedChanged = (expected.st_ctim.tv_sec, expected.st_ctim.tv_nsec)
        #else
        let modified = (actual.st_mtimespec.tv_sec, actual.st_mtimespec.tv_nsec)
        let expectedModified = (expected.st_mtimespec.tv_sec, expected.st_mtimespec.tv_nsec)
        let changed = (actual.st_ctimespec.tv_sec, actual.st_ctimespec.tv_nsec)
        let expectedChanged = (expected.st_ctimespec.tv_sec, expected.st_ctimespec.tv_nsec)
        #endif
        return actual.st_dev == expected.st_dev
            && actual.st_ino == expected.st_ino
            && actual.st_mode == expected.st_mode
            && actual.st_uid == expected.st_uid
            && actual.st_gid == expected.st_gid
            && actual.st_nlink == expected.st_nlink
            && actual.st_size == expected.st_size
            && modified == expectedModified && changed == expectedChanged
    }
    #endif

    static func requireInfo(paths: IOSUsePaths) throws -> SessionService.Info {
        guard let info = try readInfo(paths: paths) else {
            throw CLIParseError.invalidValue("No active driver. Run `ios-use start` first.")
        }
        return info
    }

    static func write(info: SessionService.Info, paths: IOSUsePaths) throws {
        var root: [String: Any] = [
            "udid": info.udid,
            "deviceName": info.deviceName,
            "deviceVersion": info.deviceVersion,
            "deviceType": info.deviceType,
            "startedAt": info.startedAt,
        ]
        if let host = info.driverHost { root["driverHost"] = host }
        if let port = info.driverPort { root["driverPort"] = port }
        if let holderPid = info.holderPid {
            root["holderPid"] = holderPid
        }
        if let runnerPid = info.runnerPid {
            root["runnerPid"] = runnerPid
        }
        if info.deviceType == DeviceContextStore.macDeviceID,
           let startMode = info.startMode {
            root["startMode"] = startMode
        }
        if let sessionIdentifier = info.sessionIdentifier {
            root["sessionIdentifier"] = sessionIdentifier
        }
        if let bundleId = info.bundleId {
            root["bundleId"] = bundleId
        }
        if let controlSocketPath = info.controlSocketPath {
            root["controlSocketPath"] = controlSocketPath
        }
        if let macAppPath = info.macAppPath {
            root["macAppPath"] = macAppPath
        }
        if let executablePath = info.macExecutablePath {
            root["macExecutablePath"] = executablePath
        }
        if let installRevision = info.macInstallRevision {
            root["macInstallRevision"] = installRevision
        }
        if let socketPath = info.macRuntimeSocketPath {
            root["macRuntimeSocketPath"] = socketPath
        }
        if let logPath = info.macLogPath {
            root["macLogPath"] = logPath
        }
        if let preset = info.macDevicePreset { root["macDevicePreset"] = preset }
        if let connection = info.remoteConnection {
            root["remoteConnection"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection))
        }
        let lockDir = URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writePrivateAtomically(data, to: paths.driverLock)
    }

    static func clearDriverLock(paths: IOSUsePaths) {
        try? removeDriverLock(paths: paths)
    }

    static func removeDriverLock(paths: IOSUsePaths) throws {
        #if os(macOS) || os(Linux)
        var status = stat()
        guard lstat(paths.driverLock, &status) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return
            }
            throw CLIParseError.invalidValue(
                "Cannot inspect driver.lock before removal: errno \(errno)."
            )
        }
        guard isSafeDriverLock(status) else {
            throw CLIParseError.invalidValue(
                "Refusing to remove driver.lock because it is not an "
                    + "owner-only singly-linked regular file."
            )
        }
        guard unlink(paths.driverLock) == 0 else {
            if errno == ENOENT {
                return
            }
            throw CLIParseError.invalidValue(
                "Cannot remove driver.lock: errno \(errno)."
            )
        }
        try syncParentDirectory(
            of: paths.driverLock,
            label: "driver.lock"
        )
        #else
        do {
            try FileManager.default.removeItem(atPath: paths.driverLock)
        } catch {
            if !FileManager.default.fileExists(atPath: paths.driverLock) {
                return
            }
            throw error
        }
        #endif
    }

    private static func writePrivateAtomically(
        _ data: Data,
        to path: String
    ) throws {
        #if os(macOS) || os(Linux)
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard isSafeDriverLock(existing) else {
                throw CLIParseError.invalidValue(
                    "Refusing to replace driver.lock because it is not an "
                        + "owner-only singly-linked regular file."
                )
            }
        } else if errno != ENOENT {
            throw CLIParseError.invalidValue(
                "Cannot inspect driver.lock before writing: errno \(errno)."
            )
        }
        let destination = URL(fileURLWithPath: path)
        let temporaryPath = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".driver-lock-\(UUID().uuidString).tmp"
            )
            .path
        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CLIParseError.invalidValue(
                "Cannot create private driver.lock: errno \(errno)."
            )
        }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary {
                unlink(temporaryPath)
            }
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let written = posixWrite(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                throw CLIParseError.invalidValue(
                    "Cannot write private driver.lock: errno \(errno)."
                )
            }
        }
        guard fchmod(descriptor, 0o600) == 0,
              fsync(descriptor) == 0 else {
            throw CLIParseError.invalidValue(
                "Cannot secure private driver.lock: errno \(errno)."
            )
        }
        guard rename(temporaryPath, path) == 0 else {
            throw CLIParseError.invalidValue(
                "Cannot install private driver.lock: errno \(errno)."
            )
        }
        removeTemporary = false
        try syncParentDirectory(of: path, label: "driver.lock")
        #else
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
        #endif
    }

    #if os(macOS) || os(Linux)
    private static func syncParentDirectory(
        of path: String,
        label: String
    ) throws {
        let parent = URL(fileURLWithPath: path)
            .deletingLastPathComponent().path
        let descriptor = open(
            parent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw CLIParseError.invalidValue(
                "Cannot open \(label) parent for fsync: errno \(errno)."
            )
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT))
                == mode_t(S_IFDIR),
              status.st_uid == geteuid(),
              fsync(descriptor) == 0 else {
            throw CLIParseError.invalidValue(
                "Cannot fsync \(label) parent: errno \(errno)."
            )
        }
    }
    #endif

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func validateOwnedRunDirectory(
        _ path: String
    ) throws {
        #if os(macOS) || os(Linux)
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT))
                == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: Mac Runtime directory is "
                    + "not an owner-only directory."
            )
        }
        #endif
    }
}
