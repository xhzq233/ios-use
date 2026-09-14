import Foundation

/// A caller-owned driver endpoint. Attaching never owns the remote runtime.
enum TCPAttachService {
    static let deviceType = "tcp"

    static func validateEndpoint(host: String, port: Int) throws {
        guard !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"), !host.contains("\0") else {
            throw CLIParseError.invalidValue("--host must be an IP address or hostname, without a URL scheme.")
        }
        guard (1...65535).contains(port) else {
            throw CLIParseError.invalidValue("--port must be between 1 and 65535.")
        }
    }

    static func attach(options: AttachOptions, paths: IOSUsePaths) throws -> String {
        try validateEndpoint(host: options.host, port: options.port)
        guard let deviceID = paths.deviceID else {
            throw CLIParseError.missingRequiredOption("--device")
        }
        return try SessionOperationLock.withExclusiveLock(paths: paths) {
            guard try DriverSessionStore.readInfo(paths: paths) == nil else {
                throw CLIParseError.invalidValue("Device \(deviceID) already has an active session.")
            }
            let info = SessionService.Info(
                udid: deviceID,
                deviceName: "TCP driver",
                deviceVersion: "",
                deviceType: deviceType,
                driverHost: options.host,
                driverPort: options.port
            )
            let client = DriverClient(session: info, paths: paths, socketTimeoutSeconds: 10)
            defer { client.close() }
            // Verify the actual protocol before persisting a selectable session.
            _ = try client.dom(raw: false, fresh: false)
            try DriverSessionStore.write(info: info, paths: paths)
            return "Attached Device \(deviceID) to \(options.host):\(options.port)\n"
        }
    }

    static func detach(paths: IOSUsePaths) throws -> String {
        try SessionOperationLock.withExclusiveLock(paths: paths) {
            try detachLocked(info: SessionService.requireDriverLock(paths: paths), paths: paths)
        }
    }

    static func detachLocked(info: SessionService.Info, paths: IOSUsePaths) throws -> String {
        guard info.isAttached else {
            throw CLIParseError.invalidValue("detach requires a TCP attachment. Use stop for a locally managed driver.")
        }
        try DriverSessionStore.removeDriverLock(paths: paths)
        return "Detached Device \(info.udid); external driver remains running\n"
    }
}
