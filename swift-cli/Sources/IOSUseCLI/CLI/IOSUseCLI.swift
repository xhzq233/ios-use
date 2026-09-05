import Foundation
import IOSUseProtocol

public struct IOSUseCLI: Sendable {
    public typealias CLIOutputSink = @Sendable (String) -> Void
    typealias PlayCoverSignerInitializer =
        @Sendable () throws -> PlayCoverSigningIdentityEvidence

    static var driverClientFactoryForTesting: ((SessionService.Info) -> DriverCommandClient)? {
        get { DriverCommandExecution.clientFactoryForTesting }
        set { DriverCommandExecution.clientFactoryForTesting = newValue }
    }
    static var playCoverDriverClientFactoryForTesting:
        ((SessionService.Info) -> DriverCommandClient)? {
        get { DriverCommandExecution.playCoverClientFactoryForTesting }
        set { DriverCommandExecution.playCoverClientFactoryForTesting = newValue }
    }

    public let paths: IOSUsePaths
    public let outputSink: CLIOutputSink?
    private let playCoverSignerInitializer: PlayCoverSignerInitializer
    private let registerHomesForDiskUsage: Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        outputSink: CLIOutputSink? = nil,
        registerHomesForDiskUsage: Bool = false
    ) {
        self.init(
            environment: environment,
            outputSink: outputSink,
            registerHomesForDiskUsage: registerHomesForDiskUsage,
            playCoverSignerInitializer: {
                try PlayCoverSigningIdentityService()
                    .initializeForConfiguration()
            }
        )
    }

    init(
        environment: [String: String],
        outputSink: CLIOutputSink? = nil,
        registerHomesForDiskUsage: Bool = false,
        playCoverSignerInitializer:
            @escaping PlayCoverSignerInitializer
    ) {
        self.paths = IOSUsePaths.resolve(environment: environment)
        self.outputSink = outputSink
        self.registerHomesForDiskUsage = registerHomesForDiskUsage
        self.playCoverSignerInitializer = playCoverSignerInitializer
    }

    /// Internal test-only construction keeps commands on the fixture's
    /// explicitly isolated account-global/cache/socket namespace.
    init(
        pathsForTesting paths: IOSUsePaths,
        outputSink: CLIOutputSink? = nil,
        registerHomesForDiskUsage: Bool = false,
        playCoverSignerInitializer:
            @escaping PlayCoverSignerInitializer = {
                try PlayCoverSigningIdentityService()
                    .initializeForConfiguration()
            }
    ) {
        self.paths = paths
        self.outputSink = outputSink
        self.registerHomesForDiskUsage = registerHomesForDiskUsage
        self.playCoverSignerInitializer = playCoverSignerInitializer
    }

    public func run(arguments: [String]) -> CLIResult {
        if arguments.first == XCTestSessionHolderService.commandName {
            do {
                return CLIResult(
                    exitCode: 0,
                    stdout: try XCTestSessionHolderService.run(arguments: Array(arguments.dropFirst()), paths: paths)
                )
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        }

        if arguments.first == AppLogCaptureService.helperCommandName {
            do {
                return CLIResult(
                    exitCode: 0,
                    stdout: try AppLogCaptureService.runHelper(arguments: Array(arguments.dropFirst()), paths: paths)
                )
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        }

        return runPublicInvocation(arguments: arguments)
    }

    private func runPublicInvocation(arguments: [String]) -> CLIResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let invocationState = CLIInvocationState()
        let performanceCollector =
            CLIInvocationPerformanceCollector(
                startedAt: startedAt
            )
        return CLIInvocationContext.$current.withValue(
            invocationState
        ) {
            CLIInvocationPerformanceContext.$current.withValue(
                performanceCollector
            ) {
                let wantsJSON = CLIParser.requestsJSON(arguments)
                let command = performanceCommandName(
                    arguments: arguments
                )
                if command == "start" || command == "stop" {
                    invocationState.suppressAlertRefresh()
                }
                let result = executePublicInvocation(
                    arguments: arguments
                )
                let invocationSnapshot =
                    invocationState.snapshot()
                let finalized = MachineOutput.finalizeInvocation(
                    result,
                    expectsMachineOutput: wantsJSON,
                    snapshot: invocationSnapshot
                )
                let totalElapsedMs =
                    performanceCollector.freezeTotalElapsedMs()
                if command != "du" {
                    appendPerformanceLog(
                        command: command,
                        ok: finalized.exitCode == 0,
                        totalElapsedMs: totalElapsedMs,
                        snapshot: performanceCollector.snapshot()
                    )
                }
                return finalized
            }
        }
    }

    private func executePublicInvocation(
        arguments: [String]
    ) -> CLIResult {
        let (machineArguments, wantsJSON) = CLIParser.extractGlobalJSONFlag(arguments)
        let publicArguments: [String]
        do {
            publicArguments = try CLIParser.extractGlobalDeviceFlag(
                machineArguments
            ).0
        } catch {
            let command = machineArguments.first ?? "unknown"
            if wantsJSON {
                return MachineOutput.failure(
                    command: command,
                    error: error,
                    data: machineParseHelp(arguments: machineArguments),
                    exitCode: 64
                )
            }
            return CLIErrorEnvelope(message: "\(error)").render(
                help: CLIHelp.rootText
            )
        }
        if let immediate = CLIHelp.immediateResult(arguments: publicArguments) {
            return immediate
        }

        guard let first = publicArguments.first else {
            return CLIResult(exitCode: 0, stdout: Self.helpText)
        }
        let machineCommand = publicArguments.first ?? first
        switch first {
        case _ where first.hasPrefix("-") && first != "--json":
            let error = CLIParseError.unknownOption(first)
            if wantsJSON {
                return MachineOutput.failure(
                    command: machineCommand,
                    error: error,
                    data: machineParseHelp(arguments: machineArguments),
                    exitCode: 64
                )
            }
            return CLIErrorEnvelope(message: error.description).render(help: CLIHelp.rootText)
        default:
            let invocation: ParsedInvocation
            do {
                invocation = try CLIParser.parseInvocation(arguments)
            } catch let error as CLIParseError {
                if wantsJSON {
                    return MachineOutput.failure(
                        command: machineCommand,
                        error: error,
                        data: machineParseHelp(arguments: machineArguments),
                        exitCode: 64
                    )
                }
                return CLIErrorEnvelope(message: error.description).render(help: CLIHelp.parseErrorHelp(arguments: arguments))
            } catch {
                if wantsJSON {
                    return MachineOutput.failure(
                        command: machineCommand,
                        error: error,
                        data: machineParseHelp(arguments: machineArguments),
                        exitCode: 64
                    )
                }
                return CLIErrorEnvelope(message: "\(error)").render()
            }
            let result = execute(
                invocation.command,
                json: invocation.json,
                deviceID: invocation.deviceID
            )
            if registerHomesForDiskUsage,
               result.exitCode == 0,
               case .start = invocation.command {
                IOSUseHomeDiscoveryStore.registerIfExisting(paths: paths)
            }
            return result
        }
    }

    private func performanceCommandName(arguments: [String]) -> String {
        let withoutJSON = CLIParser.extractGlobalJSONFlag(arguments).0
        let normalized = (try? CLIParser.extractGlobalDeviceFlag(
            withoutJSON
        ).0) ?? withoutJSON
        guard let first = normalized.first else {
            return "help"
        }
        let command: String
        switch first {
        case "-h", "--help", "help":
            command = "help"
        case "-V", "--version":
            command = "version"
        case "media", "proxy":
            if normalized.count > 1,
               !normalized[1].hasPrefix("-") {
                command = "\(first) \(normalized[1])"
            } else {
                command = first
            }
        default:
            command = first
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        let safe = command.unicodeScalars.map {
            allowed.contains($0) ? String($0) : "_"
        }.joined()
        return String(safe.prefix(80))
    }

    private func appendPerformanceLog(
        command: String,
        ok: Bool,
        totalElapsedMs: Double,
        snapshot: CLIInvocationPerformanceSnapshot
    ) {
        var fields = [
            "[cli]",
            "command=\(command)",
            "ok=\(ok)",
            "commandElapsedMs=\(totalElapsedMs)",
        ]
        if let alertRefreshElapsedMs =
                snapshot.alertRefreshElapsedMs {
            fields.append(
                "alertRefreshElapsedMs=\(alertRefreshElapsedMs)"
            )
        }
        CLILogService.append(
            paths: paths,
            [fields.joined(separator: " ")]
        )
    }

    private struct InvocationTarget {
        let paths: IOSUsePaths
        let startUDID: String?
    }

    private func resolveInvocationTarget(
        for command: ParsedCommand,
        explicitDeviceID: String?
    ) throws -> InvocationTarget {
        switch command {
        case .start(let options):
            if options.mac {
                if let explicitDeviceID {
                    let normalized = try DeviceContextStore
                        .normalizeExplicitDeviceID(
                            explicitDeviceID,
                            paths: paths
                        )
                    guard normalized == DeviceContextStore.macDeviceID else {
                        throw CLIParseError.invalidValue(
                            "start --mac requires --device mac."
                        )
                    }
                }
                try DeviceContextStore.requireInactive(
                    deviceID: DeviceContextStore.macDeviceID,
                    paths: paths
                )
                return InvocationTarget(
                    paths: try paths.deviceContext(
                        DeviceContextStore.macDeviceID
                    ),
                    startUDID: nil
                )
            }

            var requestedUDID = options.udid
            var normalizedExplicit: String?
            if let explicitDeviceID {
                let normalized = try DeviceContextStore
                    .normalizeExplicitDeviceID(
                        explicitDeviceID,
                        paths: paths
                    )
                guard normalized != DeviceContextStore.macDeviceID,
                      let targetUDID = DeviceContextStore.targetUDID(
                          from: normalized
                      ) else {
                    throw CLIParseError.invalidValue(
                        "A real or Simulator Device ID is required."
                    )
                }
                if let requestedUDID, requestedUDID != targetUDID {
                    throw CLIParseError.invalidValue(
                        "start target \(requestedUDID) does not match --device \(normalized)."
                    )
                }
                requestedUDID = targetUDID
                normalizedExplicit = normalized
            }
            if requestedUDID == nil {
                requestedUDID = try DeviceService.listDevices(
                    simulatorOnly: false,
                    paths: paths
                ).first(where: { $0.kind == .real })?.udid
            }
            guard let requestedUDID, !requestedUDID.isEmpty else {
                throw CLIParseError.invalidValue(
                    "No --udid and no USB real devices detected."
                )
            }
            if let existing = DeviceContextStore.sessions(
                paths: paths
            ).first(where: {
                $0.info.udid == requestedUDID
                    && (normalizedExplicit == nil
                        || normalizedExplicit == $0.deviceID)
            }) {
                if SessionService.isIncompleteRealDriverLock(existing.info) {
                    return InvocationTarget(
                        paths: existing.paths,
                        startUDID: requestedUDID
                    )
                }
                throw CLIParseError.invalidValue(
                    "Driver already started for Device \(existing.deviceID)."
                )
            }
            let info = try SessionService.resolveDriverInfo(
                udid: requestedUDID,
                paths: paths
            )
            let resolvedDeviceID = DeviceContextStore.deviceID(for: info)
            if let normalizedExplicit,
               normalizedExplicit != resolvedDeviceID {
                throw CLIParseError.invalidValue(
                    "Device \(normalizedExplicit) resolved as \(resolvedDeviceID)."
                )
            }
            try DeviceContextStore.requireInactive(
                deviceID: resolvedDeviceID,
                paths: paths
            )
            return InvocationTarget(
                paths: try paths.deviceContext(resolvedDeviceID),
                startUDID: requestedUDID
            )

        case .stop, .driver, .debug, .uiTree, .capture,
                .mediaImport:
            let context = try DeviceContextStore.activeContext(
                explicitDeviceID: explicitDeviceID,
                paths: paths
            )
            return InvocationTarget(
                paths: context.paths,
                startUDID: nil
            )

        case .nslog:
            if let explicitDeviceID {
                let normalized = try DeviceContextStore
                    .normalizeExplicitDeviceID(
                        explicitDeviceID,
                        paths: paths
                    )
                return InvocationTarget(
                    paths: try paths.deviceContext(normalized),
                    startUDID: nil
                )
            }
            let active = DeviceContextStore.sessions(paths: paths)
            if active.count == 1 {
                return InvocationTarget(
                    paths: active[0].paths,
                    startUDID: nil
                )
            }
            if active.count > 1 {
                _ = try DeviceContextStore.activeContext(
                    explicitDeviceID: nil,
                    paths: paths
                )
            }
            return InvocationTarget(paths: paths, startUDID: nil)

        case .open(let options):
            return try resolveOptionalActiveTarget(
                explicitDeviceID: explicitDeviceID,
                impliedUDID: options.session.udid
            )

        case .appLifecycle(let options):
            return try resolveOptionalActiveTarget(
                explicitDeviceID: explicitDeviceID,
                impliedUDID: options.session.udid
            )

        case .oslog(let options):
            return try resolveOptionalActiveTarget(
                explicitDeviceID: explicitDeviceID,
                impliedUDID: options.session.udid
            )

        case .install(let options):
            return try resolveOptionalActiveTarget(
                explicitDeviceID: explicitDeviceID,
                impliedUDID: options.udid
            )
        case .uninstall(let options):
            return try resolveOptionalActiveTarget(
                explicitDeviceID: explicitDeviceID,
                impliedUDID: options.udid
            )
        case .apps(let options):
            return try resolveOptionalActiveTarget(
                explicitDeviceID: explicitDeviceID,
                impliedUDID: options.udid
            )
        case .ddiMount(let options):
            return try resolveOptionalActiveTarget(
                explicitDeviceID: explicitDeviceID,
                impliedUDID: options.udid
            )

        case .proxy(.start), .proxy(.read), .proxy(.stop):
            let context = try DeviceContextStore.activeContext(
                explicitDeviceID: explicitDeviceID,
                paths: paths
            )
            return InvocationTarget(
                paths: context.paths,
                startUDID: nil
            )

        case .du, .status, .script, .config,
                .proxy(.doctor), .proxy(.configca):
            guard explicitDeviceID == nil else {
                throw CLIParseError.invalidValue(
                    "--device is not supported by \(command.commandName)."
                )
            }
            return InvocationTarget(paths: paths, startUDID: nil)
        }
    }

    private func resolveOptionalActiveTarget(
        explicitDeviceID: String?,
        impliedUDID: String?
    ) throws -> InvocationTarget {
        let active = DeviceContextStore.sessions(paths: paths)
        if explicitDeviceID != nil {
            let context = try DeviceContextStore.activeContext(
                explicitDeviceID: explicitDeviceID,
                impliedUDID: impliedUDID,
                paths: paths
            )
            return InvocationTarget(
                paths: context.paths,
                startUDID: nil
            )
        }
        if let impliedUDID {
            if let context = active.first(where: {
                $0.info.udid == impliedUDID
            }) {
                return InvocationTarget(
                    paths: context.paths,
                    startUDID: nil
                )
            }
            return InvocationTarget(paths: paths, startUDID: nil)
        }
        if active.count == 1 {
            return InvocationTarget(
                paths: active[0].paths,
                startUDID: nil
            )
        }
        if active.count > 1 {
            _ = try DeviceContextStore.activeContext(
                explicitDeviceID: nil,
                paths: paths
            )
        }
        return InvocationTarget(paths: paths, startUDID: nil)
    }

    private func execute(
        _ parsed: ParsedCommand,
        json: Bool,
        deviceID: String?
    ) -> CLIResult {
        if case .start(let options) = parsed,
           options.mac,
           let warning = Self.macBackendCompatibilityWarning(
               for: ProcessInfo.processInfo.operatingSystemVersion
           ) {
            CLIInvocationContext.current?.recordWarning(warning)
        }
        // An explicit Mac App start must establish its read-only signer
        // evidence before routing probes driver.lock. This keeps a missing
        // configuration ahead of every Mac state/cache/source mutation and
        // passes the exact same evidence into preparation.
        let explicitMacSigningIdentity:
            PlayCoverSigningIdentityEvidence?
        if case .start(let options) = parsed,
           options.mac,
           let appPath = options.appPath,
           !appPath.isEmpty {
            do {
                explicitMacSigningIdentity =
                    try PlayCoverService
                        .requireHealthySigningIdentityForStart()
            } catch {
                return commandFailure(
                    command: parsed.commandName,
                    error: error,
                    json: json
                )
            }
        } else {
            explicitMacSigningIdentity = nil
        }
        let target: InvocationTarget
        do {
            target = try resolveInvocationTarget(
                for: parsed,
                explicitDeviceID: deviceID
            )
        } catch {
            return commandFailure(
                command: parsed.commandName,
                error: error,
                json: json
            )
        }
        let commandPaths = target.paths
        if let routedFailure = playCoverRoutingFailure(
            for: parsed,
            paths: commandPaths,
            json: json
        ) {
            return routedFailure
        }
        switch parsed {
        case .du:
            let snapshot = DiskUsageService.snapshot(paths: paths)
            if json {
                return MachineOutput.success(
                    command: parsed.commandName,
                    data: snapshot.machineData,
                    warnings: snapshot.warnings
                )
            }
            return CLIResult(exitCode: 0, stdout: snapshot.formatted())
        case .status(let options):
            if json {
                let snapshot = StatusService.machineSnapshot(paths: paths)
                return MachineOutput.success(command: parsed.commandName, data: snapshot.data, warnings: snapshot.warnings)
            }
            do {
                return CLIResult(exitCode: 0, stdout: try StatusService.status(paths: paths, verbose: options.verbose))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .script(let options):
            return ScriptRuntimeService.run(options: options)
        case .config(let options) where options.playCover:
            return executePlayCoverConfiguration(json: json)
        case .config(let options) where options.list:
            let output = ConfigService.formatList(
                ConfigService.listEntries(paths: paths)
            )
            if json {
                return MachineOutput.success(
                    command: parsed.commandName,
                    data: .object(["display": .string(output)])
                )
            }
            return CLIResult(exitCode: 0, stdout: output)
        case .config(let options) where options.simulator:
            do {
                let output = try ConfigService.configureSimulator(
                    udid: options.udid,
                    paths: paths
                )
                if json {
                    return MachineOutput.success(
                        command: parsed.commandName,
                        data: .object(["display": .string(output)])
                    )
                }
                return CLIResult(exitCode: 0, stdout: output)
            } catch {
                return commandFailure(
                    command: parsed.commandName,
                    error: error,
                    json: json
                )
            }
        case .config(let options):
            do {
                let output = try ConfigService.configureDevice(
                    options: options,
                    paths: paths
                )
                if json {
                    return MachineOutput.success(
                        command: parsed.commandName,
                        data: .object(["display": .string(output)])
                    )
                }
                return CLIResult(exitCode: 0, stdout: output)
            } catch {
                return commandFailure(
                    command: parsed.commandName,
                    error: error,
                    json: json
                )
            }
        case .start(let options):
            do {
                let output: String
                if options.mac {
                    output = try SessionService
                        .startPlayCoverAfterPreflight(
                        appPath: options.appPath,
                        signingIdentity:
                            explicitMacSigningIdentity,
                        captureStdio: options.log,
                        timeout: options.timeout,
                        paths: commandPaths
                    )
                } else {
                    output = try SessionService.start(
                        udid: target.startUDID,
                        paths: commandPaths,
                        verbose: options.verbose
                    )
                }
                if json {
                    let snapshot = StatusService.machineSnapshot(
                        paths: paths
                    )
                    return MachineOutput.success(
                        command: parsed.commandName,
                        data: snapshot.data,
                        warnings: snapshot.warnings
                    )
                }
                return CLIResult(exitCode: 0, stdout: output)
            } catch {
                return commandFailure(
                    command: parsed.commandName,
                    error: error,
                    json: json
                )
            }
        case .debug(let options):
            return executeDebug(
                options,
                paths: commandPaths,
                json: json
            )
        case .uiTree(let options):
            return executeUITree(
                options,
                paths: commandPaths,
                json: json
            )
        case .install(let options):
            do {
                let result = try AppManagementService.installResult(options: options, paths: commandPaths)
                if json {
                    return MachineOutput.success(
                        command: parsed.commandName,
                        data: AppManagementService.machineInstallData(result)
                    )
                }
                return CLIResult(
                    exitCode: 0,
                    stdout: AppManagementService.formatInstallResult(result, verbose: options.verbose)
                )
            } catch {
                return commandFailure(command: parsed.commandName, error: error, json: json)
            }
        case .uninstall(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try AppManagementService.uninstall(options: options, paths: commandPaths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .apps(let options):
            do {
                let result = try AppManagementService.listResult(options: options, paths: commandPaths)
                if json {
                    return MachineOutput.success(
                        command: parsed.commandName,
                        data: AppManagementService.machineAppsData(result)
                    )
                }
                return CLIResult(exitCode: 0, stdout: try AppManagementService.formatListResult(result, json: false))
            } catch {
                return commandFailure(command: parsed.commandName, error: error, json: json)
            }
        case .ddiMount(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try DeveloperDiskImageService.mount(options: options, paths: commandPaths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .open(let options):
            return executeOpen(
                options,
                paths: commandPaths,
                json: json
            )
        case .appLifecycle(let options):
            return executeAppLifecycle(
                options,
                paths: commandPaths,
                json: json
            )
        case .oslog(let options):
            return executeOSLog(options, paths: commandPaths)
        case .nslog(let options):
            do {
                switch options.command {
                case .stream:
                    return CLIResult(exitCode: 0, stdout: try NSLogService.stream(options: options, paths: commandPaths))
                case .start:
                    return CLIResult(exitCode: 0, stdout: try NSLogService.start(options: options, paths: commandPaths))
                case .read:
                    return CLIResult(exitCode: 0, stdout: try NSLogService.read(options: options, paths: commandPaths))
                case .stop:
                    return CLIResult(exitCode: 0, stdout: try NSLogService.stop(paths: commandPaths))
                }
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .stop:
            do {
                let output = try SessionService.stop(paths: commandPaths)
                if json {
                    let snapshot = StatusService.machineSnapshot(
                        paths: paths
                    )
                    return MachineOutput.success(
                        command: parsed.commandName,
                        data: snapshot.data,
                        warnings: snapshot.warnings
                    )
                }
                return CLIResult(exitCode: 0, stdout: output)
            } catch {
                return commandFailure(
                    command: parsed.commandName,
                    error: error,
                    json: json
                )
            }
        case .proxy(.doctor):
            return CLIResult(exitCode: 0, stdout: ProxyService.doctor(paths: commandPaths))
        case .proxy(.configca(let markTrusted)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.configCA(markTrusted: markTrusted, paths: commandPaths))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.start(let interfaceName, let serverOnly)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.start(interfaceName: interfaceName, serverOnly: serverOnly, paths: commandPaths))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.read(let filter, let raw, let last)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.read(filter: filter, raw: raw, last: last, paths: commandPaths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.stop(let serverOnly)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.stop(serverOnly: serverOnly, paths: commandPaths))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .driver(let action):
            return executeDriver(
                action,
                paths: commandPaths,
                json: json
            )
        case .capture(let options):
            do {
                let output = try DeviceCommandLock.withExclusiveLock(
                    paths: commandPaths
                ) {
                    try CaptureService.run(
                        options: options,
                        paths: commandPaths
                    )
                }
                return CLIResult(exitCode: 0, stdout: output)
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .mediaImport(let options):
            do {
                let result = try DeviceCommandLock.withExclusiveLock(
                    paths: commandPaths
                ) {
                    try MediaImportService.run(
                        options: options,
                        paths: commandPaths
                    )
                }
                if json {
                    return MachineOutput.success(
                        command: parsed.commandName,
                        data: MediaImportService.machineData(result)
                    )
                }
                return CLIResult(exitCode: 0, stdout: MediaImportService.format(result))
            } catch {
                return commandFailure(command: parsed.commandName, error: error, json: json)
            }
        }
    }

    private func executePlayCoverConfiguration(
        json: Bool
    ) -> CLIResult {
        do {
            let evidence = try playCoverSignerInitializer()
            if json {
                return MachineOutput.success(
                    command: "config",
                    data: playCoverSignerMachineData(evidence)
                )
            }
            let expiresAt = ISO8601DateFormatter().string(
                from: evidence.notAfter
            )
            return CLIResult(
                exitCode: 0,
                stdout: """
                Mac backend signing identity is ready.
                Certificate SHA-256: \(evidence.certificateSHA256)
                Expires: \(expiresAt)

                """
            )
        } catch {
            return commandFailure(
                command: "config",
                error: error,
                json: json,
                mutationMayHaveApplied: true
            )
        }
    }

    private func playCoverSignerMachineData(
        _ evidence: PlayCoverSigningIdentityEvidence
    ) -> MachineValue {
        .object([
            "backend": .string("mac"),
            "status": .string("ready"),
            "certificateSHA256":
                .string(evidence.certificateSHA256),
            "expiresAt": .string(
                ISO8601DateFormatter().string(
                    from: evidence.notAfter
                )
            ),
        ])
    }

    private func playCoverRoutingFailure(
        for command: ParsedCommand,
        paths: IOSUsePaths,
        json: Bool
    ) -> CLIResult? {
        let active: SessionService.Info?
        do {
            active = try SessionService.readDriverLockInfo(
                paths: paths
            )
        } catch {
            switch command {
            case .du, .status, .script, .config, .start, .stop:
                return nil
            case .open:
                return commandFailure(
                    command: command.commandName,
                    error: OpenURLService.MacOpenError.targetMismatch(
                        String(describing: error)
                    ),
                    json: json
                )
            default:
                return commandFailure(
                    command: command.commandName,
                    error: error,
                    json: json
                )
            }
        }
        guard active?.deviceType
                == PlayCoverSessionService.deviceType else {
            return nil
        }
        switch command {
        case .du, .status, .script, .config, .start, .stop, .capture, .open, .oslog, .debug, .uiTree:
            return nil
        case .mediaImport:
            return nil
        case .appLifecycle(let options):
            return commandFailure(
                command: options.action.commandName,
                error: PlayCoverDriverClientError
                    .lifecycleCommandUnsupported(
                        options.action.commandName
                    ),
                json: json
            )
        case .driver(let action):
            switch action {
            case .dom, .screenshot, .waitFor,
                    .tap, .longPress, .swipe, .input,
                    .dismissAlert:
                return nil
            case .activateApp:
                return commandFailure(
                    command: action.name,
                    error: PlayCoverDriverClientError
                        .lifecycleCommandUnsupported("activateApp"),
                    json: json
                )
            case .terminateApp:
                return commandFailure(
                    command: action.name,
                    error: PlayCoverDriverClientError
                        .lifecycleCommandUnsupported("terminateApp"),
                    json: json
                )
            case .home:
                return commandFailure(
                    command: action.name,
                    error: PlayCoverDriverClientError
                        .lifecycleCommandUnsupported("home"),
                    json: json
                )
            case .rotate:
                return commandFailure(
                    command: action.name,
                    error: PlayCoverBackendError.capabilityUnavailable("rotate"),
                    json: json
                )
            }
        default:
            return commandFailure(
                command: command.commandName,
                error: PlayCoverBackendError.capabilityUnavailable(command.commandName),
                json: json
            )
        }
    }

    private func executeOpen(
        _ options: OpenURLOptions,
        paths: IOSUsePaths,
        json: Bool,
        hostDeviceTypeHint: String? = nil
    ) -> CLIResult {
        do {
            let validatedURL = try OpenURLService.validatedURL(
                options.url
            )
            let result = try DeviceCommandLock.withExclusiveLock(
                paths: paths
            ) { () throws -> OpenURLService.OpenResult in
                if options.dom {
                    return try OpenURLService.openWithDom(
                        url: validatedURL,
                        session: options.session,
                        paths: paths
                    )
                }
                let resolved: OpenURLService.OpenResult?
                if options.session.udid != nil
                    || hostDeviceTypeHint != nil {
                    resolved = try OpenURLService
                        .openHostSideIfAvailable(
                            url: validatedURL,
                            udid: options.session.udid,
                            deviceType: hostDeviceTypeHint,
                            paths: paths
                        )
                        ?? OpenURLService.openHostSideIfAvailable(
                            url: validatedURL,
                            session: options.session,
                            paths: paths
                        )
                } else {
                    resolved = try OpenURLService
                        .openHostSideIfAvailable(
                            url: validatedURL,
                            session: options.session,
                            paths: paths
                        )
                }
                guard let resolved else {
                    throw CLIParseError.invalidValue("open target is unavailable. Pass a USB real device UDID, pass a booted Simulator UDID, or run `ios-use start` first.")
                }
                return resolved
            }
            var stdout = "\(result.message)\n"
            if let dom = result.dom {
                stdout += "\n" + DriverOutput.formatDom(dom) + "\n"
            }
            if json {
                return MachineOutput.success(command: "open", data: OpenURLService.machineData(result))
            }
            return CLIResult(exitCode: 0, stdout: stdout)
        } catch {
            if json, let readinessError = error as? OpenURLService.ReadinessError {
                return MachineOutput.failure(
                    command: "open",
                    error: error,
                    data: OpenURLService.machineData(readinessError.hostResult),
                    mutationMayHaveApplied: true
                )
            }
            return commandFailure(command: "open", error: error, json: json)
        }
    }

    static func macBackendCompatibilityWarning(
        for operatingSystemVersion: OperatingSystemVersion
    ) -> String? {
        guard operatingSystemVersion.majorVersion >= 26 else {
            return nil
        }
        return "The Mac backend is not fully supported on macOS 26 or newer. "
            + "An App may launch, but UI interaction can still crash. "
            + "Use a validated older macOS release, a real device, or a "
            + "Simulator for reliable automation."
    }

    private func executeAppLifecycle(
        _ options: AppLifecycleOptions,
        paths: IOSUsePaths,
        json: Bool
    ) -> CLIResult {
        do {
            let result = try DeviceCommandLock.withExclusiveLock(
                paths: paths
            ) {
                try AppLifecycleService.runWithReadiness(
                    options: options,
                    paths: paths
                )
            }
            var stdout = "\(result.message)\n"
            if let dom = result.dom {
                stdout += "\n" + DriverOutput.formatDom(dom) + "\n"
            }
            if json {
                return MachineOutput.success(
                    command: options.action.commandName,
                    data: AppLifecycleService.machineData(options: options, result: result)
                )
            }
            return CLIResult(exitCode: 0, stdout: stdout)
        } catch {
            if json, let readinessError = error as? AppLifecycleService.ReadinessError {
                return MachineOutput.failure(
                    command: options.action.commandName,
                    error: error,
                    data: AppLifecycleService.machineData(options: options, result: readinessError.hostResult),
                    mutationMayHaveApplied: true
                )
            }
            return commandFailure(command: options.action.commandName, error: error, json: json)
        }
    }

    private func executeOSLog(
        _ options: OSLogOptions,
        paths: IOSUsePaths,
        hostDeviceTypeHint: String? = nil
    ) -> CLIResult {
        do {
            let stdout = try OSLogCommandService.run(options: options, paths: paths, hostDeviceTypeHint: hostDeviceTypeHint, outputSink: outputSink)
            if let outputSink, !stdout.isEmpty {
                outputSink(stdout)
                return CLIResult(exitCode: 0)
            }
            return CLIResult(exitCode: 0, stdout: stdout)
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    private func executeDriver(
        _ action: DriverAction,
        paths: IOSUsePaths,
        json: Bool
    ) -> CLIResult {
        let session = LockedDriverClientSession(paths: paths)
        defer { session.close() }
        do {
            let result = try DeviceCommandLock.withExclusiveLock(
                paths: paths
            ) {
                try DriverCommandExecutor.execute(
                    action: action,
                    paths: paths
                ) { body in
                    try session.run(body)
                }
            }
            if json {
                let output = result.machineOutput(for: action)
                return MachineOutput.success(command: action.name, data: output.data, warnings: output.warnings)
            }
            return CLIResult(exitCode: 0, stdout: result.stdout)
        } catch {
            if json {
                return MachineOutput.failure(
                    command: action.name,
                    error: error,
                    data: machineDriverErrorData(error)
                )
            }
            return CLIErrorEnvelope(
                message: renderDriverFailure(error),
                exitCode: 1
            ).render()
        }
    }

    private func executeDebug(
        _ options: DebugOptions,
        paths: IOSUsePaths,
        json: Bool
    ) -> CLIResult {
        do {
            let session = try SessionService.requireDriverLock(paths: paths)
            guard session.deviceType == PlayCoverSessionService.deviceType else {
                throw PlayCoverBackendError.capabilityUnavailable("debug")
            }
            guard let sessionID = session.sessionIdentifier,
                  !sessionID.isEmpty else {
                throw PlayCoverDriverClientError.incompleteSessionIdentity(
                    "sessionID"
                )
            }
            let refreshAlertStatus =
                CLIInvocationContext.current?.claimAlertRefresh() ?? true
            let client = try PlayCoverDriverClient.runtimeClient(
                for: session,
                timeoutSeconds: PlayCoverRuntimeClient.debugTimeoutSeconds,
                refreshAlertStatus: refreshAlertStatus
            )
            let liveOutputEnabled = outputSink != nil
            var liveEvents: [String] = []
            var finalWasWrittenLive = false
            let payload = try client.debug(
                PlayCoverRuntimeDebugArguments(
                    script: options.script,
                    reset: options.reset,
                    stream: options.stream
                ),
                onEvent: { event in
                    if liveOutputEnabled {
                        FileHandle.standardError.write(
                            Data((event + "\n").utf8)
                        )
                    } else {
                        liveEvents.append(event)
                    }
                },
                onFinal: { final in
                    guard options.stream, liveOutputEnabled else {
                        return
                    }
                    if json {
                        let fields: [String: MachineValue] = [
                            "display": .string(final.display),
                            "agent": .string(final.agent),
                            "events": .array(
                                final.events.map(MachineValue.string)
                            ),
                        ]
                        let result = MachineOutput.success(
                            command: "debug",
                            data: .object(fields)
                        )
                        outputSink?(result.stdout)
                    } else if !final.display.isEmpty {
                        outputSink?(final.display + "\n")
                    }
                    finalWasWrittenLive = true
                }
            )
            if !liveOutputEnabled {
                liveEvents.append(contentsOf: payload.events.dropFirst(liveEvents.count))
            }
            let eventText = liveEvents.joined(separator: "\n")
            if finalWasWrittenLive {
                return CLIResult(exitCode: 0)
            }
            if json {
                var fields: [String: MachineValue] = [
                    "display": .string(payload.display),
                    "agent": .string(payload.agent),
                ]
                fields["events"] = .array(
                    payload.events.map(MachineValue.string)
                )
                let result = MachineOutput.success(
                    command: "debug",
                    data: .object(fields)
                )
                return CLIResult(
                    exitCode: result.exitCode,
                    stdout: result.stdout,
                    stderr: result.stderr
                        + (eventText.isEmpty ? "" : eventText + "\n")
                )
            }
            return CLIResult(
                exitCode: 0,
                stdout: payload.display.isEmpty
                    ? ""
                    : payload.display + "\n",
                stderr: eventText.isEmpty ? "" : eventText + "\n"
            )
        } catch {
            let mutationMayHaveApplied =
                Self.debugMutationMayHaveApplied(error)
            if json {
                return commandFailure(
                    command: "debug",
                    error: error,
                    json: true,
                    mutationMayHaveApplied:
                        mutationMayHaveApplied
                )
            }
            return CLIErrorEnvelope(
                message: Self.debugFailureMessage(
                    error,
                    mutationMayHaveApplied:
                        mutationMayHaveApplied
                ),
                exitCode: 1
            ).render()
        }
    }

    private func executeUITree(
        _ options: UITreeOptions,
        paths: IOSUsePaths,
        json: Bool
    ) -> CLIResult {
        do {
            let payload = try PlayCoverUITreeService.run(
                options: options,
                paths: paths
            )
            if json {
                return MachineOutput.success(
                    command: "ui-tree",
                    data: PlayCoverUITreeService.machineData(payload)
                )
            }
            return CLIResult(
                exitCode: 0,
                stdout: PlayCoverUITreeService.format(payload)
            )
        } catch {
            return commandFailure(
                command: "ui-tree",
                error: error,
                json: json
            )
        }
    }

    static func debugMutationMayHaveApplied(
        _ error: Error
    ) -> Bool {
        guard let runtimeError =
                error as? PlayCoverRuntimeClientError else {
            return false
        }
        switch runtimeError {
        case .remoteError(let code, _, _):
            return code == "frida_eval_failed"
                || code == "frida_reset_failed"
                || code == "frida_eval_timeout"
                || code == "frida_invalid_query"
        case .readFailed,
             .unexpectedEOF,
             .emptyResponseFrame,
             .responseFrameTooLarge,
             .responseIsNotUTF8,
             .responseDecodingFailed,
             .requestIDMismatch,
             .sessionIDMismatch,
             .responseIdentityMismatch,
             .malformedResponse:
            return true
        case .timeout(let operation):
            return operation.hasPrefix("response ")
        default:
            return false
        }
    }

    static func debugFailureMessage(
        _ error: Error,
        mutationMayHaveApplied: Bool
    ) -> String {
        var lines = ["\(error)"]
        if case PlayCoverRuntimeClientError.remoteError(
            _, _, let details
        ) = error {
            lines.append(
                contentsOf: (details?.suggestions ?? [])
                    .filter {
                        !$0.localizedCaseInsensitiveContains(
                            "debug --reset"
                        )
                    }
                    .map { "Suggestion: \($0)" }
            )
        }
        if mutationMayHaveApplied {
            lines.append(
                "Debug execution may have installed hooks or changed "
                    + "Agent/App state before failing. Run "
                    + "`ios-use debug --reset` before continuing if you "
                    + "need a clean Agent. Reset does not undo arbitrary "
                    + "App object or native-memory changes."
            )
        }
        return lines.joined(separator: "\n")
    }

    private func commandFailure(
        command: String,
        error: Error,
        json: Bool,
        exitCode: Int32 = 1,
        mutationMayHaveApplied: Bool? = nil
    ) -> CLIResult {
        if json {
            return MachineOutput.failure(
                command: command,
                error: error,
                data: machineDriverErrorData(error),
                exitCode: exitCode,
                mutationMayHaveApplied: mutationMayHaveApplied
            )
        }
        return CLIErrorEnvelope(message: "\(error)", exitCode: exitCode).render()
    }

    private func machineParseHelp(arguments: [String]) -> MachineValue {
        .object(["help": .string(CLIHelp.parseErrorHelp(arguments: arguments))])
    }

    static func isAppNotRunningError(_ error: Error) -> Bool {
        isAppNotRunningErrorMessage(String(describing: error))
    }

    static func isAppNotRunningErrorMessage(_ message: String) -> Bool {
        return message.range(of: #"not running|already terminated|no such process|state=1|state=0"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static var helpText: String {
        CLIHelp.rootText
    }
}
