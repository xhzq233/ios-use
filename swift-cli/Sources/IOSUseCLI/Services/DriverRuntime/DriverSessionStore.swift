import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum DriverSessionStore {
    static func clear(paths: IOSUsePaths) {
        clearDriverLock(paths: paths)
    }

    static func readDriverLock(paths: IOSUsePaths) -> String? {
        try? readInfo(paths: paths)?.udid
    }

    static func readInfo(paths: IOSUsePaths) throws -> SessionService.Info? {
        guard FileManager.default.fileExists(atPath: paths.driverLock) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: paths.driverLock))
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIParseError.invalidValue("Invalid driver.lock: expected JSON object.")
        }
        guard let udid = raw["udid"] as? String, !udid.isEmpty,
              let deviceType = raw["deviceType"] as? String, !deviceType.isEmpty else {
            throw CLIParseError.invalidValue("Invalid driver.lock: missing udid/deviceType.")
        }
        guard deviceType == "real"
                || deviceType == "simulator"
                || deviceType == PlayCoverSessionService.deviceType else {
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
            startedAt: startedAt,
            holderPid: raw["holderPid"] as? Int,
            runnerPid: raw["runnerPid"] as? Int,
            startMode: raw["startMode"] as? String,
            sessionIdentifier: raw["sessionIdentifier"] as? String,
            bundleId: raw["bundleId"] as? String,
            controlSocketPath: raw["controlSocketPath"] as? String,
            playCoverAppPath: raw["playcoverAppPath"] as? String,
            profileHash: raw["profileHash"] as? String,
            playCoverRuntimeSocketPath: raw["playcoverRuntimeSocketPath"] as? String,
            playCoverLaunchNonce: raw["playcoverLaunchNonce"] as? String,
            playCoverPreparedGenerationID: raw["playcoverPreparedGenerationID"] as? String,
            playCoverRuntimeInstanceID: raw["playcoverRuntimeInstanceID"] as? String
        )
        if deviceType == PlayCoverSessionService.deviceType {
            guard let appPath = info.playCoverAppPath, !appPath.isEmpty,
                  let bundleId = info.bundleId, !bundleId.isEmpty,
                  let profileHash = info.profileHash, !profileHash.isEmpty,
                  let runnerPid = info.runnerPid, runnerPid > 0 else {
                throw CLIParseError.invalidValue(
                    "Invalid driver.lock: incomplete PlayCover session."
                )
            }
            guard info.playCoverRuntimeSocketPath?.isEmpty == false,
                  info.playCoverLaunchNonce?.isEmpty == false,
                  info.playCoverPreparedGenerationID?.isEmpty == false,
                  info.playCoverRuntimeInstanceID?.isEmpty == false else {
                throw CLIParseError.invalidValue(
                    "Invalid driver.lock: incomplete PlayCover runtime identity."
                )
            }
        }
        return info
    }

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
        if let holderPid = info.holderPid {
            root["holderPid"] = holderPid
        }
        if let runnerPid = info.runnerPid {
            root["runnerPid"] = runnerPid
        }
        if info.deviceType == PlayCoverSessionService.deviceType,
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
        if let playCoverAppPath = info.playCoverAppPath {
            root["playcoverAppPath"] = playCoverAppPath
        }
        if let profileHash = info.profileHash {
            root["profileHash"] = profileHash
        }
        if let socketPath = info.playCoverRuntimeSocketPath {
            root["playcoverRuntimeSocketPath"] = socketPath
        }
        if let launchNonce = info.playCoverLaunchNonce {
            root["playcoverLaunchNonce"] = launchNonce
        }
        if let generationID = info.playCoverPreparedGenerationID {
            root["playcoverPreparedGenerationID"] = generationID
        }
        if let runtimeInstanceID = info.playCoverRuntimeInstanceID {
            root["playcoverRuntimeInstanceID"] = runtimeInstanceID
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
        do {
            try FileManager.default.removeItem(atPath: paths.driverLock)
        } catch {
            if !FileManager.default.fileExists(atPath: paths.driverLock) {
                return
            }
            throw error
        }
    }

    private static func writePrivateAtomically(
        _ data: Data,
        to path: String
    ) throws {
        #if canImport(Darwin)
        var existing = stat()
        if Darwin.lstat(path, &existing) == 0 {
            guard (existing.st_mode & mode_t(S_IFMT))
                    == mode_t(S_IFREG),
                  existing.st_uid == geteuid() else {
                throw CLIParseError.invalidValue(
                    "Refusing to replace driver.lock because it is not an owned regular file."
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
        let descriptor = Darwin.open(
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
            Darwin.close(descriptor)
            if removeTemporary {
                Darwin.unlink(temporaryPath)
            }
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
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
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw CLIParseError.invalidValue(
                "Cannot secure private driver.lock: errno \(errno)."
            )
        }
        guard Darwin.rename(temporaryPath, path) == 0 else {
            throw CLIParseError.invalidValue(
                "Cannot install private driver.lock: errno \(errno)."
            )
        }
        removeTemporary = false
        #else
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
        #endif
    }
}
