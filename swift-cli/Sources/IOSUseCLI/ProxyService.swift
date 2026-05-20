import Darwin
import Foundation
import CryptoKit
import Dispatch
import IOSUseProtocol

public struct ProxySessionState: Codable, Equatable, Sendable {
    public struct NetworkInfo: Codable, Equatable, Sendable {
        public var interface: String
        public var macLanIp: String
    }

    public var sessionId: String
    public var status: String
    public var startedAt: Int
    public var stoppedAt: Int?
    public var udid: String
    public var flowFile: String
    public var caInstalled: Bool?
    public var network: NetworkInfo?
    public var mitmdumpPid: Int32?
    public var mitmdumpPort: Int?
}

public enum ProxyService {
    public static func doctor(paths: IOSUsePaths) -> String {
        var lines = ["", "Proxy Doctor:", ""]
        lines.append(commandExists("mitmdump") ? "  ✓ mitmdump installed" : "  ✗ mitmdump installed")
        let caExists = FileManager.default.fileExists(atPath: caPath(paths: paths))
        lines.append(caExists ? "  ✓ CA generated" : "  ✗ CA generated")
        lines.append(caTrustRecordStatus(paths: paths))
        if let wifi = try? detectLanInfo(interfaceName: nil) {
            lines.append("  ✓ Wi-Fi LAN IP: \(wifi.macLanIp) (\(wifi.interface))")
        } else {
            lines.append("  ✗ Wi-Fi LAN IP: unavailable")
        }
        let state = readState(paths: paths)
        let running = state?.status == "running" && isMitmdumpProcess(pid: state?.mitmdumpPid ?? 0, expectedFlowFile: state?.flowFile)
        lines.append(running ? "  ✓ Proxy: running" : "  - Proxy: not running")
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func configCA(udid requestedUdid: String?, paths: IOSUsePaths, outputSink: FlowService.OutputSink? = nil) throws -> String {
        let udid = try resolveUdid(requestedUdid, paths: paths)
        try ensureMitmproxyCA(paths: paths)
        let pem = try String(contentsOfFile: caPath(paths: paths), encoding: .utf8)
        let fingerprint = fingerprintPEM(pem)
        if caStateMatches(udid: udid, fingerprint: fingerprint, paths: paths) {
            return "CA already installed and trusted on device.\n"
        }
        try SessionService.prepareDriverSession(SessionOptions(udid: udid), paths: paths)
        _ = try withRecoveredDriver(paths: paths) { driver in
            try driver.proxyCAPush(caBase64: base64Body(fromPEM: pem))
        }
        let flowOutput = try FlowService.run(file: flowPath("proxy_configca.yaml", paths: paths), options: FlowOptions(file: "", udid: udid), paths: paths, outputSink: outputSink)

        let existingState = readState(paths: paths)
        var state = existingState ?? ProxySessionState(
            sessionId: "proxy-\(nowMs())",
            status: "stopped",
            startedAt: nowMs(),
            udid: udid,
            flowFile: ""
        )
        if existingState?.status != "running" || existingState?.udid == udid {
            state.udid = udid
            state.caInstalled = true
            try writeState(state, paths: paths)
        }
        try writeCAState(udid: udid, fingerprint: fingerprint, paths: paths)
        return (outputSink == nil ? flowOutput : "") + "CA installed and trusted on device.\n"
    }

    public static func start(udid requestedUdid: String?, interfaceName: String?, paths: IOSUsePaths, outputSink: FlowService.OutputSink? = nil) throws -> String {
        let interruptMonitor = InterruptMonitor()
        interruptMonitor.start()
        defer { interruptMonitor.stop() }
        let udid = try resolveStartUdid(requestedUdid, paths: paths)
        if let state = readState(paths: paths), state.status == "running", isMitmdumpProcess(pid: state.mitmdumpPid ?? 0, expectedFlowFile: state.flowFile) {
            throw CLIParseError.invalidValue("Proxy already running. Run `proxy stop` first.")
        }

        try ensureMitmproxyCA(paths: paths)
        let pem = try String(contentsOfFile: caPath(paths: paths), encoding: .utf8)
        let caReady = caStateMatches(udid: udid, fingerprint: fingerprintPEM(pem), paths: paths)
        let wifi = try detectLanInfo(interfaceName: interfaceName)
        let flowFile = "\(paths.artifacts)/proxy-\(isoStamp()).flow"
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)

        let pid = try startMitmdump(flowFile: flowFile, paths: paths)
        let startingState = ProxySessionState(
            sessionId: "proxy-\(nowMs())",
            status: "starting",
            startedAt: nowMs(),
            udid: udid,
            flowFile: flowFile,
            caInstalled: caReady,
            network: ProxySessionState.NetworkInfo(interface: wifi.interface, macLanIp: wifi.macLanIp),
            mitmdumpPid: pid,
            mitmdumpPort: IOSUseProtocol.proxyMitmdumpPort
        )
        try writeState(startingState, paths: paths)
        var startupCompleted = false
        defer {
            if !startupCompleted {
                killMitmdump(pid: pid, expectedFlowFile: flowFile)
                var stoppedState = startingState
                stoppedState.status = "stopped"
                stoppedState.stoppedAt = nowMs()
                stoppedState.mitmdumpPid = nil
                try? writeState(stoppedState, paths: paths)
            }
        }
        var pendingFlowOutput = ""
        do {
            try interruptMonitor.throwIfInterrupted()
            try verifyDeviceCanReachMac(udid: udid, macLanIp: wifi.macLanIp, paths: paths)
            try interruptMonitor.throwIfInterrupted()
            let flowOutput = try FlowService.run(
                file: flowPath("proxy_set_wifi_proxy.yaml", paths: paths),
                options: FlowOptions(file: "", udid: udid, externalVars: ["server": wifi.macLanIp, "port": String(IOSUseProtocol.proxyMitmdumpPort)]),
                paths: paths,
                outputSink: outputSink
            )
            if outputSink == nil {
                pendingFlowOutput = flowOutput
            }
        } catch {
            throw error
        }

        let state = ProxySessionState(
            sessionId: "proxy-\(nowMs())",
            status: "running",
            startedAt: nowMs(),
            udid: udid,
            flowFile: flowFile,
            caInstalled: caReady,
            network: ProxySessionState.NetworkInfo(interface: wifi.interface, macLanIp: wifi.macLanIp),
            mitmdumpPid: pid,
            mitmdumpPort: IOSUseProtocol.proxyMitmdumpPort
        )
        try writeState(state, paths: paths)
        startupCompleted = true
        var output = "Proxy started. Traffic: device -> \(wifi.macLanIp):\(IOSUseProtocol.proxyMitmdumpPort) -> mitmdump\nCapture: \(flowFile)\nView with: mitmweb -r \(flowFile)\n"
        if !caReady {
            output = "CA trust record not found. HTTP capture can still work; HTTPS decryption requires the CA to be installed and trusted.\n" + output
        }
        return pendingFlowOutput + output
    }

