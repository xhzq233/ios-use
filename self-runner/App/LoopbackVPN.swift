import NetworkExtension

@MainActor final class LoopbackVPN {
    private var manager: NETunnelProviderManager?
    func start() async throws {
        let bundle = Bundle.main.bundleIdentifier! + ".loopback"
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundle } ?? NETunnelProviderManager()
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
    func stop() { manager?.connection.stopVPNTunnel() }
}
