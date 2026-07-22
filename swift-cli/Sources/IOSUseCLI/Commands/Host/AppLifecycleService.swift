import Foundation
import IOSUseProtocol

enum AppLifecycleService {
    struct Result {
        let message: String
        let didTerminateApp: Bool?
        let dom: ForyDomPayload?
        let targetUdid: String?
        let deviceType: String?
        let readiness: ForyWaitAppForegroundPayload?
        let logFile: String?
        let logCapturePid: Int32?

        init(
            message: String,
            didTerminateApp: Bool? = nil,
            dom: ForyDomPayload? = nil,
            targetUdid: String? = nil,
            deviceType: String? = nil,
            readiness: ForyWaitAppForegroundPayload? = nil,
            logFile: String? = nil,
            logCapturePid: Int32? = nil
        ) {
            self.message = message
            self.didTerminateApp = didTerminateApp
            self.dom = dom
            self.targetUdid = targetUdid
            self.deviceType = deviceType
            self.readiness = readiness
            self.logFile = logFile
            self.logCapturePid = logCapturePid
        }

        func withTarget(udid: String, deviceType: String) -> Result {
            Result(
                message: message,
                didTerminateApp: didTerminateApp,
                dom: dom,
                targetUdid: udid,
                deviceType: deviceType,
                readiness: readiness,
                logFile: logFile,
                logCapturePid: logCapturePid
            )
        }
    }

    struct ReadinessError: Error, CustomStringConvertible {
        let hostResult: Result
        let underlying: Error

        var description: String {
            "Host lifecycle mutation was dispatched (\(hostResult.message)); readiness failed: \(underlying)"
        }
    }

    static var realDeviceRunnerForTesting: ((AppLifecycleOptions, String) throws -> Result)?
    static var simulatorRunnerForTesting: ((AppLifecycleOptions, String) throws -> Result)?

    static func run(options: AppLifecycleOptions, paths: IOSUsePaths) throws -> Result {
        let activeDriver = SessionService.read(paths: paths)
        let udid = try SessionService.resolveTargetUdid(
            explicitUdid: options.session.udid,
            paths: paths,
            missingMessage: "\(options.action.commandName) requires --udid or an active driver. Run `ios-use start` or pass `--udid <UDID>`."
        )
        let deviceType = activeDriver?.udid == udid
            ? activeDriver?.deviceType
            : (DeviceService.looksLikeSimulatorUDID(udid) ? "simulator" : "real")

        let result: Result
        switch deviceType {
        case "simulator":
            result = try runSimulator(options: options, udid: udid, paths: paths)
        case "real":
            result = try runRealDevice(options: options, udid: udid, paths: paths)
        default:
            throw CLIParseError.invalidValue("Invalid driver.lock: unknown deviceType \(deviceType ?? "(missing)").")
        }
        return result.withTarget(udid: udid, deviceType: deviceType!)
    }

