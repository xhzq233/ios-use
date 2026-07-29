import Foundation
import IOSUseProtocol

public struct IOSUseCLI: Sendable {
    public typealias CLIOutputSink = @Sendable (String) -> Void
    typealias PlayCoverSignerInitializer =
        @Sendable () throws -> PlayCoverSigningIdentityEvidence

    public static let version = "1.3.4"
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

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, outputSink: CLIOutputSink? = nil) {
        self.init(
            environment: environment,
            outputSink: outputSink,
            playCoverSignerInitializer: {
                try PlayCoverSigningIdentityService()
                    .initializeForConfiguration()
            }
        )
    }

    init(
        environment: [String: String],
        outputSink: CLIOutputSink? = nil,
        playCoverSignerInitializer:
            @escaping PlayCoverSignerInitializer
    ) {
        self.paths = IOSUsePaths.resolve(environment: environment)
        self.outputSink = outputSink
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
                appendPerformanceLog(
                    command: command,
                    ok: finalized.exitCode == 0,
                    totalElapsedMs: totalElapsedMs,
                    snapshot: performanceCollector.snapshot()
                )
                return finalized
            }
        }
    }

    private func executePublicInvocation(
        arguments: [String]
    ) -> CLIResult {
        let (machineArguments, wantsJSON) = CLIParser.extractGlobalJSONFlag(arguments)
        if let immediate = CLIHelp.immediateResult(arguments: machineArguments) {
            return immediate
        }

        guard let first = arguments.first else {
            return CLIResult(exitCode: 0, stdout: Self.helpText)
        }
        let machineCommand = machineArguments.first ?? first
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
            return execute(invocation.command, json: invocation.json)
        }
    }

    private func performanceCommandName(arguments: [String]) -> String {
        let normalized = CLIParser.extractGlobalJSONFlag(arguments).0
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

    private func execute(_ parsed: ParsedCommand, json: Bool) -> CLIResult {
        if let routedFailure = playCoverRoutingFailure(for: parsed, json: json) {
            return routedFailure
        }
        switch parsed {
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
        case .config(let options) where options.playCover:
            return executePlayCoverConfiguration(json: json)
        case .config(let options) where options.list:
            return CLIResult(exitCode: 0, stdout: ConfigService.formatList(ConfigService.listEntries(paths: paths)))
        case .config(let options) where options.simulator:
            do {
                return CLIResult(exitCode: 0, stdout: try ConfigService.configureSimulator(udid: options.udid, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .config(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try ConfigService.configureDevice(options: options, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .start(let options):
            do {
                let output: String
                if options.mac {
                    output = try SessionService.startPlayCover(
                        appPath: options.appPath,
                        captureStdio: options.log,
                        timeout: options.timeout,
                        paths: paths
                    )
                } else {
                    output = try SessionService.start(
                        udid: options.udid,
                        paths: paths,
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
        case .install(let options):
            do {
                let result = try AppManagementService.installResult(options: options, paths: paths)
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
                return CLIResult(exitCode: 0, stdout: try AppManagementService.uninstall(options: options, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .apps(let options):
            do {
                let result = try AppManagementService.listResult(options: options, paths: paths)
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
                return CLIResult(exitCode: 0, stdout: try DeveloperDiskImageService.mount(options: options, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .open(let options):
            return executeOpen(options, json: json)
        case .appLifecycle(let options):
            return executeAppLifecycle(options, json: json)
        case .oslog(let options):
            return executeOSLog(options)
        case .nslog(let options):
            do {
                switch options.command {
                case .stream:
                    return CLIResult(exitCode: 0, stdout: try NSLogService.stream(options: options, paths: paths))
                case .start:
                    return CLIResult(exitCode: 0, stdout: try NSLogService.start(options: options, paths: paths))
                case .read:
                    return CLIResult(exitCode: 0, stdout: try NSLogService.read(options: options, paths: paths))
                case .stop:
                    return CLIResult(exitCode: 0, stdout: try NSLogService.stop(paths: paths))
                }
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .stop:
            do {
                let output = try SessionService.stop(paths: paths)
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
            return CLIResult(exitCode: 0, stdout: ProxyService.doctor(paths: paths))
        case .proxy(.configca(let markTrusted)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.configCA(markTrusted: markTrusted, paths: paths))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.start(let interfaceName, let serverOnly)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.start(interfaceName: interfaceName, serverOnly: serverOnly, paths: paths))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.read(let filter, let raw, let last)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.read(filter: filter, raw: raw, last: last, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.stop(let serverOnly)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.stop(serverOnly: serverOnly, paths: paths))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .driver(let action):
            return executeDriver(action, json: json)
        case .capture(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try CaptureService.run(options: options, paths: paths))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .mediaImport(let options):
            do {
                let result = try MediaImportService.run(options: options, paths: paths)
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
                Mac backend PlayCover-derived signing identity is ready.
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
        json: Bool
    ) -> CLIResult? {
        let active: SessionService.Info?
        do {
            active = try SessionService.readDriverLockInfo(
                paths: paths
            )
        } catch {
            switch command {
            case .status, .config, .start, .stop:
                return nil
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
        case .status, .config, .start, .stop, .capture, .open, .oslog:
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
            case .dom, .inspect, .screenshot, .waitFor,
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
            }
        default:
            return commandFailure(
                command: command.commandName,
                error: PlayCoverBackendError.capabilityUnavailable(command.commandName),
                json: json
            )
        }
    }

    private func executeOpen(_ options: OpenURLOptions, json: Bool, hostDeviceTypeHint: String? = nil) -> CLIResult {
        do {
            let result: OpenURLService.OpenResult
            if options.dom {
                result = try OpenURLService.openWithDom(url: options.url, session: options.session, paths: paths)
            } else {
                let validatedURL = try OpenURLService.validatedURL(options.url)
                let resolved: OpenURLService.OpenResult?
                if options.session.udid != nil || hostDeviceTypeHint != nil {
                    resolved = try OpenURLService.openHostSideIfAvailable(url: validatedURL, udid: options.session.udid, deviceType: hostDeviceTypeHint, paths: paths)
                        ?? OpenURLService.openHostSideIfAvailable(url: validatedURL, session: options.session, paths: paths)
                } else {
                    resolved = try OpenURLService.openHostSideIfAvailable(url: validatedURL, session: options.session, paths: paths)
                }
                guard let resolved else {
                    throw CLIParseError.invalidValue("open target is unavailable. Pass a USB real device UDID, pass a booted Simulator UDID, or run `ios-use start` first.")
                }
                result = resolved
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

    private func executeAppLifecycle(_ options: AppLifecycleOptions, json: Bool) -> CLIResult {
        do {
            let result = try AppLifecycleService.runWithReadiness(options: options, paths: paths)
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

    private func executeOSLog(_ options: OSLogOptions, hostDeviceTypeHint: String? = nil) -> CLIResult {
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

    private func executeDriver(_ action: DriverAction, json: Bool) -> CLIResult {
        let session = LockedDriverClientSession(paths: paths)
        defer { session.close() }
        do {
            let result = try DriverCommandExecutor.execute(action: action, paths: paths) { body in
                try session.run(body)
            }
            if json {
                let output = result.machineOutput(for: action)
                return MachineOutput.success(command: action.name, data: output.data, warnings: output.warnings)
            }
            return CLIResult(exitCode: 0, stdout: result.stdout)
        } catch {
            let evidence = DriverFailureEvidence.collect(to: error, action: action, session: session, paths: paths)
            if json {
                return MachineOutput.failure(
                    command: action.name,
                    error: error,
                    data: machineDriverErrorData(error),
                    evidenceManifest: evidence.manifestPath
                )
            }
            return CLIErrorEnvelope(message: evidence.renderedMessage, exitCode: 1).render()
        }
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
