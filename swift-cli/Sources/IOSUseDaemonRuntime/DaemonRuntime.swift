import Darwin
import Foundation

public final class DaemonExecutor {
    private let environment: [String: String]
    private let paths: IOSUsePaths
    private let logger: DaemonLogger
    private let driverChannel: DaemonDriverChannel
    private let scheduler = DeviceCommandScheduler()
    private let cwdLock = NSLock()

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, logger: DaemonLogger? = nil) {
        self.environment = environment
        self.paths = IOSUsePaths.resolve(environment: environment)
        self.logger = logger ?? DaemonLogger(paths: self.paths)
        self.driverChannel = DaemonDriverChannel(paths: self.paths, logger: self.logger)
    }

    public func handle(
        _ request: DaemonRequest,
        output: DaemonOutputHandles,
        cancellation: DaemonCancellationToken = DaemonCancellationToken()
    ) -> DaemonServer.Response {
        var runnerEnvironment = environment
        for (key, value) in request.environment where key != "IOS_USE_HOME" {
            runnerEnvironment[key] = value
        }
        runnerEnvironment["IOS_USE_HOME"] = paths.root
        let runner = DaemonCommandRunner(
            environment: runnerEnvironment,
            paths: paths,
            output: output,
            driverChannel: driverChannel,
            logger: logger,
            cancellation: cancellation
        )
        let parsed: ParsedCommand?
        switch runner.parse(request) {
        case .command(let command):
            parsed = command
        case .result(let result):
            logger.info("request \(request.id) argv=\(DaemonCommandRunner.redactedArguments(request.argv).joined(separator: " "))")
            output.writeStdout(result.stdout)
            output.writeStderr(result.stderr)
            logger.info("request \(request.id) exit=\(result.exitCode)")
            return DaemonServer.Response(exit: DaemonExit(id: request.id, exitCode: result.exitCode))
        }
        let key = parsed?.daemonQueueKey(activeEndpoint: driverChannel.currentEndpoint)
        guard let key else {
            return executeNow(request, parsed: parsed, runner: runner, cancellation: cancellation)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedDaemonResponse()
        Task {
            do {
                let response = try await scheduler.enqueue(udid: key, kind: parsed?.daemonKind ?? .local) {
                    self.executeNow(request, parsed: parsed, runner: runner, cancellation: cancellation)
                }
                result.set(response)
            } catch {
                output.writeStderr("error: \(error)\n")
                result.set(DaemonServer.Response(exit: DaemonExit(id: request.id, exitCode: 1)))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result.value ?? DaemonServer.Response(exit: DaemonExit(id: request.id, exitCode: 1))
    }

    private func executeNow(
        _ request: DaemonRequest,
        parsed: ParsedCommand?,
        runner: DaemonCommandRunner,
        cancellation: DaemonCancellationToken
    ) -> DaemonServer.Response {
        if cancellation.isCancelled {
            return DaemonServer.Response(exit: cancellation.cancelledExit(id: request.id))
        }
        cancellation.onCancel {
            runner.cancel()
        }
        if cancellation.isCancelled {
            return DaemonServer.Response(exit: cancellation.cancelledExit(id: request.id))
        }
        let outcome: DaemonCommandRunner.RunOutcome
        if parsed?.requiresDaemonWorkingDirectory == true {
            cwdLock.lock()
            let previous = FileManager.default.currentDirectoryPath
            _ = FileManager.default.changeCurrentDirectoryPath(request.cwd)
            outcome = runner.run(request, parsed: parsed)
            _ = FileManager.default.changeCurrentDirectoryPath(previous)
            cwdLock.unlock()
        } else {
            outcome = runner.run(request, parsed: parsed)
        }
        if cancellation.isCancelled {
            return DaemonServer.Response(exit: cancellation.cancelledExit(id: request.id), shouldStopDaemon: outcome.shouldStopDaemon)
        }
        return DaemonServer.Response(exit: outcome.exit, shouldStopDaemon: outcome.shouldStopDaemon)
    }
}

public final class DaemonProcess {
    private let paths: IOSUsePaths
    private let logger: DaemonLogger
    private let executor: DaemonExecutor
    private var server: DaemonServer?
    private var signalSources: [DispatchSourceSignal] = []

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = IOSUsePaths.resolve(environment: environment)
        let logger = DaemonLogger(paths: paths)
        self.logger = logger
        logger.info("daemon process initializing")
        self.executor = DaemonExecutor(environment: environment, logger: logger)
    }

    public func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let server = DaemonServer(paths: paths) { [executor] request, output, cancellation in
            executor.handle(request, output: output, cancellation: cancellation)
        }
        self.server = server
        do {
            try server.start()
            installStopHandlers()
            server.wait()
            return 0
        } catch {
            logger.error("failed to start daemon: \(error)")
            return 1
        }
    }

    private func installStopHandlers() {
        for signalNumber in [SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber)
            source.setEventHandler { [weak self] in
                self?.server?.stop()
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

private final class LockedDaemonResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DaemonServer.Response?

    var value: DaemonServer.Response? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: DaemonServer.Response) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

public extension ParsedCommand {
    var daemonKind: CommandKind {
        switch self {
        case .devices:
            return .local
        case .config(let options):
            return options.list ? .local : .config
        case .stop:
            return .stop
        case .flow:
            return .flow
        case .nslog:
            return .streaming
        case .proxy(let command):
            switch command {
            case .configca:
                return .proxyUI
            case .start, .stop:
                return .streaming
            case .doctor:
                return .local
            }
        case .driver(let action):
            if case .oslog = action {
                return .streaming
            }
            return .ui
        }
    }

    var requiresDaemonWorkingDirectory: Bool {
        switch daemonKind {
        case .local, .streaming:
            return false
        case .ui, .flow, .config, .stop, .proxyUI:
            return true
        }
    }

    func daemonQueueKey(activeEndpoint: DriverEndpoint?) -> String? {
        switch daemonKind {
        case .local, .streaming:
            return nil
        case .ui, .flow, .config, .stop, .proxyUI:
            return "__driver__"
        }
    }
}
