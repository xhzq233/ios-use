import Foundation

/// Linux dispatches the shared UI commands to caller-managed TCP drivers.
public struct IOSUseCLI: Sendable {
    public typealias CLIOutputSink = @Sendable (String) -> Void
    public let paths: IOSUsePaths

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        outputSink: CLIOutputSink? = nil,
        registerHomesForDiskUsage: Bool = false
    ) {
        paths = IOSUsePaths.resolve(environment: environment)
    }

    init(pathsForTesting paths: IOSUsePaths) { self.paths = paths }

    public static var helpText: String { CLIHelp.rootText }

    public func run(arguments: [String]) -> CLIResult {
        let state = CLIInvocationState()
        return CLIInvocationContext.$current.withValue(state) {
            let result = runInvocation(arguments)
            return MachineOutput.finalizeInvocation(
                result, expectsMachineOutput: CLIParser.requestsJSON(arguments), snapshot: state.snapshot()
            )
        }
    }

    private func runInvocation(_ arguments: [String]) -> CLIResult {
        let json = CLIParser.requestsJSON(arguments)
        let invocation: ParsedInvocation
        do {
            let withoutJSON = CLIParser.extractGlobalJSONFlag(arguments).0
            let publicArguments = try CLIParser.extractGlobalDeviceFlag(withoutJSON).0
            if let immediate = CLIHelp.immediateResult(arguments: publicArguments) { return immediate }
            invocation = try CLIParser.parseInvocation(arguments)
        } catch {
            if json { return MachineOutput.failure(command: arguments.first ?? "unknown", error: error, exitCode: 64) }
            return CLIErrorEnvelope(message: "\(error)").render(help: CLIHelp.parseErrorHelp(arguments: arguments))
        }
        let command = invocation.command.commandName
        do {
            switch invocation.command {
            case .attach(let options):
                CLIInvocationContext.current?.suppressAlertRefresh()
                guard let id = invocation.deviceID else { throw CLIParseError.missingRequiredOption("--device") }
                guard id != DeviceContextStore.macDeviceID else {
                    throw CLIParseError.invalidValue("The Device ID mac is reserved. Choose another TCP alias.")
                }
                let context = try paths.deviceContext(id)
                let output = try TCPAttachService.attach(options: options, paths: context)
                return json ? MachineOutput.success(command: command, data: .object([
                    "deviceId": .string(id), "host": .string(options.host),
                    "port": .integer(options.port), "status": .string("attached")
                ])) : CLIResult(exitCode: 0, stdout: output)
            case .status:
                let contexts: [DeviceContextStore.Context]
                if let id = invocation.deviceID {
                    contexts = [try DeviceContextStore.activeContext(explicitDeviceID: id, paths: paths)]
                } else { contexts = DeviceContextStore.sessions(paths: paths) }
                if json {
                    return MachineOutput.success(command: command, data: .object([
                        "cliVersion": .string(Self.version),
                        "devices": .array(contexts.map { context in .object([
                            "deviceId": .string(context.deviceID), "deviceType": .string(context.info.deviceType),
                            "status": .string("attached"),
                            "driverHost": context.info.driverHost.map(MachineValue.string) ?? .null,
                            "driverPort": context.info.driverPort.map(MachineValue.integer) ?? .null,
                            "versionMatchesCli": .null
                        ]) })
                    ]))
                }
                let output = contexts.map { "\($0.deviceID) attached \($0.info.driverHost ?? ""):\($0.info.driverPort ?? 0)" }.joined(separator: "\n")
                return CLIResult(exitCode: 0, stdout: contexts.isEmpty ? "No attached Devices. Run ios-use attach.\n" : output + "\n")
            case .driver, .appLifecycle, .detach, .stop:
                let context = try DeviceContextStore.activeContext(explicitDeviceID: invocation.deviceID, paths: paths)
                guard context.info.isAttached else {
                    throw CLIParseError.invalidValue("Linux requires a TCP attachment. Run ios-use attach.")
                }
                switch invocation.command {
                case .driver(let action):
                    return executeDriver(action, paths: context.paths, json: json)
                case .appLifecycle(let options):
                    return executeAppLifecycle(options, paths: context.paths, json: json)
                default:
                    CLIInvocationContext.current?.suppressAlertRefresh()
                    let output = try TCPAttachService.detach(paths: context.paths)
                    return json ? MachineOutput.success(command: command, data: .object([
                        "deviceId": .string(context.deviceID), "status": .string("detached")
                    ])) : CLIResult(exitCode: 0, stdout: output)
                }
            default:
                throw CLIParseError.invalidValue("\(command) is unavailable on Linux. Start and manage the device through its provider, then use ios-use attach for UI operations.")
            }
        } catch {
            return commandFailure(command: command, error: error, json: json)
        }
    }
}
