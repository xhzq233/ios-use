import Foundation
import IOSUseProtocol

extension IOSUseCLI {
    func executeDriver(
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
                return try DriverCommandExecutor.execute(
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

    func executeAppLifecycle(
        _ options: AppLifecycleOptions,
        paths: IOSUsePaths,
        json: Bool
    ) -> CLIResult {
        do {
            let result = try DeviceCommandLock.withExclusiveLock(
                paths: paths
            ) {
                return try AppLifecycleService.runWithReadiness(
                    options: options,
                    paths: paths
                )
            }
            if json {
                return MachineOutput.success(
                    command: options.action.commandName,
                    data: AppLifecycleService.machineData(options: options, result: result)
                )
            }
            var stdout = "\(result.message)\n"
            if let dom = result.dom {
                stdout += "\n" + DriverOutput.formatDom(dom) + "\n"
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

    func commandFailure(
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

    static func isAppNotRunningError(_ error: Error) -> Bool {
        isAppNotRunningErrorMessage(String(describing: error))
    }

    static func isAppNotRunningErrorMessage(_ message: String) -> Bool {
        return message.range(of: #"not running|already terminated|no such process|state=1|state=0"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
