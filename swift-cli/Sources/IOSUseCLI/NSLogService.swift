import Darwin
import Foundation
import IOSUseProtocol
@preconcurrency import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

public enum NSLogService {
    public static func stream(options: NSLogOptions, paths: IOSUsePaths) throws -> String {
        let grepRegex = try options.grep.flatMap { grep -> NSRegularExpression? in
            guard !grep.isEmpty else { return nil }
            return try NSRegularExpression(pattern: grep, options: regexOptions(options.flags))
        }

        try acquireForegroundOwnership(paths: paths, mode: "cli")
        let server = try NSLoggerServer(options: NSLoggerServerOptions(name: options.name), paths: paths)
        do {
            try server.start()
            try writeLock(paths: paths, server: server, mode: "cli")
        } catch {
            server.stop()
            releaseLock(paths: paths)
            throw error
        }
        defer {
            server.stop()
            releaseLock(paths: paths)
        }

        server.onMessage = { entry in
            guard let grepRegex else {
                writeStdout("\(entry)\n")
                return
            }
            if Self.matches(entry, regex: grepRegex) {
                writeStdout("\(entry)\n")
            }
        }

        writeStdout("NSLogger listening on port \(server.port) (SSL)\n")
        writeStdout("Streaming logs... Press Ctrl+C to stop.\n")

        let interruptMonitor = InterruptMonitor(onInterrupt: {
            writeStderr("NSLogger interrupted, cleaning up...\n")
        })
        interruptMonitor.start()
        defer { interruptMonitor.stop() }

        while server.isRunning && !interruptMonitor.interrupted {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        try interruptMonitor.throwIfInterrupted()
        return ""
    }

    static func matches(_ entry: String, pattern: String, flags: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern, options: regexOptions(flags))
        return matches(entry, regex: regex)
    }

