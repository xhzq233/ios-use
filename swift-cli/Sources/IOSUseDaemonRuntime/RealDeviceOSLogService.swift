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
        DaemonLogger(paths: IOSUsePaths.resolve()).info("[real-oslog] \(message)")
    }
}

private struct PairRecord {
    let hostID: String
    let systemBUID: String
    let hostPrivateKey: Data
    let hostCertificate: Data

    static func load(udid: String) throws -> PairRecord {
        let fd = try Usbmux.openSocket()
        defer { Darwin.close(fd) }
        let payload: [String: Any] = [
            "MessageType": "ReadPairRecord",
            "PairRecordID": udid,
            "ProgName": "ios-use",
            "ClientVersionString": "1.0",
        ]
        let response = try Usbmux.request(fd: fd, payload: payload, tag: 0)
        guard let rawPair = response["PairRecordData"] else {
            throw CLIParseError.invalidValue("No pair record found for device \(udid). Please pair with the device first.")
        }
        let pairData = try plistData(rawPair)
        let pair = try parsePlist(pairData)
        guard let hostID = pair["HostID"] as? String,
              let systemBUID = pair["SystemBUID"] as? String else {
            throw CLIParseError.invalidValue("Invalid pair record for device \(udid)")
        }
        return PairRecord(
            hostID: hostID,
            systemBUID: systemBUID,
            hostPrivateKey: try plistData(pair["HostPrivateKey"] as Any),
            hostCertificate: try plistData(pair["HostCertificate"] as Any)
        )
    }

    private static func plistData(_ value: Any) throws -> Data {
        if let data = value as? Data { return data }
        if let string = value as? String, let data = Data(base64Encoded: string) { return data }
        throw CLIParseError.invalidValue("Invalid pair record data")
    }
}

private struct LockdownService {
    let port: Int
    let enableServiceSSL: Bool
}

private final class LockdownClient {
    private let fd: Int32
    private let pairRecord: PairRecord
    private var stream: DeviceStream

    init(udid: String, pairRecord: PairRecord) throws {
        self.fd = try Usbmux.connect(udid: udid, port: 62_078)
        self.pairRecord = pairRecord
        self.stream = PlainDeviceStream(fd: fd)
    }

    func startSession() throws {
        let response = try request([
            "Request": "StartSession",
            "HostID": pairRecord.hostID,
            "SystemBUID": pairRecord.systemBUID,
        ])
        if let error = response["Error"] {
            throw CLIParseError.invalidValue("StartSession failed: \(error)")
        }
        guard response["SessionID"] != nil else {
            throw CLIParseError.invalidValue("StartSession returned no SessionID")
        }
    }

    func enableSessionSSL() throws {
        stream = try OpenSSLDeviceStream(fd: fd, pairRecord: pairRecord)
    }

    func startService(_ serviceName: String) throws -> LockdownService {
        let response = try request([
            "Request": "StartService",
            "Service": serviceName,
        ])
        if let error = response["Error"] {
            throw CLIParseError.invalidValue("StartService(\(serviceName)) failed: \(error)")
        }
        guard let port = response["Port"] as? Int else {
            throw CLIParseError.invalidValue("StartService(\(serviceName)) returned no port")
        }
        return LockdownService(port: port, enableServiceSSL: (response["EnableServiceSSL"] as? Bool) ?? false)
    }

    func disconnect() {
        stream.close()
        Darwin.close(fd)
    }

    private func request(_ body: [String: Any]) throws -> [String: Any] {
        var request = body
        request["Label"] = "ios-use"
        request["ProtocolVersion"] = "2"
        let xml = try serializePlist(request)
        try stream.write(uint32BE(UInt32(xml.count)) + xml)
        let header = try stream.readExact(byteCount: 4, timeoutSeconds: 5)
        let size = Int(readUInt32BE(header, 0))
        guard size > 0, size <= 10 * 1024 * 1024 else {
            throw CLIParseError.invalidValue("lockdown plist invalid size: \(size)")
        }
        return try parsePlist(try stream.readExact(byteCount: size, timeoutSeconds: 5))
    }
}

