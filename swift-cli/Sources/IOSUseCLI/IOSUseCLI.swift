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

public struct IOSUseCLI: Sendable {
    public static let version = "1.0.0"

    public init() {}

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
                return CLIResult(exitCode: 64, stderr: "error: unknown option '\(first)'\n")
            }
            return unsupportedCommand(first)
        }
    }

    private func unsupportedCommand(_ command: String) -> CLIResult {
        let known = DriverCommand(rawValue: command) != nil ? "driver command" : "command"
        return CLIResult(
            exitCode: 64,
            stderr: "error: Swift CLI \(known) '\(command)' is not implemented yet; use the TypeScript CLI for now.\n"
        )
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
