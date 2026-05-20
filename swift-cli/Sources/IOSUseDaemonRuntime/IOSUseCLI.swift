import Foundation
import IOSUseProtocol

public struct CLIResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CLIErrorEnvelope: Equatable, Sendable {
    public let message: String
    public let exitCode: Int32

    public init(message: String, exitCode: Int32 = 64) {
        self.message = message
        self.exitCode = exitCode
    }

    public func render() -> CLIResult {
        CLIResult(exitCode: exitCode, stderr: "error: \(message)\n")
    }
}

public struct IOSUsePaths: Equatable, Sendable {
    public let root: String
    public let config: String
    public let nslogLock: String
    public let daemonSocket: String
    public let daemonPid: String
    public let daemonLog: String
    public let logs: String
    public let artifacts: String

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> IOSUsePaths {
        let root = configuredRoot(environment: environment)
        let socket = daemonSocketPath(root: root)
        return IOSUsePaths(
            root: root,
            config: "\(root)/config.json",
            nslogLock: "\(root)/state/nslog.lock",
            daemonSocket: socket,
            daemonPid: "\(root)/state/daemon.pid",
            daemonLog: "\(root)/logs/daemon.log",
            logs: "\(root)/logs",
            artifacts: "\(root)/artifacts"
        )
    }

    private static func configuredRoot(environment: [String: String]) -> String {
        if let iosUseHome = environment["IOS_USE_HOME"], !iosUseHome.isEmpty {
            return iosUseHome
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return "\(home)/.ios-use"
    }

    private static func daemonSocketPath(root: String) -> String {
        let preferred = "\(root)/state/daemon.sock"
        if preferred.utf8.count < 100 {
            return preferred
        }
        return "/tmp/iud-\(stableHash(root)).sock"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

public struct IOSUseCLI: Sendable {
    public typealias CLIOutputSink = @Sendable (String) -> Void

    public static let version = "1.0.1"

    public let paths: IOSUsePaths
    public let outputSink: CLIOutputSink?
    private let driverChannel: DaemonDriverChannel?
    private let cancellation: DaemonCancellationToken?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        outputSink: CLIOutputSink? = nil,
        driverChannel: DaemonDriverChannel? = nil,
        cancellation: DaemonCancellationToken? = nil
    ) {
        self.paths = IOSUsePaths.resolve(environment: environment)
        self.outputSink = outputSink
        self.driverChannel = driverChannel
        self.cancellation = cancellation
    }

    public func run(arguments: [String]) -> CLIResult {
        guard let first = arguments.first else {
            return CLIErrorEnvelope(message: CLIParseError.missingCommand.description).render()
        }
        if first.hasPrefix("-") {
            return CLIErrorEnvelope(message: "unknown option '\(first)'").render()
        }
        do {
            let parsed = try CLIParser.parse(arguments)
            return executeParsed(parsed)
        } catch let error as CLIParseError {
            return CLIErrorEnvelope(message: error.description).render()
        } catch {
            return CLIErrorEnvelope(message: "\(error)").render()
        }
    }

    public func executeParsed(_ parsed: ParsedCommand) -> CLIResult {
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
        case .flow(let options):
            do {
                let stdout = try FlowService.run(file: options.file, options: options, paths: paths, outputSink: outputSink, driverChannel: driverChannel, cancellation: cancellation)
                return CLIResult(exitCode: 0, stdout: outputSink == nil ? stdout : "")
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .nslog(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try NSLogService.stream(options: options, paths: paths, cancellation: cancellation))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .stop:
            DriverBootstrap.deleteResidualSessionFile(paths: paths)
            return CLIResult(exitCode: 0, stdout: "Daemon stopped\n")
        case .proxy(.doctor):
            return CLIResult(exitCode: 0, stdout: ProxyService.doctor(paths: paths))
        case .proxy(.configca(let udid)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.configCA(udid: udid, paths: paths, outputSink: outputSink, driverChannel: driverChannel))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.start(let udid, let interfaceName)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.start(udid: udid, interfaceName: interfaceName, paths: paths, outputSink: outputSink, driverChannel: driverChannel))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.stop(let udid)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.stop(udid: udid, paths: paths, outputSink: outputSink, driverChannel: driverChannel))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .driver(let action):
            return executeDriver(action)
        }
    }

