import Darwin
import Foundation

enum CoreDeviceTCPError: Error, CustomStringConvertible, Equatable {
    case invalidIPv6Address(String)
    case invalidIPv6Packet(String)
    case invalidTCPPacket(String)
    case connectionReset
    case connectionClosed
    case connectionTimeout
    case unexpectedHandshake(String)

    var description: String {
        switch self {
        case .invalidIPv6Address(let address):
            return "CoreDevice TCP invalid IPv6 address: \(address)"
        case .invalidIPv6Packet(let detail):
            return "CoreDevice TCP invalid IPv6 packet: \(detail)"
        case .invalidTCPPacket(let detail):
            return "CoreDevice TCP invalid packet: \(detail)"
        case .connectionReset:
            return "CoreDevice TCP connection reset"
        case .connectionClosed:
            return "CoreDevice TCP connection closed"
        case .connectionTimeout:
            return "CoreDevice TCP connection timed out"
        case .unexpectedHandshake(let detail):
            return "CoreDevice TCP unexpected handshake: \(detail)"
        }
    }
}

struct CoreDeviceTCPSegment: Equatable {
    let sourceAddress: Data
    let destinationAddress: Data
    let sourcePort: UInt16
    let destinationPort: UInt16
    let sequenceNumber: UInt32
    let acknowledgmentNumber: UInt32
    let flags: UInt8
    let payload: Data

    var hasSyn: Bool { flags & CoreDeviceTCPFlags.syn != 0 }
    var hasAck: Bool { flags & CoreDeviceTCPFlags.ack != 0 }
    var hasFin: Bool { flags & CoreDeviceTCPFlags.fin != 0 }
    var hasRst: Bool { flags & CoreDeviceTCPFlags.rst != 0 }
}

enum CoreDeviceTCPFlags {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let psh: UInt8 = 0x08
    static let ack: UInt8 = 0x10
}

enum CoreDeviceIPv6TCPCodec {
    static let ipv6HeaderSize = 40
    static let tcpHeaderSize = 20
    static let protocolTCP: UInt8 = 6

    static func parseIPv6Address(_ address: String) throws -> Data {
        var raw = in6_addr()
        let result = address.withCString {
            inet_pton(AF_INET6, $0, &raw)
        }
        guard result == 1 else {
            throw CoreDeviceTCPError.invalidIPv6Address(address)
        }
        return withUnsafeBytes(of: raw) { Data($0) }
    }

    static func encodeSegment(
        sourceAddress: Data,
        destinationAddress: Data,
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: UInt8,
        payload: Data = Data(),
        windowSize: UInt16 = UInt16.max
    ) throws -> Data {
        guard sourceAddress.count == 16, destinationAddress.count == 16 else {
            throw CoreDeviceTCPError.invalidIPv6Packet("IPv6 addresses must be 16 bytes")
        }
        let tcpLength = tcpHeaderSize + payload.count
        guard tcpLength <= UInt16.max else {
            throw CoreDeviceTCPError.invalidTCPPacket("TCP payload too large: \(payload.count)")
        }

        var tcp = Data()
        tcp.append(uint16BE(sourcePort))
        tcp.append(uint16BE(destinationPort))
        tcp.append(uint32BE(sequenceNumber))
        tcp.append(uint32BE(acknowledgmentNumber))
        tcp.append(UInt8(tcpHeaderSize / 4) << 4)
        tcp.append(flags)
        tcp.append(uint16BE(windowSize))
        tcp.append(uint16BE(0))
        tcp.append(uint16BE(0))
        tcp.append(payload)

        let checksum = tcpChecksum(
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            tcpSegment: tcp
        )
        tcp[16] = UInt8((checksum >> 8) & 0xff)
        tcp[17] = UInt8(checksum & 0xff)

        var packet = Data(repeating: 0, count: ipv6HeaderSize)
        packet[0] = 0x60
        packet[4] = UInt8((tcpLength >> 8) & 0xff)
        packet[5] = UInt8(tcpLength & 0xff)
        packet[6] = protocolTCP
        packet[7] = 64
        packet.replaceSubrange(8..<24, with: sourceAddress)
        packet.replaceSubrange(24..<40, with: destinationAddress)
        packet.append(tcp)
        return packet
    }

