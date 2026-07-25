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
                var fields: [String: MachineValue] = [
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
                    "playcoverAppPath": info.playCoverAppPath.map(MachineValue.string) ?? .null,
                    "profileHash": info.profileHash.map(MachineValue.string) ?? .null,
                    "driverVersion": config.flatMap(\.driverVersion).map(MachineValue.string) ?? .null,
                    "versionMatchesCli": info.deviceType == PlayCoverSessionService.deviceType
                        ? .null
                        : .boolean(config?.driverVersion == IOSUseCLI.version),
                ]
                if info.deviceType == PlayCoverSessionService.deviceType {
                    switch playCoverRuntimeHealth(info: info, diagnostics: true) {
                    case .success(let payload):
                        fields["runtime"] = playCoverRuntimeMachineValue(payload)
                    case .failure(let error):
                        fields["runtime"] = .object([
                            "status": .string("unreachable"),
                            "identityVerified": .boolean(false),
                            "error": .string(String(describing: error)),
                        ])
                        warnings.append("PlayCover runtime health check failed: \(error)")
                    }
                }
                driver = .object(fields)
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
        lines.append(contentsOf: driverLines(paths: paths, verbose: verbose))
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

    private static func driverLines(
        paths: IOSUsePaths,
        verbose: Bool
    ) -> [String] {
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
            if let appPath = info.playCoverAppPath, !appPath.isEmpty {
                parts.append("app: \(appPath)")
            }
            if let profileHash = info.profileHash, !profileHash.isEmpty {
                parts.append("profile: \(profileHash)")
            }
            if info.deviceType == PlayCoverSessionService.deviceType {
                switch playCoverRuntimeHealth(
                    info: info,
                    diagnostics: verbose
                ) {
                case .success(let payload):
                    parts.append("runtime: reachable")
                    parts.append("runtime instance: \(payload.runtimeInstanceID)")
                    if let socketPath = info.playCoverRuntimeSocketPath {
                        parts.append("socket: \(socketPath)")
                    }
                    if verbose {
                        parts.append(
                            "geometry: \(formatRuntimeNumber(payload.logicalWidth))"
                                + "x\(formatRuntimeNumber(payload.logicalHeight))"
                                + " @\(formatRuntimeNumber(payload.scale))x"
                        )
                        parts.append("runtime stage: \(payload.stage)")
                        parts.append(
                            "capabilities: \(payload.capabilities.joined(separator: ","))"
                        )
                    }
                case .failure(let error):
                    parts.append("runtime: unreachable (\(error))")
                }
            }
            return ["  - \(parts.joined(separator: " | "))"]
        } catch {
            return ["  invalid driver.lock: \(error)"]
        }
    }

    private static func playCoverRuntimeHealth(
        info: SessionService.Info,
        diagnostics: Bool
    ) -> Result<PlayCoverRuntimeResponsePayload, Error> {
        guard let socketPath = info.playCoverRuntimeSocketPath,
              !socketPath.isEmpty,
              let launchNonce = info.playCoverLaunchNonce,
              !launchNonce.isEmpty else {
            return .failure(
                CLIParseError.invalidValue(
                    "Invalid driver.lock: PlayCover runtime socket identity is incomplete."
                )
            )
        }
        do {
            let client = PlayCoverRuntimeClient(
                socketPath: socketPath,
                launchNonce: launchNonce,
                timeoutSeconds: 0.75
            )
            let payload = diagnostics
                ? try client.diagnostics()
                : try client.ping()
            try validatePlayCoverRuntimeIdentity(payload, info: info)
            return .success(payload)
        } catch {
            return .failure(error)
        }
    }

    private static func validatePlayCoverRuntimeIdentity(
        _ payload: PlayCoverRuntimeResponsePayload,
        info: SessionService.Info
    ) throws {
        guard payload.protocolVersion == PlayCoverRuntimeClient.schemaVersion,
              Int(payload.pid) == info.runnerPid,
              payload.bundleIdentifier == info.bundleId,
              payload.profileHash == info.profileHash,
              payload.preparedGenerationID == info.playCoverPreparedGenerationID,
              payload.runtimeSocketPath == info.playCoverRuntimeSocketPath,
              payload.runtimeInstanceID == info.playCoverRuntimeInstanceID else {
            throw CLIParseError.invalidValue(
                "PlayCover runtime identity no longer matches the active session."
            )
        }
    }

    private static func playCoverRuntimeMachineValue(
        _ payload: PlayCoverRuntimeResponsePayload
    ) -> MachineValue {
        var fields: [String: MachineValue] = [
            "status": .string("reachable"),
            "identityVerified": .boolean(true),
            "protocolVersion": .integer(payload.protocolVersion),
            "pid": .integer(Int(payload.pid)),
            "bundleIdentifier": .string(payload.bundleIdentifier),
            "profileHash": .string(payload.profileHash),
            "preparedGenerationID": .string(payload.preparedGenerationID),
            "runtimeSocketPath": .string(payload.runtimeSocketPath),
            "runtimeInstanceID": .string(payload.runtimeInstanceID),
            "capabilities": .array(payload.capabilities.map(MachineValue.string)),
            "logicalWidth": .double(payload.logicalWidth),
            "logicalHeight": .double(payload.logicalHeight),
            "nativeWidth": .double(payload.nativeWidth),
            "nativeHeight": .double(payload.nativeHeight),
            "scale": .double(payload.scale),
            "windowWidth": payload.windowWidth.map(MachineValue.double) ?? .null,
            "windowHeight": payload.windowHeight.map(MachineValue.double) ?? .null,
            "stage": .string(payload.stage),
        ]
        if let observed = payload.observed {
            fields["observed"] = .object(
                observed.mapValues(playCoverRuntimeJSONMachineValue)
            )
        }
        return .object(fields)
    }

    private static func playCoverRuntimeJSONMachineValue(
        _ value: PlayCoverRuntimeJSONValue
    ) -> MachineValue {
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .boolean(value)
        case .number(let value):
            return .double(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map(playCoverRuntimeJSONMachineValue))
        case .object(let values):
            return .object(values.mapValues(playCoverRuntimeJSONMachineValue))
        }
    }

    private static func formatRuntimeNumber(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.3f", value)
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
