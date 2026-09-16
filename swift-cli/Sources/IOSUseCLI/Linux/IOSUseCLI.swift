import Foundation

/// Linux uses shared Driver and Apple device services over provider connections.
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
        if arguments.first == XCTestSessionHolderService.commandName || arguments.first == AppLogCaptureService.helperCommandName {
            do {
                let output = arguments.first == XCTestSessionHolderService.commandName
                    ? try XCTestSessionHolderService.run(arguments: Array(arguments.dropFirst()), paths: paths)
                    : try AppLogCaptureService.runHelper(arguments: Array(arguments.dropFirst()), paths: paths)
                return CLIResult(exitCode: 0, stdout: output)
            } catch { return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render() }
        }
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
            case .start(let options) where options.connectionPath != nil:
                let connection = try RemoteDeviceConnection.load(path: options.connectionPath!)
                let targetPaths = try remotePaths(invocation.deviceID ?? connection.udid)
                let output = try RemoteDeviceService.start(connectionPath: options.connectionPath!, paths: targetPaths, verbose: options.verbose)
                return json ? MachineOutput.success(command: command, data: .object([
                    "deviceId": .string(targetPaths.deviceID!), "status": .string("running"), "lifecycleOwner": .string("ios-use")
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
                            "status": .string("running"),
                            "lifecycleOwner": .string("ios-use"),
                            "driverHost": context.info.driverHost.map(MachineValue.string) ?? .null,
                            "driverPort": context.info.driverPort.map(MachineValue.integer) ?? .null,
                            "versionMatchesCli": .null
                        ]) })
                    ]))
                }
                let output = contexts.map { "\($0.deviceID) running (ios-use) \($0.info.driverHost ?? ""):\($0.info.driverPort ?? 0)" }.joined(separator: "\n")
                return CLIResult(exitCode: 0, stdout: contexts.isEmpty ? "No active Devices. Use start --connection <file>.\n" : output + "\n")
            case .driver, .appLifecycle, .stop, .apps, .install, .uninstall, .open:
                let context = try DeviceContextStore.activeContext(explicitDeviceID: invocation.deviceID, paths: paths)
                guard context.info.remoteConnection != nil else {
                    throw CLIParseError.invalidValue("Linux requires a remote device connection.")
                }
                return try RemoteDeviceConnection.$current.withValue(context.info.remoteConnection) {
                    switch invocation.command {
                    case .driver(let action):
                        return executeDriver(action, paths: context.paths, json: json)
                    case .appLifecycle(let options):
                        return executeAppLifecycle(options, paths: context.paths, json: json)
                    case .apps(let options):
                        let result = try AppManagementService.listResult(options: options, paths: context.paths)
                        return json ? MachineOutput.success(command: command, data: AppManagementService.machineAppsData(result))
                            : CLIResult(exitCode: 0, stdout: try AppManagementService.formatListResult(result, json: false))
                    case .install(let options):
                        let result = try AppManagementService.installResult(options: options, paths: context.paths)
                        return json ? MachineOutput.success(command: command, data: AppManagementService.machineInstallData(result))
                            : CLIResult(exitCode: 0, stdout: AppManagementService.formatInstallResult(result, verbose: options.verbose))
                    case .uninstall(let options):
                        let output = try AppManagementService.uninstall(options: options, paths: context.paths)
                        return json ? MachineOutput.success(command: command, data: .object(["display": .string(output)]))
                            : CLIResult(exitCode: 0, stdout: output)
                    case .open(let options):
                        return executeOpen(options, paths: context.paths, json: json)
                    case .stop:
                        let output = try RemoteDeviceService.stop(info: context.info, paths: context.paths)
                        return json ? MachineOutput.success(command: command, data: .object(["status": .string("stopped")]))
                            : CLIResult(exitCode: 0, stdout: output)
                    default:
                        throw CLIParseError.invalidValue("\(command) is unavailable on Linux.")
                    }
                }
            default:
                throw CLIParseError.invalidValue("\(command) is unavailable on Linux. Use start --connection <file> for remote App services and UI operations.")
            }
        } catch {
            return commandFailure(command: command, error: error, json: json)
        }
    }

    private func remotePaths(_ deviceID: String) throws -> IOSUsePaths {
        guard deviceID != DeviceContextStore.macDeviceID else {
            throw CLIParseError.invalidValue("The Device ID mac is reserved. Choose another device alias.")
        }
        return try paths.deviceContext(deviceID)
    }
}