    static func decodeSegment(_ packet: Data) throws -> CoreDeviceTCPSegment {
        try CDTunnelIPv6Packet.validate(packet)
        guard packet.count >= ipv6HeaderSize + tcpHeaderSize else {
            throw CoreDeviceTCPError.invalidIPv6Packet("packet shorter than IPv6 + TCP headers")
        }
        guard packet[6] == protocolTCP else {
            throw CoreDeviceTCPError.invalidIPv6Packet("unsupported next header \(packet[6])")
        }
        let payloadLength = Int(readUInt16BE(packet, 4))
        guard packet.count == ipv6HeaderSize + payloadLength else {
            throw CoreDeviceTCPError.invalidIPv6Packet("payload length mismatch")
        }
        let tcpOffset = ipv6HeaderSize
        let dataOffset = Int(packet[tcpOffset + 12] >> 4) * 4
        guard dataOffset >= tcpHeaderSize, payloadLength >= dataOffset else {
            throw CoreDeviceTCPError.invalidTCPPacket("invalid TCP data offset")
        }
        let payloadStart = tcpOffset + dataOffset
        return CoreDeviceTCPSegment(
            sourceAddress: Data(packet[8..<24]),
            destinationAddress: Data(packet[24..<40]),
            sourcePort: readUInt16BE(packet, tcpOffset),
            destinationPort: readUInt16BE(packet, tcpOffset + 2),
            sequenceNumber: readUInt32BE(packet, tcpOffset + 4),
            acknowledgmentNumber: readUInt32BE(packet, tcpOffset + 8),
            flags: packet[tcpOffset + 13],
            payload: Data(packet[payloadStart..<packet.count])
        )
    }

    static func tcpChecksum(sourceAddress: Data, destinationAddress: Data, tcpSegment: Data) -> UInt16 {
        var pseudo = Data()
        pseudo.append(sourceAddress)
        pseudo.append(destinationAddress)
        pseudo.append(uint32BE(UInt32(tcpSegment.count)))
        pseudo.append(contentsOf: [0, 0, 0, protocolTCP])
        pseudo.append(tcpSegment)
        return internetChecksum(pseudo)
    }

    static func internetChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < data.count {
            sum += UInt32(readUInt16BE(data, index))
            index += 2
        }
        if index < data.count {
            sum += UInt32(data[index]) << 8
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return UInt16(~sum & 0xffff)
    }
}

final class CoreDeviceUserSpaceTCPConnection: DeviceStream {
    private let tunnel: IPv6PacketIO
    private let localAddress: Data
    private let remoteAddress: Data
    private let localPort: UInt16
    private let remotePort: UInt16
    private let maxSegmentPayload: Int
    private let eventSink: ((String) -> Void)?
    private var sendSequence: UInt32
    private var receiveSequence: UInt32 = 0
    private var inbound = Data()
    private var connected = false
    private var closed = false
    private var pendingAck = false

    init(
        tunnel: IPv6PacketIO,
        localAddress: String,
        remoteAddress: String,
        localPort: UInt16 = UInt16.random(in: 49_152...65_000),
        remotePort: Int,
        initialSequence: UInt32 = UInt32.random(in: 1...UInt32.max - 1),
        maxSegmentPayload: Int = 1_200,
        eventSink: ((String) -> Void)? = nil
    ) throws {
        self.tunnel = tunnel
        self.localAddress = try CoreDeviceIPv6TCPCodec.parseIPv6Address(localAddress)
        self.remoteAddress = try CoreDeviceIPv6TCPCodec.parseIPv6Address(remoteAddress)
        self.localPort = localPort
        guard remotePort > 0, remotePort <= Int(UInt16.max) else {
            throw CoreDeviceTCPError.invalidTCPPacket("invalid remote port \(remotePort)")
        }
        self.remotePort = UInt16(remotePort)
        self.sendSequence = initialSequence
        self.maxSegmentPayload = max(1, maxSegmentPayload)
        self.eventSink = eventSink
    }

