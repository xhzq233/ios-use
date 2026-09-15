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
                return executeAttachment(options, paths: try attachmentPaths(invocation.deviceID), command: command, json: json)
            case .start(let options) where options.endpoint != nil:
                return executeAttachment(options.endpoint!, paths: try attachmentPaths(invocation.deviceID), command: command, json: json)
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
                            "lifecycleOwner": .string("external"),
                            "driverHost": context.info.driverHost.map(MachineValue.string) ?? .null,
                            "driverPort": context.info.driverPort.map(MachineValue.integer) ?? .null,
                            "versionMatchesCli": .null
                        ]) })
                    ]))
                }
                let output = contexts.map { "\($0.deviceID) attached (external) \($0.info.driverHost ?? ""):\($0.info.driverPort ?? 0)" }.joined(separator: "\n")
                return CLIResult(exitCode: 0, stdout: contexts.isEmpty ? "No attached Devices. Run ios-use start -d <id> --host <host> --port <port>.\n" : output + "\n")
            case .driver, .appLifecycle, .detach, .stop:
                let context = try DeviceContextStore.activeContext(explicitDeviceID: invocation.deviceID, paths: paths)
                guard context.info.isAttached else {
                    throw CLIParseError.invalidValue("Linux requires a TCP attachment. Run ios-use start -d <id> --host <host> --port <port>.")
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
                throw CLIParseError.invalidValue("\(command) is unavailable on Linux. Start and manage the device through its provider, then use ios-use start -d <id> --host <host> --port <port> for UI operations.")
            }
        } catch {
            return commandFailure(command: command, error: error, json: json)
        }
    }

    private func attachmentPaths(_ deviceID: String?) throws -> IOSUsePaths {
        guard let deviceID else { throw CLIParseError.missingRequiredOption("--device") }
        guard deviceID != DeviceContextStore.macDeviceID else {
            throw CLIParseError.invalidValue("The Device ID mac is reserved. Choose another TCP alias.")
        }
        return try paths.deviceContext(deviceID)
    }
}