private protocol DeviceStream {
    func write(_ data: Data) throws
    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data
    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data
    func close()
}

private final class PlainDeviceStream: DeviceStream {
    let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    func write(_ data: Data) throws {
        try writeAll(fd: fd, data: data)
    }

    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while out.count < byteCount {
            let chunk = try readAvailable(maxBytes: byteCount - out.count, timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { throw CLIParseError.invalidValue("device read timeout") }
            out.append(chunk)
        }
        return out
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        guard waitForReadable(fd: fd, timeoutSeconds: timeoutSeconds) else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = Darwin.read(fd, &buffer, maxBytes)
        if n > 0 { return Data(buffer.prefix(n)) }
        if n == 0 { return Data() }
        if errno == EINTR || errno == EAGAIN { return Data() }
        throw CLIParseError.invalidValue("device read failed: errno \(errno)")
    }

    func close() {}
}

private final class OpenSSLDeviceStream: DeviceStream {
    private let process: Process
    private let proxy: LocalFDProxy
    private let tempDir: URL
    private let input: FileHandle
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let condition = NSCondition()
    private var buffer = Data()
    private var stderrBuffer = Data()
    private var closed = false

    init(fd: Int32, pairRecord: PairRecord) throws {
        Self.debug("prepare openssl client credentials")
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-openssl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let keyPath = tempDir.appendingPathComponent("host.key").path
        let certPath = tempDir.appendingPathComponent("host.crt").path
        try pairRecord.hostPrivateKey.write(to: URL(fileURLWithPath: keyPath), options: .atomic)
        try pairRecord.hostCertificate.write(to: URL(fileURLWithPath: certPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certPath)

        self.proxy = try LocalFDProxy(targetFD: fd)
        let inputPipe = Pipe()
        self.outputPipe = Pipe()
        self.errorPipe = Pipe()
        self.input = inputPipe.fileHandleForWriting
        self.process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "openssl", "s_client",
            "-quiet",
            "-connect", "127.0.0.1:\(proxy.port)",
            "-cert", certPath,
            "-key", keyPath,
            "-ign_eof",
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendOutput(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStderr(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.signal()
        }
        Self.debug("start openssl s_client on local proxy port \(proxy.port)")
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            proxy.close()
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    deinit {
        close()
    }

    func write(_ data: Data) throws {
        condition.lock()
        let isClosed = closed
        condition.unlock()
        if isClosed { throw CLIParseError.invalidValue("TLS stream is closed") }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw CLIParseError.invalidValue("TLS write failed: \(error)")
        }
    }

    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while out.count < byteCount {
            let chunk = try readAvailable(maxBytes: byteCount - out.count, timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { throw CLIParseError.invalidValue("TLS read timeout") }
            out.append(chunk)
        }
        return out
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty, !closed, process.isRunning, Date() < deadline {
            let nextWake = Date().addingTimeInterval(0.05)
            condition.wait(until: nextWake < deadline ? nextWake : deadline)
        }
        if !buffer.isEmpty {
            let count = min(maxBytes, buffer.count)
            let out = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(out)
        }
        if !process.isRunning, !closed {
            let detail = String(data: stderrBuffer, encoding: .utf8)?
                .split(separator: "\n")
                .suffix(3)
                .joined(separator: "\n") ?? ""
            throw CLIParseError.invalidValue("TLS process exited\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return Data()
    }

    func close() {
        condition.lock()
        if closed {
            condition.unlock()
            return
        }
        closed = true
        condition.broadcast()
        condition.unlock()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? input.close()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { process.interrupt() }
            }
        }
        proxy.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func appendOutput(_ data: Data) {
        condition.lock()
        buffer.append(data)
        condition.broadcast()
        condition.unlock()
    }

    private func appendStderr(_ data: Data) {
        condition.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > 16 * 1024 {
            stderrBuffer.removeFirst(stderrBuffer.count - 16 * 1024)
        }
        condition.broadcast()
        condition.unlock()
    }

    private func signal() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["IOS_USE_DEBUG_OSLOG"] == "1" else { return }
        DaemonLogger(paths: IOSUsePaths.resolve()).info("[real-oslog] \(message)")
    }
}

private final class LocalFDProxy {
    let port: Int
    private let listenerFD: Int32
    private let targetFD: Int32
    private let lock = NSLock()
    private var clientFD: Int32 = -1
    private var closed = false

    init(targetFD: Int32) throws {
        self.targetFD = targetFD
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIParseError.invalidValue("failed to create TLS proxy socket") }
        self.listenerFD = fd

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue("failed to bind TLS proxy socket: errno \(err)")
        }
        guard Darwin.listen(fd, 1) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue("failed to listen on TLS proxy socket: errno \(err)")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue("failed to inspect TLS proxy socket: errno \(err)")
        }
        self.port = Int(UInt16(bigEndian: bound.sin_port))
        startAccepting()
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let localClient = clientFD
        clientFD = -1
        lock.unlock()

