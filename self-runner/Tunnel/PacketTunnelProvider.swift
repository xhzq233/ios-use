import NetworkExtension
import SelfRunnerCore

/// Reflect packets for one local peer. Swapping both IPv4 addresses preserves
/// the IPv4 and TCP/UDP pseudo-header checksums; ports and payload stay intact.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var running = false
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        setTunnelNetworkSettings(settings) { error in
            if error == nil { self.running = true; self.read() }
            completionHandler(error)
        }
    }
    private func read() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.running else { return }
            var reflected = [Data](), families = [NSNumber]()
            for (packet, family) in zip(packets, protocols) {
                guard family.int32Value == AF_INET, let reply = LoopbackPacket.reflect(packet) else { continue }
                reflected.append(reply); families.append(family)
            }
            self.packetFlow.writePackets(reflected, withProtocols: families)
            self.read()
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        completionHandler()
    }
}
