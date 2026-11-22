import Foundation

public enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var foundation: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues(\.foundation)
        case .array(let v): return v.map(\.foundation)
        case .null: return NSNull()
        }
    }
}

public struct ScriptFailure: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Script: Decodable {
    public struct Step: Decodable {
        public let command: String?
        public let args: [String: JSONValue]?
        public let count: Int?
        public let steps: [Step]?
    }
    public let name: String
    public let steps: [Step]
    public static let commands: Set<String> = ["activateApp", "home", "dom", "tap", "longPress", "input", "swipe", "waitFor", "screenshot", "sleep", "assertText"]

    public static func parse(_ data: Data) throws -> Script {
        guard data.count <= 1_048_576 else { throw ScriptFailure("Script exceeds 1 MiB") }
        let script = try JSONDecoder().decode(Script.self, from: data)
        _ = try script.flattened()
        return script
    }
    public func flattened() throws -> [Step] {
        var output = [Step]()
        func expand(_ steps: [Step], depth: Int) throws {
            guard depth <= 8 else { throw ScriptFailure("Repeat nesting exceeds 8") }
            for step in steps {
                if let nested = step.steps {
                    guard step.command == nil, step.args == nil, let count = step.count, (1...100).contains(count), !nested.isEmpty else {
                        throw ScriptFailure("Repeat requires count 1...100 and nonempty steps only")
                    }
                    for _ in 0..<count { try expand(nested, depth: depth + 1) }
                } else {
                    guard step.count == nil, let command = step.command, Self.commands.contains(command) else {
                        throw ScriptFailure("Unknown or missing command")
                    }
                    if command == "sleep" {
                        guard case .number(let seconds) = step.args?["seconds"], seconds.isFinite, (0...300).contains(seconds) else {
                            throw ScriptFailure("sleep requires seconds between 0 and 300")
                        }
                    }
                    if command == "assertText" {
                        guard case .string(let text) = step.args?["text"], !text.isEmpty else { throw ScriptFailure("assertText requires text") }
                    }
                    guard output.count < 1000 else { throw ScriptFailure("Script exceeds 1000 expanded steps") }
                    output.append(step)
                }
            }
        }
        guard !steps.isEmpty else { throw ScriptFailure("Script has no steps") }
        try expand(steps, depth: 0)
        return output
    }
}

public final class ScriptCancellation {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let value = stopped; lock.unlock()
        if value { throw ScriptFailure("Script cancelled") }
    }
}

public enum ScriptExecutor {
    /// Runs on the caller's serial worker. Commands are never run concurrently.
    /// A cancellation takes effect between UI calls and during sleep intervals.
    public static func run(_ script: Script, cancellation: ScriptCancellation,
                           execute: (String, [String: Any]) throws -> [String: Any],
                           report: (Int, String, Result<[String: Any], Error>) -> Void) throws {
        for (index, step) in try script.flattened().enumerated() {
            try cancellation.check()
            let command = step.command!
            let args = (step.args ?? [:]).mapValues(\.foundation)
            do {
                var result: [String: Any] = [:]
                if command == "sleep" {
                    let deadline = ProcessInfo.processInfo.systemUptime + (args["seconds"] as! Double)
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        try cancellation.check()
                        Thread.sleep(forTimeInterval: min(0.05, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                    }
                } else if command == "assertText" {
                    result = try execute("dom", [:])
                    guard let text = result["text"] as? String, text.contains(args["text"] as! String) else {
                        throw ScriptFailure("Screen text assertion failed")
                    }
                } else { result = try execute(command, args) }
                try cancellation.check()
                report(index, command, .success(result))
            } catch {
                report(index, command, .failure(error))
                throw error
            }
        }
    }
}