    private func executeDriver(_ action: DriverAction) -> CLIResult {
        if case .oslog(let pattern, let flags, let timeout, let name, let clear, let bundleId, let session) = action {
            do {
                return try oslog(pattern: pattern, flags: flags, timeout: timeout, name: name, clear: clear, bundleId: bundleId, session: session)
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        }
        do {
            if let driverChannel {
                return try driverChannel.withClient(session: action.session) { client, _ in
                    try executeDriverAction(action, client: client)
                }
            } else {
                let endpoint = try DriverBootstrap.resolveEndpoint(session: action.session, current: nil, paths: paths)
                let client = DriverClient(endpoint: endpoint)
                defer { client.close() }
                return try executeDriverAction(action, client: client)
            }
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    private func executeDriverAction(_ action: DriverAction, client: DriverClient) throws -> CLIResult {
        switch action {
        case .dom(let raw, let fresh, _):
            return CLIResult(exitCode: 0, stdout: try DriverOutput.formatDom(client.dom(raw: raw, fresh: fresh)))
        case .find(let label, let traits, let cindex, _):
            return CLIResult(exitCode: 0, stdout: try DriverOutput.formatFind(label: label, payload: client.find(label: label, traits: traits, cindex: cindex)))
        case .waitFor(let label, let timeout, let traits, let cindex, _):
            return CLIResult(exitCode: 0, stdout: try DriverOutput.formatWaitFor(label: label, payload: client.waitFor(label: label, timeout: timeout, traits: traits, cindex: cindex)))
        case .screenshot(let name, _):
            return try saveScreenshot(name: name, client: client)
        case .tap(let target, let offset, let offsetRatio, let traits, let cindex, _):
            return try tap(target: target, offset: offset, offsetRatio: offsetRatio, traits: traits, cindex: cindex, client: client)
        case .longPress(let target, let duration, let traits, let cindex, _):
            let payload = try client.longPress(target: try Self.target(target, traits: traits, cindex: cindex), durationMs: duration, traits: traits, cindex: cindex)
            return CLIResult(exitCode: 0, stdout: "Longpress\n\(DriverOutput.formatElement(payload))")
        case .input(let label, let content, let traits, let cindex, _):
            try client.input(label: label, content: content, traits: traits, cindex: cindex)
            return CLIResult(exitCode: 0, stdout: "Input \"\(content)\" into \"\(label)\"\n")
        case .swipe(let to, let from, let dir, let distance, let traits, let cindex, _):
            let result = try client.swipe(to: try Self.target(to, traits: traits, cindex: cindex), from: try Self.target(from), distance: distance, dir: dir, traits: traits, cindex: cindex)
            return CLIResult(exitCode: 0, stdout: DriverOutput.formatSwipe(result))
        case .activateApp(let bundleId, _):
            try client.activateApp(bundleId: bundleId)
            return CLIResult(exitCode: 0, stdout: "App \(bundleId) activated\n")
        case .terminateApp(let bundleId, _):
            do {
                try client.terminateApp(bundleId: bundleId)
            } catch {
                if Self.isAppNotRunningError(error) {
                    return CLIResult(exitCode: 0, stdout: "App \(bundleId) not running, skipped terminate\n")
                }
                throw error
            }
            return CLIResult(exitCode: 0, stdout: "App \(bundleId) terminated\n")
        case .home:
            try client.home()
            return CLIResult(exitCode: 0, stdout: "Pressed Home\n")
        case .openURL(let url, _):
            _ = try client.openURL(url: url)
            return CLIResult(exitCode: 0, stdout: "Opened URL: \(url)\n")
        case .dismissAlert(let index, _):
            return CLIResult(exitCode: 0, stdout: try DriverOutput.formatAlert(client.dismissAlert(index: index)))
        case .oslog:
            throw CLIParseError.invalidValue("internal error: oslog should not require driver session")
        }
    }

    private func saveScreenshot(name: String?, client: DriverClient) throws -> CLIResult {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "screenshot", extension: "jpg")
        try client.screenshot().write(to: URL(fileURLWithPath: path))
        return CLIResult(exitCode: 0, stdout: "Screenshot saved: \(path)\n")
    }

    private func oslog(pattern: String?, flags: String?, timeout: Double?, name: String?, clear: Bool, bundleId: String?, session: SessionOptions) throws -> CLIResult {
        let activeEndpoint = driverChannel?.currentEndpoint
        if clear {
            if let udid = session.udid ?? activeEndpoint?.udid {
                return CLIResult(exitCode: 0, stdout: OSLogService.clear(udid: udid))
            }
            return CLIResult(exitCode: 0, stdout: OSLogService.clear())
        }
        let defaultUsbUdid = try session.udid == nil && activeEndpoint?.udid == nil
            ? DeviceService.listDevices(simulatorOnly: false, paths: paths).first?.udid
            : nil
        guard let udid = session.udid ?? activeEndpoint?.udid ?? defaultUsbUdid else {
            throw CLIParseError.invalidValue("oslog requires --udid, an active session, or a connected USB device")
        }
        return CLIResult(
            exitCode: 0,
            stdout: try OSLogService.fetch(
                udid: udid,
                pattern: pattern,
                flags: flags,
                bundleId: bundleId,
                timeout: timeout,
                name: name,
                paths: paths,
                deviceTypeHint: activeEndpoint?.udid == udid ? activeEndpoint?.deviceType : (defaultUsbUdid == udid ? "real" : nil)
            )
        )
    }

    private func tap(target: String, offset: String?, offsetRatio: String?, traits: String?, cindex: Int32?, client: DriverClient) throws -> CLIResult {
        let foryTarget = try Self.target(target, traits: traits, cindex: cindex)
        if foryTarget.point != nil && (offset != nil || offsetRatio != nil) {
            throw CLIParseError.invalidValue("offset requires element label, not absolute point")
        }
        let offsetPoint = try offset.map { try Self.pointPair($0, emptyDefault: 0) }
        let ratioPoint = try offsetPoint == nil ? (offsetRatio.map { try Self.pointPair($0, emptyDefault: IOSUseProtocol.defaultTargetRatio) } ?? ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio)) : ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio)
        let result = try client.tap(target: foryTarget, traits: traits, cindex: cindex, offset: offsetPoint, ratio: ratioPoint)
        return CLIResult(exitCode: 0, stdout: "Tap\n\(DriverOutput.formatElement(result))")
    }

