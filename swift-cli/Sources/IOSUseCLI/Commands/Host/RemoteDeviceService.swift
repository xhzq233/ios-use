import Foundation

enum RemoteDeviceService {
    static func start(connectionPath: String, paths: IOSUsePaths, verbose: Bool) throws -> String {
        let connection = try RemoteDeviceConnection.load(path: connectionPath)
        return try RemoteDeviceConnection.$current.withValue(connection) {
            try SessionOperationLock.withExclusiveLock(paths: paths) {
                guard try DriverSessionStore.readInfo(paths: paths) == nil else {
                    throw CLIParseError.invalidValue("Device already has an active session")
                }
                let homePaths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": paths.root])
                if let existing = DeviceContextStore.sessions(paths: homePaths).first(where: {
                    DeviceContextStore.sameUDID($0.info.udid, connection.udid)
                }) {
                    throw CLIParseError.invalidValue("Device \(connection.udid) is already running as \(existing.deviceID). Stop that session before starting another alias.")
                }
                let metadata = try DriverLifecycleService.launchRealDriverHolder(
                    udid: connection.udid, bundleId: connection.driverBundleID, paths: paths, verbose: verbose
                )
                let info = SessionService.Info(
                    udid: connection.udid, deviceName: "Remote iPhone", deviceVersion: "", deviceType: "real",
                    driverHost: connection.driver.host, driverPort: connection.driver.port,
                    remoteConnection: connection, holderPid: metadata.holderPid, runnerPid: metadata.runnerPid,
                    startMode: "remote", sessionIdentifier: metadata.sessionIdentifier,
                    bundleId: connection.driverBundleID, controlSocketPath: metadata.controlSocketPath
                )
                do {
                    let client = DriverClient(session: info, paths: paths, socketTimeoutSeconds: 15)
                    defer { client.close() }
                    _ = try client.dom(raw: false, fresh: true)
                    try DriverSessionStore.write(info: info, paths: paths)
                    return "Started remote XCTest Driver for Device \(paths.deviceID ?? connection.udid)\n"
                } catch {
                    _ = DriverLifecycleService.terminateFullXCTestHolderIfNeeded(info: info, paths: paths)
                    throw error
                }
            }
        }
    }

    struct Health {
        let status: String
        let error: String?

        var machineFields: [String: MachineValue] {
            ["status": .string(status), "error": error.map(MachineValue.string) ?? .null]
        }
    }

    static func health(info: SessionService.Info) -> Health {
        guard let pid = info.holderPid.flatMap(Int32.init(exactly:)),
              pid > 0, DriverLifecycleService.processAlive(pid: pid) else {
            return Health(status: "stale", error: "XCTest holder is no longer running. Stop this session, then start it again.")
        }
        guard let socket = info.controlSocketPath, let connection = info.remoteConnection else {
            return Health(status: "unhealthy", error: "Remote session has no holder control connection")
        }
        do {
            let holder = try XCTestSessionHolderControlClient.request(socketPath: socket, command: "status", timeoutSeconds: 1)
            guard holder.holderPid == info.holderPid,
                  holder.sessionIdentifier == info.sessionIdentifier,
                  holder.runnerPid == info.runnerPid,
                  holder.status == "ready" else {
                return Health(status: "unhealthy", error: "XCTest holder is not ready for the recorded session (\(holder.status))")
            }
            let fd = try TCPConnector.connect(host: connection.driver.host, port: connection.driver.port, timeoutSeconds: 1)
            _ = posixClose(fd)
            return Health(status: "healthy", error: nil)
        } catch {
            return Health(status: "unhealthy", error: String(describing: error))
        }
    }

    static func stop(info: SessionService.Info, paths: IOSUsePaths) throws -> String {
        try SessionOperationLock.withExclusiveLock(paths: paths) {
            if let capture = AppLogCaptureService.readState(paths: paths)?.lastCapture,
               capture.udid == info.udid {
                try AppLogCaptureService.stopCaptureForInstall(bundleID: capture.bundleID, udid: info.udid, paths: paths)
            }
            let result = DriverLifecycleService.terminateFullXCTestHolderIfNeeded(info: info, paths: paths)
            if let message = DriverLifecycleService.holderTerminationFailureMessage(result: result, info: info) {
                throw CLIParseError.invalidValue(message)
            }
            try DriverSessionStore.removeDriverLock(paths: paths)
            return "Stopped remote XCTest Driver; provider connection remains available\n"
        }
    }
}
