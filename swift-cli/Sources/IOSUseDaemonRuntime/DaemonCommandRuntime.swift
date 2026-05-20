import Foundation
import IOSUseProtocol

public final class DaemonLogger: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var handle: FileHandle?

    public init(paths: IOSUsePaths) {
        self.path = paths.daemonLog
        try? FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        self.handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
    }

    deinit {
        try? handle?.close()
    }

    public func info(_ message: String) {
        write("INFO", message)
    }

    public func error(_ message: String) {
        write("ERROR", message)
    }

    private func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [daemon] [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: data)
    }
}

public final class DaemonDriverChannel: @unchecked Sendable {
    private let paths: IOSUsePaths
    private let logger: DaemonLogger?
    private let lock = NSLock()
    private var endpoint: DriverEndpoint?
    private var client: DriverClient?

    public init(paths: IOSUsePaths, logger: DaemonLogger? = nil) {
        self.paths = paths
        self.logger = logger
    }

    public var currentEndpoint: DriverEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoint
    }

    public func close() {
        lock.lock()
        let old = endpoint
        client?.close()
        client = nil
        endpoint = nil
        lock.unlock()
        if let old {
            logger?.info("closed driver channel for \(old.udid)")
        }
    }

    func withClient<T>(session: SessionOptions, _ body: (DriverClient, DriverEndpoint) throws -> T) throws -> T {
        let resolved = try DriverBootstrap.resolveEndpoint(session: session, current: currentEndpoint, paths: paths)
        let activeClient = try clientFor(endpoint: resolved)
        do {
            return try body(activeClient, resolved)
        } catch {
            if shouldDropChannel(after: error) {
                close()
            }
            throw error
        }
    }

    private func clientFor(endpoint resolved: DriverEndpoint) throws -> DriverClient {
        lock.lock()
        defer { lock.unlock() }
        if let client, endpoint == resolved {
            return client
        }
        client?.close()
        let next = DriverClient(endpoint: resolved)
        client = next
        endpoint = resolved
        logger?.info("opened driver channel for \(resolved.udid) (\(resolved.deviceType))")
        return next
    }

    private func shouldDropChannel(after error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("driver TCP read failed")
            || text.contains("driver TCP write failed")
            || text.contains("invalid driver frame length")
            || text.contains("driver frame exceeds max size")
            || text.contains("driver TCP connect failed")
    }
}

public final class DaemonCommandRunner: @unchecked Sendable {
    public enum ParseOutcome {
        case command(ParsedCommand?)
        case result(CLIResult)
    }

    public struct RunOutcome: Sendable {
        public let exit: DaemonExit
        public let shouldStopDaemon: Bool
    }

    private let environment: [String: String]
    private let paths: IOSUsePaths
    private let output: DaemonOutputHandles
    private let driverChannel: DaemonDriverChannel
    private let logger: DaemonLogger
    private let cancellation: DaemonCancellationToken?

    public init(
        environment: [String: String],
        paths: IOSUsePaths,
        output: DaemonOutputHandles,
        driverChannel: DaemonDriverChannel,
        logger: DaemonLogger,
        cancellation: DaemonCancellationToken? = nil
    ) {
        self.environment = environment
        self.paths = paths
        self.output = output
        self.driverChannel = driverChannel
        self.logger = logger
        self.cancellation = cancellation
    }

    public func parse(_ request: DaemonRequest) -> ParseOutcome {
        let arguments = request.argv
        guard let first = arguments.first else {
            return .command(nil)
        }
        if arguments.dropFirst().contains("--help") || arguments.dropFirst().contains("-h") {
            return .command(nil)
        }
        switch first {
        case "-h", "--help", "help":
            return .command(nil)
        case "-V", "--version":
            return .result(CLIResult(exitCode: 0, stdout: "\(IOSUseCLI.version)\n"))
        default:
            if first.hasPrefix("-") {
                return .result(CLIErrorEnvelope(message: "unknown option '\(first)'").render())
            }
            do {
                return .command(try CLIParser.parse(arguments))
            } catch let error as CLIParseError {
                return .result(CLIErrorEnvelope(message: error.description).render())
            } catch {
                return .result(CLIErrorEnvelope(message: "\(error)").render())
            }
        }
    }

    public func run(_ request: DaemonRequest, parsed: ParsedCommand?) -> RunOutcome {
        logger.info("request \(request.id) argv=\(Self.redactedArguments(request.argv).joined(separator: " "))")
        let result: CLIResult
        let shouldStop: Bool
        if let parsed {
            let commandResult = executeParsed(parsed)
            result = commandResult.result
            shouldStop = commandResult.shouldStopDaemon
        } else {
            result = CLIResult(exitCode: 0, stdout: IOSUseCLI.helpText)
            shouldStop = false
        }
        output.writeStdout(result.stdout)
        output.writeStderr(result.stderr)
        logger.info("request \(request.id) exit=\(result.exitCode)")
        return RunOutcome(exit: DaemonExit(id: request.id, exitCode: result.exitCode), shouldStopDaemon: shouldStop)
    }

    public func cancel() {
        logger.info("request cancelled; closing driver channel")
        driverChannel.close()
    }

    private func executeParsed(_ parsed: ParsedCommand) -> (result: CLIResult, shouldStopDaemon: Bool) {
        switch parsed {
        case .stop:
            return (stop(), true)
        default:
            return (IOSUseCLI(environment: environment, outputSink: { [output] text in
                output.writeStdout(text)
            }, driverChannel: driverChannel, cancellation: cancellation).executeParsed(parsed), false)
        }
    }

    private func stop() -> CLIResult {
        let endpoint = driverChannel.currentEndpoint
        driverChannel.close()
        DriverBootstrap.deleteResidualSessionFile(paths: paths)
        var stdout = ""
        do {
            if try DriverBootstrap.terminateDriverIfNeeded(endpoint: endpoint) {
                stdout += "Driver app stopped\n"
            }
        } catch {
            logger.error("failed to terminate driver: \(error)")
        }
        stdout += "Daemon stopped\n"
        return CLIResult(exitCode: 0, stdout: stdout)
    }

    static func redactedArguments(_ arguments: [String]) -> [String] {
        let sensitiveOptions = Set(["--apple-id", "--password", "--token", "--secret", "--cert", "--p12"])
        var result: [String] = []
        var redactNext = false
        for argument in arguments {
            if redactNext {
                result.append("<redacted>")
                redactNext = false
                continue
            }
            if let equals = argument.firstIndex(of: "=") {
                let key = String(argument[..<equals])
                if sensitiveOptions.contains(key) {
                    result.append("\(key)=<redacted>")
                    continue
                }
            }
            result.append(argument)
            if sensitiveOptions.contains(argument) {
                redactNext = true
            }
        }
        return result
    }
}
