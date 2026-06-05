import Darwin
import Foundation

protocol IPv6PacketIO {
    func readIPv6Packet(timeoutSeconds: Double) throws -> Data
    func writeIPv6Packet(_ packet: Data) throws
    func close()
}

extension CoreDeviceTunnelClient: IPv6PacketIO {}

enum CoreDeviceTunnelBridgeError: Error, CustomStringConvertible, Equatable {
    case emptyPacket
    case invalidUtunFrame
    case utunOpenFailed(Int32)
    case utunControlLookupFailed(Int32)
    case utunConnectFailed(Int32)
    case utunNameLookupFailed(Int32)

    var description: String {
        switch self {
        case .emptyPacket:
            return "CoreDevice tunnel bridge read an empty packet"
        case .invalidUtunFrame:
            return "CoreDevice tunnel bridge read an invalid utun frame"
        case .utunOpenFailed(let error):
            return "CoreDevice tunnel bridge failed to open utun socket: errno \(error)"
        case .utunControlLookupFailed(let error):
            return "CoreDevice tunnel bridge failed to resolve utun kernel control: errno \(error)"
        case .utunConnectFailed(let error):
            return "CoreDevice tunnel bridge failed to connect utun kernel control: errno \(error)"
        case .utunNameLookupFailed(let error):
            return "CoreDevice tunnel bridge failed to read utun interface name: errno \(error)"
        }
    }
}

struct CoreDeviceTunnelBridgeStats: Equatable {
    var deviceToInterfacePackets = 0
    var interfaceToDevicePackets = 0
    var deviceToInterfaceBytes = 0
    var interfaceToDeviceBytes = 0
}

final class CoreDeviceTunnelBridge {
    private let device: IPv6PacketIO
    private let networkInterface: IPv6PacketIO
    private let statsLock = NSLock()
    private var statsStorage = CoreDeviceTunnelBridgeStats()
    var stats: CoreDeviceTunnelBridgeStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return statsStorage
    }

    init(device: IPv6PacketIO, networkInterface: IPv6PacketIO) {
        self.device = device
        self.networkInterface = networkInterface
    }

    func pumpDeviceToInterfaceOnce(timeoutSeconds: Double = 1) throws {
        let packet = try device.readIPv6Packet(timeoutSeconds: timeoutSeconds)
        guard !packet.isEmpty else {
            throw CoreDeviceTunnelBridgeError.emptyPacket
        }
        try CDTunnelIPv6Packet.validate(packet)
        try networkInterface.writeIPv6Packet(packet)
        statsLock.lock()
        statsStorage.deviceToInterfacePackets += 1
        statsStorage.deviceToInterfaceBytes += packet.count
        statsLock.unlock()
    }

    func pumpInterfaceToDeviceOnce(timeoutSeconds: Double = 1) throws {
        let packet = try networkInterface.readIPv6Packet(timeoutSeconds: timeoutSeconds)
        guard !packet.isEmpty else {
            throw CoreDeviceTunnelBridgeError.emptyPacket
        }
        try CDTunnelIPv6Packet.validate(packet)
        try device.writeIPv6Packet(packet)
        statsLock.lock()
        statsStorage.interfaceToDevicePackets += 1
        statsStorage.interfaceToDeviceBytes += packet.count
        statsLock.unlock()
    }

    func close() {
        device.close()
        networkInterface.close()
    }
}

struct CoreDeviceTunnelInterfaceConfig: Equatable {
    let interfaceName: String
    let clientAddress: String
    let serverAddress: String
    let mtu: Int

    init(interfaceName: String, handshake: CoreDeviceTunnelHandshake) {
        self.interfaceName = interfaceName
        self.clientAddress = handshake.clientAddress
        self.serverAddress = handshake.serverAddress
        self.mtu = handshake.clientMTU
    }
}

enum CoreDeviceTunnelInterfaceConfigurator {
    static var shellRunnerForTesting: ((String, [String]) throws -> String)?

    static func ifconfigArguments(for config: CoreDeviceTunnelInterfaceConfig) -> [String] {
        [
            config.interfaceName,
            "inet6",
            config.clientAddress,
            config.serverAddress,
            "prefixlen",
            "128",
            "mtu",
            "\(config.mtu)",
            "up",
        ]
    }

