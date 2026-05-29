import Foundation

enum CDTunnelError: Error, CustomStringConvertible, Equatable {
    case payloadTooLarge(Int)
    case invalidMagic
    case invalidPayloadSize(Int)
    case invalidJSON
    case missingField(String)
    case invalidIPv6Packet
    case ipv6PacketTooLarge(Int)

    var description: String {
        switch self {
        case .payloadTooLarge(let size):
            return "CDTunnel payload too large: \(size)"
        case .invalidMagic:
            return "CDTunnel invalid packet magic"
        case .invalidPayloadSize(let size):
            return "CDTunnel invalid payload size: \(size)"
        case .invalidJSON:
            return "CDTunnel payload is not a JSON dictionary"
        case .missingField(let field):
            return "CDTunnel handshake response missing \(field)"
        case .invalidIPv6Packet:
            return "CDTunnel invalid IPv6 packet"
        case .ipv6PacketTooLarge(let size):
            return "CDTunnel IPv6 packet too large: \(size)"
        }
    }
}

struct CoreDeviceTunnelHandshake: Equatable {
    let serverAddress: String
    let serverRSDPort: Int
    let clientAddress: String
    let clientMTU: Int
}

enum CDTunnelPacket {
    static let magic = Data("CDTunnel".utf8)
    static let requestedMTU = 16_000
    private static let maxPayloadSize = 64 * 1024

    static func encodeJSON(_ body: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard payload.count <= UInt16.max else {
            throw CDTunnelError.payloadTooLarge(payload.count)
        }
        var packet = Data()
        packet.append(magic)
        packet.append(uint16BE(UInt16(payload.count)))
        packet.append(payload)
        return packet
    }

    static func encodeHandshakeRequest(mtu: Int = requestedMTU) throws -> Data {
        try encodeJSON([
            "type": "clientHandshakeRequest",
            "mtu": mtu,
        ])
    }

    static func decodeJSONPacket(_ data: Data) throws -> [String: Any] {
        guard data.count >= 10 else {
            throw CDTunnelError.invalidPayloadSize(data.count)
        }
        guard data.prefix(8) == magic else {
            throw CDTunnelError.invalidMagic
        }
        let size = Int(readUInt16BE(data, 8))
        guard size > 0, size <= maxPayloadSize, data.count == 10 + size else {
            throw CDTunnelError.invalidPayloadSize(size)
        }
        let raw = try JSONSerialization.jsonObject(with: Data(data.dropFirst(10)), options: [])
        guard let body = raw as? [String: Any] else {
            throw CDTunnelError.invalidJSON
        }
        return body
    }

    static func decodeHandshakeResponse(_ data: Data) throws -> CoreDeviceTunnelHandshake {
        try decodeHandshakeResponseBody(decodeJSONPacket(data))
    }

    static func decodeHandshakeResponseBody(_ body: [String: Any]) throws -> CoreDeviceTunnelHandshake {
        guard let serverAddress = body["serverAddress"] as? String else {
            throw CDTunnelError.missingField("serverAddress")
        }
        guard let serverRSDPort = body["serverRSDPort"] as? Int else {
            throw CDTunnelError.missingField("serverRSDPort")
        }
        guard let clientParameters = body["clientParameters"] as? [String: Any] else {
            throw CDTunnelError.missingField("clientParameters")
        }
        guard let clientAddress = clientParameters["address"] as? String else {
            throw CDTunnelError.missingField("clientParameters.address")
        }
        guard let clientMTU = clientParameters["mtu"] as? Int else {
            throw CDTunnelError.missingField("clientParameters.mtu")
        }
        return CoreDeviceTunnelHandshake(
            serverAddress: serverAddress,
            serverRSDPort: serverRSDPort,
            clientAddress: clientAddress,
            clientMTU: clientMTU
        )
    }
}

enum CDTunnelIPv6Packet {
    static let headerSize = 40
    static let maxPacketSize = 256 * 1024

    static func bodySize(fromHeader header: Data) throws -> Int {
        guard header.count == headerSize, (header[0] >> 4) == 6 else {
            throw CDTunnelError.invalidIPv6Packet
        }
        let bodySize = Int(readUInt16BE(header, 4))
        let packetSize = headerSize + bodySize
        guard packetSize <= maxPacketSize else {
            throw CDTunnelError.ipv6PacketTooLarge(packetSize)
        }
        return bodySize
    }

    static func validate(_ packet: Data) throws {
        guard packet.count >= headerSize else {
            throw CDTunnelError.invalidIPv6Packet
        }
        let header = Data(packet.prefix(headerSize))
        let bodySize = try bodySize(fromHeader: header)
        guard packet.count == headerSize + bodySize else {
            throw CDTunnelError.invalidIPv6Packet
        }
    }
}

final class CoreDeviceTunnelClient {
    private let stream: DeviceStream

    init(stream: DeviceStream) {
        self.stream = stream
    }

    static func connect(udid: String) throws -> CoreDeviceTunnelClient {
        CoreDeviceTunnelClient(
            stream: try LockdownSession.connectToService("com.apple.internal.devicecompute.CoreDeviceProxy", udid: udid)
        )
    }

    static func withCoreDeviceProxy<T>(udid: String, _ body: (CoreDeviceTunnelClient) throws -> T) throws -> T {
        let client = try connect(udid: udid)
        defer { client.close() }
        return try body(client)
    }

    func requestHandshake(mtu: Int = CDTunnelPacket.requestedMTU) throws -> CoreDeviceTunnelHandshake {
        try stream.write(CDTunnelPacket.encodeHandshakeRequest(mtu: mtu))
        let header = try stream.readExact(byteCount: 10, timeoutSeconds: 10)
        guard header.prefix(8) == CDTunnelPacket.magic else {
            throw CDTunnelError.invalidMagic
        }
        let payloadSize = Int(readUInt16BE(header, 8))
        guard payloadSize > 0, payloadSize <= 64 * 1024 else {
            throw CDTunnelError.invalidPayloadSize(payloadSize)
        }
        let payload = try stream.readExact(byteCount: payloadSize, timeoutSeconds: 10)
        return try CDTunnelPacket.decodeHandshakeResponse(header + payload)
    }

    func readIPv6Packet(timeoutSeconds: Double = 10) throws -> Data {
        let header = try stream.readExact(byteCount: CDTunnelIPv6Packet.headerSize, timeoutSeconds: timeoutSeconds)
        let bodySize = try CDTunnelIPv6Packet.bodySize(fromHeader: header)
        let body = bodySize == 0 ? Data() : try stream.readExact(byteCount: bodySize, timeoutSeconds: timeoutSeconds)
        return header + body
    }

    func writeIPv6Packet(_ packet: Data) throws {
        try CDTunnelIPv6Packet.validate(packet)
        try stream.write(packet)
    }

    func close() {
        stream.close()
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