    public static func stop(udid requestedUdid: String?, paths: IOSUsePaths, outputSink: FlowService.OutputSink? = nil) throws -> String {
        guard let state = readState(paths: paths) else {
            if let requestedUdid, !requestedUdid.isEmpty {
                let flowOutput = try FlowService.run(file: flowPath("proxy_clear_wifi_proxy.yaml", paths: paths), options: FlowOptions(file: "", udid: requestedUdid), paths: paths, outputSink: outputSink)
                return (outputSink == nil ? flowOutput : "") + "Proxy stopped.\n"
            }
            throw CLIParseError.invalidValue("PROXY_NOT_RUNNING: no running proxy session")
        }
        let udid = try resolveStopUdid(requestedUdid, state: state)
        var pendingFlowOutput = ""
        do {
            let flowOutput = try FlowService.run(file: flowPath("proxy_clear_wifi_proxy.yaml", paths: paths), options: FlowOptions(file: "", udid: udid), paths: paths, outputSink: outputSink)
            if outputSink == nil {
                pendingFlowOutput = flowOutput
            }
        } catch {
            throw CLIParseError.invalidValue("Unable to clear device Wi-Fi proxy. Manually disable Wi-Fi proxy: Settings -> Wi-Fi -> current network (i) -> Configure Proxy -> Off, then retry `ios-use proxy stop`.")
        }
        killMitmdump(pid: state.mitmdumpPid, expectedFlowFile: state.flowFile)
        var stoppedState = state
        stoppedState.status = "stopped"
        stoppedState.stoppedAt = nowMs()
        stoppedState.mitmdumpPid = nil
        try writeState(stoppedState, paths: paths)
        return pendingFlowOutput + "Proxy stopped.\n"
    }

