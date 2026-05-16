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
        default:
            return parsedButNotImplemented(parsed)
        }
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

    private func parsedButNotImplemented(_ parsed: ParsedCommand) -> CLIResult {
        CLIErrorEnvelope(message: "Swift CLI command '\(parsed.commandName)' parsed successfully but execution is not migrated yet.").render()
    }

    public static var helpText: String {
        """
        Usage: ios-use-swift [--help] [--version] <command>

        Swift rewrite scaffold for ios-use.

        Current status:
          - protocol constants and driver command names are available in IOSUseProtocol
          - driver command execution is not migrated yet
          - use `bun run src/cli.ts <command>` for production behavior

        Options:
          -h, --help       Show help
          -V, --version    Show version

        Planned command groups:
          devices, config, dom, find, waitFor, screenshot, tap, longPress, input, swipe
          activateApp, terminateApp, home, openURL, dismissAlert, flow, proxy, oslog, nslog

        """
    }
}
