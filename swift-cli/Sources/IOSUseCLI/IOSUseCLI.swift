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
    public let logs: String
    public let artifacts: String

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> IOSUsePaths {
        let root = configuredRoot(environment: environment)
        return IOSUsePaths(
            root: root,
            config: "\(root)/config.json",
            session: "\(root)/state/session.json",
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
    public static let version = "1.0.0"

    public let paths: IOSUsePaths

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = IOSUsePaths.resolve(environment: environment)
    }

    public func run(arguments: [String]) -> CLIResult {
        guard let first = arguments.first else {
            return CLIResult(exitCode: 0, stdout: Self.helpText)
        }

        if arguments.dropFirst().contains("--help") || arguments.dropFirst().contains("-h") {
            return CLIResult(exitCode: 0, stdout: Self.helpText)
        }

        switch first {
        case "-h", "--help", "help":
            return CLIResult(exitCode: 0, stdout: Self.helpText)
        case "-V", "--version":
            return CLIResult(exitCode: 0, stdout: "\(Self.version)\n")
        default:
            if first.hasPrefix("-") {
                return CLIErrorEnvelope(message: "unknown option '\(first)'").render()
            }
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
                return CLIResult(exitCode: 0, stdout: try FlowService.run(file: options.file, options: options, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .nslog(let options):
            do {
                return CLIResult(exitCode: 0, stdout: try NSLogService.stream(options: options, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .stop:
            SessionService.clear(paths: paths)
            return CLIResult(exitCode: 0, stdout: "Session stopped\n")
        case .proxy(.doctor):
            return CLIResult(exitCode: 0, stdout: ProxyService.doctor(paths: paths))
        case .proxy(.configca(let udid)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.configCA(udid: udid, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.start(let udid, let interfaceName)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.start(udid: udid, interfaceName: interfaceName, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .proxy(.stop(let udid)):
            do {
                return CLIResult(exitCode: 0, stdout: try ProxyService.stop(udid: udid, paths: paths))
            } catch {
                return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
            }
        case .driver(let action):
            return executeDriver(action)
        }
    }

    private func executeDriver(_ action: DriverAction) -> CLIResult {
        do {
            try prepareDriverSession(action.session)
            let client = DriverClient()
            switch action {
            case .dom(let raw, let fresh, _):
                return CLIResult(exitCode: 0, stdout: try DriverOutput.formatDom(client.dom(raw: raw, fresh: fresh)))
            case .find(let label, let traits, _):
                return CLIResult(exitCode: 0, stdout: try DriverOutput.formatFind(label: label, payload: client.find(label: label, traits: traits)))
            case .waitFor(let label, let timeout, let traits, _):
                return CLIResult(exitCode: 0, stdout: try DriverOutput.formatWaitFor(label: label, payload: client.waitFor(label: label, timeout: timeout, traits: traits)))
            case .screenshot(let name, _):
                return try saveScreenshot(name: name, client: client)
            case .tap(let target, let offset, let offsetRatio, let traits, _):
                return try tap(target: target, offset: offset, offsetRatio: offsetRatio, traits: traits, client: client)
            case .longPress(let target, let duration, let traits, _):
                let payload = try client.longPress(target: try Self.target(target), durationMs: duration, traits: traits)
                return CLIResult(exitCode: 0, stdout: "Longpress\n\(DriverOutput.formatElement(payload))")
            case .input(let label, let content, let traits, _):
                try client.input(label: label, content: content, traits: traits)
                return CLIResult(exitCode: 0, stdout: "Input \"\(content)\" into \"\(label)\"\n")
            case .swipe(let to, let from, let dir, let distance, let traits, _):
                let result = try client.swipe(to: try Self.target(to), from: try Self.target(from), distance: distance, dir: dir, traits: traits)
                return CLIResult(exitCode: 0, stdout: DriverOutput.formatSwipe(result))
            case .activateApp(let bundleId, _):
                try client.activateApp(bundleId: bundleId)
                return CLIResult(exitCode: 0, stdout: "App \(bundleId) activated\n")
            case .terminateApp(let bundleId, _):
                try client.terminateApp(bundleId: bundleId)
                return CLIResult(exitCode: 0, stdout: "App \(bundleId) terminated\n")
            case .home:
                try client.home()
                return CLIResult(exitCode: 0, stdout: "Pressed Home\n")
            case .openURL(let url, _):
                _ = try client.openURL(url: url)
                return CLIResult(exitCode: 0, stdout: "Opened URL: \(url)\n")
            case .dismissAlert(let index, _):
                return CLIResult(exitCode: 0, stdout: try DriverOutput.formatAlert(client.dismissAlert(index: index)))
            case .oslog(let pattern, let flags, let timeout, let name, let clear, let bundleId, let session):
                return try oslog(pattern: pattern, flags: flags, timeout: timeout, name: name, clear: clear, bundleId: bundleId, session: session)
            }
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    private func saveScreenshot(name: String?, client: DriverClient) throws -> CLIResult {
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
        let prefix = name ?? "screenshot"
        let path = "\(paths.artifacts)/\(prefix).jpg"
        try client.screenshot().write(to: URL(fileURLWithPath: path))
        return CLIResult(exitCode: 0, stdout: "Screenshot saved: \(path)\n")
    }

    private func oslog(pattern: String?, flags: String?, timeout: Double?, name: String?, clear: Bool, bundleId: String?, session: SessionOptions) throws -> CLIResult {
        if clear {
            return CLIResult(exitCode: 0, stdout: OSLogService.clear())
        }
        guard let udid = session.udid else {
            throw CLIParseError.invalidValue("oslog requires --udid")
        }
        return CLIResult(
            exitCode: 0,
            stdout: try OSLogService.fetchSimulator(
                udid: udid,
                pattern: pattern,
                flags: flags,
                bundleId: bundleId,
                timeout: timeout,
                name: name,
                paths: paths
            )
        )
    }

    private func tap(target: String, offset: String?, offsetRatio: String?, traits: String?, client: DriverClient) throws -> CLIResult {
        let foryTarget = try Self.target(target)
        if foryTarget.point != nil && offset != nil {
            throw CLIParseError.invalidValue("offset requires element label, not absolute point")
        }
        let offsetPoint = try offset.map(Self.pointPair)
        let ratioPoint = try offsetPoint == nil ? (offsetRatio.map(Self.pointPair) ?? ForyPoint(x: 0.5, y: 0.5)) : ForyPoint(x: 0.5, y: 0.5)
        let result = try client.tap(target: foryTarget, traits: traits, offset: offsetPoint, ratio: ratioPoint)
        return CLIResult(exitCode: 0, stdout: "Tap\n\(DriverOutput.formatElement(result))")
    }

    private func prepareDriverSession(_ session: SessionOptions) throws {
        guard let udid = session.udid else { return }
        let configured = DeviceService.configuredUdids(paths: paths)
        guard configured.contains(udid) else {
            throw CLIParseError.invalidValue("No signing config found for device \(udid). Run `ios-use config --udid \(udid)` first.")
        }
        let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).first { $0.udid == udid }
        try SessionService.writeSimulatorSession(
            udid: udid,
            deviceName: simulator?.name ?? "Simulator",
            deviceVersion: simulator?.version ?? "",
            paths: paths
        )
    }

    private static func target(_ value: String?) throws -> ForyTarget {
        guard let value, !value.isEmpty else { return ForyTarget() }
        if let point = try? pointPair(value) {
            return ForyTarget(label: "", point: point)
        }
        return ForyTarget(label: value, point: nil)
    }

    private static func pointPair(_ value: String) throws -> ForyPoint {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw CLIParseError.invalidValue("Invalid point pair: \"\(value)\"")
        }
        let rawX = parts[0].trimmingCharacters(in: .whitespaces)
        let rawY = parts[1].trimmingCharacters(in: .whitespaces)
        let x = rawX.isEmpty ? 0 : Double(rawX)
        let y = rawY.isEmpty ? 0 : Double(rawY)
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
            let configured = DeviceService.configuredUdids(paths: paths)
            let lines = devices.map { DeviceService.format($0, configured: configured) }.joined(separator: "\n")
            return CLIResult(exitCode: 0, stdout: "\(lines)\n")
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    public static var helpText: String {
        """
        Usage: ios-use-swift [--help] [--version] <command>

        Swift CLI for ios-use.

        Current status:
          - `dist/ios-use` is the default Swift executable
          - Swift CLI and driver compile the same shared IOSUseProtocol/Fory model source
          - driver read, mutation, lifecycle, oslog, nslog, proxy, config, devices, and Simulator flow paths are migrated
          - real-device host paths are implemented but still require physical-device validation
          - `src/cli.ts` remains a legacy reference, not the default runtime path

        Options:
          -h, --help       Show help
          -V, --version    Show version

        Commands:
          devices, config, dom, find, waitFor, screenshot, tap, longpress, input, swipe
          activateApp, terminateApp, home, openURL, dismissAlert, flow, proxy, oslog, nslog

        """
    }
}
