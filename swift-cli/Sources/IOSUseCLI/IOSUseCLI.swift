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
    public let session: String
    public let nslogLock: String
    public let logs: String
    public let artifacts: String

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> IOSUsePaths {
        let root = configuredRoot(environment: environment)
        return IOSUsePaths(
            root: root,
            config: "\(root)/config.json",
            session: "\(root)/state/session.json",
            nslogLock: "\(root)/state/nslog.lock",
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
}

public struct IOSUseCLI: Sendable {
    public typealias CLIOutputSink = @Sendable (String) -> Void

    public static let version = "1.0.2"
    static var driverClientFactoryForTesting: ((SessionService.Info?) -> DriverCommandClient)?

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
                return CLIResult(exitCode: 0, stdout: try NSLogService.stream(options: options, paths: paths))
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
        case .proxy(.configca(let udid)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.configCA(udid: udid, paths: paths, outputSink: outputSink))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.start(let udid, let interfaceName)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.start(udid: udid, interfaceName: interfaceName, paths: paths, outputSink: outputSink))
            } catch let signal as CLIExitSignal {
                return CLIResult(exitCode: signal.exitCode, stderr: "error: \(signal.message)\n")
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.stop(let udid)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.stop(udid: udid, paths: paths, outputSink: outputSink))
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
            switch action {
            case .dom(let raw, let fresh, _):
                let payload = try withPreparedDriverClient(action.session) { client in
                    try client.dom(raw: raw, fresh: fresh)
                }
                return CLIResult(exitCode: 0, stdout: DriverOutput.formatDom(payload))
            case .find(let label, let traits, let cindex, _):
                let payload = try withPreparedDriverClient(action.session) { client in
                    try client.find(label: label, traits: traits, cindex: cindex)
                }
                return CLIResult(exitCode: 0, stdout: DriverOutput.formatFind(label: label, payload: payload))
            case .waitFor(let label, let timeout, let traits, let cindex, _):
                let payload = try withPreparedDriverClient(action.session) { client in
                    try client.waitFor(label: label, timeout: timeout, traits: traits, cindex: cindex)
                }
                return CLIResult(exitCode: 0, stdout: DriverOutput.formatWaitFor(label: label, payload: payload))
            case .screenshot(let name, _):
                let data = try withPreparedDriverClient(action.session) { client in
                    try client.screenshot()
                }
                return try saveScreenshot(name: name, data: data)
            case .tap(let target, let offset, let offsetRatio, let traits, let cindex, _):
                let foryTarget = try Self.target(target, traits: traits, cindex: cindex)
                if foryTarget.point != nil && (offset != nil || offsetRatio != nil) {
                    throw CLIParseError.invalidValue("offset requires element label, not absolute point")
                }
                let offsetPoint = try offset.map { try Self.pointPair($0, emptyDefault: 0) }
                let ratioPoint = try offsetPoint == nil ? (offsetRatio.map { try Self.pointPair($0, emptyDefault: IOSUseProtocol.defaultTargetRatio) } ?? ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio)) : ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio)
                let payload = try withPreparedDriverClient(action.session) { client in
                    try client.tap(target: foryTarget, traits: traits, cindex: cindex, offset: offsetPoint, ratio: ratioPoint)
                }
                return CLIResult(exitCode: 0, stdout: "Tap\n\(DriverOutput.formatElement(payload))")
            case .longPress(let target, let duration, let traits, let cindex, _):
                let foryTarget = try Self.target(target, traits: traits, cindex: cindex)
                let payload = try withPreparedDriverClient(action.session) { client in
                    try client.longPress(target: foryTarget, durationMs: duration, traits: traits, cindex: cindex)
                }
                return CLIResult(exitCode: 0, stdout: "Longpress\n\(DriverOutput.formatElement(payload))")
            case .input(let label, let content, let traits, let cindex, _):
                try withPreparedDriverClient(action.session) { client in
                    try client.input(label: label, content: content, traits: traits, cindex: cindex)
                }
                return CLIResult(exitCode: 0, stdout: "Input \"\(content)\" into \"\(label)\"\n")
            case .swipe(let to, let from, let dir, let distance, let traits, let cindex, _):
                let toTarget = try Self.target(to, traits: traits, cindex: cindex)
                let fromTarget = try Self.target(from)
                let result = try withPreparedDriverClient(action.session) { client in
                    try client.swipe(to: toTarget, from: fromTarget, distance: distance, dir: dir, traits: traits, cindex: cindex)
                }
                return CLIResult(exitCode: 0, stdout: DriverOutput.formatSwipe(result))
            case .activateApp(let bundleId, _):
                try withPreparedDriverClient(action.session) { client in
                    try client.activateApp(bundleId: bundleId)
                }
                return CLIResult(exitCode: 0, stdout: "App \(bundleId) activated\n")
            case .terminateApp(let bundleId, _):
                do {
                    try withPreparedDriverClient(action.session) { client in
                        try client.terminateApp(bundleId: bundleId)
                    }
                } catch {
                    if Self.isAppNotRunningError(error) {
                        return CLIResult(exitCode: 0, stdout: "App \(bundleId) not running, skipped terminate\n")
                    }
                    throw error
                }
                return CLIResult(exitCode: 0, stdout: "App \(bundleId) terminated\n")
            case .home:
                try withPreparedDriverClient(action.session) { client in
                    try client.home()
                }
                return CLIResult(exitCode: 0, stdout: "Pressed Home\n")
            case .openURL(let url, _):
                _ = try withPreparedDriverClient(action.session) { client in
                    try client.openURL(url: url)
                }
                return CLIResult(exitCode: 0, stdout: "Opened URL: \(url)\n")
            case .dismissAlert(let index, _):
                let payload = try withPreparedDriverClient(action.session) { client in
                    try client.dismissAlert(index: index)
                }
                return CLIResult(exitCode: 0, stdout: DriverOutput.formatAlert(payload))
            case .oslog:
                throw CLIParseError.invalidValue("internal error: oslog should not require driver session")
            }
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    private func withPreparedDriverClient<T>(_ session: SessionOptions, _ body: (DriverCommandClient) throws -> T) throws -> T {
        try prepareDriverSession(session)
        do {
            return try runWithDriverClient(body)
        } catch {
            guard Self.isRecoverableDriverConnectFailure(error) else { throw error }
            try SessionService.launchPreparedDriverSession(paths: paths, verbose: session.verbose)
            return try runWithDriverClient(body)
        }
    }

    private func runWithDriverClient<T>(_ body: (DriverCommandClient) throws -> T) throws -> T {
        let client = Self.driverClientFactoryForTesting?(SessionService.read(paths: paths))
            ?? DriverClient(session: SessionService.read(paths: paths))
        defer { client.close() }
        return try body(client)
    }

    private func saveScreenshot(name: String?, data: Data) throws -> CLIResult {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "screenshot", extension: "jpg")
        try data.write(to: URL(fileURLWithPath: path))
        return CLIResult(exitCode: 0, stdout: "Screenshot saved: \(path)\n")
    }

    private func oslog(pattern: String?, flags: String?, timeout: Double?, name: String?, clear: Bool, bundleId: String?, session: SessionOptions) throws -> CLIResult {
        if clear {
            if let udid = session.udid ?? SessionService.read(paths: paths)?.udid {
                return CLIResult(exitCode: 0, stdout: OSLogService.clear(udid: udid))
            }
            return CLIResult(exitCode: 0, stdout: OSLogService.clear())
        }
        let activeSession = SessionService.read(paths: paths)
        let defaultUsbUdid = try session.udid == nil && activeSession?.udid == nil
            ? DeviceService.listDevices(simulatorOnly: false, paths: paths).first?.udid
            : nil
        guard let udid = session.udid ?? activeSession?.udid ?? defaultUsbUdid else {
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
                deviceTypeHint: activeSession?.udid == udid ? activeSession?.deviceType : (defaultUsbUdid == udid ? "real" : nil)
            )
        )
    }

    private func prepareDriverSession(_ session: SessionOptions) throws {
        try SessionService.prepareDriverSession(session, paths: paths)
    }

    private static func isRecoverableDriverConnectFailure(_ error: Error) -> Bool {
        (error as? DriverClientError)?.isRecoverableConnectFailure == true
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

    public static var helpText: String {
        CLIHelp.rootText
    }
}
