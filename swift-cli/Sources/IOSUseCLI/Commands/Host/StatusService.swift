import Foundation

public enum StatusService {
    static func machineSnapshot(paths: IOSUsePaths) -> (data: MachineValue, warnings: [String]) {
        let configured = DeviceService.configuredDevices(paths: paths)
        var warnings: [String] = []
        let devices: [IOSDevice]
        do {
            devices = try DeviceService.listDevices(simulatorOnly: false, paths: paths)
        } catch {
            devices = []
            warnings.append("connected device lookup failed: \(error)")
        }

        let deviceValues = devices.map { device -> MachineValue in
            let config = configured[device.udid]
            var value: [String: MachineValue] = [
                "name": .string(device.name),
                "version": .string(device.version),
                "udid": .string(device.udid),
                "kind": .string(device.kind.rawValue),
                "configured": .boolean(config != nil),
                "driverUpdateRequired": .boolean(config?.needsDriverUpdate ?? false),
            ]
            if let metadata = device.metadata {
                value["metadata"] = .object([
                    "productType": metadata.productType.map(MachineValue.string) ?? .null,
                    "productName": metadata.productName.map(MachineValue.string) ?? .null,
                    "buildVersion": metadata.buildVersion.map(MachineValue.string) ?? .null,
                    "batteryCurrentCapacity": metadata.batteryCurrentCapacity.map(MachineValue.integer) ?? .null,
                    "status": metadata.status.map(MachineValue.string) ?? .null,
                    "detail": metadata.detail.map(MachineValue.string) ?? .null,
                ])
            }
            return .object(value)
        }

        let driver: MachineValue
        do {
            if let info = try SessionService.readDriverLockInfo(paths: paths) {
                let config = configured[info.udid]
                driver = .object([
                    "status": .string("running"),
                    "udid": .string(info.udid),
                    "deviceName": .string(info.deviceName),
                    "deviceVersion": .string(info.deviceVersion),
                    "deviceType": .string(info.deviceType),
                    "startedAt": .integer(info.startedAt),
                    "holderPid": info.holderPid.map(MachineValue.integer) ?? .null,
                    "runnerPid": info.runnerPid.map(MachineValue.integer) ?? .null,
                    "startMode": info.startMode.map(MachineValue.string) ?? .null,
                    "sessionIdentifier": info.sessionIdentifier.map(MachineValue.string) ?? .null,
                    "bundleId": info.bundleId.map(MachineValue.string) ?? .null,
                    "driverVersion": config.flatMap(\.driverVersion).map(MachineValue.string) ?? .null,
                    "versionMatchesCli": .boolean(config?.driverVersion == IOSUseCLI.version),
                ])
            } else {
                driver = .object(["status": .string("notRunning")])
            }
        } catch {
            driver = .object([
                "status": .string("invalid"),
                "error": .string(String(describing: error)),
            ])
            warnings.append("driver.lock is invalid: \(error)")
        }

        let configValues = ConfigService.listEntries(paths: paths).map { entry in
            MachineValue.object([
                "udid": .string(entry.udid),
                "bundleId": .string(entry.bundleId),
                "driverVersion": .string(entry.driverVersion),
                "versionMatchesCli": .boolean(entry.driverVersion == IOSUseCLI.version),
                "signingExpiresAt": entry.signingExpiresAt.map {
                    .string(ISO8601DateFormatter().string(from: $0))
                } ?? .null,
            ])
        }
        let activeUdid = (try? SessionService.readDriverLockInfo(paths: paths))?.udid
        return (
            .object([
                "cli": .object(["version": .string(IOSUseCLI.version)]),
                "selectedTarget": activeUdid.map(MachineValue.string) ?? .null,
                "connectedDevices": .array(deviceValues),
                "driver": driver,
                "configuredDevices": .array(configValues),
            ]),
            warnings
        )
    }

    public static func status(paths: IOSUsePaths, verbose: Bool = false) throws -> String {
        let configuredDevices = DeviceService.configuredDevices(paths: paths)
        var lines: [String] = []

        lines.append("Connected devices:")
        lines.append(contentsOf: deviceLines(simulatorOnly: false, paths: paths, configuredDevices: configuredDevices, verbose: verbose, emptyMessage: "No connected real devices found."))
        lines.append("")

        lines.append("Driver:")
        lines.append(contentsOf: driverLines(paths: paths))
        lines.append("")

        lines.append("App log:")
        lines.append(contentsOf: appLogLines(paths: paths))
        lines.append("")

        lines.append("NSLog:")
        lines.append(contentsOf: nslogLines(paths: paths))
        lines.append("")

        lines.append("Proxy:")
        lines.append(contentsOf: proxyLines(paths: paths))
        lines.append("")

        lines.append("Config:")
        lines.append(contentsOf: configLines(entries: ConfigService.listEntries(paths: paths)))

        return lines.joined(separator: "\n") + "\n"
    }