    static func matches(_ entry: String, regex: NSRegularExpression) -> Bool {
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

    static var processCommandOverrideForTesting: ((Int32) -> String?)?
    static var processAliveOverrideForTesting: ((Int32) -> Bool)?
    static var killOverrideForTesting: ((Int32, Int32) -> Int32)?

    static func acquireForegroundOwnership(paths: IOSUsePaths, mode: String) throws {
        if let record = readLock(paths: paths) {
            if processAlive(record.pid) {
                guard record.iosUseHome == nil || standardizedPath(record.iosUseHome ?? "") == standardizedPath(paths.root),
                      isIOSUseNSLogOwnerProcess(pid: record.pid) else {
                    throw CLIParseError.invalidValue("nslog lock is owned by an unrelated live process (PID \(record.pid)); not terminating it. Remove stale lock manually if needed: \(paths.nslogLock)")
                }
                terminateProcess(pid: record.pid)
                if let bonjourPid = record.bonjourPid {
                    terminateBonjourPublisher(pid: bonjourPid)
                }
            }
            try? FileManager.default.removeItem(atPath: paths.nslogLock)
        }
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: paths.nslogLock).deletingLastPathComponent().path, withIntermediateDirectories: true, attributes: nil)
    }

    static func writeLock(paths: IOSUsePaths, server: NSLoggerServer, mode: String) throws {
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: paths.nslogLock).deletingLastPathComponent().path, withIntermediateDirectories: true, attributes: nil)
        let record = NSLogLockRecord(
            pid: getpid(),
            bonjourPid: server.bonjourPid,
            port: server.port,
            name: server.bonjourServiceName,
            startedAt: ISO8601DateFormatter().string(from: Date()),
            iosUseHome: paths.root,
            mode: mode
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: URL(fileURLWithPath: paths.nslogLock), options: [.atomic])
    }

    static func releaseLock(paths: IOSUsePaths) {
        guard let record = readLock(paths: paths), record.pid == getpid() else {
            return
        }
        try? FileManager.default.removeItem(atPath: paths.nslogLock)
    }

    static func regexOptions(_ flags: String) throws -> NSRegularExpression.Options {
        var options: NSRegularExpression.Options = []
        for flag in flags {
            switch flag {
            case "i":
                options.insert(.caseInsensitive)
            case "m":
                options.insert(.anchorsMatchLines)
            case "s":
                options.insert(.dotMatchesLineSeparators)
            case "g", "u", "y":
                continue
            default:
                throw CLIParseError.invalidValue("Invalid regex flag: \(flag)")
            }
        }
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

    private static func readLock(paths: IOSUsePaths) -> NSLogLockRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.nslogLock)) else { return nil }
        if let record = try? JSONDecoder().decode(NSLogLockRecord.self, from: data) {
            return record
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ")
        guard let pid = parts.first.flatMap({ Int32($0) }) else { return nil }
        return NSLogLockRecord(
            pid: pid,
            bonjourPid: nil,
            port: nil,
            name: nil,
            startedAt: parts.dropFirst().first.map(String.init) ?? "",
            iosUseHome: nil,
            mode: "legacy"
        )
    }

    private static func terminateProcess(pid: Int32) {
        _ = sendSignal(pid: pid, signal: SIGTERM)
        try? waitForProcessExit(pid: pid, timeoutSeconds: 1)
        if processAlive(pid) {
            _ = sendSignal(pid: pid, signal: SIGKILL)
            try? waitForProcessExit(pid: pid, timeoutSeconds: 1)
        }
    }

    private static func terminateBonjourPublisher(pid: Int32) {
        guard pid > 0, isBonjourPublisherProcess(pid: pid) else { return }
        _ = sendSignal(pid: pid, signal: SIGTERM)
        try? waitForProcessExit(pid: pid, timeoutSeconds: 1)
        if processAlive(pid) {
            _ = sendSignal(pid: pid, signal: SIGKILL)
        }
    }

    private static func isIOSUseNSLogOwnerProcess(pid: Int32) -> Bool {
        guard let command = processCommand(pid: pid)?.lowercased() else { return false }
        return command.contains("ios-use") && (command.contains(" nslog") || command.contains(" flow"))
    }

    private static func isBonjourPublisherProcess(pid: Int32) -> Bool {
        guard let command = processCommand(pid: pid) else { return false }
        return command.contains("dns-sd -R") && command.contains("_nslogger-ssl._tcp")
    }

    private static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if let override = processAliveOverrideForTesting {
            return override(pid)
        }
        return Darwin.kill(pid, 0) == 0
    }

    private static func sendSignal(pid: Int32, signal: Int32) -> Int32 {
        if let override = killOverrideForTesting {
            return override(pid, signal)
        }
        return Darwin.kill(pid, signal)
    }

    private static func processCommand(pid: Int32) -> String? {
        if let override = processCommandOverrideForTesting {
            return override(pid)
        }
        return (try? Shell.run("ps", arguments: ["-p", String(pid), "-o", "command="]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    private static func waitForProcessExit(pid: Int32, timeoutSeconds: Double) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !processAlive(pid) {
                return
            }
            usleep(50_000)
        }
    }
}

private struct NSLogLockRecord: Codable, Equatable {
    var pid: Int32
    var bonjourPid: Int32?
    var port: Int?
    var name: String?
    var startedAt: String
    var iosUseHome: String?
    var mode: String
}

public struct NSLoggerServerOptions: Equatable, Sendable {
    public let port: Int
    public let useSSL: Bool
    public var name: String?
    public var publishBonjour: Bool
    public var maxBufferSize: Int

    public init(port: Int = 0, name: String? = nil, publishBonjour: Bool = true, maxBufferSize: Int = IOSUseProtocol.nsloggerDefaultBufferSize) {
        self.port = port
        self.useSSL = true
        self.name = name
        self.publishBonjour = publishBonjour
        self.maxBufferSize = maxBufferSize
    }
}

public final class NSLoggerServer {
    public private(set) var port: Int
    public private(set) var isRunning = false
    public var onMessage: ((String) -> Void)?
    public private(set) var bonjourPid: Int32?
    public private(set) var bonjourServiceName: String?

    private let options: NSLoggerServerOptions
    private let paths: IOSUsePaths
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var bonjour: Process?
    private var receiveBuffer = Data()
    private var entries: [String] = []
    private var entryBaseIndex = 0
    private var totalEntriesSeen = 0
    private var connectedClients = 0
    private var activeClients = 0
    private let lock = NSLock()