    /// Compose a host-side lifecycle mutation with the shared driver
    /// `waitAppForeground` readiness command. Returns L2 by default; with
    /// `--no-wait` it returns at L0 without contacting the driver.
    static func runWithReadiness(options: AppLifecycleOptions, paths: IOSUsePaths) throws -> Result {
        guard options.action == .activate else {
            return try run(options: options, paths: paths)
        }
        if options.noWait {
            return try run(options: options, paths: paths)
        }
        // Preflight: a matching active driver is required for default L2 readiness.
        guard let activeDriver = SessionService.read(paths: paths) else {
            throw CLIParseError.invalidValue("activateApp requires an active driver for UI readiness. Run `ios-use start`, or use --no-wait for host-only launch.")
        }
        let udid = try SessionService.resolveTargetUdid(
            explicitUdid: options.session.udid,
            paths: paths,
            missingMessage: "activateApp requires --udid or an active driver. Run `ios-use start` or pass `--udid <UDID>`. Use --no-wait for host-only launch."
        )
        guard activeDriver.udid == udid else {
            throw CLIParseError.invalidValue("activateApp target \(udid) does not match active Driver target \(activeDriver.udid). Run `ios-use stop` and `ios-use start \(udid)`, or use --no-wait for host-only launch.")
        }
        // Host mutation first (may start log recording).
        let hostResult = try run(options: options, paths: paths)
        // Then wait for L2 through the driver.
        let readiness: ForyWaitAppForegroundPayload
        do {
            readiness = try DriverCommandExecution.withLockedClient(paths: paths, verbose: options.session.verbose) { client in
                try client.waitAppForeground(
                    expectedBundleId: options.bundleID,
                    timeout: 0,
                    returnDom: options.dom
                )
            }
        } catch {
            throw ReadinessError(hostResult: hostResult, underlying: error)
        }
        guard readiness.snapshotReady else {
            throw ReadinessError(
                hostResult: hostResult,
                underlying: CLIParseError.invalidValue("Driver returned readiness without a successful snapshot")
            )
        }
        var message = hostResult.message
        if !message.hasSuffix("\n") { message += "\n" }
        message += String(
            format: "Readiness: UI ready | active: %@ | elapsed: %.4fs",
            locale: Locale(identifier: "en_US_POSIX"),
            readiness.activeBundleId,
            readiness.elapsed
        )
        return Result(
            message: message,
            didTerminateApp: hostResult.didTerminateApp,
            dom: readiness.dom,
            targetUdid: hostResult.targetUdid,
            deviceType: hostResult.deviceType,
            readiness: readiness,
            logFile: hostResult.logFile,
            logCapturePid: hostResult.logCapturePid
        )
    }

    static func machineData(options: AppLifecycleOptions, result: Result) -> MachineValue {
        let mutationDispatched = options.action == .activate || result.didTerminateApp != false
        var data: [String: MachineValue] = [
            "action": .string(options.action.commandName),
            "bundleId": .string(options.bundleID),
            "deviceUdid": result.targetUdid.map(MachineValue.string) ?? .null,
            "deviceType": result.deviceType.map(MachineValue.string) ?? .null,
            "mutationDispatched": .boolean(mutationDispatched),
            "didTerminateApp": result.didTerminateApp.map(MachineValue.boolean) ?? .null,
            "logFile": result.logFile.map(MachineValue.string) ?? .null,
            "logCapturePid": result.logCapturePid.map { .integer(Int($0)) } ?? .null,
        ]
        if let readiness = result.readiness {
            data["readiness"] = machineReadiness(readiness)
        } else {
            data["readiness"] = .null
        }
        return .object(data)
    }

    static func machineReadiness(_ readiness: ForyWaitAppForegroundPayload) -> MachineValue {
        .object([
            "expectedBundleId": .string(readiness.expectedBundleId),
            "activeBundleId": .string(readiness.activeBundleId),
            "appState": .string(appStateName(readiness.appState)),
            "appStateCode": .integer(Int(readiness.appState)),
            "snapshotReady": .boolean(readiness.snapshotReady),
            "elapsed": .double(readiness.elapsed),
            "dom": readiness.dom.map(machineDom) ?? .null,
        ])
    }

    private static func appStateName(_ rawValue: Int32) -> String {
        switch IOSUseAppState(rawValue: rawValue) {
        case .unknown: return "unknown"
        case .notRunning: return "notRunning"
        case .suspended: return "suspended"
        case .background: return "background"
        case .foreground: return "foreground"
        case nil: return "unknown"
        }
    }

    private static func runSimulator(options: AppLifecycleOptions, udid: String, paths: IOSUsePaths) throws -> Result {
        if let simulatorRunnerForTesting {
            return try simulatorRunnerForTesting(options, udid)
        }
        switch options.action {
        case .activate:
            if options.log {
                return try AppLogCaptureService.start(bundleID: options.bundleID, udid: udid, deviceType: "simulator", paths: paths)
            }
            try SimulatorService.activateApp(bundleID: options.bundleID, udid: udid, terminateExisting: options.terminateExisting)
            return Result(message: "App \(options.bundleID) activated")
        case .terminate:
            let terminated = try SimulatorService.terminateApp(bundleID: options.bundleID, udid: udid)
            return try resultForTerminate(bundleID: options.bundleID, udid: udid, terminated: terminated, paths: paths)
        }
    }