    public static func readState(paths: IOSUsePaths) -> ProxySessionState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath(paths: paths))) else { return nil }
        return try? JSONDecoder().decode(ProxySessionState.self, from: data)
    }

    static func resolveUdidForTesting(_ requested: String?, paths: IOSUsePaths) throws -> String {
        try resolveUdid(requested, paths: paths)
    }

    static func resolveStartUdidForTesting(_ requested: String?, paths: IOSUsePaths) throws -> String {
        try resolveStartUdid(requested, paths: paths)
    }

    static func resolveStopUdidForTesting(_ requested: String?, state: ProxySessionState) throws -> String {
        try resolveStopUdid(requested, state: state)
    }

    private static func resolveUdid(_ requested: String?, paths: IOSUsePaths) throws -> String {
        if let requested, !requested.isEmpty { return requested }
        if let session = readSession(paths: paths), let udid = session["udid"] as? String, !udid.isEmpty { return udid }
        if let state = readState(paths: paths), !state.udid.isEmpty { return state.udid }
        try SessionService.prepareDriverSession(SessionOptions(), paths: paths)
        if let session = readSession(paths: paths), let udid = session["udid"] as? String, !udid.isEmpty { return udid }
        throw CLIParseError.invalidValue("No device UDID. Pass --udid or run an action command first.")
    }

    private static func resolveStartUdid(_ requested: String?, paths: IOSUsePaths) throws -> String {
        if let requested, !requested.isEmpty { return requested }
        if let device = try DeviceService.listDevices(simulatorOnly: false, paths: paths).first {
            try SessionService.prepareDriverSession(SessionOptions(udid: device.udid), paths: paths)
            return device.udid
        }
        throw CLIParseError.invalidValue("No USB device UDID. Pass --udid or connect a configured USB device.")
    }

    private static func resolveStopUdid(_ requested: String?, state: ProxySessionState) throws -> String {
        if let requested, !requested.isEmpty, requested != state.udid {
            throw CLIParseError.invalidValue("Proxy is running for \(state.udid), not \(requested). Run `proxy stop --udid \(state.udid)` or manually disable Wi-Fi proxy.")
        }
        return state.udid
    }

    private static func readSession(paths: IOSUsePaths) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.session)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeState(_ state: ProxySessionState, paths: IOSUsePaths) throws {
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: statePath(paths: paths)), options: .atomic)
    }

    private static func statePath(paths: IOSUsePaths) -> String { "\(paths.root)/state/proxy-session.json" }
    private static func caStatePath(paths: IOSUsePaths) -> String { "\(paths.root)/state/proxy-ca.json" }
    static func caPathForTesting(paths: IOSUsePaths) -> String { caPath(paths: paths) }
    static func fingerprintPEMForTesting(_ pem: String) -> String { fingerprintPEM(pem) }
    private static func caPath(paths: IOSUsePaths) -> String { "\(mitmproxyDir(paths: paths))/mitmproxy-ca-cert.pem" }
    private static func mitmproxyDir(paths: IOSUsePaths) -> String { "\(paths.root)/mitmproxy" }

    private static func writeCAState(udid: String, fingerprint: String, paths: IOSUsePaths) throws {
        var root = readCAState(paths: paths)
        root[udid] = ["fingerprint": fingerprint, "installedAt": nowMs()]
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true, attributes: nil)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: caStatePath(paths: paths)), options: .atomic)
    }

    private static func readCAState(paths: IOSUsePaths) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: caStatePath(paths: paths))),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        return root
    }

    private static func caStateMatches(udid: String, fingerprint: String, paths: IOSUsePaths) -> Bool {
        readCAState(paths: paths)[udid]?["fingerprint"] as? String == fingerprint
    }

    private static func caTrustRecordStatus(paths: IOSUsePaths) -> String {
        guard FileManager.default.fileExists(atPath: caPath(paths: paths)),
              let pem = try? String(contentsOfFile: caPath(paths: paths), encoding: .utf8) else {
            return "  - CA trust record: unavailable"
        }
        let fingerprint = fingerprintPEM(pem)
        let records = readCAState(paths: paths)
        if records.values.contains(where: { $0["fingerprint"] as? String == fingerprint }) {
            return "  ✓ CA trust record: current"
        }
        return records.isEmpty ? "  - CA trust record: not recorded" : "  ✗ CA trust record: mismatch"
    }

    private static func ensureMitmproxyCA(paths: IOSUsePaths) throws {
        if FileManager.default.fileExists(atPath: caPath(paths: paths)) { return }
        try FileManager.default.createDirectory(atPath: mitmproxyDir(paths: paths), withIntermediateDirectories: true, attributes: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["mitmdump", "--set", "confdir=\(mitmproxyDir(paths: paths))", "--listen-port", "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(Double(IOSUseProtocol.mitmproxyCAGenerationTimeoutMilliseconds) / 1000.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: caPath(paths: paths)) {
                process.terminate()
                return
            }
            usleep(useconds_t(IOSUseProtocol.mitmproxyCAGenerationPollMilliseconds * 1000))
        }
        process.terminate()
        throw CLIParseError.invalidValue("CA_NOT_GENERATED: Failed to generate mitmproxy CA.")
    }

    private static func startMitmdump(flowFile: String, paths: IOSUsePaths) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "mitmdump",
            "-q",
            "--mode", "regular",
            "--listen-host", "0.0.0.0",
            "--listen-port", String(IOSUseProtocol.proxyMitmdumpPort),
            "--set", "confdir=\(mitmproxyDir(paths: paths))",
            "--set", "ssl_insecure=true",
            "--set", "connection_strategy=lazy",
            "--set", "save_stream_file=\(flowFile)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try waitForPort(IOSUseProtocol.proxyMitmdumpPort)
            guard processAlive(process.processIdentifier),
                  isMitmdumpProcess(pid: process.processIdentifier, expectedFlowFile: flowFile),
                  processOwnsListeningPort(pid: process.processIdentifier, port: IOSUseProtocol.proxyMitmdumpPort) else {
                process.terminate()
                throw CLIParseError.invalidValue("mitmdump did not start correctly on port \(IOSUseProtocol.proxyMitmdumpPort)")
            }
            return process.processIdentifier
        } catch {
            process.terminate()
            throw error
        }
    }

    private static func waitForPort(_ port: Int) throws {
        let deadline = Date().addingTimeInterval(Double(IOSUseProtocol.proxyWaitPortTimeoutMilliseconds) / 1000.0)
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                } == 0
                close(fd)
                if ok { return }
            }
            usleep(useconds_t(IOSUseProtocol.proxyWaitPortPollMilliseconds * 1000))
        }
        throw CLIParseError.invalidValue("Port \(port) not ready after \(IOSUseProtocol.proxyWaitPortTimeoutMilliseconds)ms")
    }

    private static func verifyDeviceCanReachMac(udid: String, macLanIp: String, paths: IOSUsePaths) throws {
        try SessionService.prepareDriverSession(SessionOptions(udid: udid), paths: paths)
        let token = UUID().uuidString
        let server = try ProxyProbeServer(token: token)
        defer { server.stop() }
        let url = "http://\(macLanIp):\(server.port)/ios-use-probe?token=\(token)"
        _ = try withRecoveredDriver(paths: paths) { driver in
            try driver.openURL(url: url)
        }
        guard server.wait(timeoutMilliseconds: IOSUseProtocol.proxyWaitPortTimeoutMilliseconds) else {
            throw CLIParseError.invalidValue("DEVICE_CANNOT_REACH_MAC: device \(udid) cannot reach \(macLanIp) before proxy configuration")
        }
    }

    private static func withRecoveredDriver<T>(paths: IOSUsePaths, _ body: (DriverClient) throws -> T) throws -> T {
        let driver = DriverClient(session: SessionService.read(paths: paths))
        do {
            defer { driver.close() }
            return try body(driver)
        } catch {
            driver.close()
            guard (error as? DriverClientError)?.isRecoverableConnectFailure == true else {
                throw error
            }
            try SessionService.launchPreparedDriverSession(paths: paths, verbose: false)
            let retry = DriverClient(session: SessionService.read(paths: paths))
            defer { retry.close() }
            return try body(retry)
        }
    }

    private static func detectLanInfo(interfaceName: String?) throws -> ProxySessionState.NetworkInfo {
        let iface = try interfaceName ?? wifiInterface()
        let output = try Shell.run("ifconfig", arguments: [iface])
        guard output.contains("status: active"),
              let ip = firstMatch(output, pattern: #"\binet\s+(\d+\.\d+\.\d+\.\d+)\b"#),
              !ip.hasPrefix("127."),
              !ip.hasPrefix("169.254.") else {
            throw CLIParseError.invalidValue("MAC_LAN_IP_NOT_FOUND: \(iface)")
        }
        return ProxySessionState.NetworkInfo(interface: iface, macLanIp: ip)
    }

    private static func wifiInterface() throws -> String {
        let output = try Shell.run("networksetup", arguments: ["-listallhardwareports"])
        let lines = output.split(separator: "\n").map(String.init)
        for index in lines.indices where lines[index].trimmingCharacters(in: .whitespaces) == "Hardware Port: Wi-Fi" {
            if lines.indices.contains(index + 1),
               let match = firstMatch(lines[index + 1], pattern: #"Device:\s*(\S+)"#) {
                return match
            }
        }
        throw CLIParseError.invalidValue("WIFI_INTERFACE_NOT_FOUND")
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func flowPath(_ name: String, paths: IOSUsePaths) -> String {
        let userFlow = "\(paths.root)/flows/\(name)"
        if FileManager.default.fileExists(atPath: userFlow) { return userFlow }
        return "\(FileManager.default.currentDirectoryPath)/flows/\(name)"
    }

    private static func base64Body(fromPEM pem: String) -> String {
        pem.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression)
    }

    private static func fingerprintPEM(_ pem: String) -> String {
        let der = Data(base64Encoded: base64Body(fromPEM: pem)) ?? Data(base64Body(fromPEM: pem).utf8)
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static func commandExists(_ command: String) -> Bool {
        (try? Shell.run("which", arguments: [command])) != nil
    }

    private static func processAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    static func isMitmdumpProcessForTesting(pid: Int32, expectedFlowFile: String?) -> Bool {
        isMitmdumpProcess(pid: pid, expectedFlowFile: expectedFlowFile)
    }

    private static func killMitmdump(pid: Int32?, expectedFlowFile: String?) {
        guard let pid, pid > 0 else { return }
        guard isMitmdumpProcess(pid: pid, expectedFlowFile: expectedFlowFile) else { return }
        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(Double(IOSUseProtocol.proxyProcessGraceMilliseconds) / 1000.0)
        while Date() < deadline {
            if !processAlive(pid) { return }
            usleep(100_000)
        }
        if processAlive(pid) { _ = kill(pid, SIGKILL) }
    }

    private static func isMitmdumpProcess(pid: Int32, expectedFlowFile: String?) -> Bool {
        guard let command = processCommand(pid: pid) else { return false }
        guard command.contains("mitmdump") else { return false }
        if let expectedFlowFile, !expectedFlowFile.isEmpty {
            return command.contains(expectedFlowFile)
        }
        return true
    }

    private static func processOwnsListeningPort(pid: Int32, port: Int) -> Bool {
        guard let output = try? Shell.run("lsof", arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]) else {
            return true
        }
        return output.split(separator: "\n").contains("p\(pid)")
    }

    private static func processCommand(pid: Int32) -> String? {
        (try? Shell.run("ps", arguments: ["-p", String(pid), "-o", "command="]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private static func isoStamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}

final class ProxyProbeServer {
    private(set) var port: Int

    private let fd: Int32
    private let token: String
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var matched = false
    private var stopped = false

    init(token: String) throws {
        self.token = token
        fd = socket(AF_INET, SOCK_STREAM, 0)
        port = 0
        guard fd >= 0 else {
            throw CLIParseError.invalidValue("Probe server socket failed: \(errno)")
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("Probe server bind failed: \(errno)")
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("Probe server getsockname failed: \(errno)")
        }
        port = Int(UInt16(bigEndian: bound.sin_port))
        guard listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("Probe server listen failed: \(errno)")
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func wait(timeoutMilliseconds: Int) -> Bool {
        _ = semaphore.wait(timeout: .now() + .milliseconds(timeoutMilliseconds))
        lock.lock()
        defer { lock.unlock() }
        return matched
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let shouldStop = stopped || matched
            lock.unlock()
            if shouldStop { return }

            let client = accept(fd, nil, nil)
            if client < 0 { return }
            handle(client: client)
        }
    }

    private func handle(client: Int32) {
        defer { Darwin.close(client) }
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(client, &buffer, buffer.count)
        let request = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
        let ok = request.contains(token)
        let body = ok ? "ok\n" : "bad token\n"
        let status = ok ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { ptr in
            Darwin.write(client, ptr, strlen(ptr))
        }
        if ok {
            lock.lock()
            matched = true
            lock.unlock()
            semaphore.signal()
        }
    }
}
