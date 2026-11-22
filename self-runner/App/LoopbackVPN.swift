import NetworkExtension

@MainActor final class LoopbackVPN {
    private var manager: NETunnelProviderManager?
    func start() async throws {
        let bundle = Bundle.main.bundleIdentifier! + ".loopback"
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundle } ?? NETunnelProviderManager()
        if manager.connection.status != .disconnected && manager.connection.status != .invalid {
            manager.connection.stopVPNTunnel()
            for _ in 0..<100 {
                if manager.connection.status == .disconnected || manager.connection.status == .invalid { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard manager.connection.status == .disconnected || manager.connection.status == .invalid else {
                throw CLIParseError.invalidValue("Previous local VPN is still stopping; retry after it disconnects")
            }
        }
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = bundle
        configuration.serverAddress = "10.7.0.1"
        configuration.disconnectOnSleep = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "ios-use local developer connection"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        try manager.connection.startVPNTunnel()
        for _ in 0..<100 {
            if manager.connection.status == .connected { return }
            if manager.connection.status == .invalid { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CLIParseError.invalidValue("Local VPN did not connect; check the Network Extensions signing entitlement")
    }
    func diagnostics() async -> String {
        guard let session = manager?.connection as? NETunnelProviderSession else { return "No embedded tunnel" }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("stats".utf8)) { data in
                    continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) } ?? "No tunnel diagnostics")
                }
            } catch { continuation.resume(returning: "Tunnel diagnostics: \(error)") }
        }
    }
    func removeConfiguration() async throws {
        let bundle = Bundle.main.bundleIdentifier! + ".loopback"
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        for manager in managers where (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundle {
            manager.connection.stopVPNTunnel()
            try await manager.removeFromPreferences()
        }
        self.manager = nil
    }
    func stop() { manager?.connection.stopVPNTunnel() }
}