    private static func runRealDevice(options: AppLifecycleOptions, udid: String, paths: IOSUsePaths) throws -> Result {
        if let realDeviceRunnerForTesting {
            return try realDeviceRunnerForTesting(options, udid)
        }
        let eventSink: ((String) -> Void)? = options.session.verbose
            ? { message in
                FileHandle.standardError.write(Data("[coredevice] \(message)\n".utf8))
            }
            : nil
        let runner = CoreDeviceAppLifecycleRunner(eventSink: eventSink)
        switch options.action {
        case .activate:
            if options.log {
                return try AppLogCaptureService.start(bundleID: options.bundleID, udid: udid, deviceType: "real", paths: paths)
            }
            try runner.activate(bundleID: options.bundleID, udid: udid, terminateExisting: options.terminateExisting)
            return Result(message: "App \(options.bundleID) activated")
        case .terminate:
            let terminated = try runner.terminate(bundleID: options.bundleID, udid: udid)
            return try resultForTerminate(bundleID: options.bundleID, udid: udid, terminated: terminated, paths: paths)
        }
    }

    private static func resultForTerminate(bundleID: String, udid: String, terminated: Bool, paths: IOSUsePaths) throws -> Result {
        var message = terminated
            ? "App \(bundleID) terminated"
            : "App \(bundleID) not running, skipped terminate"
        if terminated, let captureMessage = try AppLogCaptureService.observeStopAfterTerminate(bundleID: bundleID, udid: udid, paths: paths) {
            message += "\n\(captureMessage)"
        }
        return Result(message: message, didTerminateApp: terminated)
    }
}

protocol CoreDeviceAppLifecycleServicing {
    func launchApplication(
        bundleID: String,
        arguments: [String],
        terminateExisting: Bool,
        startSuspended: Bool,
        environment: [String: String],
        payloadURL: String?,
        activates: Bool?,
        standardIOIdentifier: UUID?
    ) throws -> RemoteXPCValue
    func listProcesses() throws -> [CoreDeviceProcessToken]
    func kill(processIdentifier: Int) throws
    func close()
}

extension CoreDeviceAppService: CoreDeviceAppLifecycleServicing {
    func launchApplication(
        bundleID: String,
        arguments: [String],
        terminateExisting: Bool,
        startSuspended: Bool,
        environment: [String: String],
        payloadURL: String?,
        activates: Bool?,
        standardIOIdentifier: UUID?
    ) throws -> RemoteXPCValue {
        try launchApplication(
            bundleID: bundleID,
            arguments: arguments,
            terminateExisting: terminateExisting,
            startSuspended: startSuspended,
            environment: environment,
            payloadURL: payloadURL,
            activates: activates,
            standardIOIdentifier: standardIOIdentifier,
            platformSpecificOptions: [:],
            activeUser: false
        )
    }
}

final class CoreDeviceAppLifecycleRunner {
    struct Dependencies {
        var startTunnel: (String) throws -> CoreDeviceLifecycleTunnelSession
        var openAppService: (CoreDeviceLifecycleTunnelSession) throws -> CoreDeviceAppLifecycleServicing
        var resolveBundleExecutable: (String, String) throws -> String?

        static let live = live(eventSink: nil)

        static func live(eventSink: ((String) -> Void)?) -> Dependencies {
            Dependencies(
                startTunnel: { try CoreDeviceDirectTunnelRuntime(eventSink: eventSink).start(udid: $0) },
                openAppService: { session in
                    try CoreDeviceAppService(client: session.connectRemoteXPCService(CoreDeviceAppService.serviceName))
                },
                resolveBundleExecutable: { udid, bundleID in
                    try InstallationProxyClient.withClient(udid: udid) { client in
                        try client.installedAppInfo(
                            bundleID: bundleID,
                            attributes: ["CFBundleIdentifier", "CFBundleExecutable"]
                        )?["CFBundleExecutable"] as? String
                    }
                }
            )
        }
    }

    private let dependencies: Dependencies
    private let eventSink: ((String) -> Void)?

