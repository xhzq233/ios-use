import Foundation

protocol CoreDeviceTunnel: IPv6PacketIO {
    func requestHandshake(mtu: Int) throws -> CoreDeviceTunnelHandshake
}

protocol NamedIPv6PacketIO: IPv6PacketIO {
    var interfaceName: String { get }
}

extension CoreDeviceTunnelClient: CoreDeviceTunnel {}
extension MacOSUtunInterface: NamedIPv6PacketIO {}

final class CoreDeviceTunnelRuntime {
    struct Dependencies {
        var openTunnel: (String) throws -> CoreDeviceTunnel
        var openInterface: () throws -> NamedIPv6PacketIO
        var configureInterface: (CoreDeviceTunnelInterfaceConfig) throws -> Void
        var connectRSD: (String, Int) throws -> RemoteXPCPeerInfo

        static let live = Dependencies(
            openTunnel: { try CoreDeviceTunnelClient.connect(udid: $0) },
            openInterface: { try MacOSUtunInterface.open() },
            configureInterface: { try CoreDeviceTunnelInterfaceConfigurator.apply($0) },
            connectRSD: { try RemoteServiceDiscoveryClient.connect(host: $0, port: $1) }
        )
    }

    private let dependencies: Dependencies
    private let bridgeReadTimeoutSeconds: Double
    private let eventSink: ((String) -> Void)?

    init(
        dependencies: Dependencies = .live,
        bridgeReadTimeoutSeconds: Double = 0.2,
        eventSink: ((String) -> Void)? = nil
    ) {
        self.dependencies = dependencies
        self.bridgeReadTimeoutSeconds = bridgeReadTimeoutSeconds
        self.eventSink = eventSink
    }

    func start(udid: String, mtu: Int = CDTunnelPacket.requestedMTU) throws -> CoreDeviceTunnelSession {
        eventSink?("connecting CoreDeviceProxy")
        let tunnel = try dependencies.openTunnel(udid)
        var tunnelOwned = true
        do {
            eventSink?("requesting CoreDevice tunnel handshake")
            let handshake = try tunnel.requestHandshake(mtu: mtu)
            eventSink?("handshake server=\(handshake.serverAddress):\(handshake.serverRSDPort) client=\(handshake.clientAddress) mtu=\(handshake.clientMTU)")
            eventSink?("opening macOS utun interface")
            let networkInterface = try dependencies.openInterface()
            var interfaceOwned = true
            do {
                let interfaceConfig = CoreDeviceTunnelInterfaceConfig(
                    interfaceName: networkInterface.interfaceName,
                    handshake: handshake
                )
                eventSink?("configuring \(interfaceConfig.interfaceName) for RSD tunnel")
                try dependencies.configureInterface(interfaceConfig)

                let bridge = CoreDeviceTunnelBridge(device: tunnel, networkInterface: networkInterface)
                let session = CoreDeviceTunnelSession(
                    handshake: handshake,
                    interfaceConfig: interfaceConfig,
                    bridge: bridge,
                    bridgeReadTimeoutSeconds: bridgeReadTimeoutSeconds
                )
                tunnelOwned = false
                interfaceOwned = false
                eventSink?("starting packet bridge")
                session.startPacketBridge()
                do {
                    eventSink?("connecting RSD")
                    session.peerInfo = try dependencies.connectRSD(handshake.serverAddress, handshake.serverRSDPort)
                    eventSink?("RSD peer info received")
                    return session
                } catch {
                    session.close()
                    throw error
                }
            } catch {
                if interfaceOwned {
                    networkInterface.close()
                }
                throw error
            }
        } catch {
            if tunnelOwned {
                tunnel.close()
            }
            throw error
        }
    }
}

final class CoreDeviceTunnelSession {
    let handshake: CoreDeviceTunnelHandshake
    let interfaceConfig: CoreDeviceTunnelInterfaceConfig
    var peerInfo: RemoteXPCPeerInfo?

    private let bridge: CoreDeviceTunnelBridge
    private let bridgeReadTimeoutSeconds: Double
    private let bridgeGroup = DispatchGroup()
    private let stateLock = NSLock()
    private var closed = false
    private var bridgeFailure: Error?

    var bridgeStats: CoreDeviceTunnelBridgeStats {
        bridge.stats
    }

    var bridgeErrorDescription: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bridgeFailure.map { String(describing: $0) }
    }

    init(
        handshake: CoreDeviceTunnelHandshake,
        interfaceConfig: CoreDeviceTunnelInterfaceConfig,
        bridge: CoreDeviceTunnelBridge,
        bridgeReadTimeoutSeconds: Double
    ) {
        self.handshake = handshake
        self.interfaceConfig = interfaceConfig
        self.bridge = bridge
        self.bridgeReadTimeoutSeconds = bridgeReadTimeoutSeconds
    }

    deinit {
        close()
    }

    func close() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        bridge.close()
    }

    func waitForPacketBridgeToStop(timeoutSeconds: Double = 1) -> Bool {
        bridgeGroup.wait(timeout: .now() + timeoutSeconds) == .success
    }

    fileprivate func startPacketBridge() {
        startPump(.deviceToInterface)
        startPump(.interfaceToDevice)
    }

    private enum PumpDirection {
        case deviceToInterface
        case interfaceToDevice
    }

    private func startPump(_ direction: PumpDirection) {
        let group = bridgeGroup
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { group.leave() }
            guard let self else { return }
            self.runBridgePump {
                switch direction {
                case .deviceToInterface:
                    try self.bridge.pumpDeviceToInterfaceOnce(timeoutSeconds: self.bridgeReadTimeoutSeconds)
                case .interfaceToDevice:
                    try self.bridge.pumpInterfaceToDeviceOnce(timeoutSeconds: self.bridgeReadTimeoutSeconds)
                }
            }
        }
    }

    private func runBridgePump(_ pump: () throws -> Void) {
        while !isClosed {
            do {
                try pump()
            } catch {
                if isClosed {
                    return
                }
                if Self.isIdleTimeout(error) {
                    continue
                }
                recordBridgeFailure(error)
                close()
                return
            }
        }
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func recordBridgeFailure(_ error: Error) {
        stateLock.lock()
        if bridgeFailure == nil {
            bridgeFailure = error
        }
        stateLock.unlock()
    }

    private static func isIdleTimeout(_ error: Error) -> Bool {
        String(describing: error).localizedCaseInsensitiveContains("timeout")
    }
}

extension CoreDeviceTunnelSession: CoreDeviceLifecycleTunnelSession {
    var serverAddress: String {
        handshake.serverAddress
    }

    func connectService(_ serviceName: String) throws -> DeviceStream {
        guard let peerInfo else {
            throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
        }
        let port = try peerInfo.servicePort(serviceName)
        let fd = try TCPConnector.connect(host: handshake.serverAddress, port: port)
        return OwnedFDDeviceStream(fd: fd)
    }

    func connectRemoteXPCService(_ serviceName: String) throws -> RemoteXPCClient {
        guard let peerInfo else {
            throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
        }
        return try RemoteServiceDiscoveryClient.connectRemoteXPCService(
            host: handshake.serverAddress,
            peerInfo: peerInfo,
            serviceName: serviceName
        )
    }

    func waitForClose(timeoutSeconds: Double) -> Bool {
        waitForPacketBridgeToStop(timeoutSeconds: timeoutSeconds)
    }
}
