import Foundation
import Darwin
import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class DeviceProtocolClientTests: XCTestCase {
    override func tearDown() {
        RemoteServiceDiscoveryClient.resetTestingOverrides()
        CoreDeviceTunnelInterfaceConfigurator.resetTestingOverrides()
        super.tearDown()
    }

    func testCDTunnelHandshakeRequestFrame() throws {
        let packet = try CDTunnelPacket.encodeHandshakeRequest()

        XCTAssertEqual(String(data: packet.prefix(8), encoding: .utf8), "CDTunnel")
        let payloadSize = Int((UInt16(packet[8]) << 8) | UInt16(packet[9]))
        XCTAssertEqual(payloadSize, packet.count - 10)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(packet.dropFirst(10))) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "clientHandshakeRequest")
        XCTAssertEqual(body["mtu"] as? Int, 16_000)
    }

    func testCDTunnelHandshakeResponseDecodesTunnelAddresses() throws {
        let packet = try cdtunnelPacket([
            "serverAddress": "fd7b:e5b:6f53::1",
            "serverRSDPort": 58783,
            "clientParameters": [
                "address": "fd7b:e5b:6f53::2",
                "mtu": 16000,
            ],
        ])

        let handshake = try CDTunnelPacket.decodeHandshakeResponse(packet)

        XCTAssertEqual(handshake.serverAddress, "fd7b:e5b:6f53::1")
        XCTAssertEqual(handshake.serverRSDPort, 58783)
        XCTAssertEqual(handshake.clientAddress, "fd7b:e5b:6f53::2")
        XCTAssertEqual(handshake.clientMTU, 16000)
    }

    func testCoreDeviceTunnelClientRequestsHandshake() throws {
        let response = try cdtunnelPacket([
            "serverAddress": "fd7b:e5b:6f53::1",
            "serverRSDPort": 58783,
            "clientParameters": [
                "address": "fd7b:e5b:6f53::2",
                "mtu": 16000,
            ],
        ])
        let stream = FakeDeviceStream(reads: [response])
        let client = CoreDeviceTunnelClient(stream: stream)

        let handshake = try client.requestHandshake()

        XCTAssertEqual(handshake.serverRSDPort, 58783)
        XCTAssertEqual(stream.writes.count, 1)
        XCTAssertEqual(String(data: stream.writes[0].prefix(8), encoding: .utf8), "CDTunnel")
    }

    func testCoreDeviceTunnelClientReadsAndWritesIPv6Packets() throws {
        let packet = ipv6Packet(body: Data([0xca, 0xfe]))
        let stream = FakeDeviceStream(reads: [packet])
        let client = CoreDeviceTunnelClient(stream: stream)

        let read = try client.readIPv6Packet()
        try client.writeIPv6Packet(read)

        XCTAssertEqual(read, packet)
        XCTAssertEqual(stream.writes, [packet])
    }

    func testCoreDeviceTunnelClientRejectsInvalidIPv6Packets() throws {
        var invalidVersion = ipv6Packet(body: Data())
        invalidVersion[0] = 0x40
        let stream = FakeDeviceStream(reads: [invalidVersion])
        let client = CoreDeviceTunnelClient(stream: stream)

        XCTAssertThrowsError(try client.readIPv6Packet()) { error in
            XCTAssertEqual(error as? CDTunnelError, .invalidIPv6Packet)
        }

        XCTAssertThrowsError(try client.writeIPv6Packet(Data([0x60]))) { error in
            XCTAssertEqual(error as? CDTunnelError, .invalidIPv6Packet)
        }
    }

    func testCoreDeviceTunnelBridgePumpsPacketsInBothDirections() throws {
        let devicePacket = ipv6Packet(body: Data([0x01]))
        let interfacePacket = ipv6Packet(body: Data([0x02, 0x03]))
        let device = FakeIPv6PacketIO(reads: [devicePacket])
        let networkInterface = FakeIPv6PacketIO(reads: [interfacePacket])
        let bridge = CoreDeviceTunnelBridge(device: device, networkInterface: networkInterface)

        try bridge.pumpDeviceToInterfaceOnce()
        try bridge.pumpInterfaceToDeviceOnce()
        bridge.close()

        XCTAssertEqual(networkInterface.writes, [devicePacket])
        XCTAssertEqual(device.writes, [interfacePacket])
        XCTAssertEqual(bridge.stats.deviceToInterfacePackets, 1)
        XCTAssertEqual(bridge.stats.interfaceToDevicePackets, 1)
        XCTAssertEqual(bridge.stats.deviceToInterfaceBytes, devicePacket.count)
        XCTAssertEqual(bridge.stats.interfaceToDeviceBytes, interfacePacket.count)
        XCTAssertTrue(device.closed)
        XCTAssertTrue(networkInterface.closed)
    }

    func testCoreDeviceTunnelBridgeRejectsMalformedPacketsBeforeForwarding() throws {
        var invalid = ipv6Packet(body: Data())
        invalid[0] = 0x40
        let device = FakeIPv6PacketIO(reads: [invalid])
        let networkInterface = FakeIPv6PacketIO(reads: [])
        let bridge = CoreDeviceTunnelBridge(device: device, networkInterface: networkInterface)

        XCTAssertThrowsError(try bridge.pumpDeviceToInterfaceOnce()) { error in
            XCTAssertEqual(error as? CDTunnelError, .invalidIPv6Packet)
        }
        XCTAssertTrue(networkInterface.writes.isEmpty)
        XCTAssertEqual(bridge.stats, CoreDeviceTunnelBridgeStats())
    }

    func testCoreDeviceTunnelInterfaceConfigBuildsIfconfigArguments() {
        let handshake = CoreDeviceTunnelHandshake(
            serverAddress: "fd7b:e5b:6f53::1",
            serverRSDPort: 58_783,
            clientAddress: "fd7b:e5b:6f53::2",
            clientMTU: 16_000
        )
        let config = CoreDeviceTunnelInterfaceConfig(interfaceName: "utun9", handshake: handshake)

        XCTAssertEqual(CoreDeviceTunnelInterfaceConfigurator.ifconfigArguments(for: config), [
            "utun9",
            "inet6",
            "fd7b:e5b:6f53::2",
            "fd7b:e5b:6f53::1",
            "prefixlen",
            "128",
            "mtu",
            "16000",
            "up",
        ])
    }

    func testCoreDeviceTunnelInterfaceConfiguratorAppliesIfconfig() throws {
        let handshake = CoreDeviceTunnelHandshake(
            serverAddress: "fd7b:e5b:6f53::1",
            serverRSDPort: 58_783,
            clientAddress: "fd7b:e5b:6f53::2",
            clientMTU: 16_000
        )
        let config = CoreDeviceTunnelInterfaceConfig(interfaceName: "utun9", handshake: handshake)
        var command: String?
        var arguments: [String]?
        CoreDeviceTunnelInterfaceConfigurator.shellRunnerForTesting = { cmd, args in
            command = cmd
            arguments = args
            return ""
        }

        try CoreDeviceTunnelInterfaceConfigurator.apply(config)

        XCTAssertEqual(command, "ifconfig")
        XCTAssertEqual(arguments, CoreDeviceTunnelInterfaceConfigurator.ifconfigArguments(for: config))
    }

    func testMacOSUtunInterfaceEncodesAndDecodesIPv6Frames() throws {
        let packet = ipv6Packet(body: Data([0x0a, 0x0b]))

        let frame = try MacOSUtunInterface.encodeUtunFrame(ipv6Packet: packet)
        let decoded = try MacOSUtunInterface.decodeUtunFrame(frame)

        XCTAssertEqual(frame.prefix(4), MacOSUtunInterface.loopbackHeader)
        XCTAssertEqual(decoded, packet)
    }

    func testMacOSUtunInterfaceRejectsInvalidFramesAndPackets() throws {
        let packet = ipv6Packet(body: Data())
        XCTAssertThrowsError(try MacOSUtunInterface.decodeUtunFrame(Data([0, 0, 0, 2]) + packet)) { error in
            XCTAssertEqual(error as? CoreDeviceTunnelBridgeError, .invalidUtunFrame)
        }

        var invalid = packet
        invalid[0] = 0x40
        XCTAssertThrowsError(try MacOSUtunInterface.encodeUtunFrame(ipv6Packet: invalid)) { error in
            XCTAssertEqual(error as? CDTunnelError, .invalidIPv6Packet)
        }
    }

    func testCoreDeviceIPv6TCPCodecEncodesAndDecodesSegment() throws {
        let source = try CoreDeviceIPv6TCPCodec.parseIPv6Address("fd7b:e5b:6f53::2")
        let destination = try CoreDeviceIPv6TCPCodec.parseIPv6Address("fd7b:e5b:6f53::1")
        let packet = try CoreDeviceIPv6TCPCodec.encodeSegment(
            sourceAddress: source,
            destinationAddress: destination,
            sourcePort: 50_000,
            destinationPort: 58_783,
            sequenceNumber: 100,
            acknowledgmentNumber: 900,
            flags: CoreDeviceTCPFlags.psh | CoreDeviceTCPFlags.ack,
            payload: Data("ping".utf8)
        )

        let segment = try CoreDeviceIPv6TCPCodec.decodeSegment(packet)

        XCTAssertEqual(segment.sourceAddress, source)
        XCTAssertEqual(segment.destinationAddress, destination)
        XCTAssertEqual(segment.sourcePort, 50_000)
        XCTAssertEqual(segment.destinationPort, 58_783)
        XCTAssertEqual(segment.sequenceNumber, 100)
        XCTAssertEqual(segment.acknowledgmentNumber, 900)
        XCTAssertEqual(segment.flags, CoreDeviceTCPFlags.psh | CoreDeviceTCPFlags.ack)
        XCTAssertEqual(segment.payload, Data("ping".utf8))
        XCTAssertEqual(packet[6], CoreDeviceIPv6TCPCodec.protocolTCP)

        let tcpPayload = Data(packet.dropFirst(CoreDeviceIPv6TCPCodec.ipv6HeaderSize))
        let pseudo = source + destination + uint32BE(UInt32(tcpPayload.count)) + Data([0, 0, 0, CoreDeviceIPv6TCPCodec.protocolTCP]) + tcpPayload
        XCTAssertEqual(CoreDeviceIPv6TCPCodec.internetChecksum(pseudo), 0)
    }

    func testCoreDeviceUserSpaceTCPConnectionHandshakeDataAndAck() throws {
        let local = "fd7b:e5b:6f53::2"
        let remote = "fd7b:e5b:6f53::1"
        let localAddress = try CoreDeviceIPv6TCPCodec.parseIPv6Address(local)
        let remoteAddress = try CoreDeviceIPv6TCPCodec.parseIPv6Address(remote)
        let synAck = try CoreDeviceIPv6TCPCodec.encodeSegment(
            sourceAddress: remoteAddress,
            destinationAddress: localAddress,
            sourcePort: 58_783,
            destinationPort: 50_000,
            sequenceNumber: 900,
            acknowledgmentNumber: 101,
            flags: CoreDeviceTCPFlags.syn | CoreDeviceTCPFlags.ack
        )
        let serverData = try CoreDeviceIPv6TCPCodec.encodeSegment(
            sourceAddress: remoteAddress,
            destinationAddress: localAddress,
            sourcePort: 58_783,
            destinationPort: 50_000,
            sequenceNumber: 901,
            acknowledgmentNumber: 106,
            flags: CoreDeviceTCPFlags.psh | CoreDeviceTCPFlags.ack,
            payload: Data("ok".utf8)
        )
        let tunnel = FakeIPv6PacketIO(reads: [synAck, serverData])
        let connection = try CoreDeviceUserSpaceTCPConnection(
            tunnel: tunnel,
            localAddress: local,
            remoteAddress: remote,
            localPort: 50_000,
            remotePort: 58_783,
            initialSequence: 100,
            maxSegmentPayload: 4
        )

        try connection.connect()
        try connection.write(Data("hello".utf8))
        let response = try connection.readExact(byteCount: 2, timeoutSeconds: 1)
        try connection.write(Data("!".utf8))

        XCTAssertEqual(response, Data("ok".utf8))
        XCTAssertEqual(tunnel.writes.count, 5)
        let syn = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[0])
        XCTAssertEqual(syn.flags, CoreDeviceTCPFlags.syn)
        XCTAssertEqual(syn.sequenceNumber, 100)
        let handshakeAck = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[1])
        XCTAssertEqual(handshakeAck.flags, CoreDeviceTCPFlags.ack)
        XCTAssertEqual(handshakeAck.sequenceNumber, 101)
        XCTAssertEqual(handshakeAck.acknowledgmentNumber, 901)
        let firstData = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[2])
        XCTAssertEqual(firstData.payload, Data("hell".utf8))
        XCTAssertEqual(firstData.sequenceNumber, 101)
        let secondData = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[3])
        XCTAssertEqual(secondData.payload, Data("o".utf8))
        XCTAssertEqual(secondData.sequenceNumber, 105)
        let piggybackAck = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[4])
        XCTAssertEqual(piggybackAck.flags, CoreDeviceTCPFlags.psh | CoreDeviceTCPFlags.ack)
        XCTAssertEqual(piggybackAck.payload, Data("!".utf8))
        XCTAssertEqual(piggybackAck.sequenceNumber, 106)
        XCTAssertEqual(piggybackAck.acknowledgmentNumber, 903)
    }

    func testCDTunnelRejectsInvalidMagicAndMissingFields() throws {
        var invalidMagic = try cdtunnelPacket(["type": "serverHandshakeResponse"])
        invalidMagic.replaceSubrange(0..<8, with: Data("BadMagic".utf8))
        XCTAssertThrowsError(try CDTunnelPacket.decodeJSONPacket(invalidMagic)) { error in
            XCTAssertEqual(error as? CDTunnelError, .invalidMagic)
        }

        let missingAddress = try cdtunnelPacket([
            "serverRSDPort": 58783,
            "clientParameters": [
                "address": "fd7b:e5b:6f53::2",
                "mtu": 16000,
            ],
        ])
        XCTAssertThrowsError(try CDTunnelPacket.decodeHandshakeResponse(missingAddress)) { error in
            XCTAssertEqual(error as? CDTunnelError, .missingField("serverAddress"))
        }
    }

    func testRemoteXPCWrapperRoundTripsDictionaryPayload() throws {
        let payload: [String: RemoteXPCValue] = [
            "Command": .string("DoSomething"),
            "Count": .uint64(7),
            "Enabled": .bool(true),
            "Nested": .dictionary([
                "Items": .array([.string("a"), .int64(-2), .null]),
            ]),
        ]

        let wrapper = try RemoteXPCWrapper.encodeDictionary(payload, messageID: 42, wantingReply: true)
        let decoded = try RemoteXPCWrapper.decode(wrapper)

        XCTAssertEqual(decoded.messageID, 42)
        XCTAssertEqual(decoded.flags & RemoteXPCFlags.alwaysSet, RemoteXPCFlags.alwaysSet)
        XCTAssertEqual(decoded.flags & RemoteXPCFlags.dataPresent, RemoteXPCFlags.dataPresent)
        XCTAssertEqual(decoded.flags & RemoteXPCFlags.wantingReply, RemoteXPCFlags.wantingReply)
        XCTAssertEqual(decoded.payload, .dictionary(payload))
    }

    func testRemoteXPCHTTP2ClientHandshakeFrames() throws {
        var handshake = try RemoteXPCHTTP2.encodeClientHandshake()
        XCTAssertEqual(Data(handshake.prefix(RemoteXPCHTTP2.connectionPreface.count)), RemoteXPCHTTP2.connectionPreface)
        handshake.removeFirst(RemoteXPCHTTP2.connectionPreface.count)

        let frames = try http2Frames(handshake)

        XCTAssertEqual(frames.map(\.type), [
            RemoteXPCHTTP2.frameSettings,
            RemoteXPCHTTP2.frameWindowUpdate,
            RemoteXPCHTTP2.frameHeaders,
            RemoteXPCHTTP2.frameData,
            RemoteXPCHTTP2.frameData,
            RemoteXPCHTTP2.frameHeaders,
            RemoteXPCHTTP2.frameData,
        ])
        XCTAssertEqual(frames[2].streamID, RemoteXPCHTTP2.rootStreamID)
        XCTAssertEqual(frames[2].flags, RemoteXPCHTTP2.flagEndHeaders)
        XCTAssertEqual(frames[5].streamID, RemoteXPCHTTP2.replyStreamID)

        let firstRootMessage = try RemoteXPCWrapper.decode(frames[3].payload)
        XCTAssertEqual(firstRootMessage.payload, .dictionary([:]))

        let replyChannelMessage = try RemoteXPCWrapper.decode(frames[6].payload)
        XCTAssertNil(replyChannelMessage.payload)
        XCTAssertEqual(replyChannelMessage.flags & RemoteXPCFlags.initHandshake, RemoteXPCFlags.initHandshake)
    }

    func testRemoteXPCHTTP2ClientHandshakeMatchesPymobiledevice3ReferenceBytes() throws {
        let expectedHex = """
        505249202a20485454502f322e300d0a0d0a534d0d0a0d0a\
        00000c040000000000000300000064000400100000\
        000004080000000000000f0001\
        000000010400000001\
        00002c000000000001920bb0290100000014000000000000000000000000000000423713420500000000f000000400000000000000\
        000018000000000001920bb0290102000000000000000000000000000000000000\
        000000010400000003\
        000018000000000003920bb0290100400000000000000000000000000000000000
        """.split(separator: "\n").joined()
        XCTAssertEqual(try RemoteXPCHTTP2.encodeClientHandshake().hexString, expectedHex)
        XCTAssertEqual(RemoteXPCHTTP2.settingsFrame(ack: true).hexString, "000000040100000000")
    }

    func testRemoteXPCWrapperRoundTripsUUIDAndDatePayload() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let payload: [String: RemoteXPCValue] = [
            "Identifier": .uuid(id),
            "Timestamp": .date(123_456_789),
        ]

        let decoded = try RemoteXPCWrapper.decode(try RemoteXPCWrapper.encodeDictionary(payload))

        XCTAssertEqual(decoded.payload, .dictionary(payload))
    }

    func testDTXAuxPrimitiveDictionaryMatchesPymobiledevice3PrimitiveInt32Fixture() {
        XCTAssertEqual(DTXPrimitiveDictionary.encodeAux([]), Data())
        XCTAssertEqual(
            DTXPrimitiveDictionary.encodeAux([.primitiveInt32(7)]).hexString,
            "f0010000000000000c000000000000000a0000000300000007000000"
        )
    }

    func testDTXDispatchFrameBuildsSingleFragmentWithSelectorPayloadAndAux() throws {
        let encoded = try DTXMessageEncoder.dispatch(
            identifier: 7,
            channelCode: 3,
            selector: "requestDisableMemoryLimitsForPid:",
            arguments: [.primitiveInt32(42)],
            expectsReply: true
        )

        XCTAssertEqual(readUInt32LE(encoded.wireData, 0), 0x1f3d5b79)
        XCTAssertEqual(readUInt32LE(encoded.wireData, 4), 32)
        XCTAssertEqual(encoded.wireData[8], 0)
        XCTAssertEqual(encoded.wireData[10], 1)
        XCTAssertEqual(readUInt32LE(encoded.wireData, 12), UInt32(encoded.wireData.count - 32))
        XCTAssertEqual(readUInt32LE(encoded.wireData, 16), 7)
        XCTAssertEqual(readUInt32LE(encoded.wireData, 20), 0)
        XCTAssertEqual(readUInt32LE(encoded.wireData, 24), 3)
        XCTAssertEqual(readUInt32LE(encoded.wireData, 28), DTXTransportFlag.expectsReply)

        XCTAssertEqual(encoded.wireData[32], DTXMessageKind.dispatch.rawValue)
        XCTAssertEqual(readUInt32LE(encoded.wireData, 36), UInt32(encoded.aux.count))
        XCTAssertEqual(readUInt32LE(encoded.wireData, 40), UInt32(encoded.aux.count + encoded.payload.count))
        XCTAssertEqual(try unarchiveDTXBuffer(encoded.payload) as? String, "requestDisableMemoryLimitsForPid:")
        XCTAssertEqual(encoded.aux.hexString, "f0010000000000000c000000000000000a000000030000002a000000")
    }

    func testDVTProviderAndControlContractsMatchPymobiledevice3Selectors() throws {
        XCTAssertEqual(DVTInstrumentsContract.Provider.secureServiceName, "com.apple.instruments.remoteserver.DVTSecureSocketProxy")
        XCTAssertEqual(DVTInstrumentsContract.Provider.rsdServiceName, "com.apple.instruments.dtservicehub")
        XCTAssertEqual(DVTInstrumentsContract.Provider.oldServiceName, "com.apple.instruments.remoteserver")
        XCTAssertEqual(DVTInstrumentsContract.Provider.capabilities[DVTInstrumentsContract.Provider.terminationCallbackCapability], 1)

        let notify = try DVTInstrumentsContract.Control.notifyCapabilities()
        XCTAssertEqual(notify.serviceIdentifier, "DTXControl")
        XCTAssertEqual(notify.selector, "_notifyOfPublishedCapabilities:")
        XCTAssertFalse(notify.expectsReply)
        let capabilities = try XCTUnwrap(try unarchiveDTXArgument(notify.arguments[0]) as? NSDictionary)
        XCTAssertEqual((capabilities[DVTInstrumentsContract.Provider.terminationCallbackCapability] as? NSNumber)?.intValue, 1)

        let requestChannel = try DVTInstrumentsContract.Control.requestChannel(code: 7, identifier: DVTInstrumentsContract.XCTestManagerDaemon.proxyServiceIdentifier)
        XCTAssertEqual(requestChannel.selector, "_requestChannelWithCode:identifier:")
        XCTAssertEqual(requestChannel.arguments[0], .primitiveInt32(7))
        XCTAssertEqual(try unarchiveDTXArgument(requestChannel.arguments[1]) as? String, DVTInstrumentsContract.XCTestManagerDaemon.proxyServiceIdentifier)
        XCTAssertTrue(requestChannel.expectsReply)
        XCTAssertEqual(DVTInstrumentsContract.Control.cancelChannel(code: 7).selector, "_channelCanceled:")
    }

    func testXCTestManagerContractsMatchPymobiledevice3Selectors() throws {
        XCTAssertEqual(DVTInstrumentsContract.XCTestManagerDaemon.secureServiceName, "com.apple.testmanagerd.lockdown.secure")
        XCTAssertEqual(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName, "com.apple.dt.testmanagerd.remote")
        XCTAssertEqual(DVTInstrumentsContract.XCTestManagerDaemon.oldServiceName, "com.apple.testmanagerd.lockdown")
        XCTAssertEqual(
            DVTInstrumentsContract.XCTestManagerDaemon.proxyServiceIdentifier,
            "dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface"
        )

        let modernControl = try XCTUnwrap(try DVTInstrumentsContract.XCTestManagerDaemon.initiateControlSession(productMajorVersion: 17))
        XCTAssertEqual(modernControl.serviceIdentifier, "XCTestManager_DaemonConnectionInterface")
        XCTAssertEqual(modernControl.selector, "_IDE_initiateControlSessionWithCapabilities:")
        XCTAssertEqual((try unarchiveDTXArgument(modernControl.arguments[0]) as? NSDictionary)?.count, 0)

        let ios16Control = try XCTUnwrap(try DVTInstrumentsContract.XCTestManagerDaemon.initiateControlSession(productMajorVersion: 16))
        XCTAssertEqual(ios16Control.selector, "_IDE_initiateControlSessionWithProtocolVersion:")
        XCTAssertEqual((try unarchiveDTXArgument(ios16Control.arguments[0]) as? NSNumber)?.intValue, 36)
        XCTAssertNil(try DVTInstrumentsContract.XCTestManagerDaemon.initiateControlSession(productMajorVersion: 10))

        let ios17Auth = try DVTInstrumentsContract.XCTestManagerDaemon.authorizeTestSession(productMajorVersion: 17, pid: 456)
        XCTAssertEqual(ios17Auth.selector, "_IDE_authorizeTestSessionWithProcessID:")
        XCTAssertEqual((try unarchiveDTXArgument(ios17Auth.arguments[0]) as? NSNumber)?.intValue, 456)

        let ios11Auth = try DVTInstrumentsContract.XCTestManagerDaemon.authorizeTestSession(productMajorVersion: 11, pid: 456)
        XCTAssertEqual(ios11Auth.selector, "_IDE_initiateControlSessionForTestProcessID:protocolVersion:")

        let legacyAuth = try DVTInstrumentsContract.XCTestManagerDaemon.authorizeTestSession(productMajorVersion: 9, pid: 456)
        XCTAssertEqual(legacyAuth.selector, "_IDE_initiateControlSessionForTestProcessID:")
    }

    func testDTXStreamInvokerWritesDispatchAndDecodesObjectReply() throws {
        let reply = try DTXMessageEncoder.objectReply(
            identifier: 5,
            conversationIndex: 1,
            channelCode: -3,
            object: NSNumber(value: 999)
        )
        let stream = FakeDeviceStream(reads: [reply.wireData])
        let invoker = DTXStreamInvoker(stream: stream, channelCode: 3, firstIdentifier: 5)

        let result = try invoker.invoke(DVTInvocation(
            serviceIdentifier: "test.service",
            selector: "requestDisableMemoryLimitsForPid:",
            arguments: [.primitiveInt32(42)],
            expectsReply: true
        ))

        XCTAssertEqual((result as? NSNumber)?.intValue, 999)
        XCTAssertEqual(stream.writes.count, 1)

        let sent = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[0]]))
        XCTAssertEqual(sent.identifier, 5)
        XCTAssertEqual(sent.channelCode, 3)
        XCTAssertEqual(sent.kind, .dispatch)
        XCTAssertEqual(sent.transportFlags, DTXTransportFlag.expectsReply)
        XCTAssertEqual(try unarchiveDTXBuffer(sent.payload) as? String, "requestDisableMemoryLimitsForPid:")
        XCTAssertEqual(sent.aux.hexString, "f0010000000000000c000000000000000a000000030000002a000000")
    }

    func testDTXMessageDecoderReassemblesMultiFragmentObjectReply() throws {
        let reply = try DTXMessageEncoder.objectReply(
            identifier: 9,
            conversationIndex: 1,
            channelCode: -7,
            object: ["value": "ok", "count": NSNumber(value: 2)]
        )
        let body = Data(reply.wireData.dropFirst(32))
        let firstChunk = Data(body.prefix(23))
        let secondChunk = Data(body.dropFirst(23))
        let fragmented =
            dtxFragmentHeader(index: 0, count: 3, dataSize: body.count, identifier: 9, conversationIndex: 1, channelCode: -7)
            + dtxFragmentHeader(index: 1, count: 3, dataSize: firstChunk.count, identifier: 9, conversationIndex: 1, channelCode: -7)
            + firstChunk
            + dtxFragmentHeader(index: 2, count: 3, dataSize: secondChunk.count, identifier: 9, conversationIndex: 1, channelCode: -7)
            + secondChunk

        let decoded = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [fragmented]))

        XCTAssertEqual(decoded.identifier, 9)
        XCTAssertEqual(decoded.conversationIndex, 1)
        XCTAssertEqual(decoded.channelCode, -7)
        XCTAssertEqual(decoded.kind, .object)
        let object = try XCTUnwrap(try unarchiveDTXBuffer(decoded.payload) as? NSDictionary)
        XCTAssertEqual(object["value"] as? String, "ok")
        XCTAssertEqual((object["count"] as? NSNumber)?.intValue, 2)
    }

    func testDTXControlChannelPublishesCapabilitiesRequestsServiceAndSharesMessageIDs() throws {
        let serverCapabilities = try DTXMessageEncoder.dispatch(
            identifier: 90,
            channelCode: DVTInstrumentsContract.Control.channelCode,
            selector: "_notifyOfPublishedCapabilities:",
            arguments: [.archived(["server": 1])],
            expectsReply: false
        )
        let requestReply = try DTXMessageEncoder.okReply(
            identifier: 2,
            conversationIndex: 1,
            channelCode: DVTInstrumentsContract.Control.channelCode
        )
        let serviceReply = try DTXMessageEncoder.objectReply(
            identifier: 3,
            conversationIndex: 1,
            channelCode: -7,
            object: NSNumber(value: true)
        )
        let stream = FakeDeviceStream(reads: [serverCapabilities.wireData, requestReply.wireData, serviceReply.wireData])
        let control = DTXControlChannelClient(stream: stream)

        try control.notifyCapabilities()
        XCTAssertNil(try control.requestChannel(code: 7, identifier: DVTInstrumentsContract.XCTestManagerDaemon.proxyServiceIdentifier))
        let daemon = XCTestManagerDaemonClient(invoker: control.invoker(channelCode: 7))
        XCTAssertTrue(try daemon.authorizeTestSession(productMajorVersion: 17, pid: 42))

        XCTAssertEqual(stream.writes.count, 3)
        let notify = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[0]]))
        XCTAssertEqual(notify.identifier, 1)
        XCTAssertEqual(notify.channelCode, DVTInstrumentsContract.Control.channelCode)
        XCTAssertEqual(notify.transportFlags, 0)
        XCTAssertEqual(try unarchiveDTXBuffer(notify.payload) as? String, "_notifyOfPublishedCapabilities:")

        let request = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[1]]))
        XCTAssertEqual(request.identifier, 2)
        XCTAssertEqual(request.channelCode, DVTInstrumentsContract.Control.channelCode)
        XCTAssertEqual(request.transportFlags, DTXTransportFlag.expectsReply)
        XCTAssertEqual(try unarchiveDTXBuffer(request.payload) as? String, "_requestChannelWithCode:identifier:")

        let service = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[2]]))
        XCTAssertEqual(service.identifier, 3)
        XCTAssertEqual(service.channelCode, 7)
        XCTAssertEqual(try unarchiveDTXBuffer(service.payload) as? String, "_IDE_authorizeTestSessionWithProcessID:")
    }

    func testDTXStreamInvokerDoesNotReadReplyForFireAndForgetInvocation() throws {
        let stream = FakeDeviceStream(reads: [])
        let invoker = DTXStreamInvoker(stream: stream, channelCode: 3, firstIdentifier: 8)

        let result = try invoker.invoke(DVTInvocation(
            serviceIdentifier: "test.fire",
            selector: "fireAndForget:",
            arguments: [.archived(123)],
            expectsReply: false
        ))

        XCTAssertNil(result)
        XCTAssertEqual(stream.writes.count, 1)
        let sent = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[0]]))
        XCTAssertEqual(sent.identifier, 8)
        XCTAssertEqual(sent.kind, .dispatch)
        XCTAssertEqual(sent.transportFlags, 0)
        XCTAssertEqual(try unarchiveDTXBuffer(sent.payload) as? String, "fireAndForget:")
    }

    func testXCTestManagerDaemonClientUsesVersionedAuthorizationContracts() throws {
        let invoker = FakeDVTInvoker(replies: [NSNumber(value: true), NSNumber(value: false)])
        let client = XCTestManagerDaemonClient(invoker: invoker)

        XCTAssertNil(try client.initiateControlSession(productMajorVersion: 9))
        XCTAssertTrue(try client.authorizeTestSession(productMajorVersion: 17, pid: 777))
        XCTAssertFalse(try client.authorizeTestSession(productMajorVersion: 11, pid: 888))

        XCTAssertEqual(invoker.invocations.map(\.selector), [
            "_IDE_authorizeTestSessionWithProcessID:",
            "_IDE_initiateControlSessionForTestProcessID:protocolVersion:",
        ])
    }

    func testXCTestManagerAuthorizationProviderOpensProxyChannelAndAuthorizesPid() throws {
        let serverCapabilities = try DTXMessageEncoder.dispatch(
            identifier: 90,
            channelCode: DVTInstrumentsContract.Control.channelCode,
            selector: "_notifyOfPublishedCapabilities:",
            arguments: [.archived(["server": 1])],
            expectsReply: false
        )
        let openDaemonReply = try DTXMessageEncoder.okReply(identifier: 2, conversationIndex: 1, channelCode: 0)
        let initiateReply = try DTXMessageEncoder.objectReply(identifier: 3, conversationIndex: 1, channelCode: -1, object: [:])
        let authorizeReply = try DTXMessageEncoder.objectReply(identifier: 4, conversationIndex: 1, channelCode: -1, object: NSNumber(value: true))
        let stream = FakeDeviceStream(reads: [
            serverCapabilities.wireData,
            openDaemonReply.wireData,
            initiateReply.wireData,
            authorizeReply.wireData,
        ])
        var connectedUdids: [String] = []
        var versionUdids: [String] = []
        let provider = XCTestManagerAuthorizationProvider(dependencies: XCTestManagerAuthorizationProvider.Dependencies(
            connectTestManager: { udid in
                connectedUdids.append(udid)
                return stream
            },
            productMajorVersion: { udid in
                versionUdids.append(udid)
                return 17
            }
        ))

        try provider.authorizeDriver(udid: "REAL-UDID", pid: 321)

        XCTAssertEqual(versionUdids, ["REAL-UDID"])
        XCTAssertEqual(connectedUdids, ["REAL-UDID"])
        XCTAssertTrue(stream.closed)
        XCTAssertEqual(stream.writes.count, 4)

        let openChannel = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[1]]))
        XCTAssertEqual(openChannel.identifier, 2)
        XCTAssertEqual(openChannel.channelCode, 0)
        XCTAssertEqual(try unarchiveDTXBuffer(openChannel.payload) as? String, "_requestChannelWithCode:identifier:")

        let initiate = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[2]]))
        XCTAssertEqual(initiate.identifier, 3)
        XCTAssertEqual(initiate.channelCode, 1)
        XCTAssertEqual(try unarchiveDTXBuffer(initiate.payload) as? String, "_IDE_initiateControlSessionWithCapabilities:")

        let authorize = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[3]]))
        XCTAssertEqual(authorize.identifier, 4)
        XCTAssertEqual(authorize.channelCode, 1)
        XCTAssertEqual(try unarchiveDTXBuffer(authorize.payload) as? String, "_IDE_authorizeTestSessionWithProcessID:")
    }

    func testRemoteXPCPeerInfoParsesServices() throws {
        let peerInfo = try RemoteXPCPeerInfo.decode(remotePeerInfoValue())

        XCTAssertEqual(peerInfo.uniqueDeviceID, "00008110-001234")
        XCTAssertEqual(peerInfo.productType, "iPhone16,2")
        XCTAssertEqual(peerInfo.osVersion, "18.0")
        XCTAssertEqual(try peerInfo.servicePort("com.apple.instruments.dtservicehub"), 54321)
        XCTAssertEqual(peerInfo.services["com.apple.instruments.dtservicehub"]?.usesRemoteXPC, true)
        XCTAssertEqual(peerInfo.services["com.apple.mobile.lockdown.remote.trusted"]?.usesRemoteXPC, false)
    }

    func testRemoteXPCPeerInfoSkipsNonPortServiceEntries() throws {
        guard case .dictionary(var root) = remotePeerInfoValue() else {
            return XCTFail("remote peer info fixture must be a dictionary")
        }
        guard case .dictionary(var services) = root["Services"] else {
            return XCTFail("remote peer info fixture must include services")
        }
        services["com.apple.afc.shim.remote"] = .dictionary([
            "Properties": .dictionary([
                "UsesRemoteXPC": .bool(false),
            ]),
        ])
        root["Services"] = .dictionary(services)

        let peerInfo = try RemoteXPCPeerInfo.decode(.dictionary(root))

        XCTAssertNil(peerInfo.services["com.apple.afc.shim.remote"])
        XCTAssertEqual(try peerInfo.servicePort("com.apple.instruments.dtservicehub"), 54321)
    }

    func testRemoteXPCPeerInfoParsesStringPorts() throws {
        guard case .dictionary(var root) = remotePeerInfoValue() else {
            return XCTFail("remote peer info fixture must be a dictionary")
        }
        guard case .dictionary(var services) = root["Services"],
              case .dictionary(var service) = services["com.apple.instruments.dtservicehub"] else {
            return XCTFail("remote peer info fixture must include dtservicehub")
        }
        service["Port"] = .string("54321")
        services["com.apple.instruments.dtservicehub"] = .dictionary(service)
        root["Services"] = .dictionary(services)

        let peerInfo = try RemoteXPCPeerInfo.decode(.dictionary(root))

        XCTAssertEqual(try peerInfo.servicePort("com.apple.instruments.dtservicehub"), 54321)
    }

    func testRemoteXPCClientReceivesFragmentedPeerInfoAndAcksSettings() throws {
        let wrapper = try RemoteXPCWrapper.encode(
            messageID: 5,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: remotePeerInfoValue()
        )
        let split = 13
        let frames = RemoteXPCHTTP2.settingsFrame()
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: Data(wrapper.prefix(split)))
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: Data(wrapper.dropFirst(split)))
        let stream = FakeDeviceStream(reads: [frames])
        let client = RemoteXPCClient(stream: stream)

        try client.completeClientHandshake()
        let peerInfo = try client.receivePeerInfo()

        XCTAssertEqual(peerInfo.uniqueDeviceID, "00008110-001234")
        XCTAssertEqual(stream.writes.count, try RemoteXPCHTTP2.clientHandshakeChunks().count + 1)
        XCTAssertEqual(stream.writes[0], RemoteXPCHTTP2.connectionPreface)
        let ackFrame = try RemoteXPCHTTP2.decodeFrame(stream.writes.last!)
        XCTAssertEqual(ackFrame.type, RemoteXPCHTTP2.frameSettings)
        XCTAssertEqual(ackFrame.flags, RemoteXPCHTTP2.flagAck)
    }

    func testRemoteXPCClientSendReceiveRequestUsesRootMessageIDAfterHandshake() throws {
        let emptyDictionary = try RemoteXPCWrapper.encodeDictionary([:], messageID: 0)
        let response = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: .dictionary([
                "CoreDevice.output": .dictionary([
                    "ok": .bool(true),
                ]),
            ])
        )
        let stream = FakeDeviceStream(reads: [
            RemoteXPCHTTP2.settingsFrame()
                + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: emptyDictionary)
                + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: response),
        ])
        let client = RemoteXPCClient(stream: stream)

        try client.completeClientHandshake()
        let output = try client.sendReceiveRequest([
            "CoreDevice.featureIdentifier": .string("com.apple.coredevice.feature.launchapplication"),
        ])

        XCTAssertEqual(output.dictionaryValue?["CoreDevice.output"]?.dictionaryValue?["ok"], .bool(true))
        XCTAssertEqual(stream.writes.count, try RemoteXPCHTTP2.clientHandshakeChunks().count + 2)
        XCTAssertEqual(stream.writes[0], RemoteXPCHTTP2.connectionPreface)
        let ackFrame = try RemoteXPCHTTP2.decodeFrame(stream.writes[try RemoteXPCHTTP2.clientHandshakeChunks().count])
        XCTAssertEqual(ackFrame.type, RemoteXPCHTTP2.frameSettings)
        XCTAssertEqual(ackFrame.flags, RemoteXPCHTTP2.flagAck)
        let requestFrame = try RemoteXPCHTTP2.decodeFrame(stream.writes.last!)
        XCTAssertEqual(requestFrame.type, RemoteXPCHTTP2.frameData)
        XCTAssertEqual(requestFrame.streamID, RemoteXPCHTTP2.rootStreamID)
        let request = try RemoteXPCWrapper.decode(requestFrame.payload)
        XCTAssertEqual(request.messageID, 1)
        XCTAssertEqual(request.flags & RemoteXPCFlags.wantingReply, RemoteXPCFlags.wantingReply)
        XCTAssertEqual(
            request.payload?.dictionaryValue?["CoreDevice.featureIdentifier"],
            .string("com.apple.coredevice.feature.launchapplication")
        )
    }

    func testRemoteXPCClientConsumesConcatenatedWrappersInSingleDataFrame() throws {
        let empty = RemoteXPCWrapper.encodeEmpty(messageID: 0, flags: RemoteXPCFlags.alwaysSet)
        let response = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: remotePeerInfoValue()
        )
        let stream = FakeDeviceStream(reads: [
            RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: empty + response),
        ])
        let client = RemoteXPCClient(stream: stream)

        let peerInfo = try client.receivePeerInfo()

        XCTAssertEqual(peerInfo.uniqueDeviceID, "00008110-001234")
    }

    func testRemoteXPCPeerInfoSkipsHandshakePayloads() throws {
        let emptyDictionary = try RemoteXPCWrapper.encodeDictionary([:], messageID: 0)
        let response = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: remotePeerInfoValue()
        )
        let stream = FakeDeviceStream(reads: [
            RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: emptyDictionary),
            RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: response),
        ])
        let client = RemoteXPCClient(stream: stream)

        let peerInfo = try client.receivePeerInfo()

        XCTAssertEqual(peerInfo.uniqueDeviceID, "00008110-001234")
    }

    func testRemoteXPCPeerInfoDoesNotSwallowMalformedPeerInfoPayload() throws {
        let malformedPeerInfo = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: .dictionary([
                "Services": .dictionary([
                    "com.apple.coredevice.appservice": .dictionary([:]),
                ]),
            ])
        )
        let stream = FakeDeviceStream(reads: [
            RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: malformedPeerInfo),
        ])
        let client = RemoteXPCClient(stream: stream)

        XCTAssertThrowsError(try client.receivePeerInfo()) { error in
            XCTAssertEqual(String(describing: error), "RemoteXPC missing field: Properties")
        }
    }

    func testCoreDeviceAppServiceBuildsLaunchApplicationRequest() throws {
        let input = CoreDeviceAppService.launchApplicationInput(
            bundleID: "com.example.driver",
            arguments: ["--foo"],
            terminateExisting: true,
            startSuspended: false,
            environment: ["A": "B"]
        )

        XCTAssertEqual(
            input["applicationSpecifier"]?.dictionaryValue?["bundleIdentifier"]?.dictionaryValue?["_0"],
            .string("com.example.driver")
        )
        let options = try XCTUnwrap(input["options"]?.dictionaryValue)
        XCTAssertEqual(options["arguments"], .array([.string("--foo")]))
        XCTAssertEqual(options["environmentVariables"], .dictionary(["A": .string("B")]))
        XCTAssertEqual(options["standardIOUsesPseudoterminals"], .bool(true))
        XCTAssertEqual(options["startStopped"], .bool(false))
        XCTAssertEqual(options["terminateExisting"], .bool(true))
        XCTAssertEqual(options["user"]?.dictionaryValue?["shortName"], .string("mobile"))
        let plistData = try XCTUnwrap(options["platformSpecificOptions"])
        guard case .data(let data) = plistData else {
            return XCTFail("platformSpecificOptions must be plist data")
        }
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        XCTAssertNotNil(plist as? [String: Any])
    }

    func testCoreDeviceAppServiceBuildsPayloadURLLaunchRequest() throws {
        let input = CoreDeviceAppService.launchApplicationInput(
            bundleID: "com.apple.springboard",
            terminateExisting: false,
            payloadURL: "https://example.com",
            activates: true
        )

        XCTAssertEqual(
            input["applicationSpecifier"]?.dictionaryValue?["bundleIdentifier"]?.dictionaryValue?["_0"],
            .string("com.apple.springboard")
        )
        let options = try XCTUnwrap(input["options"]?.dictionaryValue)
        XCTAssertEqual(
            options["payloadURL"],
            .dictionary([
                "relative": .string("https://example.com"),
            ])
        )
        XCTAssertEqual(options["activates"], .bool(true))
        XCTAssertEqual(options["terminateExisting"], .bool(false))
        XCTAssertEqual(options["startStopped"], .bool(false))
        XCTAssertEqual(options["user"]?.dictionaryValue?["shortName"], .string("mobile"))
    }

    func testCoreDeviceAppServiceInvokesFeatureAndReturnsOutput() throws {
        let response = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: .dictionary([
                "CoreDevice.output": .dictionary([
                    "processTokens": .array([
                        .dictionary([
                            "processIdentifier": .int64(123),
                            "executable": .string("/private/var/containers/Bundle/Application/Driver/IOSUseDriver-Runner"),
                        ]),
                    ]),
                ]),
            ])
        )
        let stream = FakeDeviceStream(reads: [
            RemoteXPCHTTP2.settingsFrame()
                + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: response),
        ])
        let client = RemoteXPCClient(stream: stream)
        try client.completeClientHandshake()
        var uuids = ["device-uuid", "invocation-uuid"]
        let service = CoreDeviceAppService(client: client) {
            uuids.removeFirst()
        }

        let processes = try service.listProcesses()

        XCTAssertEqual(processes, [
            CoreDeviceProcessToken(
                processIdentifier: 123,
                executable: "/private/var/containers/Bundle/Application/Driver/IOSUseDriver-Runner"
            ),
        ])
        let requestFrame = try RemoteXPCHTTP2.decodeFrame(stream.writes.last!)
        let request = try XCTUnwrap(try RemoteXPCWrapper.decode(requestFrame.payload).payload?.dictionaryValue)
        XCTAssertEqual(request["CoreDevice.CoreDeviceDDIProtocolVersion"], .int64(0))
        XCTAssertEqual(request["CoreDevice.deviceIdentifier"], .string("device-uuid"))
        XCTAssertEqual(request["CoreDevice.invocationIdentifier"], .string("invocation-uuid"))
        XCTAssertEqual(request["CoreDevice.featureIdentifier"], .string("com.apple.coredevice.feature.listprocesses"))
        XCTAssertEqual(
            request["CoreDevice.coreDeviceVersion"]?.dictionaryValue?["stringValue"],
            .string(CoreDeviceAppService.versionString)
        )
    }

    func testCoreDeviceAppServiceDecodesNestedExecutableURL() throws {
        let response = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: .dictionary([
                "CoreDevice.output": .dictionary([
                    "processTokens": .array([
                        .dictionary([
                            "processIdentifier": .int64(123),
                            "executable": .dictionary([
                                "url": .dictionary([
                                    "_0": .dictionary([
                                        "relative": .string("file:///private/var/containers/Bundle/Application/Driver/IOSUseDriver-Runner"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )
        let stream = FakeDeviceStream(reads: [
            RemoteXPCHTTP2.settingsFrame()
                + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: response),
        ])
        let client = RemoteXPCClient(stream: stream)
        try client.completeClientHandshake()
        let service = CoreDeviceAppService(client: client)

        let processes = try service.listProcesses()

        XCTAssertEqual(processes.first?.executable, "file:///private/var/containers/Bundle/Application/Driver/IOSUseDriver-Runner")
    }

    func testCoreDeviceAppServiceFallsBackToTokenWideExecutableSearch() throws {
        let response = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: .dictionary([
                "CoreDevice.output": .dictionary([
                    "processTokens": .array([
                        .dictionary([
                            "processIdentifier": .int64(123),
                            "process": .dictionary([
                                "url": .dictionary([
                                    "_0": .dictionary([
                                        "relative": .string("file:///private/var/containers/Bundle/Application/Driver/IOSUseDriver-Runner"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )
        let stream = FakeDeviceStream(reads: [
            RemoteXPCHTTP2.settingsFrame()
                + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: response),
        ])
        let client = RemoteXPCClient(stream: stream)
        try client.completeClientHandshake()
        let service = CoreDeviceAppService(client: client)

        let processes = try service.listProcesses()

        XCTAssertEqual(processes.first?.executable, "file:///private/var/containers/Bundle/Application/Driver/IOSUseDriver-Runner")
    }

    func testCoreDeviceAppServiceExtractsProcessIdentifierFromLaunchOutputShapes() {
        XCTAssertEqual(
            CoreDeviceAppService.extractProcessIdentifier(from: .dictionary([
                "processIdentifier": .int64(123),
            ])),
            123
        )
        XCTAssertEqual(
            CoreDeviceAppService.extractProcessIdentifier(from: .dictionary([
                "processToken": .dictionary([
                    "processIdentifier": .uint64(456),
                ]),
            ])),
            456
        )
        XCTAssertEqual(
            CoreDeviceAppService.extractProcessIdentifier(from: .array([
                .dictionary(["metadata": .string("ignored")]),
                .dictionary(["process": .dictionary(["processIdentifier": .int64(789)])]),
            ])),
            789
        )
        XCTAssertNil(CoreDeviceAppService.extractProcessIdentifier(from: .dictionary(["status": .string("ok")])))
    }

    func testRemoteServiceDiscoveryClientConnectsAndReturnsPeerInfo() throws {
        let response = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: remotePeerInfoValue()
        )
        let stream = FakeDeviceStream(reads: [
            RemoteXPCHTTP2.settingsFrame()
                + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: response),
        ])
        var requestedHost: String?
        var requestedPort: Int?
        RemoteServiceDiscoveryClient.streamConnectorForTesting = { host, port in
            requestedHost = host
            requestedPort = port
            return stream
        }

        let peerInfo = try RemoteServiceDiscoveryClient.connect(host: "fd7b:e5b:6f53::1", port: 58_783)

        XCTAssertEqual(requestedHost, "fd7b:e5b:6f53::1")
        XCTAssertEqual(requestedPort, 58_783)
        XCTAssertEqual(peerInfo.uniqueDeviceID, "00008110-001234")
        XCTAssertTrue(stream.closed)
        XCTAssertTrue(stream.writes[0].starts(with: RemoteXPCHTTP2.connectionPreface))
    }

    func testCoreDeviceTunnelRuntimeStartsBridgeAndFetchesPeerInfo() throws {
        let handshake = CoreDeviceTunnelHandshake(
            serverAddress: "fd7b:e5b:6f53::1",
            serverRSDPort: 58_783,
            clientAddress: "fd7b:e5b:6f53::2",
            clientMTU: 16_000
        )
        let devicePacket = ipv6Packet(body: Data([0x10]))
        let interfacePacket = ipv6Packet(body: Data([0x20]))
        let tunnel = FakeCoreDeviceTunnel(handshake: handshake, reads: [devicePacket])
        let networkInterface = FakeNamedIPv6PacketIO(interfaceName: "utun42", reads: [interfacePacket])
        var openedUDID: String?
        var appliedConfig: CoreDeviceTunnelInterfaceConfig?
        var rsdHost: String?
        var rsdPort: Int?
        let runtime = CoreDeviceTunnelRuntime(
            dependencies: CoreDeviceTunnelRuntime.Dependencies(
                openTunnel: {
                    openedUDID = $0
                    return tunnel
                },
                openInterface: { networkInterface },
                configureInterface: {
                    appliedConfig = $0
                },
                connectRSD: { host, port in
                    rsdHost = host
                    rsdPort = port
                    return try RemoteXPCPeerInfo.decode(self.remotePeerInfoValue())
                }
            ),
            bridgeReadTimeoutSeconds: 0.001
        )

        let session = try runtime.start(udid: "REAL-UDID", mtu: 12_000)

        XCTAssertEqual(openedUDID, "REAL-UDID")
        XCTAssertEqual(tunnel.requestedMTU, 12_000)
        XCTAssertEqual(appliedConfig?.interfaceName, "utun42")
        XCTAssertEqual(appliedConfig?.clientAddress, handshake.clientAddress)
        XCTAssertEqual(rsdHost, handshake.serverAddress)
        XCTAssertEqual(rsdPort, handshake.serverRSDPort)
        XCTAssertEqual(session.peerInfo?.uniqueDeviceID, "00008110-001234")
        XCTAssertTrue(waitUntil {
            networkInterface.writes.contains(devicePacket) && tunnel.writes.contains(interfacePacket)
        })
        XCTAssertNil(session.bridgeErrorDescription)

        session.close()
        XCTAssertTrue(session.waitForPacketBridgeToStop())
        XCTAssertTrue(tunnel.isClosed)
        XCTAssertTrue(networkInterface.isClosed)
    }

    func testCoreDeviceTunnelRuntimeClosesResourcesWhenInterfaceConfigurationFails() throws {
        let handshake = CoreDeviceTunnelHandshake(
            serverAddress: "fd7b:e5b:6f53::1",
            serverRSDPort: 58_783,
            clientAddress: "fd7b:e5b:6f53::2",
            clientMTU: 16_000
        )
        let tunnel = FakeCoreDeviceTunnel(handshake: handshake, reads: [])
        let networkInterface = FakeNamedIPv6PacketIO(interfaceName: "utun42", reads: [])
        var didConnectRSD = false
        let runtime = CoreDeviceTunnelRuntime(
            dependencies: CoreDeviceTunnelRuntime.Dependencies(
                openTunnel: { _ in tunnel },
                openInterface: { networkInterface },
                configureInterface: { _ in
                    throw CLIParseError.invalidValue("ifconfig failed")
                },
                connectRSD: { _, _ in
                    didConnectRSD = true
                    return try RemoteXPCPeerInfo.decode(self.remotePeerInfoValue())
                }
            ),
            bridgeReadTimeoutSeconds: 0.001
        )

        XCTAssertThrowsError(try runtime.start(udid: "REAL-UDID")) { error in
            XCTAssertTrue(String(describing: error).contains("ifconfig failed"))
        }
        XCTAssertFalse(didConnectRSD)
        XCTAssertTrue(tunnel.isClosed)
        XCTAssertTrue(networkInterface.isClosed)
    }

    func testCoreDeviceTunnelRuntimeClosesSessionWhenRSDConnectFails() throws {
        let handshake = CoreDeviceTunnelHandshake(
            serverAddress: "fd7b:e5b:6f53::1",
            serverRSDPort: 58_783,
            clientAddress: "fd7b:e5b:6f53::2",
            clientMTU: 16_000
        )
        let tunnel = FakeCoreDeviceTunnel(handshake: handshake, reads: [])
        let networkInterface = FakeNamedIPv6PacketIO(interfaceName: "utun42", reads: [])
        let runtime = CoreDeviceTunnelRuntime(
            dependencies: CoreDeviceTunnelRuntime.Dependencies(
                openTunnel: { _ in tunnel },
                openInterface: { networkInterface },
                configureInterface: { _ in },
                connectRSD: { _, _ in
                    throw CLIParseError.invalidValue("RSD unavailable")
                }
            ),
            bridgeReadTimeoutSeconds: 0.001
        )

        XCTAssertThrowsError(try runtime.start(udid: "REAL-UDID")) { error in
            XCTAssertTrue(String(describing: error).contains("RSD unavailable"))
        }
        XCTAssertTrue(tunnel.isClosed)
        XCTAssertTrue(networkInterface.isClosed)
    }

    func testCoreDeviceDriverLifecycleLaunchesDriverThroughAppService() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        var openedHost: String?
        var sleeps: [useconds_t] = []
        var events: [String] = []
        var reachabilityChecks = 0
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { udid in
                XCTAssertEqual(udid, "REAL-UDID")
                return session
            },
            openAppService: { tunnelSession in
                openedHost = tunnelSession.serverAddress
                return appService
            },
            authorizeDriver: { udid, pid, tunnelSession in
                XCTAssertEqual(udid, "REAL-UDID")
                XCTAssertEqual(pid, 222)
                XCTAssertTrue(tunnelSession === session)
                events.append("authorize")
            },
            isDriverPortReachable: { udid in
                XCTAssertEqual(udid, "REAL-UDID")
                events.append("reachable")
                reachabilityChecks += 1
                return reachabilityChecks >= 2
            },
            sleep: { sleeps.append($0) }
        ))

        try lifecycle.launchDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner")

        XCTAssertEqual(openedHost, session.handshake.serverAddress)
        XCTAssertEqual(appService.launchedBundleIDs, ["com.example.driver.xctrunner"])
        XCTAssertEqual(events, ["authorize", "reachable", "reachable"])
        XCTAssertEqual(sleeps, [
            useconds_t(IOSUseProtocol.driverStartReadinessInitialDelayMicroseconds),
            useconds_t(IOSUseProtocol.driverStartReadinessPollIntervalMicroseconds),
        ])
        XCTAssertTrue(appService.closed)
    }

    func testCoreDeviceDriverLifecycleFallsBackToProcessListWhenLaunchOutputHasNoPID() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        appService.launchOutput = .dictionary([:])
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 333, executable: "/containers/com.example.driver.xctrunner/IOSUseDriver-Runner"),
        ]
        var authorizedPids: [Int] = []
        var sleeps: [useconds_t] = []
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            authorizeDriver: { _, pid, _ in authorizedPids.append(pid) },
            isDriverPortReachable: { _ in true },
            sleep: { sleeps.append($0) }
        ))

        try lifecycle.launchDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner")

        XCTAssertEqual(authorizedPids, [333])
        XCTAssertEqual(sleeps, [useconds_t(IOSUseProtocol.driverStartReadinessInitialDelayMicroseconds)])
    }

    func testCoreDeviceDriverLifecycleCleansLaunchedProcessWhenReadinessTimesOut() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            authorizeDriver: { _, _, _ in },
            isDriverPortReachable: { _ in false },
            sleep: { _ in }
        ))

        XCTAssertThrowsError(try lifecycle.launchDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner", timeoutSeconds: 0)) { error in
            XCTAssertTrue(String(describing: error).contains("did not become reachable"))
        }
        XCTAssertEqual(appService.signals.count, 1)
        XCTAssertEqual(appService.signals.first?.0, 222)
        XCTAssertEqual(appService.signals.first?.1, SIGKILL)
    }

    func testCoreDeviceURLLauncherOpensSpringBoardWithPayloadURL() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        var openedHost: String?
        let launcher = CoreDeviceURLLauncher(dependencies: CoreDeviceURLLauncher.Dependencies(
            startTunnel: { udid in
                XCTAssertEqual(udid, "REAL-UDID")
                return session
            },
            openAppService: { tunnelSession in
                openedHost = tunnelSession.serverAddress
                return appService
            }
        ))

        try launcher.open(url: "https://example.com", udid: "REAL-UDID")

        XCTAssertEqual(openedHost, session.handshake.serverAddress)
        XCTAssertEqual(appService.launchedBundleIDs, ["com.apple.springboard"])
        XCTAssertEqual(appService.launches.first?.payloadURL, "https://example.com")
        XCTAssertEqual(appService.launches.first?.activates, true)
        XCTAssertEqual(appService.launches.first?.terminateExisting, false)
        XCTAssertTrue(appService.closed)
    }

    func testCoreDeviceDriverLifecycleTerminatesMatchingDriverProcesses() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 100, executable: "/usr/libexec/other"),
            CoreDeviceProcessToken(processIdentifier: 101, executable: "/private/var/containers/com.example.driver.xctrunner/IOSUseDriver-Runner"),
        ]
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            authorizeDriver: { _, _, _ in XCTFail("terminate should not authorize") },
            isDriverPortReachable: { _ in false },
            sleep: { _ in }
        ))

        let terminated = try lifecycle.terminateDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner")

        XCTAssertTrue(terminated)
        XCTAssertEqual(appService.signals.count, 1)
        XCTAssertEqual(appService.signals.first?.0, 101)
        XCTAssertEqual(appService.signals.first?.1, SIGKILL)
        XCTAssertTrue(appService.closed)
    }

    func testCoreDeviceDriverLifecyclePropagatesTerminateSignalFailure() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 101, executable: "/private/var/containers/com.example.driver.xctrunner/IOSUseDriver-Runner"),
        ]
        appService.signalError = CLIParseError.invalidValue("signal rejected")
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            authorizeDriver: { _, _, _ in XCTFail("terminate should not authorize") },
            isDriverPortReachable: { _ in false },
            sleep: { _ in }
        ))

        XCTAssertThrowsError(try lifecycle.terminateDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner")) { error in
            XCTAssertTrue(String(describing: error).contains("signal rejected"))
        }
        XCTAssertTrue(appService.closed)
    }

    func testCoreDeviceDriverLifecycleTreatsConnectionClosedAfterSignalAsSuccessWhenPortDrops() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 101, executable: "file:///private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app/IOSUseDriver-Runner"),
        ]
        appService.signalError = CoreDeviceTCPError.connectionClosed
        var reachabilityChecks = 0
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            authorizeDriver: { _, _, _ in XCTFail("terminate should not authorize") },
            isDriverPortReachable: { _ in
                reachabilityChecks += 1
                return false
            },
            sleep: { _ in }
        ))

        let terminated = try lifecycle.terminateDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner")

        XCTAssertTrue(terminated)
        XCTAssertEqual(reachabilityChecks, 1)
    }

    func testCoreDeviceDriverLifecycleRequiresPortDropAfterSuccessfulStopSignal() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 101, executable: "/private/var/containers/com.example.driver.xctrunner/IOSUseDriver-Runner"),
        ]
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            authorizeDriver: { _, _, _ in XCTFail("terminate should not authorize") },
            isDriverPortReachable: { _ in true },
            sleep: { _ in }
        ))

        XCTAssertThrowsError(try lifecycle.terminateDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner")) { error in
            XCTAssertTrue(String(describing: error).contains("still reachable"))
        }
        XCTAssertEqual(appService.signals.map(\.0), [101])
    }

    func testCoreDeviceDriverLifecycleRefusesToClearStopWhenNoCandidateButPortIsReachable() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 201, executable: "/usr/libexec/other"),
        ]
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            authorizeDriver: { _, _, _ in XCTFail("terminate should not authorize") },
            isDriverPortReachable: { _ in true },
            sleep: { _ in }
        ))

        XCTAssertThrowsError(try lifecycle.terminateDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner")) { error in
            XCTAssertTrue(String(describing: error).contains("no matching driver process"))
        }
        XCTAssertTrue(appService.signals.isEmpty)
    }

    func testCoreDeviceDriverLifecycleKeepsConnectionClosedSignalFailureWhenPortStaysReachable() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppService()
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 101, executable: "file:///private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app/IOSUseDriver-Runner"),
        ]
        appService.signalError = CoreDeviceTCPError.connectionClosed
        var reachabilityChecks = 0
        let lifecycle = CoreDeviceDriverLifecycle(dependencies: CoreDeviceDriverLifecycle.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            authorizeDriver: { _, _, _ in XCTFail("terminate should not authorize") },
            isDriverPortReachable: { _ in
                reachabilityChecks += 1
                return true
            },
            sleep: { _ in }
        ))

        XCTAssertThrowsError(try lifecycle.terminateDriver(udid: "REAL-UDID", bundleID: "com.example.driver.xctrunner")) { error in
            XCTAssertEqual(error as? CoreDeviceTCPError, .connectionClosed)
        }
        XCTAssertEqual(reachabilityChecks, 10)
    }

    func testCoreDeviceDriverLifecycleMatchesDriverProcessSafely() {
        XCTAssertTrue(CoreDeviceDriverLifecycle.isDriverProcess(
            CoreDeviceProcessToken(processIdentifier: 1, executable: "/path/IOSUseDriver-Runner"),
            bundleID: nil
        ))
        XCTAssertTrue(CoreDeviceDriverLifecycle.isDriverProcess(
            CoreDeviceProcessToken(processIdentifier: 2, executable: "/containers/com.example.driver.xctrunner/app"),
            bundleID: "com.example.driver.xctrunner"
        ))
        XCTAssertTrue(CoreDeviceDriverLifecycle.isDriverProcess(
            CoreDeviceProcessToken(processIdentifier: 3, executable: "/private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner", bundleIdentifier: "com.example.driver.xctrunner"),
            bundleID: "com.example.driver.xctrunner"
        ))
        XCTAssertFalse(CoreDeviceDriverLifecycle.isDriverProcess(
            CoreDeviceProcessToken(processIdentifier: 4, executable: "/private/var/containers/Bundle/Application/Other/IOSUseDriver-Runner"),
            bundleID: "com.example.driver.xctrunner"
        ))
        XCTAssertFalse(CoreDeviceDriverLifecycle.isDriverProcess(
            CoreDeviceProcessToken(processIdentifier: 5, executable: "/containers/com.example.driver.xctrunner.old/IOSUseDriver-Runner"),
            bundleID: "com.example.driver.xctrunner"
        ))
        XCTAssertFalse(CoreDeviceDriverLifecycle.isDriverProcess(
            CoreDeviceProcessToken(processIdentifier: 6, executable: "/usr/libexec/other"),
            bundleID: "com.example.driver.xctrunner"
        ))
    }

    func testCoreDeviceDriverLifecycleFallsBackToSingleRunnerCandidateWhenBundleIDIsNotInProcessPath() {
        let candidates = CoreDeviceDriverLifecycle.driverProcessCandidates(in: [
            CoreDeviceProcessToken(processIdentifier: 1, executable: "/usr/libexec/other"),
            CoreDeviceProcessToken(processIdentifier: 2, executable: "file:///private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app/IOSUseDriver-Runner"),
        ], bundleID: "com.example.driver.xctrunner")

        XCTAssertEqual(candidates.map(\.processIdentifier), [2])
    }

    func testCoreDeviceDriverLifecycleRefusesAmbiguousRunnerFallback() {
        let candidates = CoreDeviceDriverLifecycle.driverProcessCandidates(in: [
            CoreDeviceProcessToken(processIdentifier: 1, executable: "file:///private/var/containers/Bundle/Application/A/IOSUseDriver-Runner.app/IOSUseDriver-Runner"),
            CoreDeviceProcessToken(processIdentifier: 2, executable: "file:///private/var/containers/Bundle/Application/B/IOSUseDriver-Runner.app/IOSUseDriver-Runner"),
        ], bundleID: "com.example.driver.xctrunner")

        XCTAssertTrue(candidates.isEmpty)
    }

    func testCoreDeviceTunnelAuthorizationUsesRSDTestManagerService() throws {
        let serverCapabilities = try DTXMessageEncoder.dispatch(
            identifier: 90,
            channelCode: DVTInstrumentsContract.Control.channelCode,
            selector: "_notifyOfPublishedCapabilities:",
            arguments: [.archived(["server": 1])],
            expectsReply: false
        )
        let openDaemonReply = try DTXMessageEncoder.okReply(identifier: 2, conversationIndex: 1, channelCode: 0)
        let initReply = try DTXMessageEncoder.objectReply(identifier: 3, conversationIndex: 1, channelCode: -1, object: NSDictionary())
        let authorizeReply = try DTXMessageEncoder.objectReply(identifier: 4, conversationIndex: 1, channelCode: -1, object: NSNumber(value: true))
        let stream = FakeDeviceStream(reads: [
            serverCapabilities.wireData,
            openDaemonReply.wireData,
            initReply.wireData,
            authorizeReply.wireData,
        ])
        let tunnelSession = FakeCoreDeviceLifecycleTunnelSession(stream: stream)
        var productVersionUdids: [String] = []
        let provider = CoreDeviceTunnelXCTestManagerAuthorizationProvider(
            dependencies: CoreDeviceTunnelXCTestManagerAuthorizationProvider.Dependencies(
                productMajorVersion: { udid in
                    productVersionUdids.append(udid)
                    return 26
                }
            )
        )

        try provider.authorizeDriver(udid: "REAL-UDID", pid: 43327, tunnelSession: tunnelSession)

        XCTAssertEqual(productVersionUdids, ["REAL-UDID"])
        XCTAssertEqual(tunnelSession.requestedServices, [DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName])
        XCTAssertTrue(stream.closed)
        XCTAssertEqual(stream.writes.count, 4)
        let openChannel = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[1]]))
        XCTAssertEqual(try unarchiveDTXBuffer(openChannel.payload) as? String, "_requestChannelWithCode:identifier:")
        let initiate = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[2]]))
        XCTAssertEqual(try unarchiveDTXBuffer(initiate.payload) as? String, "_IDE_initiateControlSessionWithCapabilities:")
        let authorize = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[3]]))
        XCTAssertEqual(try unarchiveDTXBuffer(authorize.payload) as? String, "_IDE_authorizeTestSessionWithProcessID:")
    }

    func testAfcOpenWriteAndCloseFrames() throws {
        let stream = FakeDeviceStream(reads: [
            afcResponse(opcode: AfcOpcode.fileOpenResult.rawValue, payload: uint64LE(42)),
            afcStatus(.success),
            afcStatus(.success),
        ])
        let client = AfcClient(stream: stream)

        let handle = try client.openFile("/PublicStaging/app.ipa")
        try client.write(handle: handle, data: Data([0xde, 0xad]))
        try client.closeFile(handle)

        XCTAssertEqual(handle, 42)
        XCTAssertEqual(stream.writes.count, 3)

        let open = stream.writes[0]
        XCTAssertEqual(String(data: open.prefix(8), encoding: .utf8), "CFA6LPAA")
        XCTAssertEqual(readUInt64LE(open, 8), UInt64(open.count))
        XCTAssertEqual(readUInt64LE(open, 16), UInt64(open.count))
        XCTAssertEqual(readUInt64LE(open, 32), AfcOpcode.fileOpen.rawValue)
        XCTAssertEqual(readUInt64LE(open, 40), 3)
        XCTAssertEqual(String(data: open.dropFirst(48).dropLast(), encoding: .utf8), "/PublicStaging/app.ipa")

        let write = stream.writes[1]
        XCTAssertEqual(readUInt64LE(write, 8), UInt64(write.count))
        XCTAssertEqual(readUInt64LE(write, 16), 48)
        XCTAssertEqual(readUInt64LE(write, 32), AfcOpcode.write.rawValue)
        XCTAssertEqual(readUInt64LE(write, 40), 42)
        XCTAssertEqual(Data(write.suffix(2)), Data([0xde, 0xad]))

        let close = stream.writes[2]
        XCTAssertEqual(readUInt64LE(close, 32), AfcOpcode.close.rawValue)
        XCTAssertEqual(readUInt64LE(close, 40), 42)
    }

    func testAfcTooMuchDataFallbackWritesAllRemainingChunksAtReducedSize() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-afc-\(UUID().uuidString)")
        let data = Data(repeating: 0xab, count: 150 * 1024)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let stream = FakeDeviceStream(reads: [
            afcResponse(opcode: AfcOpcode.fileOpenResult.rawValue, payload: uint64LE(42)),
            afcStatus(.tooMuchData),
            afcStatus(.success),
            afcStatus(.success),
            afcStatus(.success),
            afcStatus(.success),
        ])
        let client = AfcClient(stream: stream)

        do {
            try client.uploadFile(localPath: file.path, remotePath: "app.ipa")
        } catch {
            XCTFail("upload failed after write payload sizes \(stream.writes.dropFirst().map { $0.count - 48 }): \(error)")
            return
        }

        let writePayloadSizes = stream.writes
            .dropFirst()
            .dropLast()
            .map { $0.count - 48 }
        XCTAssertEqual(writePayloadSizes, [150 * 1024, 64 * 1024, 64 * 1024, 22 * 1024])
        XCTAssertEqual(readUInt64LE(stream.writes.last!, 32), AfcOpcode.close.rawValue)
    }

    func testAfcStatusErrorMapsToTypedError() throws {
        let stream = FakeDeviceStream(reads: [
            afcStatus(.permissionDenied),
        ])
        let client = AfcClient(stream: stream)

        XCTAssertThrowsError(try client.closeFile(9)) { error in
            XCTAssertEqual(error as? AfcClientError, .status(.permissionDenied))
        }
    }

    func testPlainDeviceStreamCloseClosesOwnedSocket() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { Darwin.close(fds[1]) }
        let stream = PlainDeviceStream(fd: fds[0])

        stream.close()

        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(fds[1], &byte, 1), 0)
    }

    func testInstallationProxyLookupRequestAndResponse() throws {
        let response: [String: Any] = [
            "LookupResult": [
                "com.example.app": [
                    "CFBundleIdentifier": "com.example.app",
                ],
            ],
        ]
        let stream = FakeDeviceStream(reads: [
            plistFrame(response),
        ])
        let client = InstallationProxyClient(stream: stream)

        let result = try client.lookup(attributes: ["CFBundleIdentifier"], bundleIDs: ["com.example.app"])

        XCTAssertNotNil((result["LookupResult"] as? [String: Any])?["com.example.app"])
        let request = try parseLengthPrefixedPlist(stream.writes[0])
        XCTAssertEqual(request["Command"] as? String, "Lookup")
        XCTAssertEqual(request["BundleIDs"] as? [String], ["com.example.app"])
        let options = try XCTUnwrap(request["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["ApplicationType"] as? String, "Any")
        XCTAssertEqual(options["ReturnAttributes"] as? [String], ["CFBundleIdentifier"])
    }

    func testInstallationProxyProgressCommandError() throws {
        let stream = FakeDeviceStream(reads: [
            plistFrame([
                "Status": "Installing",
                "PercentComplete": 20,
            ]),
            plistFrame([
                "Error": "ApplicationVerificationFailed",
                "ErrorDescription": "signature invalid",
            ]),
        ])
        let client = InstallationProxyClient(stream: stream)

        XCTAssertThrowsError(try client.uninstall(bundleID: "com.example.app")) { error in
            XCTAssertTrue(String(describing: error).contains("signature invalid"))
        }
        let request = try parseLengthPrefixedPlist(stream.writes[0])
        XCTAssertEqual(request["Command"] as? String, "Uninstall")
        XCTAssertEqual(request["ApplicationIdentifier"] as? String, "com.example.app")
    }

    func testInstallationProxyInstallRequestMatchesLibimobiledeviceIpaShape() throws {
        let stream = FakeDeviceStream(reads: [
            plistFrame(["Status": "Complete"]),
        ])
        let client = InstallationProxyClient(stream: stream)

        try client.install(packagePath: "PublicStaging/ios-use/com.example.app", bundleID: "com.example.app")

        let request = try parseLengthPrefixedPlist(stream.writes[0])
        XCTAssertEqual(request["Command"] as? String, "Install")
        XCTAssertEqual(request["PackagePath"] as? String, "PublicStaging/ios-use/com.example.app")
        let options = try XCTUnwrap(request["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["CFBundleIdentifier"] as? String, "com.example.app")
        XCTAssertNil(options["PackageType"])
        XCTAssertNil(options["ApplicationSINF"])
        XCTAssertNil(options["iTunesMetadata"])
    }

    func testInstallationProxyDeveloperPackageTypeIsExplicitOnly() throws {
        let stream = FakeDeviceStream(reads: [
            plistFrame(["Status": "Complete"]),
        ])
        let client = InstallationProxyClient(stream: stream)

        try client.install(packagePath: "PublicStaging/App.app", bundleID: "com.example.app", developer: true)

        let request = try parseLengthPrefixedPlist(stream.writes[0])
        let options = try XCTUnwrap(request["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["PackageType"] as? String, "Developer")
        XCTAssertEqual(options["CFBundleIdentifier"] as? String, "com.example.app")
    }

    func testInstallationProxyBrowseAggregatesCurrentListUntilComplete() throws {
        let stream = FakeDeviceStream(reads: [
            plistFrame([
                "Status": "BrowsingApplications",
                "CurrentList": [
                    [
                        "CFBundleIdentifier": "com.example.a",
                        "CFBundleName": "A",
                    ],
                ],
            ]),
            plistFrame([
                "Status": "BrowsingApplications",
                "CurrentList": [
                    [
                        "CFBundleIdentifier": "com.example.b",
                        "CFBundleName": "B",
                    ],
                ],
            ]),
            plistFrame([
                "Status": "Complete",
            ]),
        ])
        let client = InstallationProxyClient(stream: stream)

        let result = try client.browse(includeSystem: false, attributes: ["CFBundleIdentifier", "CFBundleName"])

        XCTAssertEqual(result.compactMap { $0["CFBundleIdentifier"] as? String }, ["com.example.a", "com.example.b"])
        let request = try parseLengthPrefixedPlist(stream.writes[0])
        XCTAssertEqual(request["Command"] as? String, "Browse")
        let options = try XCTUnwrap(request["ClientOptions"] as? [String: Any])
        XCTAssertEqual(options["ApplicationType"] as? String, "User")
        XCTAssertEqual(options["ReturnAttributes"] as? [String], ["CFBundleIdentifier", "CFBundleName"])
    }

    func testInstallationProxyBrowseFailsOnServiceError() throws {
        let stream = FakeDeviceStream(reads: [
            plistFrame([
                "Error": "LookupFailed",
                "ErrorDescription": "browse failed",
            ]),
        ])
        let client = InstallationProxyClient(stream: stream)

        XCTAssertThrowsError(try client.browse(includeSystem: true, attributes: [])) { error in
            XCTAssertTrue(String(describing: error).contains("browse failed"))
        }
    }

    func testInstallationProxyPackagePathMatchesAfcRelativePath() {
        XCTAssertEqual(
            RealDevicePackageInstaller.installationProxyPackagePath(forAfcPath: "PublicStaging/ios-use/app.ipa"),
            "PublicStaging/ios-use/app.ipa"
        )
        XCTAssertEqual(
            RealDevicePackageInstaller.installationProxyPackagePath(forAfcPath: "/PublicStaging/ios-use/app.ipa"),
            "PublicStaging/ios-use/app.ipa"
        )
    }

    func testRealDevicePackageInstallerValidatesInstalledVersion() throws {
        let response: [String: Any] = [
            "LookupResult": [
                "com.example.app": [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleShortVersionString": "1.1.1",
                ],
            ],
        ]

        try RealDevicePackageInstaller.validateInstalledApp(
            response: response,
            bundleID: "com.example.app",
            expectedVersion: "1.1.1"
        )

        XCTAssertThrowsError(try RealDevicePackageInstaller.validateInstalledApp(
            response: response,
            bundleID: "com.example.app",
            expectedVersion: "1.1.2"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("does not match IPA version"))
        }
    }

    private func afcResponse(opcode: UInt64, payload: Data) -> Data {
        var data = Data("CFA6LPAA".utf8)
        data.append(uint64LE(UInt64(40 + payload.count)))
        data.append(uint64LE(UInt64(40 + payload.count)))
        data.append(uint64LE(1))
        data.append(uint64LE(opcode))
        data.append(payload)
        return data
    }

    private func afcStatus(_ status: AfcStatus) -> Data {
        afcResponse(opcode: AfcOpcode.status.rawValue, payload: uint64LE(status.rawValue))
    }

    private func plistFrame(_ plist: [String: Any]) -> Data {
        let body = try! serializePlist(plist)
        return uint32BE(UInt32(body.count)) + body
    }

    private func parseLengthPrefixedPlist(_ data: Data) throws -> [String: Any] {
        let size = Int(readUInt32BE(data, 0))
        return try parsePlist(Data(data.dropFirst(4).prefix(size)))
    }

    private func cdtunnelPacket(_ body: [String: Any]) throws -> Data {
        try CDTunnelPacket.encodeJSON(body)
    }

    private func ipv6Packet(body: Data) -> Data {
        var header = Data(repeating: 0, count: CDTunnelIPv6Packet.headerSize)
        header[0] = 0x60
        header[4] = UInt8((body.count >> 8) & 0xff)
        header[5] = UInt8(body.count & 0xff)
        return header + body
    }

    private func remotePeerInfoValue() -> RemoteXPCValue {
        .dictionary([
            "Properties": .dictionary([
                "UniqueDeviceID": .string("00008110-001234"),
                "ProductType": .string("iPhone16,2"),
                "OSVersion": .string("18.0"),
            ]),
            "Services": .dictionary([
                "com.apple.instruments.dtservicehub": .dictionary([
                    "Port": .uint64(54321),
                    "Properties": .dictionary([
                        "UsesRemoteXPC": .bool(true),
                    ]),
                ]),
                "com.apple.mobile.lockdown.remote.trusted": .dictionary([
                    "Port": .uint64(62078),
                ]),
            ]),
        ])
    }

    private func makeTunnelSession(peerInfo: RemoteXPCPeerInfo) throws -> CoreDeviceTunnelSession {
        let handshake = CoreDeviceTunnelHandshake(
            serverAddress: "fd7b:e5b:6f53::1",
            serverRSDPort: 58_783,
            clientAddress: "fd7b:e5b:6f53::2",
            clientMTU: 16_000
        )
        let session = CoreDeviceTunnelSession(
            handshake: handshake,
            interfaceConfig: CoreDeviceTunnelInterfaceConfig(interfaceName: "utun42", handshake: handshake),
            bridge: CoreDeviceTunnelBridge(
                device: FakeIPv6PacketIO(reads: []),
                networkInterface: FakeIPv6PacketIO(reads: [])
            ),
            bridgeReadTimeoutSeconds: 0.001
        )
        session.peerInfo = peerInfo
        return session
    }

    private func http2Frames(_ data: Data) throws -> [RemoteXPCHTTP2Frame] {
        var remaining = data
        var frames: [RemoteXPCHTTP2Frame] = []
        while !remaining.isEmpty {
            let bytes = [UInt8](remaining.prefix(3))
            let size = (Int(bytes[0]) << 16) | (Int(bytes[1]) << 8) | Int(bytes[2])
            let frameData = Data(remaining.prefix(9 + size))
            frames.append(try RemoteXPCHTTP2.decodeFrame(frameData))
            remaining.removeFirst(9 + size)
        }
        return frames
    }

    private func waitUntil(timeoutSeconds: Double = 1, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            usleep(5_000)
        }
        return condition()
    }
}

private func unarchiveDTXArgument(_ argument: DTXAuxArgument) throws -> Any? {
    guard case .primitiveBuffer(let data) = argument else {
        XCTFail("expected archived DTX buffer argument")
        return nil
    }
    return try unarchiveDTXBuffer(data)
}

private func unarchiveDTXBuffer(_ data: Data) throws -> Any? {
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
    unarchiver.requiresSecureCoding = false
    defer { unarchiver.finishDecoding() }
    return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
}

private func dtxFragmentHeader(
    index: UInt16,
    count: UInt16,
    dataSize: Int,
    identifier: UInt32,
    conversationIndex: UInt32,
    channelCode: Int32,
    transportFlags: UInt32 = 0
) -> Data {
    var data = Data()
    data.append(uint32LE(0x1f3d5b79))
    data.append(uint32LE(32))
    data.append(uint16LEFixture(index))
    data.append(uint16LEFixture(count))
    data.append(uint32LE(UInt32(dataSize)))
    data.append(uint32LE(identifier))
    data.append(uint32LE(conversationIndex))
    data.append(uint32LE(UInt32(bitPattern: channelCode)))
    data.append(uint32LE(transportFlags))
    return data
}

private func uint16LEFixture(_ value: UInt16) -> Data {
    Data([
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
    ])
}

private final class FakeDVTInvoker: DVTInvoking {
    var invocations: [DVTInvocation] = []
    private var replies: [Any?]

    init(replies: [Any?]) {
        self.replies = replies
    }

    func invoke(_ invocation: DVTInvocation) throws -> Any? {
        invocations.append(invocation)
        guard !replies.isEmpty else { return nil }
        return replies.removeFirst()
    }
}

private final class FakeDeviceStream: DeviceStream {
    var writes: [Data] = []
    private(set) var closed = false
    private var buffer: Data

    init(reads: [Data]) {
        self.buffer = reads.reduce(Data(), +)
    }

    func write(_ data: Data) throws {
        writes.append(data)
    }

    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        guard buffer.count >= byteCount else {
            throw CLIParseError.invalidValue("fake stream underflow")
        }
        let out = buffer.prefix(byteCount)
        buffer.removeFirst(byteCount)
        return Data(out)
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        guard !buffer.isEmpty else { return Data() }
        let count = min(maxBytes, buffer.count)
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    func close() {
        closed = true
    }
}

private final class FakeCoreDeviceLifecycleTunnelSession: CoreDeviceLifecycleTunnelSession {
    let serverAddress = "fd00::1"
    var peerInfo: RemoteXPCPeerInfo?
    private let stream: DeviceStream
    private(set) var requestedServices: [String] = []
    private(set) var closed = false

    init(stream: DeviceStream, peerInfo: RemoteXPCPeerInfo? = nil) {
        self.stream = stream
        self.peerInfo = peerInfo
    }

    func connectService(_ serviceName: String) throws -> DeviceStream {
        requestedServices.append(serviceName)
        return stream
    }

    func connectRemoteXPCService(_: String) throws -> RemoteXPCClient {
        throw CLIParseError.invalidValue("fake session does not provide RemoteXPC")
    }

    func close() {
        closed = true
    }

    func waitForClose(timeoutSeconds _: Double) -> Bool {
        true
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private final class FakeIPv6PacketIO: IPv6PacketIO {
    var writes: [Data] = []
    private(set) var closed = false
    private var reads: [Data]

    init(reads: [Data]) {
        self.reads = reads
    }

    func readIPv6Packet(timeoutSeconds: Double) throws -> Data {
        guard !reads.isEmpty else {
            throw CLIParseError.invalidValue("fake packet underflow")
        }
        return reads.removeFirst()
    }

    func writeIPv6Packet(_ packet: Data) throws {
        writes.append(packet)
    }

    func close() {
        closed = true
    }
}

private final class FakeCoreDeviceTunnel: CoreDeviceTunnel {
    private let lock = NSLock()
    private let handshake: CoreDeviceTunnelHandshake
    private var reads: [Data]
    private var writesStorage: [Data] = []
    private var closed = false
    private(set) var requestedMTU: Int?

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return writesStorage
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    init(handshake: CoreDeviceTunnelHandshake, reads: [Data]) {
        self.handshake = handshake
        self.reads = reads
    }

    func requestHandshake(mtu: Int) throws -> CoreDeviceTunnelHandshake {
        lock.lock()
        requestedMTU = mtu
        lock.unlock()
        return handshake
    }

    func readIPv6Packet(timeoutSeconds: Double) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !reads.isEmpty else {
            if closed {
                throw CLIParseError.invalidValue("fake tunnel closed")
            }
            throw CLIParseError.invalidValue("fake tunnel read timeout")
        }
        return reads.removeFirst()
    }

    func writeIPv6Packet(_ packet: Data) throws {
        lock.lock()
        writesStorage.append(packet)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

private final class FakeCoreDeviceAppService: CoreDeviceAppManaging {
    var launchedBundleIDs: [String] = []
    var launches: [(bundleID: String, terminateExisting: Bool, payloadURL: String?, activates: Bool?)] = []
    var launchOutput: RemoteXPCValue = .dictionary(["processIdentifier": .int64(222)])
    var processes: [CoreDeviceProcessToken] = []
    var signals: [(Int, Int32)] = []
    var signalError: Error?
    private(set) var closed = false

    func launchApplication(
        bundleID: String,
        arguments _: [String],
        terminateExisting: Bool,
        startSuspended _: Bool,
        environment _: [String: String],
        payloadURL: String?,
        activates: Bool?
    ) throws -> RemoteXPCValue {
        launchedBundleIDs.append(bundleID)
        launches.append((bundleID, terminateExisting, payloadURL, activates))
        return launchOutput
    }

    func listProcesses() throws -> [CoreDeviceProcessToken] {
        processes
    }

    func sendSignal(processIdentifier: Int, signal: Int) throws -> RemoteXPCValue {
        if let signalError {
            throw signalError
        }
        signals.append((processIdentifier, Int32(signal)))
        return .dictionary([:])
    }

    func close() {
        closed = true
    }
}

private final class FakeNamedIPv6PacketIO: NamedIPv6PacketIO {
    let interfaceName: String
    private let lock = NSLock()
    private var reads: [Data]
    private var writesStorage: [Data] = []
    private var closed = false

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return writesStorage
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    init(interfaceName: String, reads: [Data]) {
        self.interfaceName = interfaceName
        self.reads = reads
    }

    func readIPv6Packet(timeoutSeconds: Double) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !reads.isEmpty else {
            if closed {
                throw CLIParseError.invalidValue("fake interface closed")
            }
            throw CLIParseError.invalidValue("fake interface read timeout")
        }
        return reads.removeFirst()
    }

    func writeIPv6Packet(_ packet: Data) throws {
        lock.lock()
        writesStorage.append(packet)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}