    static func apply(_ config: CoreDeviceTunnelInterfaceConfig) throws {
        let arguments = ifconfigArguments(for: config)
        if let shellRunnerForTesting {
            _ = try shellRunnerForTesting("ifconfig", arguments)
        } else {
            _ = try Shell.run("ifconfig", arguments: arguments)
        }
    }

    static func resetTestingOverrides() {
        shellRunnerForTesting = nil
    }
}

final class MacOSUtunInterface: IPv6PacketIO {
    static let loopbackHeader = Data([0x00, 0x00, 0x00, UInt8(AF_INET6)])
    private static let ctlIoCgInfo = UInt(0xc064_4e03)

    let interfaceName: String
    private let fd: Int32
    private var closed = false

    init(fd: Int32, interfaceName: String) {
        self.fd = fd
        self.interfaceName = interfaceName
        setSocketNoSigPipe(fd)
    }

    static func open() throws -> MacOSUtunInterface {
        let fd = Darwin.socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else {
            throw CoreDeviceTunnelBridgeError.utunOpenFailed(errno)
        }
        do {
            var info = ctl_info()
            try fillControlName("com.apple.net.utun_control", into: &info)
            guard Darwin.ioctl(fd, ctlIoCgInfo, &info) == 0 else {
                throw CoreDeviceTunnelBridgeError.utunControlLookupFailed(errno)
            }

            var address = sockaddr_ctl()
            address.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
            address.sc_family = UInt8(AF_SYSTEM)
            address.ss_sysaddr = UInt16(AF_SYS_CONTROL)
            address.sc_id = info.ctl_id
            address.sc_unit = 0
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size))
                }
            }
            guard connected == 0 else {
                throw CoreDeviceTunnelBridgeError.utunConnectFailed(errno)
            }

            return MacOSUtunInterface(fd: fd, interfaceName: try interfaceName(fd: fd))
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func encodeUtunFrame(ipv6Packet: Data) throws -> Data {
        try CDTunnelIPv6Packet.validate(ipv6Packet)
        return loopbackHeader + ipv6Packet
    }

    static func decodeUtunFrame(_ frame: Data) throws -> Data {
        guard frame.count > loopbackHeader.count,
              frame.prefix(loopbackHeader.count) == loopbackHeader else {
            throw CoreDeviceTunnelBridgeError.invalidUtunFrame
        }
        let packet = Data(frame.dropFirst(loopbackHeader.count))
        try CDTunnelIPv6Packet.validate(packet)
        return packet
    }

    func readIPv6Packet(timeoutSeconds: Double) throws -> Data {
        guard waitForReadable(fd: fd, timeoutSeconds: timeoutSeconds) else {
            throw DeviceStreamError.timeout("utun read")
        }
        var buffer = [UInt8](repeating: 0, count: CDTunnelIPv6Packet.maxPacketSize + Self.loopbackHeader.count)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            return try Self.decodeUtunFrame(Data(buffer.prefix(count)))
        }
        if count == 0 {
            throw DeviceStreamError.closed("utun")
        }
        if errno == EINTR || errno == EAGAIN {
            throw DeviceStreamError.timeout("utun read")
        }
        throw DeviceStreamError.readFailed("utun", errno: errno)
    }

    func writeIPv6Packet(_ packet: Data) throws {
        try writeAll(fd: fd, data: Self.encodeUtunFrame(ipv6Packet: packet))
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    private static func interfaceName(fd: Int32) throws -> String {
        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var length = socklen_t(name.count)
        let result = name.withUnsafeMutableBufferPointer { pointer in
            Darwin.getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, pointer.baseAddress, &length)
        }
        guard result == 0 else {
            throw CoreDeviceTunnelBridgeError.utunNameLookupFailed(errno)
        }
        return String(cString: name)
    }

    private static func fillControlName(_ name: String, into info: inout ctl_info) throws {
        let bytes = Array(name.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: info.ctl_name) else {
            throw CLIParseError.invalidValue("utun control name too long")
        }
        withUnsafeMutableBytes(of: &info.ctl_name) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                raw[index] = UInt8(bitPattern: byte)
            }
        }
    }
}
