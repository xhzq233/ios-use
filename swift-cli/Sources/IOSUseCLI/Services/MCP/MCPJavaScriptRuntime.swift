import Darwin
import Foundation
import MCP

/// One stdio client owns one JavaScript context. Device connections live in
/// that context's Host; requests never share a context across server processes.
final class MCPJavaScriptRuntime: @unchecked Sendable {
    private let paths: IOSUsePaths
    private let queue = DispatchQueue(label: "ios-use.mcp.javascript")
    private let stateLock = NSLock()
    private var current: MCPExecution?
    private var resetting = false
    private var closed = false
    // Accessed only on queue.
    private var kernel: MCPJavaScriptKernel?

    init(paths: IOSUsePaths) {
        self.paths = paths
    }

    func execute(code: String, timeoutMS: Int) async -> CallTool.Result {
        let execution = MCPExecution()
        guard begin(execution) else {
            return Self.failure("Another JavaScript execution or reset is in progress. Await it, or use js_reset to interrupt it.")
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let result: CallTool.Result
                    do {
                        if let reason = execution.reason {
                            result = Self.failure(reason)
                        } else {
                            if kernel == nil {
                                kernel = try MCPJavaScriptKernel(paths: paths)
                            }
                            let activeKernel = kernel!
                            execution.attach(activeKernel)
                            result = try activeKernel.execute(code: code, timeoutMS: timeoutMS, execution: execution)
                        }
                    } catch {
                        result = Self.failure("JavaScript execution failed: \(error)")
                        kernel?.interrupt()
                    }
                    if execution.reason != nil || kernel?.isRunning == false {
                        kernel?.close()
                        kernel = nil
                    }
                    execution.finish()
                    stateLock.lock()
                    if current === execution { current = nil }
                    stateLock.unlock()
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            execution.cancel("JavaScript execution cancelled; its context was reset. Observe the Device before retrying any action.")
        }
    }

    func reset() async -> CallTool.Result {
        guard let interrupted = beginReset() else {
            return Self.failure("A JavaScript reset is already in progress.")
        }
        interrupted.execution?.cancel("JavaScript execution interrupted by js_reset.")
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                kernel?.close()
                kernel = nil
                stateLock.lock()
                resetting = false
                stateLock.unlock()
                continuation.resume(returning: .init(content: [
                    .text(text: "JavaScript context reset. Device Drivers and Apps were not stopped.", annotations: nil, _meta: nil)
                ]))
            }
        }
    }

    func close() {
        stateLock.lock()
        closed = true
        let execution = current
        stateLock.unlock()
        execution?.cancel("MCP client disconnected; JavaScript context closed.")
        queue.sync {
            kernel?.close()
            kernel = nil
        }
    }

    func interrupt() {
        stateLock.lock()
        let execution = current
        stateLock.unlock()
        execution?.cancel("MCP server interrupted; JavaScript context closed.")
    }

    private func begin(_ execution: MCPExecution) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, !resetting, current == nil else { return false }
        current = execution
        return true
    }

    private struct ResetState { let execution: MCPExecution? }

    private func beginReset() -> ResetState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, !resetting else { return nil }
        resetting = true
        return ResetState(execution: current)
    }

    private static func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

private final class MCPExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted: String?
    private var complete = false
    private weak var kernel: MCPJavaScriptKernel?

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    func attach(_ kernel: MCPJavaScriptKernel) {
        lock.lock()
        self.kernel = kernel
        let cancel = interrupted != nil
        lock.unlock()
        if cancel { kernel.interrupt() }
    }

    func cancel(_ reason: String) {
        lock.lock()
        guard !complete, interrupted == nil else { lock.unlock(); return }
        interrupted = reason
        let activeKernel = kernel
        lock.unlock()
        activeKernel?.interrupt()
    }

    func finish() {
        lock.lock()
        complete = true
        kernel = nil
        lock.unlock()
    }
}

private final class MCPJavaScriptKernel: @unchecked Sendable {
    private let host: MCPRuntimeHost
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private var interrupted = false
    private var pending = Data()

    init(paths: IOSUsePaths) throws {
        host = try MCPRuntimeHost(paths: paths)
        process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--permission", "--input-type=module", "-e", MCPJavaScriptSource.code, "--", String(host.port)]
        let environment = ProcessInfo.processInfo.environment
        process.environment = [
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": environment["LC_ALL"] ?? "en_US.UTF-8",
            "NODE_NO_WARNINGS": "1",
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        host.start()
        do { try process.run() }
        catch {
            host.stop()
            throw CLIParseError.invalidValue("Unable to start JavaScript. Install Node.js 22.18+ and retry: \(error)")
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !interrupted && process.isRunning
    }

    private struct Event: Decodable {
        let event: String
        let content: Tool.Content?
        let isError: Bool?
    }

    func execute(code: String, timeoutMS: Int, execution: MCPExecution) throws -> CallTool.Result {
        let timeout = DispatchWorkItem {
            execution.cancel("JavaScript execution timed out after \(timeoutMS) ms; its context was reset. Device actions already issued may have applied; observe before retrying.")
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(timeoutMS), execute: timeout)
        defer { timeout.cancel() }
        var request = try JSONEncoder().encode(["code": code])
        request.append(0x0a)
        try input.write(contentsOf: request)
        var content: [Tool.Content] = []
        while let line = try readLine() {
            let event = try JSONDecoder().decode(Event.self, from: line)
            if let item = event.content { content.append(item) }
            if event.event == "complete" {
                execution.finish()
                if let reason = execution.reason {
                    content.append(.text(text: reason, annotations: nil, _meta: nil))
                    return .init(content: content, isError: true)
                }
                return .init(content: content, isError: event.isError ?? false)
            }
        }
        content.append(.text(text: execution.reason ?? "JavaScript worker exited; its context was reset.", annotations: nil, _meta: nil))
        return .init(content: content, isError: true)
    }

    private func readLine() throws -> Data? {
        var scanned = pending.startIndex
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = pending[scanned...].firstIndex(of: 0x0a) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                return line
            }
            scanned = pending.endIndex
            // FileHandle.read(upToCount:) can wait to fill the entire count on
            // Darwin pipes. A tool completion must return as soon as it arrives.
            let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            pending.append(contentsOf: buffer.prefix(count))
        }
    }

    func interrupt() {
        lock.lock()
        if interrupted { lock.unlock(); return }
        interrupted = true
        let running = process.isRunning
        let pid = process.processIdentifier
        lock.unlock()
        host.shutdown()
        // A JavaScript busy loop cannot cooperate with cancellation.
        if running { Darwin.kill(pid, SIGKILL) }
    }

    func close() {
        interrupt()
        try? input.close()
        process.waitUntilExit()
        try? output.close()
        host.stop()
    }
}