        Darwin.close(listenerFD)
        if localClient >= 0 {
            Darwin.shutdown(localClient, SHUT_RDWR)
            Darwin.close(localClient)
        }
    }

    private func startAccepting() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let accepted = Darwin.accept(self.listenerFD, &addr, &len)
            guard accepted >= 0 else { return }
            self.lock.lock()
            if self.closed {
                self.lock.unlock()
                Darwin.close(accepted)
                return
            }
            self.clientFD = accepted
            self.lock.unlock()
            Self.bridge(from: accepted, to: self.targetFD, shutdownTargetOnEOF: true)
            Self.bridge(from: self.targetFD, to: accepted, shutdownTargetOnEOF: true)
        }
    }

    private static func bridge(from source: Int32, to destination: Int32, shutdownTargetOnEOF: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = Darwin.read(source, &buffer, buffer.count)
                if n > 0 {
                    do {
                        try writeAll(fd: destination, data: Data(buffer.prefix(n)))
                    } catch {
                        break
                    }
                } else if n == 0 {
                    break
                } else if errno != EINTR {
                    break
                }
            }
            if shutdownTargetOnEOF {
                Darwin.shutdown(destination, SHUT_WR)
            }
        }
    }
}

enum Usbmux {
    static func listUsbDeviceUdids() throws -> [String] {
        let fd = try openSocket()
        defer { Darwin.close(fd) }
        let list = try request(fd: fd, payload: [
            "MessageType": "ListDevices",
            "ProgName": "ios-use",
            "ClientVersionString": "1.0",
        ], tag: 0)
        guard let devices = list["DeviceList"] as? [[String: Any]] else {
            return []
        }
        return devices.compactMap { device in
            guard let props = device["Properties"] as? [String: Any],
                  let serial = props["SerialNumber"] as? String else { return nil }
            if let connectionType = props["ConnectionType"] as? String, connectionType != "USB" {
                return nil
            }
            return serial
        }
    }