    func connect(timeoutSeconds: Double = 10) throws {
        guard !connected else { return }
        try sendSegment(flags: CoreDeviceTCPFlags.syn)
        let synSequence = sendSequence
        sendSequence &+= 1

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            guard let segment = try readMatchingSegment(timeoutSeconds: max(0, deadline.timeIntervalSinceNow)) else {
                continue
            }
            if segment.hasRst {
                eventSink?("TCP received RST seq=\(segment.sequenceNumber) ack=\(segment.acknowledgmentNumber)")
                throw CoreDeviceTCPError.connectionReset
            }
            guard segment.hasSyn, segment.hasAck else {
                continue
            }
            guard segment.acknowledgmentNumber == synSequence &+ 1 else {
                throw CoreDeviceTCPError.unexpectedHandshake("SYN/ACK acknowledged \(segment.acknowledgmentNumber), expected \(synSequence &+ 1)")
            }
            receiveSequence = segment.sequenceNumber &+ 1
            try sendSegment(flags: CoreDeviceTCPFlags.ack)
            connected = true
            return
        }
        throw CoreDeviceTCPError.connectionTimeout
    }

    func write(_ data: Data) throws {
        guard connected, !closed else {
            throw CoreDeviceTCPError.connectionClosed
        }
        var remaining = data
        while !remaining.isEmpty {
            let count = min(maxSegmentPayload, remaining.count)
            let chunk = Data(remaining.prefix(count))
            try sendSegment(flags: CoreDeviceTCPFlags.psh | CoreDeviceTCPFlags.ack, payload: chunk)
            sendSequence &+= UInt32(chunk.count)
            remaining.removeFirst(count)
        }
    }

    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while out.count < byteCount {
            let chunk = try readAvailable(maxBytes: byteCount - out.count, timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
            if chunk.isEmpty {
                throw CoreDeviceTCPError.connectionTimeout
            }
            out.append(chunk)
        }
        return out
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        if inbound.isEmpty {
            try fillInbound(timeoutSeconds: timeoutSeconds)
        }
        let count = min(maxBytes, inbound.count)
        let out = Data(inbound.prefix(count))
        inbound.removeFirst(count)
        return out
    }

    func close() {
        guard !closed else { return }
        if connected {
            try? sendSegment(flags: CoreDeviceTCPFlags.fin | CoreDeviceTCPFlags.ack)
            sendSequence &+= 1
        }
        closed = true
        connected = false
    }

    private func fillInbound(timeoutSeconds: Double) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while inbound.isEmpty, Date() < deadline, !closed {
            if pendingAck {
                try sendSegment(flags: CoreDeviceTCPFlags.ack)
            }
            guard let segment = try readMatchingSegment(timeoutSeconds: max(0, deadline.timeIntervalSinceNow)) else {
                continue
            }
            if segment.hasRst {
                closed = true
                eventSink?("TCP received RST seq=\(segment.sequenceNumber) ack=\(segment.acknowledgmentNumber)")
                throw CoreDeviceTCPError.connectionReset
            }
            if !segment.payload.isEmpty {
                if segment.sequenceNumber == receiveSequence {
                    inbound.append(segment.payload)
                    receiveSequence &+= UInt32(segment.payload.count)
                    try sendSegment(flags: CoreDeviceTCPFlags.ack)
                }
            } else if segment.hasFin {
                receiveSequence &+= 1
                try sendSegment(flags: CoreDeviceTCPFlags.ack)
                closed = true
                if inbound.isEmpty {
                    throw CoreDeviceTCPError.connectionClosed
                }
            }
        }
    }

    private func readMatchingSegment(timeoutSeconds: Double) throws -> CoreDeviceTCPSegment? {
        do {
            let packet = try tunnel.readIPv6Packet(timeoutSeconds: timeoutSeconds)
            let segment = try CoreDeviceIPv6TCPCodec.decodeSegment(packet)
            guard segment.sourceAddress == remoteAddress,
                  segment.destinationAddress == localAddress,
                  segment.sourcePort == remotePort,
                  segment.destinationPort == localPort else {
                eventSink?("TCP ignored packet srcPort=\(segment.sourcePort) dstPort=\(segment.destinationPort) flags=0x\(String(segment.flags, radix: 16)) bytes=\(segment.payload.count)")
                return nil
            }
            eventSink?("TCP received flags=0x\(String(segment.flags, radix: 16)) seq=\(segment.sequenceNumber) ack=\(segment.acknowledgmentNumber) bytes=\(segment.payload.count)")
            return segment
        } catch CoreDeviceTCPError.invalidIPv6Packet {
            return nil
        } catch CoreDeviceTCPError.invalidTCPPacket {
            return nil
        } catch {
            if Self.isTimeout(error) {
                return nil
            }
            throw error
        }
    }

    private func sendSegment(flags: UInt8, payload: Data = Data()) throws {
        let packet = try CoreDeviceIPv6TCPCodec.encodeSegment(
            sourceAddress: localAddress,
            destinationAddress: remoteAddress,
            sourcePort: localPort,
            destinationPort: remotePort,
            sequenceNumber: sendSequence,
            acknowledgmentNumber: receiveSequence,
            flags: flags,
            payload: payload
        )
        eventSink?("TCP send flags=0x\(String(flags, radix: 16)) seq=\(sendSequence) ack=\(receiveSequence) bytes=\(payload.count)")
        try tunnel.writeIPv6Packet(packet)
        if flags & CoreDeviceTCPFlags.ack != 0 {
            pendingAck = false
        }
    }

    private static func isTimeout(_ error: Error) -> Bool {
        String(describing: error).localizedCaseInsensitiveContains("timeout")
    }
}

