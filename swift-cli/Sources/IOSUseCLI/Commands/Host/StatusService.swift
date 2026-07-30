import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum StatusService {
    static var playCoverDiagnosticsForTesting:
        ((SessionService.Info) throws
            -> PlayCoverRuntimeDiagnosticsPayload)?

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
                    "macAppPath": info.macAppPath.map(MachineValue.string) ?? .null,
                    "macExecutablePath": info.macExecutablePath.map(MachineValue.string) ?? .null,
                    "macGenerationKey": info.macGenerationKey.map(MachineValue.string) ?? .null,
                    "macRuntimeSocketPath": info.macRuntimeSocketPath.map(MachineValue.string) ?? .null,
                    "macLogPath": info.macLogPath.map(MachineValue.string) ?? .null,
                    "driverVersion": config.flatMap(\.driverVersion).map(MachineValue.string) ?? .null,
                    "versionMatchesCli": info.deviceType == PlayCoverSessionService.deviceType
                        ? .null
                        : .boolean(config?.driverVersion == IOSUseCLI.version),
                ]
                if info.deviceType == PlayCoverSessionService.deviceType {
                    switch playCoverRuntimeHealth(info: info) {
                    case .healthy(let payload):
                        fields["status"] = .string("healthy")
                        fields["runtime"] = playCoverRuntimeMachineValue(payload)
                    case .unhealthy(
                        let error,
                        let identityVerified,
                        let payload
                    ):
                        fields["status"] = .string("unhealthy")
                        var runtime: [String: MachineValue] = [
                            "status": .string("unhealthy"),
                            "identityVerified":
                                .boolean(identityVerified),
                            "error": .string(error),
                        ]
                        // A Runtime which authenticated successfully but
                        // failed the fixed-device/host contract must retain
                        // its structured diagnostics.  In particular, this
                        // keeps a canvas-capture error observable instead of
                        // making it look like a socket/identity failure.
                        if let payload {
                            runtime["stage"] = .string(payload.stage)
                            runtime["stdio"] =
                                playCoverRuntimeStdioMachineValue(
                                    payload.stdio
                                )
                            if let host = payload.geometry.host {
                                runtime["host"] =
                                    playCoverRuntimeHostMachineValue(host)
                            }
                            runtime["diagnostics"] = .object(
                                payload.diagnostics.mapValues(
                                    playCoverRuntimeJSONMachineValue
                                )
                            )
                        }
                        fields["runtime"] = .object(runtime)
                        warnings.append("Mac Runtime health check failed: \(error)")
                    case .stale(let error):
                        fields["status"] = .string("stale")
                        fields["runtime"] = .object([
                            "status": .string("stale"),
                            "identityVerified": .boolean(false),
                            "error": .string(error),
                        ])
                        warnings.append("Mac session is stale: \(error)")
                    }
                }
                driver = .object(fields)
            } else {
                do {
                    if let pending =
                            try PlayCoverPendingLaunchCoordinator
                                .readOnlySnapshot(paths: paths) {
                        driver = .object([
                            "status": .string(pending.status),
                            "deviceType": .string(
                                PlayCoverSessionService.deviceType
                            ),
                            "phase": .string(
                                pending.phase.rawValue
                            ),
                            "sessionIdentifier": .string(
                                pending.sessionID
                            ),
                            "bundleId": .string(
                                pending.bundleIdentifier
                            ),
                            "macGenerationKey": .string(
                                pending.generationKey
                            ),
                            "ownerPid": pending.ownerPID.map {
                                .integer(Int($0))
                            } ?? .null,
                            "reason": .string(pending.reason),
                        ])
                    } else {
                        driver = .object([
                            "status": .string("notRunning"),
                        ])
                    }
                } catch {
                    driver = .object([
                        "status": .string("invalidPendingLaunch"),
                        "deviceType": .string(
                            PlayCoverSessionService.deviceType
                        ),
                        "error": .string(
                            String(describing: error)
                        ),
                    ])
                    warnings.append(
                        "Mac pending launch is invalid: \(error)"
                    )
                }
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
                do {
                    guard let pending =
                            try PlayCoverPendingLaunchCoordinator
                                .readOnlySnapshot(paths: paths) else {
                        return ["  not running (no driver.lock)"]
                    }
                    var parts = [
                        pending.status,
                        "device: \(PlayCoverSessionService.deviceType)",
                        "phase: \(pending.phase.rawValue)",
                        "session: \(pending.sessionID)",
                        "bundle: \(pending.bundleIdentifier)",
                        "generation: \(pending.generationKey)",
                    ]
                    if let ownerPID = pending.ownerPID {
                        parts.append("owner pid: \(ownerPID)")
                    }
                    parts.append("reason: \(pending.reason)")
                    return [
                        "  - \(parts.joined(separator: " | "))",
                    ]
                } catch {
                    return [
                        "  invalid Mac pending launch: \(error)",
                    ]
                }
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
            if let appPath = info.macAppPath, !appPath.isEmpty {
                parts.append("app: \(appPath)")
            }
            if let generation = info.macGenerationKey,
               !generation.isEmpty {
                parts.append("generation: \(generation)")
            }
            if let logPath = info.macLogPath,
               !logPath.isEmpty {
                parts.append("stdio log: \(logPath)")
            }
            if info.deviceType == PlayCoverSessionService.deviceType {
                switch playCoverRuntimeHealth(info: info) {
                case .healthy(let payload):
                    parts[0] = "healthy"
                    parts.append("runtime: healthy")
                    if let socketPath = info.macRuntimeSocketPath {
                        parts.append("socket: \(socketPath)")
                    }
                    parts.append(
                        "geometry: \(formatRuntimeNumber(payload.geometry.logical.width))"
                            + "x\(formatRuntimeNumber(payload.geometry.logical.height))"
                            + " @\(formatRuntimeNumber(payload.geometry.scale))x"
                    )
                    parts.append(
                        "safe area: \(formatRuntimeNumber(payload.geometry.safeArea.top)),"
                            + "\(formatRuntimeNumber(payload.geometry.safeArea.left)),"
                            + "\(formatRuntimeNumber(payload.geometry.safeArea.bottom)),"
                            + "\(formatRuntimeNumber(payload.geometry.safeArea.right))"
                    )
                    parts.append("runtime stage: \(payload.stage)")
                    parts.append(
                        "capabilities: \(payload.capabilities.joined(separator: ","))"
                    )
                case .unhealthy(let error, _, let payload):
                    parts[0] = "unhealthy"
                    parts.append("runtime: unhealthy (\(error))")
                    if let captureError = payload?.geometry.host?.capture.error,
                       !captureError.isEmpty {
                        parts.append("host capture: \(captureError)")
                    }
                case .stale(let error):
                    parts[0] = "stale"
                    parts.append("runtime: stale (\(error))")
                }
            }
            return ["  - \(parts.joined(separator: " | "))"]
        } catch {
            return ["  invalid driver.lock: \(error)"]
        }
    }

    private enum PlayCoverRuntimeHealth {
        case healthy(PlayCoverRuntimeDiagnosticsPayload)
        case unhealthy(
            String,
            identityVerified: Bool,
            payload: PlayCoverRuntimeDiagnosticsPayload?
        )
        case stale(String)
    }

    private static func playCoverRuntimeHealth(
        info: SessionService.Info
    ) -> PlayCoverRuntimeHealth {
        guard let pidValue = info.runnerPid,
              pidValue > 0,
              pidValue <= Int(Int32.max),
              let expectedExecutable =
                info.macExecutablePath,
              !expectedExecutable.isEmpty else {
            return .stale(
                "driver.lock has incomplete PID/executable identity"
            )
        }
        let pid = Int32(pidValue)
        let actualExecutable: String
        switch PlayCoverSessionService.processState(pid) {
        case .running(let executablePath):
            actualExecutable = executablePath
        case .missing:
            return .stale("recorded App process is not running")
        case .unverifiable(let errorNumber):
            return .unhealthy(
                "cannot verify recorded App process identity: "
                    + "errno \(errorNumber)",
                identityVerified: false,
                payload: nil
            )
        }
        guard PlayCoverRuntimeClient.canonicalPath(actualExecutable)
                == PlayCoverRuntimeClient.canonicalPath(
                    expectedExecutable
                ) else {
            return .stale(
                "recorded PID belongs to a different executable"
            )
        }
        let payload: PlayCoverRuntimeDiagnosticsPayload
        do {
            if let override = playCoverDiagnosticsForTesting {
                payload = try override(info)
            } else {
                let client =
                    try PlayCoverDriverClient.runtimeClient(
                        for: info,
                        timeoutSeconds: 0.75,
                        refreshAlertStatus:
                            CLIInvocationContext
                                .current?
                                .claimAlertRefresh()
                                ?? true
                    )
                payload = try client.diagnostics()
            }
        } catch {
            return .unhealthy(
                String(describing: error),
                identityVerified: false,
                payload: nil
            )
        }
        do {
            try validatePlayCoverRuntimeIdentity(payload, info: info)
        } catch {
            return .unhealthy(
                String(describing: error),
                identityVerified: false,
                payload: nil
            )
        }
        do {
            try validatePlayCoverRuntimeStdio(
                payload,
                info: info
            )
            try PlayCoverDriverClient.validateFixedDevice(
                payload.geometry,
                stage: payload.stage
            )
            return .healthy(payload)
        } catch {
            return .unhealthy(
                String(describing: error),
                identityVerified: true,
                payload: payload
            )
        }
    }

    private static func validatePlayCoverRuntimeIdentity(
        _ payload: PlayCoverRuntimeDiagnosticsPayload,
        info: SessionService.Info
    ) throws {
        guard Int(payload.pid) == info.runnerPid,
              payload.bundleIdentifier == info.bundleId,
              let executable = info.macExecutablePath,
              PlayCoverRuntimeClient.canonicalPath(
                  payload.executablePath
              ) == PlayCoverRuntimeClient.canonicalPath(
                  executable
              ) else {
            throw CLIParseError.invalidValue(
                "Mac Runtime identity no longer matches the active session."
            )
        }
    }

    private static func validatePlayCoverRuntimeStdio(
        _ payload: PlayCoverRuntimeDiagnosticsPayload,
        info: SessionService.Info
    ) throws {
        if let expectedPath = info.macLogPath {
            guard let stdio = payload.stdio else {
                throw CLIParseError.invalidValue(
                    "Mac Runtime omitted stdio initialization evidence."
                )
            }
            guard stdio.status == "redirected",
                  stdio.path.map(
                    PlayCoverRuntimeClient.canonicalPath
                  ) == PlayCoverRuntimeClient.canonicalPath(
                    expectedPath
                  ),
                  let device = stdio.device,
                  let inode = stdio.inode,
                  stdio.failureStage == nil,
                  stdio.errorNumber == nil else {
                throw CLIParseError.invalidValue(
                    "Mac Runtime stdio log no longer matches "
                        + "the active session."
                )
            }
            #if canImport(Darwin)
            var status = stat()
            guard Darwin.lstat(expectedPath, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & 0o7777 == 0o600,
                  UInt64(truncatingIfNeeded: status.st_dev)
                    == device,
                  UInt64(status.st_ino) == inode else {
                throw CLIParseError.invalidValue(
                    "Mac stdio log path no longer identifies "
                        + "the Runtime's owner-only open file."
                )
            }
            #endif
        } else {
            // Existing schema-v3 prepared generations predate the optional
            // stdio field and remain valid for sessions without --log.
            guard let stdio = payload.stdio else {
                return
            }
            guard stdio.status == "disabled",
                  stdio.path == nil,
                  stdio.device == nil,
                  stdio.inode == nil,
                  stdio.failureStage == nil,
                  stdio.errorNumber == nil else {
                throw CLIParseError.invalidValue(
                    "Mac Runtime reports stdio capture for a "
                        + "session started without --log."
                )
            }
        }
    }

    static func playCoverRuntimeMachineValue(
        _ payload: PlayCoverRuntimeDiagnosticsPayload
    ) -> MachineValue {
        var fields: [String: MachineValue] = [
            "status": .string("healthy"),
            "identityVerified": .boolean(true),
            "protocolVersion": .integer(
                PlayCoverRuntimeClient.schemaVersion
            ),
            "pid": .integer(Int(payload.pid)),
            "bundleIdentifier": .string(payload.bundleIdentifier),
            "executablePath": .string(payload.executablePath),
            "capabilities": .array(payload.capabilities.map(MachineValue.string)),
            "logicalWidth": .double(payload.geometry.logical.width),
            "logicalHeight": .double(payload.geometry.logical.height),
            "nativeWidth": .double(payload.geometry.native.width),
            "nativeHeight": .double(payload.geometry.native.height),
            "scale": .double(payload.geometry.scale),
            "windowWidth": .double(payload.geometry.window.width),
            "windowHeight": .double(payload.geometry.window.height),
            "safeAreaTop": .double(payload.geometry.safeArea.top),
            "safeAreaLeft": .double(payload.geometry.safeArea.left),
            "safeAreaBottom": .double(payload.geometry.safeArea.bottom),
            "safeAreaRight": .double(payload.geometry.safeArea.right),
            "stage": .string(payload.stage),
            "stdio": playCoverRuntimeStdioMachineValue(
                payload.stdio
            ),
        ]
        if let host = payload.geometry.host {
            fields["host"] = playCoverRuntimeHostMachineValue(host)
        }
        fields["diagnostics"] = .object(
            payload.diagnostics.mapValues(
                playCoverRuntimeJSONMachineValue
            )
        )
        return .object(fields)
    }

    private static func playCoverRuntimeStdioMachineValue(
        _ stdio: PlayCoverRuntimeStdioState?
    ) -> MachineValue {
        guard let stdio else {
            return .null
        }
        return .object([
            "status": .string(stdio.status),
            "path": stdio.path.map(MachineValue.string) ?? .null,
            "device": stdio.device.map {
                .string(String($0))
            } ?? .null,
            "inode": stdio.inode.map {
                .string(String($0))
            } ?? .null,
            "failureStage":
                stdio.failureStage.map(MachineValue.string) ?? .null,
            "errorNumber": stdio.errorNumber.map {
                .integer(Int($0))
            } ?? .null,
        ])
    }

    private static func playCoverRuntimeHostMachineValue(
        _ host: PlayCoverRuntimeHostGeometry
    ) -> MachineValue {
        func frame(_ value: PlayCoverRuntimeFrame) -> MachineValue {
            .object([
                "x": .double(value.x),
                "y": .double(value.y),
                "width": .double(value.width),
                "height": .double(value.height),
            ])
        }
        return .object([
            "status": .string(host.status),
            "hostPolicy": .boolean(host.hostPolicy),
            "frame": frame(host.frame),
            "contentBounds": frame(host.contentBounds),
            "canvasRect": frame(host.canvasRect),
            "canvasBounds": frame(host.canvasBounds),
            "displayScale": .double(host.displayScale),
            "inverseDisplayScale": .double(host.inverseDisplayScale),
            "opaque": .boolean(host.opaque),
            "publicTitleBar": .boolean(host.publicTitleBar),
            "titleVisible": .boolean(host.titleVisible),
            "resizable": .boolean(host.resizable),
            "title": .string(host.title),
            "titleExpected": .string(host.titleExpected),
            "capture": .object([
                "ready": .boolean(host.capture.ready),
                "error": host.capture.error.map(MachineValue.string) ?? .null,
                "hostContentCGWindowRect":
                    frame(host.capture.hostContentCGWindowRect),
                "hostCGWindowBounds":
                    frame(host.capture.hostCGWindowBounds),
                "canvasCGWindowRect":
                    frame(host.capture.canvasCGWindowRect),
                "hostWindowNumber": host.capture.hostWindowNumber.map {
                    .integer(Int($0))
                } ?? .null,
            ]),
        ])
    }

    static func playCoverRuntimeJSONMachineValue(
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
