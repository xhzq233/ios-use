import Foundation

struct OSLogEvent: Equatable {
    var rawLine: String
    var processName: String?
    var pid: Int?
    var message: String
}

enum RealDeviceOSTraceService {
    static var collectorForTesting: ((String, Double?, OSLogOptions.SourceFilter) throws -> [String])?
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm:ss"
        return formatter
    }()

    static func collectActivity(udid: String, timeoutSeconds: Double?, source: OSLogOptions.SourceFilter) throws -> [String] {
        if let collectorForTesting {
            return try collectorForTesting(udid, timeoutSeconds, source)
        }
        var lines: [String] = []
        try streamActivity(udid: udid, timeoutSeconds: timeoutSeconds, source: source) { event in
            lines.append(event.rawLine)
        }
        return lines
    }

    static func streamActivity(udid: String, timeoutSeconds: Double? = nil, source: OSLogOptions.SourceFilter, onEvent: (OSLogEvent) throws -> Void) throws {
        let resolvedPID = try resolvePID(source: source, udid: udid)
        let stream = try LockdownSession.connectToService("com.apple.os_trace_relay", udid: udid)
        defer { stream.close() }

        var options: [String: Any] = [
            "MessageFilter": 0xFFFF,
            "StreamFlags": 0x3C,
            "Request": "StartActivity",
        ]
        options["Pid"] = resolvedPID.map { Int64($0) } ?? Int64(0x0FFFFFFFF)
        try sendPlist(options, stream: stream)
        try checkRequestSuccessful(try readPlist(stream: stream, timeoutSeconds: 5), request: "StartActivity")

        let deadline = timeoutSeconds.map { Date().addingTimeInterval(max(0, $0)) }
        while deadline.map({ Date() < $0 }) ?? true {
            let remaining = deadline.map { max(0, $0.timeIntervalSinceNow) } ?? 0.25
            guard let frame = try readMessageFrame(stream: stream, timeoutSeconds: min(0.25, remaining)) else {
                continue
            }
            guard let event = parseEventPacket(frame) else { continue }
            try onEvent(event)
        }
    }

    private static func resolvePID(source: OSLogOptions.SourceFilter, udid: String) throws -> Int? {
        if source.process != nil, source.pid != nil {
            throw CLIParseError.invalidValue("--process and --pid are mutually exclusive")
        }
        if let pid = source.pid {
            return pid
        }
        guard let process = source.process, !process.isEmpty else {
            return nil
        }
        let stream = try LockdownSession.connectToService("com.apple.os_trace_relay", udid: udid)
        defer { stream.close() }
        let processes = try pidList(stream: stream)
        let matches = processes.filter { $0.processName == process }
        if matches.isEmpty {
            throw CLIParseError.invalidValue("os_trace_relay found no process named \(process)")
        }
        if matches.count > 1 {
            let pids = matches.map { String($0.pid) }.joined(separator: ", ")
            throw CLIParseError.invalidValue("os_trace_relay found multiple processes named \(process): \(pids)")
        }
        return matches[0].pid
    }

    private static func pidList(stream: DeviceStream) throws -> [(pid: Int, processName: String)] {
        try sendPlist(["Request": "PidList"], stream: stream)
        let response = try readPlist(stream: stream, timeoutSeconds: 5)
        try checkRequestSuccessful(response, request: "PidList")
        guard let payload = response["Payload"] as? [String: Any] else {
            throw CLIParseError.invalidValue("PidList returned no Payload")
        }
        return payload.compactMap { key, value in
            guard let pid = Int(key),
                  let dict = value as? [String: Any],
                  let processName = dict["ProcessName"] as? String else {
                return nil
            }
            return (pid: pid, processName: processName)
        }
    }

    private static func sendPlist(_ body: [String: Any], stream: DeviceStream) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: body, format: .binary, options: 0)
        try stream.write(uint32BE(UInt32(data.count)) + data)
    }

    private static func readPlist(stream: DeviceStream, timeoutSeconds: Double) throws -> [String: Any] {
        guard let frame = try readMessageFrame(stream: stream, timeoutSeconds: timeoutSeconds) else {
            throw CLIParseError.invalidValue("os_trace_relay plist read timeout")
        }
        return try parsePlist(frame)
    }

    private static func readMessageFrame(stream: DeviceStream, timeoutSeconds: Double) throws -> Data? {
        let messageType = try stream.readAvailable(maxBytes: 1, timeoutSeconds: timeoutSeconds)
        guard !messageType.isEmpty else { return nil }
        guard messageType.count == 1 else {
            throw CLIParseError.invalidValue("os_trace_relay invalid message type frame")
        }
        let lengthData = try stream.readExact(byteCount: 4, timeoutSeconds: 5)
        let length: UInt32
        switch messageType[messageType.startIndex] {
        case 1:
            length = readUInt32BE(lengthData, 0)
        case 2:
            length = readUInt32LE(lengthData, 0)
        default:
            throw CLIParseError.invalidValue("os_trace_relay unexpected message type \(messageType[messageType.startIndex])")
        }
        guard length > 0, length <= 100 * 1024 * 1024 else {
            throw CLIParseError.invalidValue("os_trace_relay invalid frame size \(length)")
        }
        return try stream.readExact(byteCount: Int(length), timeoutSeconds: 30)
    }

    private static func checkRequestSuccessful(_ response: [String: Any], request: String) throws {
        guard response["Status"] as? String == "RequestSuccessful" else {
            throw CLIParseError.invalidValue("\(request) failed: \(plistResponseSummary(response))")
        }
    }

    static func parseEventPacket(_ data: Data) -> OSLogEvent? {
        guard data.count >= 129 else { return nil }
        let marker = data[data.startIndex]
        let type = readUInt32LE(data, 1)
        guard marker == 2, type == 8 || type == 2 else { return nil }
        let headerSize = Int(readUInt32LE(data, 5))
        guard headerSize >= 129, data.count >= headerSize else { return nil }
        let pid = Int(readUInt32LE(data, 9))
        let procPathLength = Int(readUInt16LE(data, 37))
        let timeSec = Int64(bitPattern: readUInt64LE(data, 55))
        let timeUsec = readUInt32LE(data, 63)
        let level = data[data.startIndex + 68]
        let imagePathLength = Int(readUInt16LE(data, 107))
        let messageLength = Int(readUInt32LE(data, 109))
        let stringsOffset = headerSize
        let messageOffset = stringsOffset + procPathLength + imagePathLength
        guard messageOffset + messageLength <= data.count else { return nil }

        let processPath = stringField(data, offset: stringsOffset, length: procPathLength)
        let processName = processPath.split(separator: "/").last.map(String.init) ?? processPath
        let message = stringField(data, offset: messageOffset, length: messageLength)
        let line = "\(formatTimestamp(seconds: timeSec, microseconds: timeUsec)) \(processName)[\(pid)] <\(levelName(level))>: \(message)"
        return OSLogEvent(rawLine: line, processName: processName, pid: pid, message: message)
    }

    private static func stringField(_ data: Data, offset: Int, length: Int) -> String {
        guard length > 0, offset >= 0, offset + length <= data.count else { return "" }
        let bytes = data[offset..<(offset + length)].filter { $0 != 0 }
        return String(data: Data(bytes), encoding: .utf8) ?? ""
    }

    private static func levelName(_ level: UInt8) -> String {
        switch level {
        case 0: return "Notice"
        case 0x01: return "Info"
        case 0x02: return "Debug"
        case 0x10: return "Error"
        case 0x11: return "Fault"
        default: return "Unknown"
        }
    }

    private static func formatTimestamp(seconds: Int64, microseconds: UInt32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return "\(timestampFormatter.string(from: date)).\(String(format: "%06u", microseconds))"
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        let bytes = [UInt8](data)
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}