final class CoreDeviceDirectTunnelRuntime {
    struct Dependencies {
        var openTunnel: (String) throws -> CoreDeviceTunnel

        static let live = Dependencies(
            openTunnel: { try CoreDeviceTunnelClient.connect(udid: $0) }
        )
    }

    private let dependencies: Dependencies
    private let eventSink: ((String) -> Void)?

    init(dependencies: Dependencies = .live, eventSink: ((String) -> Void)? = nil) {
        self.dependencies = dependencies
        self.eventSink = eventSink
    }

    func start(udid: String, mtu: Int = CDTunnelPacket.requestedMTU) throws -> CoreDeviceDirectTunnelSession {
        eventSink?("connecting CoreDeviceProxy")
        let tunnel = try dependencies.openTunnel(udid)
        do {
            eventSink?("requesting CoreDevice tunnel handshake")
            let handshake = try tunnel.requestHandshake(mtu: mtu)
            eventSink?("handshake server=\(handshake.serverAddress):\(handshake.serverRSDPort) client=\(handshake.clientAddress) mtu=\(handshake.clientMTU)")
            let session = CoreDeviceDirectTunnelSession(tunnel: tunnel, handshake: handshake, eventSink: eventSink)
            do {
                eventSink?("connecting RSD through userspace TCP")
                let client = try session.connectRemoteXPCClient(port: handshake.serverRSDPort)
                do {
                    session.peerInfo = try client.receivePeerInfo()
                    session.retainRemoteXPCClient(client)
                } catch {
                    client.close()
                    throw error
                }
                eventSink?("RSD peer info received")
                return session
            } catch {
                session.close()
                throw error
            }
        } catch {
            tunnel.close()
            throw error
        }
    }
}

