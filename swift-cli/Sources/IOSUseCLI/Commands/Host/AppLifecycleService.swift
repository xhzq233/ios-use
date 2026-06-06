import Foundation

enum AppLifecycleService {
    struct Result: Equatable {
        let message: String
    }

    static var realDeviceRunnerForTesting: ((AppLifecycleOptions.Action, String, String) throws -> Result)?
    static var simulatorRunnerForTesting: ((AppLifecycleOptions.Action, String, String) throws -> Result)?

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
            return try runSimulator(action: options.action, bundleID: options.bundleID, udid: udid)
        case "real":
            return try runRealDevice(action: options.action, bundleID: options.bundleID, udid: udid)
        default:
            throw CLIParseError.invalidValue("Invalid driver.lock: unknown deviceType \(deviceType ?? "(missing)").")
        }
    }

    private static func runSimulator(action: AppLifecycleOptions.Action, bundleID: String, udid: String) throws -> Result {
        if let simulatorRunnerForTesting {
            return try simulatorRunnerForTesting(action, bundleID, udid)
        }
        switch action {
        case .activate:
            try SimulatorService.activateApp(bundleID: bundleID, udid: udid)
            return Result(message: "App \(bundleID) activated")
        case .terminate:
            let terminated = try SimulatorService.terminateApp(bundleID: bundleID, udid: udid)
            return Result(message: terminated
                ? "App \(bundleID) terminated"
                : "App \(bundleID) not running, skipped terminate")
        }
    }

    private static func runRealDevice(action: AppLifecycleOptions.Action, bundleID: String, udid: String) throws -> Result {
        if let realDeviceRunnerForTesting {
            return try realDeviceRunnerForTesting(action, bundleID, udid)
        }
        switch action {
        case .activate:
            try CoreDeviceAppLifecycleRunner().activate(bundleID: bundleID, udid: udid)
            return Result(message: "App \(bundleID) activated")
        case .terminate:
            let terminated = try CoreDeviceAppLifecycleRunner().terminate(bundleID: bundleID, udid: udid)
            return Result(message: terminated
                ? "App \(bundleID) terminated"
                : "App \(bundleID) not running, skipped terminate")
        }
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
        activates: Bool?
    ) throws -> RemoteXPCValue
    func listProcesses() throws -> [CoreDeviceProcessToken]
    func kill(processIdentifier: Int) throws
    func close()
}

extension CoreDeviceAppService: CoreDeviceAppLifecycleServicing {}

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

    func activate(bundleID: String, udid: String) throws {
        try withAppService(udid: udid) { appService in
            _ = try appService.launchApplication(
                bundleID: bundleID,
                arguments: [],
                terminateExisting: false,
                startSuspended: false,
                environment: [:],
                payloadURL: nil,
                activates: true
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
