import Foundation

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
        guard deviceType == "real" || deviceType == "simulator" else {
            throw CLIParseError.invalidValue("Invalid driver.lock: unknown deviceType \(deviceType).")
        }
        guard let startedAt = raw["startedAt"] as? Int else {
            throw CLIParseError.invalidValue("Invalid driver.lock: missing startedAt.")
        }
        return SessionService.Info(
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
            controlSocketPath: raw["controlSocketPath"] as? String
        )
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
        if let sessionIdentifier = info.sessionIdentifier {
            root["sessionIdentifier"] = sessionIdentifier
        }
        if let bundleId = info.bundleId {
            root["bundleId"] = bundleId
        }
        if let controlSocketPath = info.controlSocketPath {
            root["controlSocketPath"] = controlSocketPath
        }
        let lockDir = URL(fileURLWithPath: paths.driverLock).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: paths.driverLock), options: .atomic)
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
}