protocol CoreDeviceLifecycleTunnelSession: AnyObject {
    var serverAddress: String { get }
    var peerInfo: RemoteXPCPeerInfo? { get }
    func connectService(_ serviceName: String) throws -> DeviceStream
    func connectRemoteXPCService(_ serviceName: String) throws -> RemoteXPCClient
    func close()
    func waitForClose(timeoutSeconds: Double) -> Bool
}

final class CoreDeviceDirectTunnelSession: CoreDeviceLifecycleTunnelSession {
    private static let remoteXPCHandshakeTimeoutSeconds = 15.0

    let tunnel: CoreDeviceTunnel
    let handshake: CoreDeviceTunnelHandshake
    var peerInfo: RemoteXPCPeerInfo?
    private let eventSink: ((String) -> Void)?
    private var nextLocalPort: UInt16 = 49_152
    private var retainedRemoteXPCClients: [RemoteXPCClient] = []
    private var closed = false

    var serverAddress: String { handshake.serverAddress }

    init(tunnel: CoreDeviceTunnel, handshake: CoreDeviceTunnelHandshake, eventSink: ((String) -> Void)? = nil) {
        self.tunnel = tunnel
        self.handshake = handshake
        self.eventSink = eventSink
    }

    func connectRemoteXPCService(_ serviceName: String) throws -> RemoteXPCClient {
        guard let peerInfo else {
            throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
        }
        let stream = try connectServicePort(peerInfo.servicePort(serviceName))
        do {
            let client = RemoteXPCClient(stream: stream, eventSink: eventSink)
            try client.completeClientHandshake(timeoutSeconds: Self.remoteXPCHandshakeTimeoutSeconds)
            eventSink?("RemoteXPC client handshake sent to \(handshake.serverAddress):\(try peerInfo.servicePort(serviceName))")
            return client
        } catch {
            stream.close()
            throw error
        }
    }

    func connectRemoteXPCClient(port: Int) throws -> RemoteXPCClient {
        let stream = try connectServicePort(port)
        do {
            let client = RemoteXPCClient(stream: stream, eventSink: eventSink)
            try client.completeClientHandshake(timeoutSeconds: Self.remoteXPCHandshakeTimeoutSeconds)
            eventSink?("RemoteXPC client handshake sent to \(handshake.serverAddress):\(port)")
            return client
        } catch {
            stream.close()
            throw error
        }
    }

    func connectService(_ serviceName: String) throws -> DeviceStream {
        guard let peerInfo else {
            throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
        }
        return try connectServicePort(peerInfo.servicePort(serviceName))
    }

    private func connectServicePort(_ port: Int) throws -> CoreDeviceUserSpaceTCPConnection {
        eventSink?("opening userspace TCP \(handshake.serverAddress):\(port)")
        let stream = try CoreDeviceUserSpaceTCPConnection(
            tunnel: tunnel,
            localAddress: handshake.clientAddress,
            remoteAddress: handshake.serverAddress,
            localPort: allocateLocalPort(),
            remotePort: port,
            eventSink: eventSink
        )
        do {
            try stream.connect()
            eventSink?("userspace TCP connected to \(handshake.serverAddress):\(port)")
            return stream
        } catch {
            stream.close()
            throw error
        }
    }

    func retainRemoteXPCClient(_ client: RemoteXPCClient) {
        retainedRemoteXPCClients.append(client)
    }

    func close() {
        guard !closed else { return }
        closed = true
        for client in retainedRemoteXPCClients {
            client.close()
        }
        retainedRemoteXPCClients.removeAll()
        tunnel.close()
    }

    func waitForClose(timeoutSeconds _: Double = 1) -> Bool {
        true
    }

    private func allocateLocalPort() -> UInt16 {
        let port = nextLocalPort
        if nextLocalPort == 65_000 {
            nextLocalPort = 49_152
        } else {
            nextLocalPort += 1
        }
        return port
    }
}

private func uint16BE(_ value: UInt16) -> Data {
    Data([
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ])
}

private func readUInt16BE(_ data: Data, _ offset: Int) -> UInt16 {
    let bytes = [UInt8](data)
    return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
}