    private static func deviceLines(simulatorOnly: Bool, paths: IOSUsePaths, configuredDevices: [String: DeviceService.ConfiguredDevice], verbose: Bool, emptyMessage: String) -> [String] {
        do {
            let devices = try DeviceService.listDevices(simulatorOnly: simulatorOnly, paths: paths)
            guard !devices.isEmpty else { return ["  \(emptyMessage)"] }
            return devices.map { "  - \(DeviceService.format($0, configuredDevices: configuredDevices, verbose: verbose))" }
        } catch {
            return ["  unavailable: \(error)"]
        }
    }

    private static func driverLines(paths: IOSUsePaths) -> [String] {
        do {
            guard let info = try SessionService.readDriverLockInfo(paths: paths) else {
                return ["  not running (no driver.lock)"]
            }
            var parts = ["running", "udid: \(info.udid)", "device: \(info.deviceType)", "name: \(info.deviceName)", "iOS: \(info.deviceVersion)"]
            if let startMode = info.startMode, !startMode.isEmpty {
                parts.append("mode: \(startMode)")
            }
            if let bundleId = info.bundleId, !bundleId.isEmpty {
                parts.append("bundle: \(bundleId)")
            }
            if let holderPid = info.holderPid {
                parts.append("holder pid: \(holderPid)")
            }
            if let runnerPid = info.runnerPid {
                parts.append("runner pid: \(runnerPid)")
            }
            if let sessionIdentifier = info.sessionIdentifier, !sessionIdentifier.isEmpty {
                parts.append("session: \(sessionIdentifier)")
            }
            return ["  - \(parts.joined(separator: " | "))"]
        } catch {
            return ["  invalid driver.lock: \(error)"]
        }
    }

    private static func appLogLines(paths: IOSUsePaths) -> [String] {
        guard let capture = AppLogCaptureService.readState(paths: paths)?.lastCapture else {
            return ["  not running (no app log state)"]
        }
        let status = capture.status == "running" ? "running" : "not running (\(capture.status))"
        var parts = [status, "bundle: \(capture.bundleID)", "udid: \(capture.udid)", "device: \(capture.deviceType)"]
        if let pid = capture.helperPID {
            parts.append("pid: \(pid)")
        }
        parts.append("log: \(capture.logFile)")
        if let lastError = capture.lastError, !lastError.isEmpty {
            parts.append("last error: \(lastError)")
        }
        return ["  - \(parts.joined(separator: " | "))"]
    }

    private static func nslogLines(paths: IOSUsePaths) -> [String] {
        guard let capture = NSLogService.readState(paths: paths)?.lastCapture else {
            return ["  not running (no NSLog state)"]
        }
        let status = capture.status == "running" ? "running" : "not running (\(capture.status))"
        var parts = [status]
        if let name = capture.name, !name.isEmpty {
            parts.append("name: \(name)")
        }
        if let pid = capture.pid {
            parts.append("pid: \(pid)")
        }
        if let port = capture.port {
            parts.append("port: \(port)")
        }
        parts.append("log: \(capture.logFile)")
        return ["  - \(parts.joined(separator: " | "))"]
    }

    private static func proxyLines(paths: IOSUsePaths) -> [String] {
        guard let state = ProxyService.readState(paths: paths) else {
            return ["  not running (no proxy state)"]
        }
        var parts = [state.status, "udid: \(state.udid)"]
        if let serverStatus = state.serverStatus {
            parts.append("server: \(serverStatus)")
        }
        if let deviceProxyStatus = state.deviceProxyStatus {
            parts.append("device proxy: \(deviceProxyStatus)")
        }
        if let caStatus = state.caStatus {
            parts.append("CA: \(caStatus)")
        } else if let caInstalled = state.caInstalled {
            parts.append("CA: \(caInstalled ? "installed" : "not installed")")
        }
        if let network = state.network {
            parts.append("network: \(network.macLanIp) (\(network.interface))")
        }
        if let pid = state.mitmdumpPid {
            parts.append("mitmdump pid: \(pid)")
        }
        if let port = state.mitmdumpPort {
            parts.append("port: \(port)")
        }
        parts.append("capture: \(state.flowFile)")
        if let lastError = state.lastError, !lastError.isEmpty {
            parts.append("last error: \(lastError)")
        }
        return ["  - \(parts.joined(separator: " | "))"]
    }

    private static func configLines(entries: [DeviceConfigEntry]) -> [String] {
        guard !entries.isEmpty else { return ["  no configured devices"] }
        return entries.map { entry in
            var parts = [entry.udid, "bundleId: \(entry.bundleId)", "driverVersion: \(entry.driverVersion)"]
            if entry.driverVersion != IOSUseCLI.version {
                parts.append("driver update required")
            }
            if let signing = ConfigService.signingStatusText(for: entry) {
                parts.append(signing)
            }
            return "  - \(parts.joined(separator: " | "))"
        }
    }
}
