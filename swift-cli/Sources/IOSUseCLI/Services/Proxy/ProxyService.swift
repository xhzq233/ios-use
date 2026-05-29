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
    public var lastCapture: ProxyLastCapture? = nil
    public var serverStatus: String? = nil
    public var deviceProxyStatus: String? = nil
    public var caStatus: String? = nil
    public var lastError: String? = nil
}

public struct ProxyLastCapture: Codable, Equatable, Sendable {
    public var flowFile: String
    public var udid: String
    public var startedAt: Int
    public var stoppedAt: Int?
    public var status: String
    public var mitmdumpPid: Int32?
    public var network: ProxySessionState.NetworkInfo?
}

public enum ProxyService {
    static var mitmdumpReadOverrideForTesting: ((String, Bool, String?) throws -> String)?
    static var startMitmdumpOverrideForTesting: ((String, IOSUsePaths) throws -> Int32)?
    static var detectLanInfoOverrideForTesting: ((String?) throws -> ProxySessionState.NetworkInfo)?
    static var flowDirectoryOverrideForTesting: String?

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
        if let state {
            lines.append("  - Proxy server status: \(running ? "running" : (state.serverStatus ?? state.status))")
            lines.append("  - Device proxy status: \(state.deviceProxyStatus ?? (state.status == "running" ? "configured" : "unknown"))")
            if let caStatus = state.caStatus {
                lines.append("  - CA status: \(caStatus)")
            }
            if let lastError = state.lastError, !lastError.isEmpty {
                lines.append("  - Last proxy error: \(lastError)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func configCA(markTrusted: Bool = false, paths: IOSUsePaths, outputSink: FlowService.OutputSink? = nil) throws -> String {
        let activeDriver = try SessionService.requireDriverLock(paths: paths)
        let udid = activeDriver.udid
        try ensureMitmproxyCA(paths: paths)
        let pem = try String(contentsOfFile: caPath(paths: paths), encoding: .utf8)
        let fingerprint = fingerprintPEM(pem)
        if caStateMatches(udid: udid, fingerprint: fingerprint, paths: paths) {
            return "CA already installed and trusted on device.\n"
        }
        if markTrusted {
            try writeCAState(udid: udid, fingerprint: fingerprint, paths: paths)
            try updateProxyCAStatus(udid: udid, caInstalled: true, caStatus: "trusted", lastError: nil, paths: paths)
            return "CA trust marked as manually confirmed on device.\n"
        }
        _ = try withRecoveredDriver(paths: paths) { driver in
            try driver.proxyCAPush(caBase64: base64Body(fromPEM: pem))
        }
        do {
            let flowOutput = try FlowService.run(file: flowPath("proxy_configca.yaml", paths: paths), options: FlowOptions(file: ""), paths: paths, outputSink: outputSink)
            try writeCAState(udid: udid, fingerprint: fingerprint, paths: paths)
            try updateProxyCAStatus(udid: udid, caInstalled: true, caStatus: "trusted", lastError: nil, paths: paths)
            return (outputSink == nil ? flowOutput : "") + "CA installed and trusted on device.\n"
        } catch let signal as CLIExitSignal {
            try? updateProxyCAStatus(udid: udid, caInstalled: false, caStatus: "pendingManualTrust", lastError: signal.message, paths: paths)
            throw signal
        } catch {
            try? updateProxyCAStatus(udid: udid, caInstalled: false, caStatus: "pendingManualTrust", lastError: String(describing: error), paths: paths)
            return """
            CA trust requires manual confirmation.
            Complete the CA profile install/trust steps on the device, then run:
              ios-use proxy configca --mark-trusted
            Automation stopped at: \(error)
            """
        }
    }

    public static func start(interfaceName: String?, serverOnly: Bool = false, paths: IOSUsePaths, outputSink: FlowService.OutputSink? = nil) throws -> String {
        let interruptMonitor = InterruptMonitor()
        interruptMonitor.start()
        defer { interruptMonitor.stop() }
        let activeDriver = serverOnly ? try? SessionService.requireDriverLock(paths: paths) : try SessionService.requireDriverLock(paths: paths)
        let udid = activeDriver?.udid ?? ""

        if var state = readState(paths: paths), isRunningProxyServer(state) {
            if serverOnly {
                return "Proxy server already running. Traffic: device -> \(state.network?.macLanIp ?? "Mac LAN IP"):\(state.mitmdumpPort ?? IOSUseProtocol.proxyMitmdumpPort) -> mitmdump\nCapture: \(state.flowFile)\nRead with: ios-use proxy read\n"
            }
            if !state.udid.isEmpty && state.udid != udid {
                throw CLIParseError.invalidValue("Proxy is running for \(state.udid), not active driver \(udid). Run `ios-use start \(state.udid)` and `ios-use proxy stop`, or manually disable Wi-Fi proxy.")
            }
            if state.deviceProxyStatus == "configured" || state.deviceProxyStatus == nil {
                throw CLIParseError.invalidValue("Proxy already running. Run `proxy stop` first.")
            }
            let wifi = try interfaceName == nil ? (state.network ?? detectLanInfo(interfaceName: nil)) : detectLanInfo(interfaceName: interfaceName)
            let caReady = currentCAReady(udid: udid, paths: paths) ?? (state.caInstalled ?? false)
            state.udid = udid
            state.network = wifi
            state.caInstalled = caReady
            state.caStatus = caReady ? "trusted" : "unknown"
            state.deviceProxyStatus = "pending"
            state.serverStatus = "running"
            state.lastCapture = state.lastCapture ?? lastCapture(from: state)
            try writeState(state, paths: paths)
            return try configureDeviceProxy(state: state, wifi: wifi, caReady: caReady, paths: paths, outputSink: outputSink, interruptMonitor: interruptMonitor)
        }

        try ensureMitmproxyCA(paths: paths)
        let pem = try String(contentsOfFile: caPath(paths: paths), encoding: .utf8)
        let caReady = !udid.isEmpty && caStateMatches(udid: udid, fingerprint: fingerprintPEM(pem), paths: paths)
        let wifi = try detectLanInfo(interfaceName: interfaceName)
        let flowFile = "\(paths.artifacts)/proxy-\(isoStamp()).mitm"
        try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)

        let pid = try startMitmdump(flowFile: flowFile, paths: paths)
        var state = ProxySessionState(
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
        state.serverStatus = "running"
        state.deviceProxyStatus = serverOnly ? "unknown" : "pending"
        state.caStatus = caReady ? "trusted" : "unknown"
        state.lastCapture = lastCapture(from: state)
        do {
            try writeState(state, paths: paths)
        } catch {
            killMitmdump(pid: pid, expectedFlowFile: flowFile)
            throw error
        }

        if serverOnly {
            return serverStartedOutput(state: state, wifi: wifi, configuredDevice: false, caReady: caReady)
        }
        return try configureDeviceProxy(state: state, wifi: wifi, caReady: caReady, paths: paths, outputSink: outputSink, interruptMonitor: interruptMonitor)
    }

    public static func stop(serverOnly: Bool = false, paths: IOSUsePaths, outputSink: FlowService.OutputSink? = nil) throws -> String {
        guard let state = readState(paths: paths) else {
            throw CLIParseError.invalidValue("PROXY_NOT_RUNNING: no running proxy session")
        }
        guard state.status == "running" else {
            throw CLIParseError.invalidValue("PROXY_NOT_RUNNING: no running proxy session")
        }
        if serverOnly {
            return try stopProxyServerOnly(state: state, paths: paths)
        }
        let activeDriver = try SessionService.requireDriverLock(paths: paths)
        guard state.udid.isEmpty || state.udid == activeDriver.udid else {
            throw CLIParseError.invalidValue("Proxy is running for \(state.udid), not active driver \(activeDriver.udid). Run `ios-use start \(state.udid)` and `ios-use proxy stop`, or manually disable Wi-Fi proxy.")
        }
        var pendingFlowOutput = ""
        do {
            let flowOutput = try FlowService.run(file: flowPath("proxy_clear_wifi_proxy.yaml", paths: paths), options: FlowOptions(file: ""), paths: paths, outputSink: outputSink)
            if outputSink == nil {
                pendingFlowOutput = flowOutput
            }
        } catch {
            var failedState = state
            failedState.deviceProxyStatus = "clearFailed"
            failedState.lastError = String(describing: error)
            failedState.lastCapture = failedState.lastCapture ?? lastCapture(from: failedState)
            try? writeState(failedState, paths: paths)
            throw CLIParseError.invalidValue("Unable to clear device Wi-Fi proxy. Manually disable Wi-Fi proxy: Settings -> Wi-Fi -> current network (i) -> Configure Proxy -> Off, then retry `ios-use proxy stop`.")
        }
        killMitmdump(pid: state.mitmdumpPid, expectedFlowFile: state.flowFile)
        var stoppedState = state
        stoppedState.status = "stopped"
        stoppedState.stoppedAt = nowMs()
        stoppedState.mitmdumpPid = nil
        stoppedState.serverStatus = "stopped"
        stoppedState.deviceProxyStatus = "unknown"
        stoppedState.lastError = nil
        stoppedState.lastCapture = lastCapture(from: stoppedState)
        try writeState(stoppedState, paths: paths)
        return pendingFlowOutput + "Proxy stopped.\n"
    }

    public static func read(filter: String?, raw: Bool, last: Int?, paths: IOSUsePaths) throws -> String {
        guard let capture = readState(paths: paths)?.lastCapture, !capture.flowFile.isEmpty else {
            throw CLIParseError.invalidValue("No proxy capture found. Run `ios-use proxy start` first.")
        }
        guard FileManager.default.fileExists(atPath: capture.flowFile) else {
            throw CLIParseError.invalidValue("Proxy capture file not found: \(capture.flowFile). Run `ios-use proxy start` first.")
        }
        let output = try readMitmdump(flowFile: capture.flowFile, raw: raw, filter: filter)
        guard let last, last > 0 else { return output }
        let hadTrailingNewline = output.hasSuffix("\n")
        let trimmedOutput = hadTrailingNewline ? String(output.dropLast()) : output
        let lines = trimmedOutput.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(last).joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    public static func readState(paths: IOSUsePaths) -> ProxySessionState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath(paths: paths))) else { return nil }
        return try? JSONDecoder().decode(ProxySessionState.self, from: data)
    }