    init(dependencies: Dependencies = .live, eventSink: ((String) -> Void)? = nil) {
        self.dependencies = dependencies
        self.eventSink = eventSink
    }

    convenience init(eventSink: ((String) -> Void)?) {
        self.init(dependencies: .live(eventSink: eventSink), eventSink: eventSink)
    }

    func activate(bundleID: String, udid: String, terminateExisting: Bool = false, standardIOIdentifier: UUID? = nil) throws {
        try withTunnel(udid: udid) { session in
            try withAppServiceInvocation(session: session) { appService in
                eventSink?("launching app bundle=\(bundleID) terminateExisting=\(terminateExisting)")
                _ = try appService.launchApplication(
                    bundleID: bundleID,
                    arguments: [],
                    terminateExisting: terminateExisting,
                    startSuspended: false,
                    environment: [:],
                    payloadURL: nil,
                    activates: true,
                    standardIOIdentifier: standardIOIdentifier
                )
            }
        }
    }

    func terminate(bundleID: String, udid: String) throws -> Bool {
        eventSink?("resolving executable for bundle=\(bundleID)")
        let executableName = try? dependencies.resolveBundleExecutable(udid, bundleID)
        eventSink?("resolved executable=\(executableName ?? "(unknown)")")
        return try withTunnel(udid: udid) { session in
            let processes = try withAppServiceInvocation(session: session) { appService in
                eventSink?("listing processes")
                return try appService.listProcesses()
            }
            let matching = processes.filter { token in
                Self.process(token, matchesBundleID: bundleID, executableName: executableName)
            }
            for process in matching {
                eventSink?(
                    "matched process pid=\(process.processIdentifier) executable=\(process.executable) bundle=\(process.bundleIdentifier ?? "(none)")"
                )
            }
            guard !matching.isEmpty else { return false }
            var killedAny = false
            for process in matching {
                do {
                    eventSink?("sending SIGKILL pid=\(process.processIdentifier)")
                    try withAppServiceInvocation(session: session) { appService in
                        try appService.kill(processIdentifier: process.processIdentifier)
                    }
                    killedAny = true
                } catch {
                    guard Self.isAlreadyTerminatedError(error) else {
                        throw error
                    }
                }
            }
            return killedAny
        }
    }

    private static func process(_ token: CoreDeviceProcessToken, matchesBundleID bundleID: String, executableName: String?) -> Bool {
        if token.bundleIdentifier == bundleID {
            return true
        }
        guard let executableName, !executableName.isEmpty else {
            return false
        }
        return executableBasename(token.executable) == executableName
    }

    private static func executableBasename(_ executable: String) -> String {
        if let url = URL(string: executable), url.scheme != nil {
            return url.lastPathComponent
        }
        return URL(fileURLWithPath: executable).lastPathComponent
    }

    private static func isAlreadyTerminatedError(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.range(
            of: #"not running|already terminated|no such process|state=1|state=0"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func withTunnel<T>(
        udid: String,
        _ body: (CoreDeviceLifecycleTunnelSession) throws -> T
    ) throws -> T {
        let session = try dependencies.startTunnel(udid)
        defer {
            session.close()
            _ = session.waitForClose(timeoutSeconds: 1)
        }
        guard session.peerInfo != nil else {
            throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
        }
        if let info = session.peerInfo, info.services[CoreDeviceAppService.serviceName] == nil {
            throw CLIParseError.invalidValue("CoreDevice appservice not available on this device. Try re-plugging the device, clearing trust, and re-pairing.")
        }
        return try body(session)
    }

    private func withAppServiceInvocation<T>(
        session: CoreDeviceLifecycleTunnelSession,
        _ body: (CoreDeviceAppLifecycleServicing) throws -> T
    ) throws -> T {
        // CoreDevice closes this RemoteXPC stream when it is reused for another
        // invocation. Reuse the tunnel, but scope appservice to one invocation.
        eventSink?("opening CoreDevice appservice")
        let appService = try dependencies.openAppService(session)
        defer { appService.close() }
        return try body(appService)
    }
}