    static func isAppNotRunningError(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.range(of: #"not running|already terminated|no such process|state=1|state=0"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func target(_ value: String?, traits: String? = nil, cindex: Int32? = nil) throws -> ForyTarget {
        guard let value, !value.isEmpty else {
            if traits != nil || cindex != nil {
                throw CLIParseError.invalidValue("traits or cindex require label target")
            }
            return ForyTarget()
        }
        if let point = try? pointPair(value, emptyDefault: 0) {
            if traits != nil || cindex != nil {
                throw CLIParseError.invalidValue("point target does not support traits or cindex")
            }
            return ForyTarget(label: "", point: point)
        }
        return ForyTarget(label: value, point: nil, traits: traits ?? "", cindex: cindex)
    }

    private static func pointPair(_ value: String, emptyDefault: Double) throws -> ForyPoint {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw CLIParseError.invalidValue("Invalid point pair: \"\(value)\"")
        }
        let rawX = parts[0].trimmingCharacters(in: .whitespaces)
        let rawY = parts[1].trimmingCharacters(in: .whitespaces)
        let x = rawX.isEmpty ? emptyDefault : Double(rawX)
        let y = rawY.isEmpty ? emptyDefault : Double(rawY)
        guard let x, let y, x.isFinite, y.isFinite else {
            throw CLIParseError.invalidValue("Invalid point pair: \"\(value)\"")
        }
        return ForyPoint(x: x, y: y)
    }

    private func listDevices(_ options: DeviceOptions) -> CLIResult {
        do {
            let devices = try DeviceService.listDevices(simulatorOnly: options.simulator, paths: paths)
            if devices.isEmpty {
                return CLIResult(exitCode: 0, stdout: options.simulator ? "No booted Simulators found\n" : "No connected real devices found\n")
            }
            let configured = DeviceService.configuredDevices(paths: paths)
            let lines = devices.map { DeviceService.format($0, configuredDevices: configured) }.joined(separator: "\n")
            return CLIResult(exitCode: 0, stdout: "\(lines)\n")
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

}
