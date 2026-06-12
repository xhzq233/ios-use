import Foundation

enum AppLifecycleService {
    struct Result: Equatable {
        let message: String
        let didTerminateApp: Bool?

        init(message: String, didTerminateApp: Bool? = nil) {
            self.message = message
            self.didTerminateApp = didTerminateApp
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

        switch deviceType {
        case "simulator":
            return try runSimulator(options: options, udid: udid, paths: paths)
        case "real":
            return try runRealDevice(options: options, udid: udid, paths: paths)
        default:
            throw CLIParseError.invalidValue("Invalid driver.lock: unknown deviceType \(deviceType ?? "(missing)").")
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
        switch options.action {
        case .activate:
            if options.log {
                return try AppLogCaptureService.start(bundleID: options.bundleID, udid: udid, deviceType: "real", paths: paths)
            }
            try CoreDeviceAppLifecycleRunner().activate(bundleID: options.bundleID, udid: udid, terminateExisting: options.terminateExisting)
            return Result(message: "App \(options.bundleID) activated")
        case .terminate:
            let terminated = try CoreDeviceAppLifecycleRunner().terminate(bundleID: options.bundleID, udid: udid)
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

        static let live = Dependencies(
            startTunnel: { try CoreDeviceDirectTunnelRuntime(eventSink: nil).start(udid: $0) },
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

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func activate(bundleID: String, udid: String, terminateExisting: Bool = false, standardIOIdentifier: UUID? = nil) throws {
        try withAppService(udid: udid) { appService in
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

    func terminate(bundleID: String, udid: String) throws -> Bool {
        let executableName = try? dependencies.resolveBundleExecutable(udid, bundleID)
        return try withAppService(udid: udid) { appService in
            let processes = try appService.listProcesses()
            let matching = processes.filter { token in
                Self.process(token, matchesBundleID: bundleID, executableName: executableName)
            }
            guard !matching.isEmpty else { return false }
            var killedAny = false
            for process in matching {
                do {
                    try appService.kill(processIdentifier: process.processIdentifier)
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

    private func withAppService<T>(udid: String, _ body: (CoreDeviceAppLifecycleServicing) throws -> T) throws -> T {
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
        let appService = try dependencies.openAppService(session)
        defer { appService.close() }
        return try body(appService)
    }
}
