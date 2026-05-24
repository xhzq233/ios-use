import Darwin
import Foundation

enum RealDeviceOSLogService {
    static func collectSyslog(udid: String, timeoutSeconds: Double) throws -> [String] {
        debug("load pair record")
        let pairRecord = try PairRecord.load(udid: udid)
        debug("connect lockdown")
        let service = try startSyslogRelay(udid: udid, pairRecord: pairRecord)

        debug("connect syslog relay port \(service.port) ssl=\(service.enableServiceSSL)")
        let fd = try Usbmux.connect(udid: udid, port: service.port)
        defer { Darwin.close(fd) }
        let stream: DeviceStream
        if service.enableServiceSSL {
            debug("enable syslog TLS")
            stream = try OpenSSLDeviceStream(fd: fd, pairRecord: pairRecord)
        } else {
            stream = PlainDeviceStream(fd: fd)
        }
        defer { stream.close() }
        debug("send syslog start")
        try stream.write(Data("start".utf8))
        debug("read syslog lines")
        return try readSyslogLines(stream: stream, timeoutSeconds: timeoutSeconds)
    }

    private static func startSyslogRelay(udid: String, pairRecord: PairRecord) throws -> LockdownService {
        let lockdown = try LockdownClient(udid: udid, pairRecord: pairRecord)
        do {
            debug("start lockdown session")
            try lockdown.startSession()
            debug("enable lockdown TLS")
            try lockdown.enableSessionSSL()
            debug("start syslog relay")
            let service = try lockdown.startService("com.apple.syslog_relay")
            lockdown.disconnect()
            return service
        } catch {
            debug("lockdown TLS path failed: \(error)")
            lockdown.disconnect()
        }

        let fallback = try LockdownClient(udid: udid, pairRecord: pairRecord)
        do {
            debug("fallback lockdown session without TLS")
            try fallback.startSession()
            debug("fallback start syslog relay")
            let service = try fallback.startService("com.apple.syslog_relay")
            fallback.disconnect()
            return service
        } catch {
            fallback.disconnect()
            throw error
        }
    }

    private static func readSyslogLines(stream: DeviceStream, timeoutSeconds: Double) throws -> [String] {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        var lines: [String] = []
        var buffer = ""
        while Date() < deadline {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let chunk = try stream.readAvailable(maxBytes: 16 * 1024, timeoutSeconds: min(0.25, remaining))
            if chunk.isEmpty { continue }
            buffer += String(data: chunk, encoding: .utf8) ?? ""
            let parts = buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            buffer = parts.last ?? ""
            for line in parts.dropLast() {
                let trimmed = cleanSyslogLine(line)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        let tail = cleanSyslogLine(buffer)
        if !tail.isEmpty { lines.append(tail) }
        return lines
    }

    private static func cleanSyslogLine(_ line: String) -> String {
        line.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["IOS_USE_DEBUG_OSLOG"] == "1" else { return }
        FileHandle.standardError.write(Data("[real-oslog] \(message)\n".utf8))
    }
}
