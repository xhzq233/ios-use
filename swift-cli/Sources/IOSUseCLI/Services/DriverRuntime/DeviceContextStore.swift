import Foundation

enum DeviceContextStore {
    struct Context: Sendable {
        let deviceID: String
        let paths: IOSUsePaths
        let info: SessionService.Info
        let legacy: Bool
    }

    static let macDeviceID = "mac"

    static func realDeviceID(_ udid: String) -> String {
        "real:\(udid)"
    }

    static func simulatorDeviceID(_ udid: String) -> String {
        "simulator:\(udid)"
    }

    static func deviceID(for info: SessionService.Info) -> String {
        switch info.deviceType {
        case PlayCoverSessionService.deviceType:
            return macDeviceID
        case "simulator":
            return simulatorDeviceID(info.udid)
        default:
            return realDeviceID(info.udid)
        }
    }

    static func targetUDID(from deviceID: String) -> String? {
        if deviceID.hasPrefix("real:") {
            return String(deviceID.dropFirst("real:".count))
        }
        if deviceID.hasPrefix("simulator:") {
            return String(deviceID.dropFirst("simulator:".count))
        }
        return nil
    }

    static func normalizeExplicitDeviceID(
        _ value: String,
        paths: IOSUsePaths
    ) throws -> String {
        if value == macDeviceID
            || value.hasPrefix("real:")
            || value.hasPrefix("simulator:") {
            return try validateDeviceID(value)
        }
        if let matching = sessions(paths: paths).first(where: {
            $0.info.udid == value
        }) {
            return matching.deviceID
        }
        return try validateDeviceID(realDeviceID(value))
    }

    static func validateDeviceID(_ value: String) throws -> String {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || "-._:".unicodeScalars.contains(scalar)
              }) else {
            throw CLIParseError.invalidValue(
                "Invalid Device ID \(value)."
            )
        }
        if value == macDeviceID {
            return value
        }
        let acceptedPrefixes = ["real:", "simulator:"]
        guard let prefix = acceptedPrefixes.first(where: {
            value.hasPrefix($0)
        }), value.count > prefix.count else {
            throw CLIParseError.invalidValue(
                "Device ID must be mac, real:<udid>, or simulator:<udid>."
            )
        }
        return value
    }

    static func sessions(paths: IOSUsePaths) -> [Context] {
        var result: [Context] = []
        if let info = try? DriverSessionStore.readInfo(paths: paths) {
            result.append(
                Context(
                    deviceID: deviceID(for: info),
                    paths: paths,
                    info: info,
                    legacy: true
                )
            )
        }

        let root = "\(paths.root)/state/devices"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: root
        ) else {
            return result
        }
        for entry in entries.sorted() {
            guard let deviceID = try? validateDeviceID(entry),
                  let contextPaths = try? paths.deviceContext(deviceID),
                  let info = try? DriverSessionStore.readInfo(
                      paths: contextPaths
                  ) else {
                continue
            }
            if result.contains(where: { $0.deviceID == deviceID }) {
                continue
            }
            result.append(
                Context(
                    deviceID: deviceID,
                    paths: contextPaths,
                    info: info,
                    legacy: false
                )
            )
        }
        return result
    }

    static func activeContext(
        explicitDeviceID: String?,
        impliedUDID: String? = nil,
        paths: IOSUsePaths
    ) throws -> Context {
        let active = sessions(paths: paths)
        if let explicitDeviceID {
            let normalized = try normalizeExplicitDeviceID(
                explicitDeviceID,
                paths: paths
            )
            guard let context = active.first(where: {
                $0.deviceID == normalized
            }) else {
                throw CLIParseError.invalidValue(
                    "No active driver for Device \(normalized). Run `ios-use start` first."
                )
            }
            return context
        }
        if let impliedUDID,
           let context = active.first(where: {
               $0.info.udid == impliedUDID
           }) {
            return context
        }
        guard active.count == 1 else {
            if active.isEmpty {
                throw CLIParseError.invalidValue(
                    "No active driver. Run `ios-use start` first."
                )
            }
            throw CLIParseError.invalidValue(
                "Multiple active Devices. Pass --device <device-id>."
            )
        }
        return active[0]
    }

    static func requireInactive(
        deviceID: String,
        paths: IOSUsePaths
    ) throws {
        if sessions(paths: paths).contains(where: {
            $0.deviceID == deviceID
        }) {
            throw CLIParseError.invalidValue(
                "Driver already started for Device \(deviceID)."
            )
        }
    }
}