    static func openSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIParseError.invalidValue("failed to open usbmux socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/var/run/usbmuxd".utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("usbmux socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { dst in
                for i in 0..<path.count { dst[i] = CChar(path[i]) }
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.count)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue("failed to connect usbmuxd: errno \(err)")
        }
        return fd
    }

    static func connect(udid: String, port: Int) throws -> Int32 {
        let fd = try openSocket()
        do {
            let list = try request(fd: fd, payload: [
                "MessageType": "ListDevices",
                "ProgName": "ios-use",
                "ClientVersionString": "1.0",
            ], tag: 0)
            guard let devices = list["DeviceList"] as? [[String: Any]] else {
                throw CLIParseError.invalidValue("usbmux ListDevices returned no devices")
            }
            let normalized = udid.replacingOccurrences(of: "-", with: "").lowercased()
            let match = devices.first { device in
                guard let props = device["Properties"] as? [String: Any],
                      let serial = props["SerialNumber"] as? String else { return false }
                return serial.replacingOccurrences(of: "-", with: "").lowercased() == normalized
            }
            guard let properties = match?["Properties"] as? [String: Any],
                  let deviceID = properties["DeviceID"] as? Int else {
                throw CLIParseError.invalidValue("Device \(udid) not found via usbmux. USB connection is required.")
            }
            let response = try request(fd: fd, payload: [
                "MessageType": "Connect",
                "ProgName": "ios-use",
                "ClientVersionString": "1.0",
                "DeviceID": deviceID,
                "PortNumber": swap16(port),
            ], tag: 1)
            guard (response["Number"] as? Int) == 0 else {
                throw CLIParseError.invalidValue("usbmux Connect failed with code \(response["Number"] ?? "unknown")")
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func request(fd: Int32, payload: [String: Any], tag: UInt32) throws -> [String: Any] {
        let body = try serializePlist(payload)
        var frame = Data()
        frame.append(uint32LE(UInt32(16 + body.count)))
        frame.append(uint32LE(1))
        frame.append(uint32LE(8))
        frame.append(uint32LE(tag))
        frame.append(body)
        try writeAll(fd: fd, data: frame)
        let header = try readExact(fd: fd, byteCount: 16, timeoutSeconds: 5)
        let size = Int(readUInt32LE(header, 0))
        guard size >= 16, size <= 10 * 1024 * 1024 else {
            throw CLIParseError.invalidValue("usbmux invalid response size: \(size)")
        }
        return try parsePlist(try readExact(fd: fd, byteCount: size - 16, timeoutSeconds: 5))
    }

    private static func swap16(_ value: Int) -> Int {
        ((value & 0xff) << 8) | ((value >> 8) & 0xff)
    }
}

private func serializePlist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

private func parsePlist(_ data: Data) throws -> [String: Any] {
    let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dict = raw as? [String: Any] else {
        throw CLIParseError.invalidValue("plist response is not a dictionary")
    }
    return dict
}

private func readExact(fd: Int32, byteCount: Int, timeoutSeconds: Double) throws -> Data {
    var out = Data()
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while out.count < byteCount {
        guard waitForReadable(fd: fd, timeoutSeconds: max(0, deadline.timeIntervalSinceNow)) else {
            throw CLIParseError.invalidValue("socket read timeout")
        }
        var buffer = [UInt8](repeating: 0, count: byteCount - out.count)
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n > 0 {
            out.append(contentsOf: buffer.prefix(n))
        } else if n == 0 {
            throw CLIParseError.invalidValue("socket closed")
        } else if errno != EINTR && errno != EAGAIN {
            throw CLIParseError.invalidValue("socket read failed: errno \(errno)")
        }
    }
    return out
}

private func writeAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            if n > 0 {
                offset += n
            } else if n < 0, errno != EINTR && errno != EAGAIN {
                throw CLIParseError.invalidValue("socket write failed: errno \(errno)")
            }
        }
    }
}

private func waitForReadable(fd: Int32, timeoutSeconds: Double) -> Bool {
    var set = fd_set()
    fdZero(&set)
    fdSet(fd, &set)
    var timeout = timeval(
        tv_sec: Int(timeoutSeconds),
        tv_usec: Int32((timeoutSeconds - floor(timeoutSeconds)) * 1_000_000)
    )
    return Darwin.select(fd + 1, &set, nil, nil, &timeout) > 0
}

private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
        let result = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if ProcessInfo.processInfo.environment["IOS_USE_DEBUG_OSLOG"] == "1" {
            DaemonLogger(paths: IOSUsePaths.resolve()).info("[real-oslog] fcntl flags=\(flags) setNonBlocking=\(result) errno=\(errno)")
        }
    } else if ProcessInfo.processInfo.environment["IOS_USE_DEBUG_OSLOG"] == "1" {
        DaemonLogger(paths: IOSUsePaths.resolve()).info("[real-oslog] fcntl get failed errno=\(errno)")
    }
}

private func fdZero(_ set: inout fd_set) {
    memset(&set, 0, MemoryLayout<fd_set>.size)
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= 1 << Int32(bitOffset)
        }
    }
}

private func uint32LE(_ value: UInt32) -> Data {
    Data([
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff),
    ])
}

private func uint32BE(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ])
}

private func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    let bytes = [UInt8](data)
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
    let bytes = [UInt8](data)
    return (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
}
