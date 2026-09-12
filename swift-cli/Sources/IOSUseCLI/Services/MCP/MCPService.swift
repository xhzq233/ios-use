import Foundation
import MCP

enum MCPService {
    static let instructions = """
    Use js for persistent JavaScript iOS automation. Start with await cua.getState() to discover Devices, or let device = await cua.getDevice(knownDeviceID). Selection emits initial AX and API guidance; use {observe:false} for an idle Device, then device.start(). Keep handles and helpers across calls. Batch known flows in one call: getAXState({emit:false}) refreshes AX; device.get() reads its full structured elements without another request. Check the expected page, not whole-text equality. Emit compact results with nodeRepl.write; observations emit by default. Use device.listApps(), activateApp(bundleId), terminateApp(bundleId), start()/stop() for lifecycle; signing/setup remains native CLI. Do not use shell polling or ios-use repl. js_reset clears JavaScript without stopping Drivers or Apps. One server process owns one context; use separate processes for independent Agent conversations.
    """

    static var tools: [Tool] {
        [
            Tool(name: "js", description: "Execute JavaScript in a persistent iOS automation context. Await Device actions; retain variables and handles between calls. Returns emitted text and images when this execution completes, without terminal polling. Use a longer timeout_ms for an expected long batch.", inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object(["type": .string("string"), "description": .string("JavaScript to execute. cua, nodeRepl and console are available.")]),
                    "title": .object(["type": .string("string"), "description": .string("Short user-facing explanation of this execution.")]),
                    "timeout_ms": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(300_000), "default": .int(30_000), "description": .string("Execution timeout. Timeout resets the JavaScript context; observe before retrying actions.")]),
                ]),
                "required": .array([.string("code")]),
                "additionalProperties": .bool(false),
            ])),
            Tool(name: "js_reset", description: "Interrupt any running JavaScript and clear persistent variables and Device handles. Does not stop Device Drivers or Apps. The next js call creates a fresh context.", inputSchema: .object([
                "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
            ])),
        ]
    }

    static func run(paths: IOSUsePaths) -> CLIResult {
        let finished = DispatchSemaphore(value: 0)
        let completion = Completion()
        let runtime = MCPJavaScriptRuntime(paths: paths)
        let server = Server(name: "ios-use", version: IOSUseCLI.version, instructions: instructions, capabilities: .init(tools: .init()))
        let interrupts = InterruptMonitor {
            runtime.interrupt()
            Task { await server.stop() }
        }
        interrupts.start()
        defer { interrupts.stop() }
        Task.detached {
            defer { runtime.close(); finished.signal() }
            do {
                await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
                await server.withMethodHandler(CallTool.self) { params in
                    switch params.name {
                    case "js":
                        let arguments = params.arguments ?? [:]
                        guard Set(arguments.keys).isSubset(of: ["code", "title", "timeout_ms"]),
                              arguments["title"] == nil || arguments["title"]?.stringValue != nil else {
                            throw MCPError.invalidParams("js accepts code, optional title string and timeout_ms only")
                        }
                        guard let code = params.arguments?["code"]?.stringValue else {
                            throw MCPError.invalidParams("js requires a code string")
                        }
                        let timeoutMS: Int
                        if let value = params.arguments?["timeout_ms"] {
                            guard let number = value.intValue, (1...300_000).contains(number) else {
                                throw MCPError.invalidParams("timeout_ms must be an integer between 1 and 300000")
                            }
                            timeoutMS = number
                        } else { timeoutMS = 30_000 }
                        return await runtime.execute(code: code, timeoutMS: timeoutMS)
                    case "js_reset":
                        guard params.arguments?.isEmpty != false else {
                            throw MCPError.invalidParams("js_reset takes no arguments")
                        }
                        return await runtime.reset()
                    default:
                        throw MCPError.invalidParams("Unknown tool: \(params.name)")
                    }
                }
                try await server.start(transport: MCPStdioTransport())
                await server.waitUntilCompleted()
                await server.stop()
                completion.set(CLIResult(exitCode: 0))
            } catch {
                completion.set(CLIResult(exitCode: 1, stderr: "MCP server failed: \(error)\n"))
            }
        }
        finished.wait()
        if interrupts.interrupted { return CLIResult(exitCode: interrupts.exitCode) }
        return completion.result
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var value = CLIResult(exitCode: 1)

        func set(_ result: CLIResult) {
            lock.lock()
            value = result
            lock.unlock()
        }

        var result: CLIResult {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