    public init(options: NSLoggerServerOptions = NSLoggerServerOptions(), paths: IOSUsePaths) throws {
        self.options = options
        self.paths = paths
        self.port = options.port
    }

    public func start() throws {
        guard !isRunning else { return }
        let credentials = try ensureTLSCredentials()
        try startNIOSSLServer(keyPath: credentials.keyPath, certPath: credentials.certPath)
        isRunning = true

        if options.publishBonjour {
            do {
                let publisher = try startBonjour(name: options.name, port: port)
                bonjour = publisher
                bonjourPid = publisher.processIdentifier
            } catch {
                stop()
                throw error
            }
        }
    }

    public func stop() {
        try? serverChannel?.close().wait()
        serverChannel = nil
        try? eventLoopGroup?.syncShutdownGracefully()
        eventLoopGroup = nil
        bonjour?.terminate()
        bonjour = nil
        bonjourPid = nil
        isRunning = false
    }

    public func grep(pattern: String, flags: String = "") throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: try NSLogService.regexOptions(flags))
        return grep(regex: regex, from: 0).matches
    }

    public func grep(regex: NSRegularExpression, from index: Int) -> (matches: [String], nextIndex: Int) {
        lock.lock()
        let absoluteStart = max(index, entryBaseIndex)
        let relativeStart = max(0, min(absoluteStart - entryBaseIndex, entries.count))
        let snapshot = Array(entries[relativeStart..<entries.count])
        let nextIndex = totalEntriesSeen
        lock.unlock()
        return (snapshot.filter { NSLogService.matches($0, regex: regex) }, nextIndex)
    }

    public func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        entryBaseIndex = totalEntriesSeen
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

    public var activeClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeClients
    }

    public func ingestForTesting(_ data: Data) {
        if clientCount == 0 {
            markClientConnected()
        }
        ingest(data)
    }

    public func markClientConnectedForTesting() {
        markClientConnected()
    }

    private func markClientConnected() {
        lock.lock()
        connectedClients += 1
        activeClients += 1
        lock.unlock()
    }

    private func markClientDisconnected() {
        lock.lock()
        activeClients = max(0, activeClients - 1)
        lock.unlock()
    }

    private func ingest(_ data: Data) {
        lock.lock()
        receiveBuffer.append(data)
        if receiveBuffer.count > IOSUseProtocol.nsloggerMaxReceiveBufferBytes {
            receiveBuffer.removeAll(keepingCapacity: false)
        }
        while let parsed = NSLogService.parseMessage(receiveBuffer) {
            if parsed.consumed == receiveBuffer.count {
                receiveBuffer.removeAll(keepingCapacity: true)
            } else {
                receiveBuffer.removeFirst(parsed.consumed)
            }
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
        totalEntriesSeen += 1
        if entries.count > options.maxBufferSize {
            let removed = entries.count - options.maxBufferSize
            entries.removeFirst(removed)
            entryBaseIndex += removed
        }
    }

    private func startBonjour(name: String?, port: Int) throws -> Process {
        let serviceName = name?.isEmpty == false ? name! : defaultBonjourName()
        bonjourServiceName = serviceName
        let serviceType = "_nslogger-ssl._tcp"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["dns-sd", "-R", serviceName, serviceType, "local", String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            throw CLIParseError.invalidValue("NSLogger Bonjour publish failed for \(serviceName) on port \(port): \(error)")
        }
    }

    private func ensureTLSCredentials() throws -> (keyPath: String, certPath: String) {
        let runtime = "\(paths.root)/runtime"
        let keyPath = "\(runtime)/nslogger-selfsigned.key"
        let certPath = "\(runtime)/nslogger-selfsigned.crt"
        try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true, attributes: nil)
        if !FileManager.default.fileExists(atPath: keyPath) {
            try NSLoggerTLSMaterial.privateKeyPEM.write(toFile: keyPath, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: certPath) {
            try NSLoggerTLSMaterial.certificatePEM.write(toFile: certPath, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certPath)
        return (keyPath, certPath)
    }

    private func startNIOSSLServer(keyPath: String, certPath: String) throws {
        let certificates = try NIOSSLCertificate.fromPEMFile(certPath).map { NIOSSLCertificateSource.certificate($0) }
        let privateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates,
            privateKey: .privateKey(privateKey)
        )
        let sslContext = try NIOSSLContext(configuration: configuration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext)).flatMap {
                        channel.pipeline.addHandler(NSLoggerTLSChannelHandler(
                            onActive: { [weak self] in self?.markClientConnected() },
                            onInactive: { [weak self] in self?.markClientDisconnected() },
                            onData: { [weak self] data in self?.ingest(data) }
                        ))
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "0.0.0.0", port: port)
                .wait()
            if let actualPort = channel.localAddress?.port {
                port = actualPort
            }
            eventLoopGroup = group
            serverChannel = channel
        } catch {
            try? group.syncShutdownGracefully()
            throw CLIParseError.invalidValue("NSLogger TLS server failed to listen on port \(port): \(error)")
        }
    }

    private func defaultBonjourName() -> String {
        let hostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hostName.isEmpty {
            return hostName
        }
        return Host.current().name ?? Host.current().localizedName ?? "ios-use"
    }

}

