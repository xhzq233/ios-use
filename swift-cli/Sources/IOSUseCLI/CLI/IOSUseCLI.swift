import Foundation
import IOSUseProtocol

public struct IOSUseCLI: Sendable {
    public typealias CLIOutputSink = @Sendable (String) -> Void

    public static let version = "1.2.1"
    static var driverClientFactoryForTesting: ((SessionService.Info) -> DriverCommandClient)? {
        get { DriverCommandExecution.clientFactoryForTesting }
        set { DriverCommandExecution.clientFactoryForTesting = newValue }
    }

    public let paths: IOSUsePaths
    public let outputSink: CLIOutputSink?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, outputSink: CLIOutputSink? = nil) {
        self.paths = IOSUsePaths.resolve(environment: environment)
        self.outputSink = outputSink
    }

    public func run(arguments: [String]) -> CLIResult {
        if let immediate = CLIHelp.immediateResult(arguments: arguments) {
            return immediate
        }

        guard let first = arguments.first else {
            return CLIResult(exitCode: 0, stdout: Self.helpText)
        }
        switch first {
        case _ where first.hasPrefix("-"):
            return CLIErrorEnvelope(message: "unknown option '\(first)'").render()
        default:
            do {
                let parsed = try CLIParser.parse(arguments)
                return execute(parsed)
            } catch let error as CLIParseError {
                return CLIErrorEnvelope(message: error.description).render()
            } catch {
                return CLIErrorEnvelope(message: "\(error)").render()
            }
        }
    }

    private func execute(_ parsed: ParsedCommand) -> CLIResult {
        switch parsed {
        case .devices(let options):
            return listDevices(options)
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
                return CLIResult(exitCode: 0, stdout: try SessionService.start(udid: options.udid, paths: paths, verbose: options.verbose))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .install(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try AppManagementService.install(options: options, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .uninstall(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try AppManagementService.uninstall(options: options, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .apps(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try AppManagementService.list(options: options, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .open(let options):
            return executeOpen(options)
        case .oslog(let options):
            return executeOSLog(options)
        case .flow(let options):
            do {
                let stdout = try FlowService.run(file: options.file, options: options, paths: paths, outputSink: outputSink)
                return CLIResult(exitCode: 0, stdout: outputSink == nil ? stdout : "")
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
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
                return CLIResult(exitCode: 0, stdout: try SessionService.stop(paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.doctor):
            return CLIResult(exitCode: 0, stdout: ProxyService.doctor(paths: paths))
        case .proxy(.configca(let markTrusted)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.configCA(markTrusted: markTrusted, paths: paths, outputSink: outputSink))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.start(let interfaceName, let serverOnly)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.start(interfaceName: interfaceName, serverOnly: serverOnly, paths: paths, outputSink: outputSink))
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
                return CLIResult(exitCode: 0, stdout: try ProxyService.stop(serverOnly: serverOnly, paths: paths, outputSink: outputSink))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .driver(let action):
            return executeDriver(action)
        }
    }

    private func executeOpen(_ options: OpenURLOptions, hostDeviceTypeHint: String? = nil) -> CLIResult {
        do {
            let validatedURL = try OpenURLService.validatedURL(options.url)
            let result: OpenURLService.OpenResult?
            if options.session.udid != nil || hostDeviceTypeHint != nil {
                result = try OpenURLService.openHostSideIfAvailable(url: validatedURL, udid: options.session.udid, deviceType: hostDeviceTypeHint, paths: paths)
                    ?? OpenURLService.openHostSideIfAvailable(url: validatedURL, session: options.session, paths: paths)
            } else {
                result = try OpenURLService.openHostSideIfAvailable(url: validatedURL, session: options.session, paths: paths)
            }
            guard let result else {
                throw CLIParseError.invalidValue("open target is unavailable. Pass a USB real device UDID, pass a booted Simulator UDID, or run `ios-use start <UDID>` first.")
            }
            return CLIResult(exitCode: 0, stdout: "\(result.message)\n")
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    private func executeOSLog(_ options: OSLogOptions, hostDeviceTypeHint: String? = nil) -> CLIResult {
        do {
            return CLIResult(exitCode: 0, stdout: try OSLogCommandService.run(options: options, paths: paths, hostDeviceTypeHint: hostDeviceTypeHint))
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    private func executeDriver(_ action: DriverAction) -> CLIResult {
        do {
            let result = try DriverCommandExecutor.execute(action: action, paths: paths) { body in
                try withLockedDriverClient(body)
            }
            return CLIResult(exitCode: 0, stdout: result.stdout)
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    private func withLockedDriverClient<T>(_ body: (DriverCommandClient) throws -> T) throws -> T {
        try DriverCommandExecution.withLockedClient(paths: paths, body)
    }

    private static func isRecoverableDriverConnectFailure(_ error: Error) -> Bool {
        (error as? DriverClientError)?.isRecoverableConnectFailure == true
    }

    static func isAppNotRunningError(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.range(of: #"not running|already terminated|no such process|state=1|state=0"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func listDevices(_ options: DeviceOptions) -> CLIResult {
        do {
            let devices = try DeviceService.listDevices(simulatorOnly: options.simulator, paths: paths)
            if devices.isEmpty {
                return CLIResult(exitCode: 0, stdout: options.simulator ? "No booted Simulators found\n" : "No connected real devices found\n")
            }
            let configured = DeviceService.configuredDevices(paths: paths)
            let lines = devices.map { DeviceService.format($0, configuredDevices: configured, verbose: options.verbose) }.joined(separator: "\n")
            return CLIResult(exitCode: 0, stdout: "\(lines)\n")
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    public static var helpText: String {
        CLIHelp.rootText
    }
}
