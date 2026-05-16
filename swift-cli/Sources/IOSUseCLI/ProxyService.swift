import Darwin
import Foundation
import CryptoKit
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
        lines.append(FileManager.default.fileExists(atPath: caPath()) ? "  ✓ CA generated" : "  ✗ CA generated")
        if let wifi = try? detectLanInfo(interfaceName: nil) {
            lines.append("  ✓ Wi-Fi LAN IP: \(wifi.macLanIp) (\(wifi.interface))")
        } else {
            lines.append("  ✗ Wi-Fi LAN IP: unavailable")
        }
        let state = readState(paths: paths)
        let running = state?.status == "running" && processAlive(state?.mitmdumpPid)
        lines.append(running ? "  ✓ Proxy: running" : "  - Proxy: not running")
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func configCA(udid requestedUdid: String?, paths: IOSUsePaths) throws -> String {
        let udid = try resolveUdid(requestedUdid, paths: paths)
        try ensureMitmproxyCA()
        let pem = try String(contentsOfFile: caPath(), encoding: .utf8)
        _ = try DriverClient().proxyCAPush(caBase64: base64Body(fromPEM: pem))
        _ = try FlowService.run(file: flowPath("proxy_configca.yaml", paths: paths), options: FlowOptions(file: "", udid: udid), paths: paths)

        var state = readState(paths: paths) ?? ProxySessionState(
            sessionId: "proxy-\(nowMs())",
            status: "stopped",
            startedAt: nowMs(),
            udid: udid,
            flowFile: ""
        )
        state.udid = udid
        state.caInstalled = true
        try writeState(state, paths: paths)
        try writeCAState(udid: udid, fingerprint: fingerprintPEM(pem), paths: paths)
        return "CA installed and trusted on device.\n"
    }

    public static func start(udid requestedUdid: String?, interfaceName: String?, paths: IOSUsePaths) throws -> String {
        let udid = try resolveUdid(requestedUdid, paths: paths)
        if let state = readState(paths: paths), state.status == "running", processAlive(state.mitmdumpPid) {
            throw CLIParseError.invalidValue("Proxy already running. Run `proxy stop` first.")
        }

        try ensureMitmproxyCA()
        let pem = try String(contentsOfFile: caPath(), encoding: .utf8)
        let caReady = caStateMatches(udid: udid, fingerprint: fingerprintPEM(pem), paths: paths)
        let wifi = try detectLanInfo(interfaceName: interfaceName)
        let flowFile = "\(paths.artifacts)/proxy-\(isoStamp()).flow"
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)

        let pid = try startMitmdump(flowFile: flowFile)
        do {
            _ = try FlowService.run(
                file: flowPath("proxy_set_wifi_proxy.yaml", paths: paths),
                options: FlowOptions(file: "", udid: udid, externalVars: ["server": wifi.macLanIp, "port": String(IOSUseProtocol.proxyMitmdumpPort)]),
                paths: paths
            )
        } catch {
            killPid(pid)
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
        var output = "Proxy started. Traffic: device -> \(wifi.macLanIp):\(IOSUseProtocol.proxyMitmdumpPort) -> mitmdump\nCapture: \(flowFile)\nView with: mitmweb -r \(flowFile)\n"
        if !caReady {
            output = "CA trust record not found. HTTP capture can still work; HTTPS decryption requires the CA to be installed and trusted.\n" + output
        }
        return output
    }

    public static func stop(udid requestedUdid: String?, paths: IOSUsePaths) throws -> String {
        let state = readState(paths: paths)
        let udid = try resolveUdid(requestedUdid ?? state?.udid, paths: paths)
        do {
            _ = try FlowService.run(file: flowPath("proxy_clear_wifi_proxy.yaml", paths: paths), options: FlowOptions(file: "", udid: udid), paths: paths)
        } catch {
            throw CLIParseError.invalidValue("Unable to clear device Wi-Fi proxy. Manually disable Wi-Fi proxy: Settings -> Wi-Fi -> current network (i) -> Configure Proxy -> Off, then retry `ios-use proxy stop`.")
        }
        killPid(state?.mitmdumpPid)
        if var state {
            state.status = "stopped"
            state.stoppedAt = nowMs()
            state.mitmdumpPid = nil
            try writeState(state, paths: paths)
        }
        return "Proxy stopped.\n"
    }

    public static func readState(paths: IOSUsePaths) -> ProxySessionState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath(paths: paths))) else { return nil }
        return try? JSONDecoder().decode(ProxySessionState.self, from: data)
    }

    private static func resolveUdid(_ requested: String?, paths: IOSUsePaths) throws -> String {
        if let requested, !requested.isEmpty { return requested }
        if let state = readState(paths: paths), !state.udid.isEmpty { return state.udid }
        if let session = readSession(paths: paths), let udid = session["udid"] as? String, !udid.isEmpty { return udid }
        throw CLIParseError.invalidValue("No device UDID. Pass --udid or run an action command first.")
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
    private static func caPath() -> String { "\(NSHomeDirectory())/.mitmproxy/mitmproxy-ca-cert.pem" }
    private static func mitmproxyDir() -> String { "\(NSHomeDirectory())/.mitmproxy" }

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

    private static func ensureMitmproxyCA() throws {
        if FileManager.default.fileExists(atPath: caPath()) { return }
        try FileManager.default.createDirectory(atPath: mitmproxyDir(), withIntermediateDirectories: true, attributes: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["mitmdump", "--set", "confdir=\(mitmproxyDir())", "--listen-port", "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(Double(IOSUseProtocol.mitmproxyCAGenerationTimeoutMilliseconds) / 1000.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: caPath()) {
                process.terminate()
                return
            }
            usleep(useconds_t(IOSUseProtocol.mitmproxyCAGenerationPollMilliseconds * 1000))
        }
        process.terminate()
        throw CLIParseError.invalidValue("CA_NOT_GENERATED: Failed to generate mitmproxy CA.")
    }

    private static func startMitmdump(flowFile: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "mitmdump",
            "-q",
            "--mode", "regular",
            "--listen-host", "0.0.0.0",
            "--listen-port", String(IOSUseProtocol.proxyMitmdumpPort),
            "--set", "confdir=\(mitmproxyDir())",
            "--set", "ssl_insecure=true",
            "--set", "connection_strategy=lazy",
            "--set", "save_stream_file=\(flowFile)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try waitForPort(IOSUseProtocol.proxyMitmdumpPort)
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

    private static func killPid(_ pid: Int32?) {
        guard let pid, pid > 0 else { return }
        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(Double(IOSUseProtocol.proxyProcessGraceMilliseconds) / 1000.0)
        while Date() < deadline {
            if !processAlive(pid) { return }
            usleep(100_000)
        }
        if processAlive(pid) { _ = kill(pid, SIGKILL) }
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private static func isoStamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