private enum NSLoggerTLSMaterial {
    static let certificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDFzCCAf+gAwIBAgIUFxaEdAiLg1028An4yy6J28acsJowDQYJKoZIhvcNAQEL
    BQAwGzEZMBcGA1UEAwwQaW9zLXVzZSBOU0xvZ2dlcjAeFw0yNjA1MTYxNDIyNTRa
    Fw0zNjA1MTMxNDIyNTRaMBsxGTAXBgNVBAMMEGlvcy11c2UgTlNMb2dnZXIwggEi
    MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCijeVhfdYwR01fWjNInaoNucjb
    z6Gz0tkCRzIOyEYefbkqW76NFA0v9ZY0pm+BzLRUmjLISfjssLjCKYs18kyBOVeI
    pfdwW3xQreyHJcaAcYuxrLa8Oaa14EwBD9pgx4nFzYbP72FF9XxYdW1/8b2ClxoG
    4Z8bq+T/oddssznjJ2rlGhYOxeE+wVSBDdGlzmnk/sWZFBk6JBfSSFaerOhGy+Kg
    E06hh0Ns3tbUDPkxXt/irk8mgR08XXAcD/KXqNeHCq4sBO6JAVzdQlbaENdRaFsM
    yFkgjXPIgP11HdgVDc+kcHonLMrZi2ocIIK0Dc6NIwrry4xCUg+8xf8OoXHZAgMB
    AAGjUzBRMB0GA1UdDgQWBBRzR2b2zoLMwLwTFmafCQRZWNMT6DAfBgNVHSMEGDAW
    gBRzR2b2zoLMwLwTFmafCQRZWNMT6DAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3
    DQEBCwUAA4IBAQAxcAOdZYsvgX+lCGZTMN4aJanCN8Rc4syE48FlUoae62jy7AGz
    kbdf8GPmIjUArspzZIQ91RJ9C+xFhf7E9bayfsPfB0hPAQpcTJ0Lz0cosMC/IZYi
    J+6hMaqpNxAhZ2246xAQvgAuJJS9NVuGFjZ1ofCgg6pSodWV/yHIJ/w87GGTCT/U
    8UsxeoctIafbGeRElxmQ4GcU46R1ym7wOCkKhMu1FuqRxxYTlaMHc4r5NbMr+p4h
    rcLRmHWY748ju9Pn/JUtBY8O+k0woSB/VevgxjIRtDd1inrnIFz3Ddnk9fnkVXN6
    2Go8I5ymCUCMBL/flPiKvAydygxkhj8i5FoY
    -----END CERTIFICATE-----
    """

    // Public, intentionally non-secret compatibility key for local NSLogger TLS.
    static let privateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCijeVhfdYwR01f
    WjNInaoNucjbz6Gz0tkCRzIOyEYefbkqW76NFA0v9ZY0pm+BzLRUmjLISfjssLjC
    KYs18kyBOVeIpfdwW3xQreyHJcaAcYuxrLa8Oaa14EwBD9pgx4nFzYbP72FF9XxY
    dW1/8b2ClxoG4Z8bq+T/oddssznjJ2rlGhYOxeE+wVSBDdGlzmnk/sWZFBk6JBfS
    SFaerOhGy+KgE06hh0Ns3tbUDPkxXt/irk8mgR08XXAcD/KXqNeHCq4sBO6JAVzd
    QlbaENdRaFsMyFkgjXPIgP11HdgVDc+kcHonLMrZi2ocIIK0Dc6NIwrry4xCUg+8
    xf8OoXHZAgMBAAECggEAGC38O1rBBBBvIWpk633MYFtM1emWN437Crw1ZX6D86Am
    7XaVKx4a8hHZZH6HYqrk/hqryCA8v1RwPy130C/5ElXJwAFUA6oQHV4pq1bCprN9
    IJI84lW/BxnUpGnLxY6Y30v5rC+C7Cmec/gPsDLwyh6Y2AIyrSaOGzpjNX+ZckDb
    d+PZwKfkW1KkuX8Eirwb261XRC46gHK26Sjbep3LUwDoIq644ZyYHj4KUiTiSt+i
    DAKTdH+oRJ3Y9biUbW50zgIQtKD7ngDllsM0e8uL/7+AKSsz3IgbhdqS7CNV6h9S
    wD6VNvt0QdADUICdnAvhVYMw6hH+Gp7hfmOQdGh5IwKBgQDY2tTUJ6s4UanLeEPQ
    BQiSG7OZc5oVZDQEbJEQOcpvQcGJFUnbsKyNrUkmW16wqysr4idEyQcFSjvtJ8mw
    JFaoHYJ9grBXqiF0OpRLYb+lB3adcoy423rS7p0isrYPpwqJm+ZFDmwJVbilUFwC
    Mafa8ex1hrZ6c/tuP6+KAZBZuwKBgQC/5cKYRfChMy5auGmhJ1PRTjtg1mFaBJIX
    5CPK6wrIubgp/sh2aV07QsO/nmzAg7xFzzhkL+LGGRJ2WO4B5ujSc4BRyK4yWJCx
    EG19es+lWrmIVCW5WwOh1kAdBabR27xfqWpu7wHtlgp9dYRYQs8P6vqKfWpA/jmH
    /ur5WhcvewKBgDsIr6Glvu3RBWk3rzZE+IVV9zmSB+NE6Qg/Seph4SMSgo4/9mBR
    I1haUSyY+RkdL959bXVDSJ7/C3tPNo+2BMU1a12ho0HqNbs/azluPc6+TmMkWPzF
    +xTLEonsnrV6Its9Tp2EBJMx+9c9Hh8Wx3xKGbYQ20JQqqTjv3TRYiubAoGAczYL
    vgaHsRCcbQU5DfMhpJF2nu43JqeF2ugzARpasCaoxjXcvxMFUZYFFl+UZYTyHWuL
    LMN/QHY/GmTMCMJM2EVWLkPxKfL4dAYr5mE8l8c/ivUSbRWSubB7b7E79dUaZMi/
    SPkgTDd/9tD+c0sxLBpk747ao0i+28KV6r1HHE8CgYEAuLTzS+uYM2TmzoRyoeV4
    Akvw/WZGaNm2+oQkEtHAud7D9VREQbx3ZrxP/BIipgcH+gnRGtRwJMwr6j15k1jh
    M5/kp2aTxnixZLlNJwagosWGbmv9eQJqhbUf/HLXhJatJnJVkurCGq2m65IHxJuQ
    lHUdeOOvSaBdXKihgfpVVwI=
    -----END PRIVATE KEY-----
    """
}

private final class NSLoggerTLSChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let onActive: () -> Void
    private let onInactive: () -> Void
    private let onData: (Data) -> Void

    init(onActive: @escaping () -> Void, onInactive: @escaping () -> Void, onData: @escaping (Data) -> Void) {
        self.onActive = onActive
        self.onInactive = onInactive
        self.onData = onData
    }

    func channelActive(context: ChannelHandlerContext) {
        onActive()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }
        onData(Data(bytes))
    }

    func channelInactive(context: ChannelHandlerContext) {
        onInactive()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

private func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

private extension String {
    func squashedWhitespace() -> String {
        var result = ""
        var pendingSpace = false
        for scalar in unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