    static func activeUdidForTesting(paths: IOSUsePaths) throws -> String {
        try SessionService.requireDriverLock(paths: paths).udid
    }

    private static func writeState(_ state: ProxySessionState, paths: IOSUsePaths) throws {
        try FileManager.default.createDirectory(atPath: "\(paths.root)/state", withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: statePath(paths: paths)), options: .atomic)
    }

    private static func updateProxyCAStatus(udid: String, caInstalled: Bool, caStatus: String, lastError: String?, paths: IOSUsePaths) throws {
        let existingState = readState(paths: paths)
        var state = existingState ?? ProxySessionState(
            sessionId: "proxy-\(nowMs())",
            status: "stopped",
            startedAt: nowMs(),
            udid: udid,
            flowFile: ""
        )
        guard existingState?.status != "running" || existingState?.udid == udid else {
            return
        }
        state.udid = udid
        state.caInstalled = caInstalled
        state.caStatus = caStatus
        state.lastError = lastError
        try writeState(state, paths: paths)
    }

    private static func currentCAReady(udid: String, paths: IOSUsePaths) -> Bool? {
        guard !udid.isEmpty,
              let pem = try? String(contentsOfFile: caPath(paths: paths), encoding: .utf8) else {
            return nil
        }
        return caStateMatches(udid: udid, fingerprint: fingerprintPEM(pem), paths: paths)
    }

    private static func isRunningProxyServer(_ state: ProxySessionState) -> Bool {
        state.status == "running" && isMitmdumpProcess(pid: state.mitmdumpPid ?? 0, expectedFlowFile: state.flowFile)
    }

    private static func configureDeviceProxy(
        state: ProxySessionState,
        wifi: ProxySessionState.NetworkInfo,
        caReady: Bool,
        paths: IOSUsePaths,
        outputSink: FlowService.OutputSink?,
        interruptMonitor: InterruptMonitor
    ) throws -> String {
        var pendingState = state
        pendingState.serverStatus = "running"
        pendingState.deviceProxyStatus = "pending"
        pendingState.lastError = nil
        pendingState.lastCapture = pendingState.lastCapture ?? lastCapture(from: pendingState)
        try writeState(pendingState, paths: paths)

        var pendingFlowOutput = ""
        do {
            try interruptMonitor.throwIfInterrupted()
            let flowOutput = try FlowService.run(
                file: flowPath("proxy_set_wifi_proxy.yaml", paths: paths),
                options: FlowOptions(file: "", externalVars: ["server": wifi.macLanIp, "port": String(pendingState.mitmdumpPort ?? IOSUseProtocol.proxyMitmdumpPort)]),
                paths: paths,
                outputSink: outputSink
            )
            if outputSink == nil {
                pendingFlowOutput = flowOutput
            }
        } catch let signal as CLIExitSignal {
            var failedState = pendingState
            failedState.lastError = signal.message
            failedState.lastCapture = failedState.lastCapture ?? lastCapture(from: failedState)
            try? writeState(failedState, paths: paths)
            throw signal
        } catch {
            var failedState = pendingState
            failedState.lastError = String(describing: error)
            failedState.lastCapture = failedState.lastCapture ?? lastCapture(from: failedState)
            try? writeState(failedState, paths: paths)
            throw CLIParseError.invalidValue("Proxy server is running at \(wifi.macLanIp):\(pendingState.mitmdumpPort ?? IOSUseProtocol.proxyMitmdumpPort), but device Wi-Fi proxy automation failed: \(error). Capture: \(pendingState.flowFile). Read with `ios-use proxy read`; retry device setup with `ios-use proxy start` or configure Wi-Fi proxy manually.")
        }

        var configuredState = pendingState
        configuredState.deviceProxyStatus = "configured"
        configuredState.lastError = nil
        configuredState.lastCapture = configuredState.lastCapture ?? lastCapture(from: configuredState)
        try writeState(configuredState, paths: paths)
        return pendingFlowOutput + serverStartedOutput(state: configuredState, wifi: wifi, configuredDevice: true, caReady: caReady)
    }

    private static func serverStartedOutput(state: ProxySessionState, wifi: ProxySessionState.NetworkInfo, configuredDevice: Bool, caReady: Bool) -> String {
        let port = state.mitmdumpPort ?? IOSUseProtocol.proxyMitmdumpPort
        var output = configuredDevice
            ? "Proxy started. Traffic: device -> \(wifi.macLanIp):\(port) -> mitmdump\n"
            : "Proxy server started. Device Wi-Fi proxy was not configured.\nTraffic: device -> \(wifi.macLanIp):\(port) -> mitmdump\n"
        output += "Capture: \(state.flowFile)\nView with: mitmweb -r \(state.flowFile)\nRead with: ios-use proxy read\n"
        if !configuredDevice {
            output += "Configure device Wi-Fi proxy manually or run: ios-use proxy start\n"
        }
        if !caReady {
            output = "CA trust record not found. HTTP capture can still work; HTTPS decryption requires the CA to be installed and trusted.\n" + output
        }
        return output
    }

    private static func stopProxyServerOnly(state: ProxySessionState, paths: IOSUsePaths) throws -> String {
        killMitmdump(pid: state.mitmdumpPid, expectedFlowFile: state.flowFile)
        var stoppedState = state
        stoppedState.status = "stopped"
        stoppedState.stoppedAt = nowMs()
        stoppedState.mitmdumpPid = nil
        stoppedState.serverStatus = "stopped"
        stoppedState.lastError = nil
        stoppedState.lastCapture = lastCapture(from: stoppedState)
        try writeState(stoppedState, paths: paths)
        return "Proxy server stopped. Device Wi-Fi proxy was not changed.\n"
    }

    private static func lastCapture(from state: ProxySessionState) -> ProxyLastCapture? {
        guard !state.flowFile.isEmpty else { return nil }
        return ProxyLastCapture(
            flowFile: state.flowFile,
            udid: state.udid,
            startedAt: state.startedAt,
            stoppedAt: state.stoppedAt,
            status: state.status,
            mitmdumpPid: state.mitmdumpPid,
            network: state.network
        )
    }

    private static func readMitmdump(flowFile: String, raw: Bool, filter: String?) throws -> String {
        if let mitmdumpReadOverrideForTesting {
            return try mitmdumpReadOverrideForTesting(flowFile, raw, filter)
        }
        var args = ["-n", "-r", flowFile, "--flow-detail=\(raw ? 4 : 1)"]
        if let filter, !filter.isEmpty {
            args.append(filter)
        }
        return try Shell.run("mitmdump", arguments: args)
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
        if let startMitmdumpOverrideForTesting {
            return try startMitmdumpOverrideForTesting(flowFile, paths)
        }
        let port = IOSUseProtocol.proxyMitmdumpPort
        let existingOwners = listeningPortOwners(port: port)
        if !existingOwners.isEmpty {
            throw CLIParseError.invalidValue("Proxy port \(port) is already in use by \(portOwnerDescription(existingOwners)). Stop that process and retry `ios-use proxy start`.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = mitmdumpStartArguments(flowFile: flowFile, paths: paths)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try waitForPort(port)
            guard processAlive(process.processIdentifier),
                  isMitmdumpProcess(pid: process.processIdentifier, expectedFlowFile: flowFile),
                  processOwnsListeningPort(pid: process.processIdentifier, port: port) else {
                let owners = listeningPortOwners(port: port).filter { $0 != process.processIdentifier }
                process.terminate()
                let ownerSuffix = owners.isEmpty ? "" : " Current owner: \(portOwnerDescription(owners))."
                throw CLIParseError.invalidValue("mitmdump did not start correctly on port \(port).\(ownerSuffix)")
            }
            return process.processIdentifier
        } catch {
            process.terminate()
            throw error
        }
    }

    static func mitmdumpStartArgumentsForTesting(flowFile: String, paths: IOSUsePaths) -> [String] {
        mitmdumpStartArguments(flowFile: flowFile, paths: paths)
    }

    private static func mitmdumpStartArguments(flowFile: String, paths: IOSUsePaths) -> [String] {
        [
            "mitmdump",
            "-q",
            "--mode", "regular",
            "--listen-host", "0.0.0.0",
            "--listen-port", String(IOSUseProtocol.proxyMitmdumpPort),
            "--set", "confdir=\(mitmproxyDir(paths: paths))",
            "--set", "ssl_insecure=true",
            "--set", "http2=false",
            "--set", "connection_strategy=eager",
            "--set", "save_stream_file=\(flowFile)",
        ]
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

    private static func withRecoveredDriver<T>(paths: IOSUsePaths, _ body: (DriverCommandClient) throws -> T) throws -> T {
        try DriverCommandExecution.withLockedClient(paths: paths, body)
    }

    private static func detectLanInfo(interfaceName: String?) throws -> ProxySessionState.NetworkInfo {
        if let detectLanInfoOverrideForTesting {
            return try detectLanInfoOverrideForTesting(interfaceName)
        }
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
        for directory in flowDirectories(paths: paths) {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return "\(paths.root)/flows/\(name)"
    }

    private static func flowDirectories(paths: IOSUsePaths) -> [String] {
        var directories: [String] = []
        if let flowDirectoryOverrideForTesting {
            directories.append(flowDirectoryOverrideForTesting)
        }
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path {
            directories.append("\(executableDirectory)/flows")
        }
        directories.append("\(paths.root)/flows")
        directories.append("\(FileManager.default.currentDirectoryPath)/flows")
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
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

    static func listeningPortOwnersForTesting(port: Int) -> [Int32] {
        listeningPortOwners(port: port)
    }

    private static func listeningPortOwners(port: Int) -> [Int32] {
        guard let output = try? Shell.run("lsof", arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]) else {
            return []
        }
        var seen = Set<Int32>()
        var owners: [Int32] = []
        for line in output.split(separator: "\n") {
            guard line.first == "p", let pid = Int32(line.dropFirst()), !seen.contains(pid) else { continue }
            seen.insert(pid)
            owners.append(pid)
        }
        return owners
    }

    private static func portOwnerDescription(_ owners: [Int32]) -> String {
        owners.map { pid in
            if let command = processCommand(pid: pid), !command.isEmpty {
                return "PID \(pid) (\(command))"
            }
            return "PID \(pid)"
        }.joined(separator: ", ")
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
