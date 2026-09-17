import Foundation
import IOSUseProtocol

extension IOSUseCLI {
    func executeOpen(
        _ options: OpenURLOptions,
        paths: IOSUsePaths,
        json: Bool,
        hostDeviceTypeHint: String? = nil
    ) -> CLIResult {
        do {
            let validatedURL = try OpenURLService.validatedURL(
                options.url
            )
            var observation: DomObservation.Output?
            let result = try DeviceCommandLock.withExclusiveLock(
                paths: paths
            ) { () throws -> OpenURLService.OpenResult in
                if options.dom || options.postDom != nil {
                    let observer = try DomObservation(paths: paths)
                    let result = try OpenURLService.openWithDom(
                        url: validatedURL,
                        bundleID: options.bundleID,
                        session: options.session,
                        paths: paths,
                        postDom: options.postDom
                    )
                    if let dom = result.dom {
                        do { observation = try observer.observe(dom, diff: options.postDom?.diff == true) }
                        catch { throw OpenURLService.ReadinessError(hostResult: result, underlying: error) }
                    }
                    return result
                }
                let resolved: OpenURLService.OpenResult?
                if options.session.udid != nil
                    || hostDeviceTypeHint != nil {
                    resolved = try OpenURLService
                        .openHostSideIfAvailable(
                            url: validatedURL,
                            bundleID: options.bundleID,
                            udid: options.session.udid,
                            deviceType: hostDeviceTypeHint,
                            paths: paths
                        )
                        ?? OpenURLService.openHostSideIfAvailable(
                            url: validatedURL,
                            bundleID: options.bundleID,
                            session: options.session,
                            paths: paths
                        )
                } else {
                    resolved = try OpenURLService
                        .openHostSideIfAvailable(
                            url: validatedURL,
                            bundleID: options.bundleID,
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
            if let observation { stdout += "\n" + observation.text }
            if json {
                return MachineOutput.success(command: "open", data: OpenURLService.machineData(result, observation: observation))
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
            var observation: DomObservation.Output?
            let result = try DeviceCommandLock.withExclusiveLock(
                paths: paths
            ) {
                let observer = options.dom || options.postDom != nil ? try DomObservation(paths: paths) : nil
                let result = try AppLifecycleService.runWithReadiness(
                    options: options,
                    paths: paths
                )
                if let dom = result.dom {
                    do { observation = try observer!.observe(dom, diff: options.postDom?.diff == true) }
                    catch { throw AppLifecycleService.ReadinessError(hostResult: result, underlying: error) }
                }
                return result
            }
            if json {
                return MachineOutput.success(
                    command: options.action.commandName,
                    data: AppLifecycleService.machineData(options: options, result: result, observation: observation)
                )
            }
            var stdout = "\(result.message)\n"
            if let observation { stdout += "\n" + observation.text }
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
