import Darwin
import Foundation

public enum NSLogService {
    private static let defaultPort = 50_000
    private static let staleLockMs = 60 * 60 * 1000
    private static let maxBufferBytes = 1024 * 1024

    public static func stream(options: NSLogOptions, paths: IOSUsePaths) throws -> String {
        try acquireLock(paths: paths)
        defer { releaseLock(paths: paths) }

        let credentials = try ensureTLSCredentials(paths: paths)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = [
            "openssl", "s_server",
            "-accept", String(defaultPort),
            "-cert", credentials.cert,
            "-key", credentials.key,
            "-quiet",
        ]
        let stdout = Pipe()
        server.standardOutput = stdout
        server.standardError = Pipe()
        try server.run()

        let bonjour = startBonjour(name: options.name, port: defaultPort)
        defer {
            server.terminate()
            bonjour?.terminate()
        }

        print("NSLogger listening on port \(defaultPort) (SSL)")
        print("Streaming logs... Press Ctrl+C to stop.")

        let regex = try options.grep.map { try NSRegularExpression(pattern: $0, options: regexOptions(options.flags)) }
        var buffer = Data()
        while server.isRunning {
            autoreleasepool {
                let chunk = stdout.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty {
                    usleep(100_000)
                    return
                }
                buffer.append(chunk)
                if buffer.count > maxBufferBytes {
                    buffer.removeAll(keepingCapacity: false)
                    return
                }
                while let parsed = parseMessage(buffer) {
                    buffer.removeFirst(parsed.consumed)
                    let entry = formatLogEntry(parsed.parts)
                    if let regex {
                        let range = NSRange(entry.startIndex..<entry.endIndex, in: entry)
                        if regex.firstMatch(in: entry, range: range) == nil { continue }
                    }
                    print(entry)
                }
            }
        }
        return ""
    }

    public struct ParsedMessage: Equatable {
        public var parts: [UInt8: AnyHashable]
        public var consumed: Int
    }

    public static func parseMessage(_ data: Data) -> ParsedMessage? {
        guard data.count >= 6 else { return nil }
        let totalSize = Int(readUInt32(data, 0))
        guard data.count >= 4 + totalSize else { return nil }
        let partCount = Int(readUInt16(data, 4))
        var offset = 6
        var parts: [UInt8: AnyHashable] = [:]

        for _ in 0..<partCount {
            guard offset + 2 <= data.count else { break }
            let key = data[offset]
            let type = data[offset + 1]
            offset += 2
            switch type {
            case 0:
                guard offset + 4 <= data.count else { return nil }
                let size = Int(readUInt32(data, offset))
                offset += 4
                guard offset + size <= data.count else { return nil }
                parts[key] = String(data: data[offset..<offset + size], encoding: .utf8) ?? ""
                offset += size
            case 1:
                guard offset + 4 <= data.count else { return nil }
                let size = Int(readUInt32(data, offset))
                offset += 4
                guard offset + size <= data.count else { return nil }
                parts[key] = Data(data[offset..<offset + size])
                offset += size
            case 2:
                guard offset + 2 <= data.count else { return nil }
                parts[key] = Int16(bitPattern: readUInt16(data, offset))
                offset += 2
            case 3:
                guard offset + 4 <= data.count else { return nil }
                parts[key] = Int32(bitPattern: readUInt32(data, offset))
                offset += 4
            case 4:
                guard offset + 8 <= data.count else { return nil }
                parts[key] = Int64(bitPattern: readUInt64(data, offset))
                offset += 8
            case 5:
                guard offset + 4 <= data.count else { return nil }
                let size = Int(readUInt32(data, offset))
                offset += 4
                guard offset + size <= data.count else { return nil }
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
            if pid > 0, kill(pid, 0) == 0, nowMs() - startedAt < staleLockMs {
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

    private static func ensureTLSCredentials(paths: IOSUsePaths) throws -> (key: String, cert: String) {
        let runtime = "\(paths.root)/runtime"
        let key = "\(runtime)/nslogger-selfsigned.key"
        let cert = "\(runtime)/nslogger-selfsigned.crt"
        if FileManager.default.fileExists(atPath: key), FileManager.default.fileExists(atPath: cert) {
            return (key, cert)
        }
        try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true, attributes: nil)
        _ = try Shell.run("openssl", arguments: [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", key,
            "-out", cert,
            "-nodes",
            "-subj", "/CN=ios-use NSLogger",
            "-days", "3650",
        ])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key)
        return (key, cert)
    }

    private static func startBonjour(name: String?, port: Int) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["dns-sd", "-R", (name?.isEmpty == false ? name! : Host.current().localizedName ?? "ios-use"), "_nslogger-ssl._tcp", "local", String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    private static func regexOptions(_ flags: String) -> NSRegularExpression.Options {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        return options
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

private extension String {
    func squashedWhitespace() -> String {
        self.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
