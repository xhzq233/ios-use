import Darwin
import Foundation
import IOSUseDaemonRuntime

struct DaemonFrontend {
    private let environment: [String: String]
    private let paths: IOSUsePaths

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        self.paths = IOSUsePaths.resolve(environment: environment)
    }

    func run(arguments: [String], executablePath: String) -> CLIResult {
        do {
            let client = DaemonClient(paths: paths)
            if arguments.first == "stop", !client.canConnect() {
                deleteResidualSessionFile()
                return CLIResult(exitCode: 0, stdout: "Daemon stopped\n")
            }
            try ensureDaemon(executablePath: executablePath)
            let request = DaemonRequest(
                argv: arguments,
                cwd: FileManager.default.currentDirectoryPath,
                environment: requestEnvironment()
            )
            let interruptForwarder = InterruptForwarder(paths: paths, requestID: request.id)
            interruptForwarder.start()
            defer { interruptForwarder.cancel() }
            let exit = try DaemonClient(paths: paths).send(
                request,
                stdoutFileDescriptor: STDOUT_FILENO,
                stderrFileDescriptor: STDERR_FILENO
            )
            return CLIResult(exitCode: exit.exitCode)
        } catch {
            return CLIErrorEnvelope(message: "\(error)", exitCode: 1).render()
        }
    }

    private func requestEnvironment() -> [String: String] {
        let allowed = ["IOS_USE_HOME", "NO_COLOR", "TERM"]
        var result: [String: String] = [:]
        for key in allowed {
            if let value = environment[key] {
                result[key] = value
            }
        }
        return result
    }

    private func ensureDaemon(executablePath: String) throws {
        if DaemonClient(paths: paths).canConnect() { return }
        try startDaemon(executablePath: executablePath)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if DaemonClient(paths: paths).canConnect() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw DaemonClientError.socketFailure("daemon did not become ready")
    }

    private func startDaemon(executablePath: String) throws {
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: paths.daemonPid).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: paths.daemonSocket).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: paths.daemonLog, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.daemonLog))
        try log.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: absoluteExecutablePath(executablePath))
        process.arguments = ["__daemon"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
    }

    private func absoluteExecutablePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
            .standardized
            .path
    }

    private func deleteResidualSessionFile() {
        try? FileManager.default.removeItem(atPath: "\(paths.root)/state/session.json")
    }
}

private final class InterruptForwarder {
    private let paths: IOSUsePaths
    private let requestID: String
    private var sources: [DispatchSourceSignal] = []

    init(paths: IOSUsePaths, requestID: String) {
        self.paths = paths
        self.requestID = requestID
    }

    func start() {
        install(signalNumber: SIGINT, name: "SIGINT")
        install(signalNumber: SIGTERM, name: "SIGTERM")
    }

    func cancel() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    private func install(signalNumber: Int32, name: String) {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber)
        source.setEventHandler { [paths, requestID] in
            _ = try? DaemonClient(paths: paths).send(.interrupt(DaemonInterrupt(id: requestID, signal: name)))
            Darwin.exit(130)
        }
        source.resume()
        sources.append(source)
    }
}
