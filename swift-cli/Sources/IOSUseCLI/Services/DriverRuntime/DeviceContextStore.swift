import Foundation

enum DeviceContextStore {
    struct Context: Sendable {
        let deviceID: String
        let paths: IOSUsePaths
        let info: SessionService.Info
        let legacy: Bool
    }

    static let macDeviceID = "mac"
    static var startHint: String {
        #if os(Linux)
        return "Run `ios-use start --connection <file>` first."
        #else
        return "Run `ios-use start` first."
        #endif
    }

    static func realDeviceID(_ udid: String) -> String {
        udid
    }

    static func simulatorDeviceID(_ udid: String) -> String {
        udid
    }

    static func deviceID(for info: SessionService.Info) -> String {
        switch info.deviceType {
        case macDeviceID:
            return macDeviceID
        case "simulator":
            return simulatorDeviceID(info.udid)
        default:
            return realDeviceID(info.udid)
        }
    }

    static func targetUDID(from deviceID: String) -> String? {
        return deviceID == macDeviceID ? nil : deviceID
    }

    static func normalizeExplicitDeviceID(
        _ value: String,
        paths: IOSUsePaths
    ) throws -> String {
        try validateDeviceID(value)
    }

    static func validateDeviceID(_ value: String) throws -> String {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || "-._".unicodeScalars.contains(scalar)
              }) else {
            throw CLIParseError.invalidValue(
                "Invalid Device ID \(value)."
            )
        }
        if value == macDeviceID {
            return value
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
        if let explicitDeviceID {
            let normalized = try normalizeExplicitDeviceID(
                explicitDeviceID,
                paths: paths
            )
            if let info = try? DriverSessionStore.readInfo(paths: paths),
               deviceID(for: info) == normalized {
                return Context(
                    deviceID: normalized,
                    paths: paths,
                    info: info,
                    legacy: true
                )
            }

            let contextPaths = try paths.deviceContext(normalized)
            let directory = URL(fileURLWithPath: contextPaths.driverLock)
                .deletingLastPathComponent()
            // Preserve exact Device ID selection on case-insensitive volumes,
            // including aliases whose directory name differs from their UDID.
            guard let name = try? directory.resourceValues(
                forKeys: [.nameKey]
            ).name,
                  name == normalized,
                  let info = try? DriverSessionStore.readInfo(
                    paths: contextPaths
                  ) else {
                throw CLIParseError.invalidValue(
                    "No active driver for Device \(normalized). \(startHint)"
                )
            }
            return Context(
                deviceID: normalized,
                paths: contextPaths,
                info: info,
                legacy: false
            )
        }
        let active = sessions(paths: paths)
        if let impliedUDID,
           let context = active.first(where: {
               $0.info.udid == impliedUDID
           }) {
            return context
        }
        guard active.count == 1 else {
            if active.isEmpty {
                throw CLIParseError.invalidValue(
                    "No active driver. \(startHint)"
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
