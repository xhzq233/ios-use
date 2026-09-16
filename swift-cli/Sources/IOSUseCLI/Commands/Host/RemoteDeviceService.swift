import Foundation

enum RemoteDeviceService {
    static func start(connectionPath: String, paths: IOSUsePaths, verbose: Bool) throws -> String {
        let connection = try RemoteDeviceConnection.load(path: connectionPath)
        return try RemoteDeviceConnection.$current.withValue(connection) {
            try SessionOperationLock.withExclusiveLock(paths: paths) {
                guard try DriverSessionStore.readInfo(paths: paths) == nil else {
                    throw CLIParseError.invalidValue("Device already has an active session")
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
