import Darwin
import Foundation
import IOSUseProtocol
import Network

public enum NSLogService {
    public static func stream(options: NSLogOptions, paths: IOSUsePaths) throws -> String {
        try acquireLock(paths: paths)
        defer { releaseLock(paths: paths) }

        let server = try NSLoggerServer(options: NSLoggerServerOptions(name: options.name), paths: paths)
        try server.start()
        defer { server.stop() }

        server.onMessage = { entry in
            guard let grep = options.grep, !grep.isEmpty else {
                print(entry)
                return
            }
            if (try? Self.matches(entry, pattern: grep, flags: options.flags)) == true {
                print(entry)
            }
        }

        print("NSLogger listening on port \(server.port) (plain TCP)")
        print("Streaming logs... Press Ctrl+C to stop.")

        while server.isRunning {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return ""
    }

    static func matches(_ entry: String, pattern: String, flags: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern, options: regexOptions(flags))
        let range = NSRange(entry.startIndex..<entry.endIndex, in: entry)
        return regex.firstMatch(in: entry, range: range) != nil
    }

    public struct ParsedMessage: Equatable {
        public var parts: [UInt8: AnyHashable]
        public var consumed: Int
    }

    public static func parseMessage(_ data: Data) -> ParsedMessage? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return nil }
        let totalSize = Int(readUInt32(bytes, 0))
        guard bytes.count >= 4 + totalSize else { return nil }
        let partCount = Int(readUInt16(bytes, 4))
        var offset = 6
        var parts: [UInt8: AnyHashable] = [:]

        for _ in 0..<partCount {
            guard offset + 2 <= bytes.count else { break }
            let key = bytes[offset]
            let type = bytes[offset + 1]
            offset += 2
            switch type {
            case 0:
                guard offset + 4 <= bytes.count else { return nil }
                let size = Int(readUInt32(bytes, offset))
                offset += 4
                guard offset + size <= bytes.count else { return nil }
                parts[key] = String(decoding: bytes[offset..<offset + size], as: UTF8.self)
                offset += size
            case 1:
                guard offset + 4 <= bytes.count else { return nil }
                let size = Int(readUInt32(bytes, offset))
                offset += 4
                guard offset + size <= bytes.count else { return nil }
                parts[key] = Data(bytes[offset..<offset + size])
                offset += size
            case 2:
                guard offset + 2 <= bytes.count else { return nil }
                parts[key] = Int16(bitPattern: readUInt16(bytes, offset))
                offset += 2
            case 3:
                guard offset + 4 <= bytes.count else { return nil }
                parts[key] = Int32(bitPattern: readUInt32(bytes, offset))
                offset += 4
            case 4:
                guard offset + 8 <= bytes.count else { return nil }
                parts[key] = Int64(bitPattern: readUInt64(bytes, offset))
                offset += 8
            case 5:
                guard offset + 4 <= bytes.count else { return nil }
                let size = Int(readUInt32(bytes, offset))
                offset += 4
                guard offset + size <= bytes.count else { return nil }
                offset += size
            default:
                return nil
            }
        }
        return ParsedMessage(parts: parts, consumed: 4 + max(totalSize, 2))
    }

    public static func formatLogEntry(_ parts: [UInt8: AnyHashable]) -> String {
        let msgType = parts[0] as? Int32
        let ts = parts[1] as? Int64
        let tsMs = (parts[2] as? Int32) ?? 0
        let tag = (parts[5] as? String) ?? ""
        let level = parts[6].map { "L\($0)" } ?? ""
        let message = (parts[7] as? String) ?? ""
        let filename = (parts[11] as? String) ?? ""
        let lineno = parts[12].map { "\($0)" } ?? "?"
        let funcName = (parts[13] as? String) ?? ""
        let seq = parts[10].map { "#\($0)" } ?? ""
        let time = ts.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) + Double(tsMs) / 1000.0)) } ?? ""

        if msgType == 3 {
            let name = (parts[20] as? String) ?? ""
            let version = (parts[21] as? String) ?? ""
            let osName = (parts[22] as? String) ?? ""
            let osVersion = (parts[23] as? String) ?? ""
            let model = (parts[24] as? String) ?? ""
            return "\(time) [CLIENT_INFO] \(name) v\(version) | \(osName) \(osVersion) | \(model)".squashedWhitespace()
        }
        if msgType == 5 { return "\(time) [MARK] \(message)".squashedWhitespace() }
        if msgType == 1 { return "\(time) [BLOCK_START] \(tag.isEmpty ? "" : "[\(tag)]") \(message)".squashedWhitespace() }
        if msgType == 2 { return "\(time) [BLOCK_END]".squashedWhitespace() }

        let loc = filename.isEmpty ? "" : " \(filename):\(lineno)"
        let fn = funcName.isEmpty ? "" : " \(funcName)()"
        let tagText = tag.isEmpty ? "" : "[\(tag)]"
        return "\(time) \(seq) \(tagText) \(level)\(loc)\(fn) \(message)".squashedWhitespace()
    }

    private static func acquireLock(paths: IOSUsePaths) throws {
        let lock = "\(paths.root)/state/nslog.lock"
        if let text = try? String(contentsOfFile: lock, encoding: .utf8) {
            let parts = text.split(separator: " ")
            let pid = parts.first.flatMap { Int32($0) } ?? 0
            let startedAt = parts.dropFirst().first.flatMap { Int($0) } ?? 0
            if pid > 0, kill(pid, 0) == 0, nowMs() - startedAt < IOSUseProtocol.nslogLockStaleMilliseconds {
                throw CLIParseError.invalidValue("nslog already running (PID \(pid)). Only one nslog instance allowed at a time; cannot grep multiple patterns simultaneously.")
            }
            try? FileManager.default.removeItem(atPath: lock)
        }
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true, attributes: nil)
        try "\(getpid()) \(nowMs())".write(toFile: lock, atomically: true, encoding: .utf8)
    }

    private static func releaseLock(paths: IOSUsePaths) {
        let lock = "\(paths.root)/state/nslog.lock"
        guard let text = try? String(contentsOfFile: lock, encoding: .utf8),
              text.split(separator: " ").first.flatMap({ Int32($0) }) == getpid() else {
            return
        }
        try? FileManager.default.removeItem(atPath: lock)
    }

    static func regexOptions(_ flags: String) -> NSRegularExpression.Options {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        return options
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

public struct NSLoggerServerOptions: Equatable, Sendable {
    public let port: Int
    public var name: String?
    public var publishBonjour: Bool
    public var maxBufferSize: Int

    public init(name: String? = nil, publishBonjour: Bool = true, maxBufferSize: Int = IOSUseProtocol.nsloggerDefaultBufferSize) {
        self.port = IOSUseProtocol.nsloggerDefaultPort
        self.name = name
        self.publishBonjour = publishBonjour
        self.maxBufferSize = maxBufferSize
    }
}

public final class NSLoggerServer {
    public let port: Int
    public private(set) var isRunning = false
    public var onMessage: ((String) -> Void)?

    private let options: NSLoggerServerOptions
    private let paths: IOSUsePaths
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "ios-use.nslogger.server")
    private var bonjour: Process?
    private var receiveBuffer = Data()
    private var entries: [String] = []
    private var connectedClients = 0
    private let lock = NSLock()

    public init(options: NSLoggerServerOptions = NSLoggerServerOptions(), paths: IOSUsePaths) throws {
        self.options = options
        self.paths = paths
        self.port = options.port
    }

    public func start() throws {
        guard !isRunning else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw CLIParseError.invalidValue("invalid NSLogger port \(port)")
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw CLIParseError.invalidValue("NSLogger server did not become ready on port \(port)")
        }
        if let startError {
            listener.cancel()
            throw CLIParseError.invalidValue("NSLogger server failed to listen on port \(port): \(startError)")
        }
        self.listener = listener
        isRunning = true

        if options.publishBonjour {
            bonjour = startBonjour(name: options.name, port: port)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll(keepingCapacity: true)
        bonjour?.terminate()
        bonjour = nil
        isRunning = false
    }

    public func grep(pattern: String, flags: String = "") throws -> [String] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return try snapshot.filter { try NSLogService.matches($0, pattern: pattern, flags: flags) }
    }

    public func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public var logCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectedClients
    }

    public func ingestForTesting(_ data: Data) {
        markClientConnected()
        ingest(data)
    }

    public func markClientConnectedForTesting() {
        markClientConnected()
    }

    private func markClientConnected() {
        lock.lock()
        connectedClients = max(connectedClients, 1)
        lock.unlock()
    }

    private func ingest(_ data: Data) {
        lock.lock()
        receiveBuffer.append(data)
        if receiveBuffer.count > IOSUseProtocol.nsloggerMaxReceiveBufferBytes {
            receiveBuffer.removeAll(keepingCapacity: false)
        }
        while let parsed = NSLogService.parseMessage(receiveBuffer) {
            receiveBuffer.removeFirst(parsed.consumed)
            let entry = NSLogService.formatLogEntry(parsed.parts)
            appendLocked(entry)
            let callback = onMessage
            lock.unlock()
            callback?(entry)
            lock.lock()
        }
        lock.unlock()
    }

    private func appendLocked(_ entry: String) {
        entries.append(entry)
        if entries.count > options.maxBufferSize {
            entries.removeFirst(entries.count - options.maxBufferSize)
        }
    }

    private func startBonjour(name: String?, port: Int) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["dns-sd", "-R", (name?.isEmpty == false ? name! : Host.current().localizedName ?? "ios-use"), "_nslogger._tcp", "local", String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                self?.markClientConnected()
            case .failed, .cancelled:
                if let connection {
                    self?.remove(connection)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.markClientConnected()
                self.ingest(data)
            }
            if error == nil, !isComplete {
                self.receive(on: connection)
            } else {
                self.remove(connection)
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === connection }
        lock.unlock()
    }

}

private extension String {
    func squashedWhitespace() -> String {
        self.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
