import Foundation
import Darwin
import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class DeviceProtocolClientTests: XCTestCase {
    override func tearDown() {
        RemoteServiceDiscoveryClient.resetTestingOverrides()
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
        XCTAssertEqual(tunnel.writes.count, 6)
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
        let payloadAck = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[4])
        XCTAssertEqual(payloadAck.flags, CoreDeviceTCPFlags.ack)
        XCTAssertEqual(payloadAck.sequenceNumber, 106)
        XCTAssertEqual(payloadAck.acknowledgmentNumber, 903)
        let piggybackAck = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[5])
        XCTAssertEqual(piggybackAck.flags, CoreDeviceTCPFlags.psh | CoreDeviceTCPFlags.ack)
        XCTAssertEqual(piggybackAck.payload, Data("!".utf8))
        XCTAssertEqual(piggybackAck.sequenceNumber, 106)
        XCTAssertEqual(piggybackAck.acknowledgmentNumber, 903)
    }

    func testCoreDeviceUserSpaceTCPConnectionAcksKeepAliveProbe() throws {
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
        let keepAlive = try CoreDeviceIPv6TCPCodec.encodeSegment(
            sourceAddress: remoteAddress,
            destinationAddress: localAddress,
            sourcePort: 58_783,
            destinationPort: 50_000,
            sequenceNumber: 900,
            acknowledgmentNumber: 101,
            flags: CoreDeviceTCPFlags.ack
        )
        let serverData = try CoreDeviceIPv6TCPCodec.encodeSegment(
            sourceAddress: remoteAddress,
            destinationAddress: localAddress,
            sourcePort: 58_783,
            destinationPort: 50_000,
            sequenceNumber: 901,
            acknowledgmentNumber: 101,
            flags: CoreDeviceTCPFlags.psh | CoreDeviceTCPFlags.ack,
            payload: Data("ok".utf8)
        )
        let tunnel = FakeIPv6PacketIO(reads: [synAck, keepAlive, serverData])
        let connection = try CoreDeviceUserSpaceTCPConnection(
            tunnel: tunnel,
            localAddress: local,
            remoteAddress: remote,
            localPort: 50_000,
            remotePort: 58_783,
            initialSequence: 100
        )

        try connection.connect()
        let response = try connection.readExact(byteCount: 2, timeoutSeconds: 1)

        XCTAssertEqual(response, Data("ok".utf8))
        XCTAssertEqual(tunnel.writes.count, 4)
        let keepAliveAck = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[2])
        XCTAssertEqual(keepAliveAck.flags, CoreDeviceTCPFlags.ack)
        XCTAssertEqual(keepAliveAck.sequenceNumber, 101)
        XCTAssertEqual(keepAliveAck.acknowledgmentNumber, 901)
        let payloadAck = try CoreDeviceIPv6TCPCodec.decodeSegment(tunnel.writes[3])
        XCTAssertEqual(payloadAck.flags, CoreDeviceTCPFlags.ack)
        XCTAssertEqual(payloadAck.sequenceNumber, 101)
        XCTAssertEqual(payloadAck.acknowledgmentNumber, 903)
    }

    func testCoreDeviceDirectTunnelRouteQueueOverflowFailsUnreadRoute() throws {
        let local = "fd7b:e5b:6f53::2"
        let remote = "fd7b:e5b:6f53::1"
        let localAddress = try CoreDeviceIPv6TCPCodec.parseIPv6Address(local)
        let remoteAddress = try CoreDeviceIPv6TCPCodec.parseIPv6Address(remote)
        let serviceName = "com.test.service"
        let servicePort = 58_783
        let localPort = IOSUseProtocol.XCConstants.userspaceTCPLocalPortLowerBound
        let handshake = CoreDeviceTunnelHandshake(
            serverAddress: remote,
            serverRSDPort: servicePort,
            clientAddress: local,
            clientMTU: IOSUseProtocol.XCConstants.coreDeviceTunnelRequestedMTU
        )
        let tunnel = FakeCoreDeviceTunnel(handshake: handshake, reads: [], autoRespondToSyn: true)
        let session = CoreDeviceDirectTunnelSession(tunnel: tunnel, handshake: handshake)
        session.peerInfo = RemoteXPCPeerInfo(
            properties: [:],
            services: [
                serviceName: RemoteXPCService(name: serviceName, port: servicePort, usesRemoteXPC: false),
            ]
        )

        let stream = try session.connectService(serviceName)
        let overflowPackets = try (0...IOSUseProtocol.XCConstants.coreDeviceRoutePacketQueueLimit).map { index in
            try CoreDeviceIPv6TCPCodec.encodeSegment(
                sourceAddress: remoteAddress,
                destinationAddress: localAddress,
                sourcePort: UInt16(servicePort),
                destinationPort: localPort,
                sequenceNumber: UInt32(901 + index),
                acknowledgmentNumber: 101,
                flags: CoreDeviceTCPFlags.psh | CoreDeviceTCPFlags.ack,
                payload: Data([UInt8(index & 0xff)])
            )
        }
        tunnel.appendReads(overflowPackets)
        usleep(100_000)

        XCTAssertThrowsError(try stream.readAvailable(maxBytes: 1, timeoutSeconds: 0.1)) { error in
            guard case CoreDeviceTCPError.routeBackpressure(let failedPort, let pendingPackets) = error else {
                return XCTFail("expected route backpressure, got \(error)")
            }
            XCTAssertEqual(failedPort, localPort)
            XCTAssertEqual(pendingPackets, IOSUseProtocol.XCConstants.coreDeviceRoutePacketQueueLimit)
        }
        XCTAssertThrowsError(try stream.write(Data("x".utf8))) { error in
            guard case CoreDeviceTCPError.routeBackpressure = error else {
                return XCTFail("expected route backpressure on write, got \(error)")
            }
        }

        session.close()
        XCTAssertTrue(session.waitForClose(timeoutSeconds: 2))
    }

    func testCoreDeviceDirectTunnelWaitForCloseWaitsForRouterReaderExit() throws {
        let local = "fd7b:e5b:6f53::2"
        let remote = "fd7b:e5b:6f53::1"
        let serviceName = "com.test.service"
        let servicePort = 58_783
        let handshake = CoreDeviceTunnelHandshake(
            serverAddress: remote,
            serverRSDPort: servicePort,
            clientAddress: local,
            clientMTU: IOSUseProtocol.XCConstants.coreDeviceTunnelRequestedMTU
        )
        let tunnel = FakeCoreDeviceTunnel(handshake: handshake, reads: [], autoRespondToSyn: true)
        let session = CoreDeviceDirectTunnelSession(tunnel: tunnel, handshake: handshake)
        session.peerInfo = RemoteXPCPeerInfo(
            properties: [:],
            services: [
                serviceName: RemoteXPCService(name: serviceName, port: servicePort, usesRemoteXPC: false),
            ]
        )

        _ = try session.connectService(serviceName)
        session.close()

        XCTAssertTrue(session.waitForClose(timeoutSeconds: 2))
        XCTAssertTrue(tunnel.isClosed)
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

    func testRemoteXPCHTTP2ClientHandshakeFramesMatchGoIOSHTTPSetup() throws {
        var handshake = try RemoteXPCHTTP2.encodeClientHandshake()
        XCTAssertEqual(Data(handshake.prefix(RemoteXPCHTTP2.connectionPreface.count)), RemoteXPCHTTP2.connectionPreface)
        handshake.removeFirst(RemoteXPCHTTP2.connectionPreface.count)

        let frames = try http2Frames(handshake)

        XCTAssertEqual(frames.map(\.type), [
            RemoteXPCHTTP2.frameSettings,
            RemoteXPCHTTP2.frameWindowUpdate,
        ])
        XCTAssertEqual(frames[0].streamID, 0)
        XCTAssertEqual(frames[1].streamID, 0)
    }

    func testRemoteXPCHTTP2ClientHandshakeMatchesGoIOSHTTPReferenceBytes() throws {
        let expectedHex = """
        505249202a20485454502f322e300d0a0d0a534d0d0a0d0a\
        00000c040000000000000300000064000400100000\
        000004080000000000000f0001
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
        XCTAssertEqual(DVTInstrumentsContract.Provider.rsdServiceName, "com.apple.instruments.dtservicehub")
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
        XCTAssertEqual(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName, "com.apple.dt.testmanagerd.remote")
        XCTAssertEqual(
            DVTInstrumentsContract.XCTestManagerDaemon.proxyServiceIdentifier,
            "dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface"
        )

        let modernControl = try DVTInstrumentsContract.XCTestManagerDaemon.initiateControlSession(productMajorVersion: 17)
        XCTAssertEqual(modernControl.serviceIdentifier, "XCTestManager_DaemonConnectionInterface")
        XCTAssertEqual(modernControl.selector, "_IDE_initiateControlSessionWithCapabilities:")
        XCTAssertEqual((try unarchiveDTXArgument(modernControl.arguments[0]) as? NSDictionary)?.count, 0)

        XCTAssertThrowsError(try DVTInstrumentsContract.XCTestManagerDaemon.initiateControlSession(productMajorVersion: 16)) { error in
            XCTAssertTrue(String(describing: error).contains("requires iOS 17 or later"))
        }
        XCTAssertThrowsError(try DVTInstrumentsContract.XCTestManagerDaemon.initiateControlSession(productMajorVersion: 10)) { error in
            XCTAssertTrue(String(describing: error).contains("requires iOS 17 or later"))
        }

        let ios17Auth = try DVTInstrumentsContract.XCTestManagerDaemon.authorizeTestSession(productMajorVersion: 17, pid: 456)
        XCTAssertEqual(ios17Auth.selector, "_IDE_authorizeTestSessionWithProcessID:")
        XCTAssertEqual((try unarchiveDTXArgument(ios17Auth.arguments[0]) as? NSNumber)?.intValue, 456)

        XCTAssertThrowsError(try DVTInstrumentsContract.XCTestManagerDaemon.authorizeTestSession(productMajorVersion: 11, pid: 456)) { error in
            XCTAssertTrue(String(describing: error).contains("requires iOS 17 or later"))
        }
        XCTAssertThrowsError(try DVTInstrumentsContract.XCTestManagerDaemon.authorizeTestSession(productMajorVersion: 9, pid: 456)) { error in
            XCTAssertTrue(String(describing: error).contains("requires iOS 17 or later"))
        }

        let sessionID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let exec = try DVTInstrumentsContract.XCTestManagerDaemon.initiateSession(sessionIdentifier: sessionID)
        XCTAssertEqual(exec.selector, "_IDE_initiateSessionWithIdentifier:capabilities:")
        XCTAssertEqual(exec.arguments.count, 2)
        XCTAssertEqual(try (unarchiveDTXArgument(exec.arguments[0]) as? NSUUID)?.uuidString, sessionID.uuidString.uppercased())
        let capabilitiesArchive = try keyedArchiveObjects(from: try primitiveBuffer(exec.arguments[1]))
        XCTAssertTrue(classNames(in: capabilitiesArchive).contains("XCTCapabilities"))
        XCTAssertTrue(String(describing: capabilitiesArchive).contains("daemon container sandbox extension"))

        let startPlan = try DVTInstrumentsContract.XCTestManagerDaemon.startExecutingTestPlan()
        XCTAssertEqual(startPlan.selector, "_IDE_startExecutingTestPlanWithProtocolVersion:")
        XCTAssertFalse(startPlan.expectsReply)
        XCTAssertEqual((try unarchiveDTXArgument(startPlan.arguments[0]) as? NSNumber)?.intValue, 36)
    }

    func testCoreDeviceAppServiceBuildsXCTestRunnerLaunchRequestWithStdIO() throws {
        let stdioID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let input = CoreDeviceAppService.launchApplicationInput(
            bundleID: "com.example.driver.xctrunner",
            arguments: ["-Arg"],
            terminateExisting: true,
            startSuspended: false,
            environment: ["XCTestManagerVariant": "DDI"],
            standardIOIdentifier: stdioID,
            platformSpecificOptions: CoreDeviceAppService.xcuiRunnerPlatformSpecificOptions(),
            activeUser: true
        )

        let options = try XCTUnwrap(input["options"]?.dictionaryValue)
        XCTAssertEqual(options["arguments"], .array([.string("-Arg")]))
        XCTAssertEqual(options["environmentVariables"], .dictionary(["XCTestManagerVariant": .string("DDI")]))
        XCTAssertEqual(options["terminateExisting"], .bool(true))
        XCTAssertEqual(options["startStopped"], .bool(false))
        XCTAssertEqual(options["user"], .dictionary(["active": .bool(true)]))
        XCTAssertEqual(
            input["standardIOIdentifiers"],
            .dictionary([
                "standardInput": .uuid(stdioID),
                "standardOutput": .uuid(stdioID),
                "standardError": .uuid(stdioID),
            ])
        )
        guard case .data(let plistData) = try XCTUnwrap(options["platformSpecificOptions"]) else {
            return XCTFail("platformSpecificOptions must be plist data")
        }
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: NSNumber])
        XCTAssertEqual(plist["ActivateSuspended"], NSNumber(value: UInt64(1)))
        XCTAssertEqual(plist["StartSuspendedKey"], NSNumber(value: UInt64(0)))
        XCTAssertEqual(plist["__ActivateSuspended"], NSNumber(value: UInt64(1)))
    }

    func testXCTestConfigurationPayloadEncodesPrivateClassNamesWithoutRegisteringRuntimeClasses() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let payload = try XCTestConfigurationPayload(
            testBundlePath: "/private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app/PlugIns/IOSUseDriver.xctest",
            sessionIdentifier: sessionID
        ).encode()

        let objects = try keyedArchiveObjects(from: payload)
        let names = classNames(in: objects)
        XCTAssertTrue(names.contains("XCTestConfiguration"))
        XCTAssertTrue(names.contains("NSURL"))
        XCTAssertTrue(names.contains("NSUUID"))
        XCTAssertTrue(String(describing: objects).contains("formatVersion = \"<CFKeyedArchiverUID"))
        XCTAssertTrue(String(describing: objects).contains("XCTAutomationSupport.framework"))
        XCTAssertTrue(String(describing: objects).contains("IOSUseDriver.xctest"))
    }

    func testDTXTransportCanSendRawObjectReplyForXCTestConfiguration() throws {
        let callback = try DTXMessageEncoder.dispatch(
            identifier: 41,
            channelCode: 5,
            selector: "_XCT_testRunnerReadyWithCapabilities:",
            arguments: [],
            expectsReply: true
        )
        let stream = FakeDeviceStream(reads: [callback.wireData])
        let transport = DTXStreamTransport(stream: stream)

        let message = try transport.readMessage()
        try transport.sendRawObjectReply(to: message, payload: Data([0xca, 0xfe]))

        let reply = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[0]]))
        XCTAssertEqual(reply.identifier, 41)
        XCTAssertEqual(reply.conversationIndex, 1)
        XCTAssertEqual(reply.channelCode, 5)
        XCTAssertEqual(reply.kind, .object)
        XCTAssertEqual(reply.payload, Data([0xca, 0xfe]))
    }

    func testDTXTransportCanSendAckReplyForCallbacksWithoutReturnValue() throws {
        let callback = try DTXMessageEncoder.dispatch(
            identifier: 42,
            channelCode: 5,
            selector: "_XCT_testBundleReadyWithProtocolVersion:minimumVersion:",
            arguments: [],
            expectsReply: true
        )
        let stream = FakeDeviceStream(reads: [callback.wireData])
        let transport = DTXStreamTransport(stream: stream)

        let message = try transport.readMessage()
        try transport.sendAckReply(to: message)

        let reply = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[0]]))
        XCTAssertEqual(reply.identifier, 42)
        XCTAssertEqual(reply.conversationIndex, 1)
        XCTAssertEqual(reply.channelCode, 5)
        XCTAssertEqual(reply.kind, .ok)
        XCTAssertTrue(reply.payload.isEmpty)
    }

    func testRealDeviceXCTestLifecycleRunsFullStartSequence() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let peerInfo = try RemoteXPCPeerInfo.decode(remotePeerInfoValue(extraServices: [
            DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName: .dictionary([
                "Port": .uint64(62001),
                "Properties": .dictionary([
                    "UsesRemoteXPC": .bool(false),
                ]),
            ]),
            CoreDeviceOpenStdIOSocket.serviceName: .dictionary([
                "Port": .uint64(62003),
                "Properties": .dictionary([
                    "UsesRemoteXPC": .bool(false),
                ]),
            ]),
            CoreDeviceAppService.serviceName: .dictionary([
                "Port": .uint64(62004),
                "Properties": .dictionary([
                    "UsesRemoteXPC": .bool(true),
                ]),
            ]),
        ]))
        let execStream = FakeDeviceStream(reads: [
            try dtxServerCapabilities().wireData,
            try DTXMessageEncoder.okReply(identifier: 2, conversationIndex: 1, channelCode: 0).wireData,
            try DTXMessageEncoder.objectReply(identifier: 3, conversationIndex: 1, channelCode: 1, object: NSNumber(value: true)).wireData,
            try DTXMessageEncoder.dispatch(
                identifier: 9,
                channelCode: 1,
                selector: "_XCT_testRunnerReadyWithCapabilities:",
                arguments: [.archived(["ready": 1])],
                expectsReply: true
            ).wireData,
        ])
        let stdioID = try XCTUnwrap(UUID(uuidString: "10203040-5060-7080-90A0-B0C0D0E0F001"))
        let stdioStream = FakeDeviceStream(reads: [uuidData(stdioID)])
        let controlStream = FakeDeviceStream(reads: [
            try dtxServerCapabilities().wireData,
            try DTXMessageEncoder.okReply(identifier: 2, conversationIndex: 1, channelCode: 0).wireData,
            try DTXMessageEncoder.objectReply(identifier: 3, conversationIndex: 1, channelCode: 1, object: [:]).wireData,
            try DTXMessageEncoder.objectReply(identifier: 4, conversationIndex: 1, channelCode: 1, object: NSNumber(value: true)).wireData,
            try DTXMessageEncoder.dispatch(
                identifier: 10,
                channelCode: 1,
                selector: "_XCT_testBundleReadyWithProtocolVersion:minimumVersion:",
                arguments: [.primitiveInt32(36), .primitiveInt32(1)],
                expectsReply: true
            ).wireData,
        ])
        let coreDeviceTunnel = FakeMultiStreamCoreDeviceLifecycleTunnelSession(
            peerInfo: peerInfo,
            streams: [stdioStream, execStream, controlStream]
        )
        var startTunnelCount = 0
        let appService = FakeXCTestRunnerAppService(pid: 333)
        let lifecycle = RealDeviceXCTestDriverLifecycle(dependencies: RealDeviceXCTestDriverLifecycle.Dependencies(
            startTunnel: { udid in
                XCTAssertEqual(udid, "REAL-XCTEST")
                guard startTunnelCount == 0 else {
                    throw CLIParseError.invalidValue("unexpected extra tunnel")
                }
                startTunnelCount += 1
                return coreDeviceTunnel
            },
            resolveRunnerInfo: { udid, bundleID in
                XCTAssertEqual(udid, "REAL-XCTEST")
                XCTAssertEqual(bundleID, "com.example.driver.xctrunner")
                return XCTestRunnerInstallInfo(
                    appPath: "/private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app",
                    testBundlePath: "/private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app/PlugIns/IOSUseDriver.xctest"
                )
            },
            productMajorVersion: { _ in 17 },
            makeSessionIdentifier: { sessionID },
            openAppService: { tunnelSession in
                XCTAssertEqual(ObjectIdentifier(tunnelSession), ObjectIdentifier(coreDeviceTunnel))
                return appService
            },
            openStdIOSocket: { tunnelSession in
                XCTAssertEqual(ObjectIdentifier(tunnelSession), ObjectIdentifier(coreDeviceTunnel))
                return try CoreDeviceOpenStdIOSocket.connect(session: tunnelSession)
            }
        ))

        let activeSession = try lifecycle.startDriverSession(udid: "REAL-XCTEST", bundleID: "com.example.driver.xctrunner")
        XCTAssertTrue(waitUntil { controlStream.writes.count == 5 })
        activeSession.close(killRunner: false)

        XCTAssertEqual(startTunnelCount, 1)
        XCTAssertEqual(coreDeviceTunnel.requestedServices, [
            CoreDeviceOpenStdIOSocket.serviceName,
            DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName,
            DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName,
        ])
        XCTAssertTrue(coreDeviceTunnel.closed)
        XCTAssertTrue(execStream.closed)
        XCTAssertTrue(stdioStream.closed)
        XCTAssertTrue(controlStream.closed)
        XCTAssertTrue(appService.closed)
        XCTAssertTrue(appService.killedProcessIdentifiers.isEmpty)
        XCTAssertEqual(appService.launches.count, 1)
        XCTAssertEqual(appService.launches.first?.bundleID, "com.example.driver.xctrunner")
        XCTAssertEqual(appService.launches.first?.standardIOIdentifier, stdioID)
        XCTAssertEqual(appService.launches.first?.environment["XCTestSessionIdentifier"], sessionID.uuidString.uppercased())
        XCTAssertEqual(
            appService.launches.first?.environment["XCTestBundlePath"],
            "/private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app/PlugIns/IOSUseDriver.xctest"
        )
        let execSelectors = selectorNames(in: execStream.writes)
        XCTAssertEqual(execSelectors, [
            "_notifyOfPublishedCapabilities:",
            "_requestChannelWithCode:identifier:",
            "_IDE_initiateSessionWithIdentifier:capabilities:",
            "_IDE_startExecutingTestPlanWithProtocolVersion:",
        ])
        let execMessages = execStream.writes.compactMap { try? DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [$0])) }
        let startPlanMessage = try XCTUnwrap(execMessages.first {
            ((try? unarchiveDTXBuffer($0.payload)) as? String) == "_IDE_startExecutingTestPlanWithProtocolVersion:"
        })
        XCTAssertEqual(startPlanMessage.channelCode, -1)
        let rawConfigReply = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [execStream.writes[3]]))
        XCTAssertEqual(rawConfigReply.identifier, 9)
        XCTAssertEqual(rawConfigReply.kind, .object)
        XCTAssertTrue(String(describing: try keyedArchiveObjects(from: rawConfigReply.payload)).contains("XCTestConfiguration"))
        let controlIdleAck = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [controlStream.writes[4]]))
        XCTAssertEqual(controlIdleAck.identifier, 10)
        XCTAssertEqual(controlIdleAck.kind, .ok)

        let controlSelectors = selectorNames(in: controlStream.writes)
        XCTAssertEqual(controlSelectors, [
            "_notifyOfPublishedCapabilities:",
            "_requestChannelWithCode:identifier:",
            "_IDE_initiateControlSessionWithCapabilities:",
            "_IDE_authorizeTestSessionWithProcessID:",
        ])
    }

    func testRealDeviceXCTestLifecycleRejectsIOSBefore17BeforeOpeningServices() throws {
        var productVersionUdids: [String] = []
        var didStartTunnel = false
        var didResolveRunner = false
        let lifecycle = RealDeviceXCTestDriverLifecycle(dependencies: RealDeviceXCTestDriverLifecycle.Dependencies(
            startTunnel: { _ in
                didStartTunnel = true
                throw CLIParseError.invalidValue("unexpected tunnel")
            },
            resolveRunnerInfo: { _, _ in
                didResolveRunner = true
                throw CLIParseError.invalidValue("unexpected runner lookup")
            },
            productMajorVersion: { udid in
                productVersionUdids.append(udid)
                return 16
            },
            makeSessionIdentifier: { UUID() },
            openAppService: { _ in
                XCTFail("iOS < 17 guard must run before AppService")
                throw CLIParseError.invalidValue("unexpected appservice")
            },
            openStdIOSocket: { _ in
                XCTFail("iOS < 17 guard must run before openstdio")
                throw CLIParseError.invalidValue("unexpected openstdio")
            }
        ))

        XCTAssertThrowsError(try lifecycle.startDriverSession(
            udid: "REAL-IOS16",
            bundleID: "com.example.driver.xctrunner"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("requires iOS 17 or later"))
        }
        XCTAssertEqual(productVersionUdids, ["REAL-IOS16"])
        XCTAssertFalse(didStartTunnel)
        XCTAssertFalse(didResolveRunner)
    }

    func testRealDeviceXCTestLifecycleSuggestsDDIMountWhenTestManagerServiceIsMissing() throws {
        let peerInfo = try RemoteXPCPeerInfo.decode(remotePeerInfoValue(extraServices: [
            CoreDeviceOpenStdIOSocket.serviceName: .dictionary([
                "Port": .uint64(62003),
                "Properties": .dictionary([
                    "UsesRemoteXPC": .bool(false),
                ]),
            ]),
            CoreDeviceAppService.serviceName: .dictionary([
                "Port": .uint64(62004),
                "Properties": .dictionary([
                    "UsesRemoteXPC": .bool(true),
                ]),
            ]),
        ]))
        let tunnel = FakeCoreDeviceLifecycleTunnelSession(stream: FakeDeviceStream(reads: []), peerInfo: peerInfo)
        var didOpenAppService = false
        let lifecycle = RealDeviceXCTestDriverLifecycle(dependencies: RealDeviceXCTestDriverLifecycle.Dependencies(
            startTunnel: { udid in
                XCTAssertEqual(udid, "REAL-XCTEST")
                return tunnel
            },
            resolveRunnerInfo: { _, _ in
                XCTestRunnerInstallInfo(
                    appPath: "/private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app",
                    testBundlePath: "/private/var/containers/Bundle/Application/UUID/IOSUseDriver-Runner.app/PlugIns/IOSUseDriver.xctest"
                )
            },
            productMajorVersion: { _ in 17 },
            makeSessionIdentifier: { UUID() },
            openAppService: { _ in
                didOpenAppService = true
                throw CLIParseError.invalidValue("unexpected appservice")
            },
            openStdIOSocket: { _ in
                XCTFail("missing testmanagerd must fail before openstdio")
                throw CLIParseError.invalidValue("unexpected openstdio")
            }
        ))

        XCTAssertThrowsError(try lifecycle.startDriverSession(
            udid: "REAL-XCTEST",
            bundleID: "com.example.driver.xctrunner"
        )) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("ios-use ddi-mount --udid REAL-XCTEST"))
            XCTAssertTrue(message.contains("Services.com.apple.dt.testmanagerd.remote"))
        }
        XCTAssertTrue(tunnel.closed)
        XCTAssertFalse(didOpenAppService)
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

    func testDTXStreamInvokerSkipsRemoteDispatchWithCollidingIdentifierBeforeReply() throws {
        let collidingDispatch = try DTXMessageEncoder.dispatch(
            identifier: 5,
            channelCode: DVTInstrumentsContract.Control.channelCode,
            selector: "_notifyOfPublishedCapabilities:",
            arguments: [.archived(["remote": 1])],
            expectsReply: false
        )
        let reply = try DTXMessageEncoder.objectReply(
            identifier: 5,
            conversationIndex: 1,
            channelCode: -3,
            object: NSNumber(value: 1001)
        )
        let stream = FakeDeviceStream(reads: [collidingDispatch.wireData, reply.wireData])
        let invoker = DTXStreamInvoker(stream: stream, channelCode: 3, firstIdentifier: 5)

        let result = try invoker.invoke(DVTInvocation(
            serviceIdentifier: "test.service",
            selector: "requestDisableMemoryLimitsForPid:",
            arguments: [.primitiveInt32(42)],
            expectsReply: true
        ))

        XCTAssertEqual((result as? NSNumber)?.intValue, 1001)
        XCTAssertEqual(stream.writes.count, 1)
    }

    func testDTXStreamInvokerAcksRemoteDispatchWithoutReturnValueBeforeReply() throws {
        let remoteCallback = try DTXMessageEncoder.dispatch(
            identifier: 77,
            channelCode: 1,
            selector: "_XCT_testBundleReadyWithProtocolVersion:minimumVersion:",
            arguments: [.primitiveInt32(36), .primitiveInt32(1)],
            expectsReply: true
        )
        let reply = try DTXMessageEncoder.objectReply(
            identifier: 5,
            conversationIndex: 1,
            channelCode: -3,
            object: NSNumber(value: 1001)
        )
        let stream = FakeDeviceStream(reads: [remoteCallback.wireData, reply.wireData])
        let invoker = DTXStreamInvoker(stream: stream, channelCode: 3, firstIdentifier: 5)

        let result = try invoker.invoke(DVTInvocation(
            serviceIdentifier: "test.service",
            selector: "requestDisableMemoryLimitsForPid:",
            arguments: [.primitiveInt32(42)],
            expectsReply: true
        ))

        XCTAssertEqual((result as? NSNumber)?.intValue, 1001)
        XCTAssertEqual(stream.writes.count, 2)
        let ack = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[1]]))
        XCTAssertEqual(ack.identifier, 77)
        XCTAssertEqual(ack.conversationIndex, 1)
        XCTAssertEqual(ack.channelCode, 1)
        XCTAssertEqual(ack.kind, .ok)
        XCTAssertTrue(ack.payload.isEmpty)
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
        let invoker = FakeDVTInvoker(replies: [NSNumber(value: true)])
        let client = XCTestManagerDaemonClient(invoker: invoker)

        XCTAssertThrowsError(try client.initiateControlSession(productMajorVersion: 9)) { error in
            XCTAssertTrue(String(describing: error).contains("requires iOS 17 or later"))
        }
        XCTAssertTrue(try client.authorizeTestSession(productMajorVersion: 17, pid: 777))
        XCTAssertThrowsError(try client.authorizeTestSession(productMajorVersion: 11, pid: 888)) { error in
            XCTAssertTrue(String(describing: error).contains("requires iOS 17 or later"))
        }

        XCTAssertEqual(invoker.invocations.map(\.selector), [
            "_IDE_authorizeTestSessionWithProcessID:",
        ])
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
        let frames = remoteXPCInitializationResponses(
            additional: RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: Data(wrapper.prefix(split)))
                + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: Data(wrapper.dropFirst(split)))
        )
        let stream = FakeDeviceStream(reads: [frames])
        let client = RemoteXPCClient(stream: stream)

        try client.completeClientHandshake()
        let peerInfo = try client.receivePeerInfo()

        XCTAssertEqual(peerInfo.uniqueDeviceID, "00008110-001234")
        XCTAssertEqual(stream.writes.count, try RemoteXPCHTTP2.clientHandshakeChunks().count + 6)
        XCTAssertEqual(stream.writes[0], RemoteXPCHTTP2.connectionPreface)
        let ackFrame = try RemoteXPCHTTP2.decodeFrame(stream.writes[try RemoteXPCHTTP2.clientHandshakeChunks().count])
        XCTAssertEqual(ackFrame.type, RemoteXPCHTTP2.frameSettings)
        XCTAssertEqual(ackFrame.flags, RemoteXPCHTTP2.flagAck)
    }

    func testRemoteXPCClientSendReceiveRequestUsesRootMessageIDAfterHandshake() throws {
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
            remoteXPCInitializationResponses(
                additional: RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.replyStreamID, payload: response)
            ),
        ])
        let client = RemoteXPCClient(stream: stream)

        try client.completeClientHandshake()
        let output = try client.sendReceiveRequest([
            "CoreDevice.featureIdentifier": .string("com.apple.coredevice.feature.launchapplication"),
        ])

        XCTAssertEqual(output.dictionaryValue?["CoreDevice.output"]?.dictionaryValue?["ok"], .bool(true))
        XCTAssertEqual(stream.writes.count, try RemoteXPCHTTP2.clientHandshakeChunks().count + 7)
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
            remoteXPCInitializationResponses(
                additional: RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.replyStreamID, payload: response)
            ),
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
            remoteXPCInitializationResponses(
                additional: RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.replyStreamID, payload: response)
            ),
        ])
        let client = RemoteXPCClient(stream: stream)
        try client.completeClientHandshake()
        let service = CoreDeviceAppService(client: client)

        let processes = try service.listProcesses()

        XCTAssertEqual(processes.first?.executable, "file:///private/var/containers/Bundle/Application/Driver/IOSUseDriver-Runner")
    }

    func testCoreDeviceAppServiceDecodesNestedBundleIdentifier() throws {
        let response = try RemoteXPCWrapper.encode(
            messageID: 1,
            flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.dataPresent,
            payload: .dictionary([
                "CoreDevice.output": .dictionary([
                    "processTokens": .array([
                        .dictionary([
                            "processIdentifier": .int64(123),
                            "executableURL": .dictionary([
                                "relative": .string("file:///private/var/containers/Bundle/Application/Demo/Demo"),
                            ]),
                            "applicationIdentifier": .dictionary([
                                "bundleIdentifier": .dictionary([
                                    "_0": .string("com.example.demo"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )
        let stream = FakeDeviceStream(reads: [
            remoteXPCInitializationResponses(
                additional: RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.replyStreamID, payload: response)
            ),
        ])
        let client = RemoteXPCClient(stream: stream)
        try client.completeClientHandshake()
        let service = CoreDeviceAppService(client: client)

        let processes = try service.listProcesses()

        XCTAssertEqual(processes.first?.bundleIdentifier, "com.example.demo")
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
            remoteXPCInitializationResponses(
                additional: RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.replyStreamID, payload: response)
            ),
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
            remoteXPCInitializationResponses(
                additional: RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: response)
            ),
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

        XCTAssertEqual(openedHost, session.serverAddress)
        XCTAssertEqual(appService.launchedBundleIDs, ["com.apple.springboard"])
        XCTAssertEqual(appService.launches.first?.payloadURL, "https://example.com")
        XCTAssertEqual(appService.launches.first?.activates, true)
        XCTAssertEqual(appService.launches.first?.terminateExisting, false)
        XCTAssertTrue(appService.closed)
    }

    func testCoreDeviceAppLifecycleRunnerActivatesAppThroughAppService() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppLifecycleService()
        let runner = CoreDeviceAppLifecycleRunner(dependencies: CoreDeviceAppLifecycleRunner.Dependencies(
            startTunnel: { udid in
                XCTAssertEqual(udid, "REAL-UDID")
                return session
            },
            openAppService: { tunnelSession in
                XCTAssertEqual(ObjectIdentifier(tunnelSession), ObjectIdentifier(session))
                return appService
            },
            resolveBundleExecutable: { _, _ in nil }
        ))

        try runner.activate(bundleID: "com.example.app", udid: "REAL-UDID")

        XCTAssertEqual(appService.launches.map(\.bundleID), ["com.example.app"])
        XCTAssertEqual(appService.launches.first?.terminateExisting, false)
        XCTAssertEqual(appService.launches.first?.activates, true)
        XCTAssertTrue(appService.closed)
        XCTAssertTrue(session.closed)
    }

    func testCoreDeviceAppLifecycleRunnerTerminatesMatchingBundleProcesses() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppLifecycleService()
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 11, executable: "file:///private/var/containers/Bundle/Application/A/Target"),
            CoreDeviceProcessToken(processIdentifier: 12, executable: "file:///private/var/containers/Bundle/Application/B/Other"),
            CoreDeviceProcessToken(processIdentifier: 13, executable: "/private/var/containers/Bundle/Application/C/Target"),
        ]
        let runner = CoreDeviceAppLifecycleRunner(dependencies: CoreDeviceAppLifecycleRunner.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            resolveBundleExecutable: { udid, bundleID in
                XCTAssertEqual(udid, "REAL-UDID")
                XCTAssertEqual(bundleID, "com.example.app")
                return "Target"
            }
        ))

        let terminated = try runner.terminate(bundleID: "com.example.app", udid: "REAL-UDID")

        XCTAssertTrue(terminated)
        XCTAssertEqual(appService.killedProcessIdentifiers, [11, 13])
        XCTAssertTrue(appService.closed)
        XCTAssertTrue(session.closed)
    }

    func testCoreDeviceAppLifecycleRunnerTreatsKillRaceAsNotRunning() throws {
        let session = try makeTunnelSession(peerInfo: RemoteXPCPeerInfo.decode(remotePeerInfoValue()))
        let appService = FakeCoreDeviceAppLifecycleService()
        appService.processes = [
            CoreDeviceProcessToken(processIdentifier: 11, executable: "/private/var/containers/Bundle/Application/A/App", bundleIdentifier: "com.example.app"),
        ]
        appService.killErrors = [
            11: CLIParseError.invalidValue("no such process"),
        ]
        let runner = CoreDeviceAppLifecycleRunner(dependencies: CoreDeviceAppLifecycleRunner.Dependencies(
            startTunnel: { _ in session },
            openAppService: { _ in appService },
            resolveBundleExecutable: { _, _ in nil }
        ))

        let terminated = try runner.terminate(bundleID: "com.example.app", udid: "REAL-UDID")

        XCTAssertFalse(terminated)
        XCTAssertEqual(appService.killedProcessIdentifiers, [11])
        XCTAssertTrue(appService.closed)
        XCTAssertTrue(session.closed)
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

    func testLockdownConnectToServiceUsesTLSWhenServiceRequiresSSL() throws {
        let pairRecord = PairRecord(
            hostID: "HOST",
            systemBUID: "BUID",
            hostPrivateKey: Data("key".utf8),
            hostCertificate: Data("cert".utf8)
        )
        let connection = LockdownServiceConnection(
            pairRecord: pairRecord,
            service: LockdownService(port: 12_345, enableServiceSSL: true)
        )
        let expectedStream = FakeDeviceStream(reads: [])
        var connected: (udid: String, port: Int)?
        var tlsInputs: (fd: Int32, hostID: String)?

        let stream = try LockdownSession.connectToStartedService(
            connection,
            udid: "REAL-UDID",
            usbmuxConnect: { udid, port in
                connected = (udid, port)
                return 42
            },
            tlsStreamFactory: { fd, record in
                tlsInputs = (fd, record.hostID)
                return expectedStream
            },
            plainStreamFactory: { _ in
                XCTFail("plain stream must not be used when EnableServiceSSL is true")
                return FakeDeviceStream(reads: [])
            }
        )

        XCTAssertEqual(connected?.udid, "REAL-UDID")
        XCTAssertEqual(connected?.port, 12_345)
        XCTAssertEqual(tlsInputs?.fd, 42)
        XCTAssertEqual(tlsInputs?.hostID, "HOST")
        XCTAssertTrue((stream as? FakeDeviceStream) === expectedStream)
    }

    func testLockdownConnectToServiceUsesPlainStreamWhenServiceDoesNotRequireSSL() throws {
        let pairRecord = PairRecord(
            hostID: "HOST",
            systemBUID: "BUID",
            hostPrivateKey: Data("key".utf8),
            hostCertificate: Data("cert".utf8)
        )
        let connection = LockdownServiceConnection(
            pairRecord: pairRecord,
            service: LockdownService(port: 12_346, enableServiceSSL: false)
        )
        let expectedStream = FakeDeviceStream(reads: [])
        var connected: (udid: String, port: Int)?
        var plainFD: Int32?

        let stream = try LockdownSession.connectToStartedService(
            connection,
            udid: "REAL-UDID",
            usbmuxConnect: { udid, port in
                connected = (udid, port)
                return 43
            },
            tlsStreamFactory: { _, _ in
                XCTFail("TLS stream must not be used when EnableServiceSSL is false")
                return FakeDeviceStream(reads: [])
            },
            plainStreamFactory: { fd in
                plainFD = fd
                return expectedStream
            }
        )

        XCTAssertEqual(connected?.udid, "REAL-UDID")
        XCTAssertEqual(connected?.port, 12_346)
        XCTAssertEqual(plainFD, 43)
        XCTAssertTrue((stream as? FakeDeviceStream) === expectedStream)
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

    func testPlainDeviceStreamEOFReportsClosedInsteadOfTimeout() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let stream = PlainDeviceStream(fd: fds[0])
        Darwin.close(fds[1])

        XCTAssertThrowsError(try stream.readExact(byteCount: 1, timeoutSeconds: 1)) { error in
            XCTAssertTrue(String(describing: error).contains("device stream closed"))
            XCTAssertFalse(String(describing: error).localizedCaseInsensitiveContains("timeout"))
        }
    }

    func testOwnedFDDeviceStreamEOFReportsClosedInsteadOfTimeout() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let stream = OwnedFDDeviceStream(fd: fds[0])
        Darwin.close(fds[1])

        XCTAssertThrowsError(try stream.readExact(byteCount: 1, timeoutSeconds: 1)) { error in
            XCTAssertTrue(String(describing: error).contains("RSD TCP stream closed"))
            XCTAssertFalse(String(describing: error).localizedCaseInsensitiveContains("timeout"))
        }
    }

    func testXCTestExecCallbackListenerTreatsTimedOutAsIdleTimeout() {
        XCTAssertTrue(XCTestExecCallbackListener.isIdleTimeout(CoreDeviceTCPError.connectionTimeout))
        XCTAssertTrue(XCTestExecCallbackListener.isIdleTimeout(DeviceStreamError.timeout("device read")))
        XCTAssertFalse(XCTestExecCallbackListener.isIdleTimeout(DeviceStreamError.closed("device stream")))
    }

    func testXCTestExecCallbackListenerAcksGenericCallbacksWithoutReturnValue() throws {
        let callback = try DTXMessageEncoder.dispatch(
            identifier: 91,
            channelCode: 1,
            selector: "_XCT_testBundleReadyWithProtocolVersion:minimumVersion:",
            arguments: [.primitiveInt32(36), .primitiveInt32(1)],
            expectsReply: true
        )
        let stream = FakeDeviceStream(reads: [callback.wireData])
        let channel = DTXChannelClient(transport: DTXStreamTransport(stream: stream), channelCode: 1)
        let listener = XCTestExecCallbackListener(channel: channel, configurationPayload: Data())

        listener.start()
        defer { listener.stop() }

        XCTAssertTrue(waitUntil { stream.writes.count == 1 })
        let ack = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[0]]))
        XCTAssertEqual(ack.identifier, 91)
        XCTAssertEqual(ack.conversationIndex, 1)
        XCTAssertEqual(ack.channelCode, 1)
        XCTAssertEqual(ack.kind, .ok)
        XCTAssertTrue(ack.payload.isEmpty)
    }

    func testDTXConnectionIdleListenerAcksGenericCallbacksWithoutReturnValue() throws {
        let callback = try DTXMessageEncoder.dispatch(
            identifier: 92,
            channelCode: 1,
            selector: "_XCT_testBundleReadyWithProtocolVersion:minimumVersion:",
            arguments: [.primitiveInt32(36), .primitiveInt32(1)],
            expectsReply: true
        )
        let stream = FakeDeviceStream(reads: [callback.wireData])
        let channel = DTXChannelClient(transport: DTXStreamTransport(stream: stream), channelCode: 1)
        let listener = DTXConnectionIdleListener(name: "test-control", channel: channel)

        listener.start()
        defer { listener.stop() }

        XCTAssertTrue(waitUntil { stream.writes.count == 1 })
        let ack = try DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [stream.writes[0]]))
        XCTAssertEqual(ack.identifier, 92)
        XCTAssertEqual(ack.conversationIndex, 1)
        XCTAssertEqual(ack.channelCode, 1)
        XCTAssertEqual(ack.kind, .ok)
        XCTAssertTrue(ack.payload.isEmpty)
    }

    func testUsbmuxDeviceIDAcceptsTopLevelAndPropertiesShapes() {
        XCTAssertEqual(Usbmux.deviceID(from: [
            "DeviceID": 7,
            "Properties": [
                "SerialNumber": "REAL-1",
            ],
        ]), 7)
        XCTAssertEqual(Usbmux.deviceID(from: [
            "Properties": [
                "DeviceID": 8,
                "SerialNumber": "REAL-2",
            ],
        ]), 8)
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
        var observed: [[String: Any]] = []

        XCTAssertThrowsError(try client.uninstall(bundleID: "com.example.app") { observed.append($0) }) { error in
            XCTAssertTrue(String(describing: error).contains("signature invalid"))
        }
        XCTAssertEqual(observed.compactMap { $0["Status"] as? String }, ["Installing"])
        XCTAssertEqual(observed.compactMap { $0["Error"] as? String }, ["ApplicationVerificationFailed"])
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

    func testMobileImageMounterQueriesPersonalizationIdentifiers() throws {
        let stream = FakeDeviceStream(reads: [
            plistFrame([
                "PersonalizationIdentifiers": [
                    "BoardId": 12,
                    "ChipID": 32784,
                    "SecurityDomain": 1,
                    "Ap,ProductType": "iPhone9,3",
                ],
            ]),
        ])
        let client = MobileImageMounterClient(stream: stream)

        let identifiers = try client.queryPersonalizationIdentifiers()

        XCTAssertEqual(identifiers.boardID, 12)
        XCTAssertEqual(identifiers.chipID, 32784)
        XCTAssertEqual(identifiers.securityDomain, 1)
        XCTAssertEqual(identifiers.apTags["Ap,ProductType"] as? String, "iPhone9,3")
        let request = try parseLengthPrefixedPlist(stream.writes[0])
        XCTAssertEqual(request["Command"] as? String, "QueryPersonalizationIdentifiers")
        XCTAssertEqual(request["PersonalizedImageType"] as? String, "DeveloperDiskImage")
    }

    func testMobileImageMounterUploadAndMountPersonalizedImageRequests() throws {
        let image = Data([0xaa, 0xbb, 0xcc])
        let signature = Data([0x01, 0x02])
        let trustCache = Data([0x03, 0x04])
        let stream = FakeDeviceStream(reads: [
            plistFrame(["Status": "ReceiveBytesAck"]),
            plistFrame(["Status": "Complete"]),
            plistFrame(["Status": "Complete"]),
        ])
        let client = MobileImageMounterClient(stream: stream)

        try client.uploadPersonalizedImage(image: image, signature: signature)
        try client.mountPersonalizedImage(signature: signature, trustCache: trustCache)

        let receive = try parseLengthPrefixedPlist(stream.writes[0])
        XCTAssertEqual(receive["Command"] as? String, "ReceiveBytes")
        XCTAssertEqual(receive["ImageType"] as? String, "Personalized")
        XCTAssertEqual(receive["ImageSize"] as? Int, image.count)
        XCTAssertEqual(receive["ImageSignature"] as? Data, signature)
        XCTAssertEqual(stream.writes[1], image)
        let mount = try parseLengthPrefixedPlist(stream.writes[2])
        XCTAssertEqual(mount["Command"] as? String, "MountImage")
        XCTAssertEqual(mount["ImageType"] as? String, "Personalized")
        XCTAssertEqual(mount["ImageSignature"] as? Data, signature)
        XCTAssertEqual(mount["ImageTrustCache"] as? Data, trustCache)
    }

    func testDeveloperDiskImageBuildManifestSelectsIdentityAndBuildsTSSRequest() throws {
        let root = try temporaryDirectory(prefix: "ddi-manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let restore = root.appendingPathComponent("Restore", isDirectory: true)
        try FileManager.default.createDirectory(at: restore.appendingPathComponent("Firmware", isDirectory: true), withIntermediateDirectories: true)
        let imageDigest = Data(repeating: 0xa1, count: 48)
        let trustDigest = Data(repeating: 0xb2, count: 48)
        let manifestURL = restore.appendingPathComponent("BuildManifest.plist")
        let manifest: [String: Any] = [
            "BuildIdentities": [
                [
                    "ApBoardID": "0x0C",
                    "ApChipID": "0x8010",
                    "Manifest": [
                        "PersonalizedDMG": [
                            "Digest": imageDigest,
                            "Info": [
                                "Path": "Image.dmg",
                                "Personalize": true,
                            ],
                            "Name": "DeveloperDiskImage",
                            "Trusted": true,
                        ],
                        "LoadableTrustCache": [
                            "Digest": trustDigest,
                            "Info": [
                                "Path": "Firmware/Image.dmg.trustcache",
                                "RestoreRequestRules": [
                                    [
                                        "Conditions": [
                                            "ApCurrentProductionMode": true,
                                            "ApRequiresImage4": true,
                                        ],
                                        "Actions": [
                                            "EPRO": true,
                                        ],
                                    ],
                                    [
                                        "Conditions": [
                                            "ApRawSecurityMode": true,
                                            "ApRequiresImage4": true,
                                        ],
                                        "Actions": [
                                            "ESEC": true,
                                        ],
                                    ],
                                ],
                            ],
                            "Trusted": true,
                        ],
                    ],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try data.write(to: manifestURL)
        try Data([1]).write(to: restore.appendingPathComponent("Image.dmg"))
        try Data([2]).write(to: restore.appendingPathComponent("Firmware/Image.dmg.trustcache"))

        let identifiers = DeveloperDiskImageBuildManifest.DeviceIdentifiers(
            boardID: 12,
            chipID: 0x8010,
            securityDomain: 1,
            apTags: ["Ap,ProductType": "iPhone9,3"]
        )
        let resolved = try DeveloperDiskImageResolver.resolve(path: root.path, identifiers: identifiers)
        defer { resolved.cleanup() }
        let buildManifest = try DeveloperDiskImageBuildManifest(url: resolved.buildManifestURL)
        let identity = try buildManifest.identity(for: identifiers)
        let request = DeveloperDiskImageBuildManifest.tssRequest(
            identity: identity,
            identifiers: identifiers,
            ecid: 12345,
            nonce: Data([0x10, 0x20])
        )

        XCTAssertEqual(resolved.imageURL.lastPathComponent, "Image.dmg")
        XCTAssertEqual(resolved.trustCacheURL.lastPathComponent, "Image.dmg.trustcache")
        XCTAssertEqual(request["@ApImg4Ticket"] as? Bool, true)
        XCTAssertEqual(request["ApBoardID"] as? Int, 12)
        XCTAssertEqual(request["ApChipID"] as? Int, 0x8010)
        XCTAssertEqual(request["ApECID"] as? Int64, 12345)
        XCTAssertEqual(request["ApNonce"] as? Data, Data([0x10, 0x20]))
        XCTAssertEqual(request["Ap,ProductType"] as? String, "iPhone9,3")
        let trustEntry = try XCTUnwrap(request["LoadableTrustCache"] as? [String: Any])
        XCTAssertEqual(trustEntry["Digest"] as? Data, trustDigest)
        XCTAssertEqual(trustEntry["EPRO"] as? Bool, true)
        XCTAssertEqual(trustEntry["ESEC"] as? Bool, true)
        XCTAssertNil(trustEntry["Info"])
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
            expectedVersion: "1.2.1"
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

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    private func remotePeerInfoValue(extraServices: [String: RemoteXPCValue] = [:]) -> RemoteXPCValue {
        var services: [String: RemoteXPCValue] = [
            "com.apple.coredevice.appservice": .dictionary([
                "Port": .uint64(54322),
                "Properties": .dictionary([
                    "UsesRemoteXPC": .bool(true),
                ]),
            ]),
            "com.apple.instruments.dtservicehub": .dictionary([
                "Port": .uint64(54321),
                "Properties": .dictionary([
                    "UsesRemoteXPC": .bool(true),
                ]),
            ]),
            "com.apple.mobile.lockdown.remote.trusted": .dictionary([
                "Port": .uint64(62078),
            ]),
        ]
        for (name, service) in extraServices {
            services[name] = service
        }
        return .dictionary([
            "Properties": .dictionary([
                "UniqueDeviceID": .string("00008110-001234"),
                "ProductType": .string("iPhone16,2"),
                "OSVersion": .string("18.0"),
            ]),
            "Services": .dictionary(services),
        ])
    }

    private func makeTunnelSession(peerInfo: RemoteXPCPeerInfo) throws -> FakeCoreDeviceLifecycleTunnelSession {
        FakeCoreDeviceLifecycleTunnelSession(stream: FakeDeviceStream(reads: []), peerInfo: peerInfo)
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

    private func remoteXPCInitializationResponses(additional: Data = Data()) -> Data {
        let rootAck = RemoteXPCWrapper.encodeEmpty(messageID: 0, flags: RemoteXPCFlags.alwaysSet)
        let replyAck = RemoteXPCWrapper.encodeEmpty(messageID: 0, flags: RemoteXPCFlags.alwaysSet)
        return RemoteXPCHTTP2.settingsFrame()
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: rootAck)
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.replyStreamID, payload: replyAck)
            + RemoteXPCHTTP2.dataFrame(streamID: RemoteXPCHTTP2.rootStreamID, payload: rootAck)
            + additional
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

    private func uuidData(_ uuid: UUID) -> Data {
        var value = uuid.uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private func unarchiveDTXArgument(_ argument: DTXAuxArgument) throws -> Any? {
    guard case .primitiveBuffer(let data) = argument else {
        XCTFail("expected archived DTX buffer argument")
        return nil
    }
    return try unarchiveDTXBuffer(data)
}

private func primitiveBuffer(_ argument: DTXAuxArgument) throws -> Data {
    guard case .primitiveBuffer(let data) = argument else {
        XCTFail("expected primitive buffer argument")
        return Data()
    }
    return data
}

private func unarchiveDTXBuffer(_ data: Data) throws -> Any? {
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
    unarchiver.requiresSecureCoding = false
    defer { unarchiver.finishDecoding() }
    return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
}

private func keyedArchiveObjects(from data: Data) throws -> [Any] {
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let root = try XCTUnwrap(plist as? [String: Any])
    return try XCTUnwrap(root["$objects"] as? [Any])
}

private func classNames(in objects: [Any]) -> Set<String> {
    Set(objects.compactMap { object in
        (object as? [String: Any])?["$classname"] as? String
    })
}

private func selectorNames(in writes: [Data]) -> [String] {
    writes.compactMap { data in
        guard let message = try? DTXMessageDecoder.readMessage(from: FakeDeviceStream(reads: [data])) else {
            return nil
        }
        return (try? unarchiveDTXBuffer(message.payload)) as? String
    }
}

private func dtxServerCapabilities(identifier: UInt32 = 90) throws -> DTXEncodedMessage {
    try DTXMessageEncoder.dispatch(
        identifier: identifier,
        channelCode: DVTInstrumentsContract.Control.channelCode,
        selector: "_notifyOfPublishedCapabilities:",
        arguments: [.archived(["server": 1])],
        expectsReply: false
    )
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

private final class FakeMultiStreamCoreDeviceLifecycleTunnelSession: CoreDeviceLifecycleTunnelSession {
    let serverAddress = "fd00::1"
    var peerInfo: RemoteXPCPeerInfo?
    private var streams: [DeviceStream]
    private(set) var requestedServices: [String] = []
    private(set) var closed = false

    init(peerInfo: RemoteXPCPeerInfo, streams: [DeviceStream]) {
        self.peerInfo = peerInfo
        self.streams = streams
    }

    func connectService(_ serviceName: String) throws -> DeviceStream {
        requestedServices.append(serviceName)
        guard !streams.isEmpty else {
            throw CLIParseError.invalidValue("fake session stream underflow for \(serviceName)")
        }
        return streams.removeFirst()
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
    private let autoRespondToSyn: Bool
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

    init(handshake: CoreDeviceTunnelHandshake, reads: [Data], autoRespondToSyn: Bool = false) {
        self.handshake = handshake
        self.autoRespondToSyn = autoRespondToSyn
        self.reads = reads
    }

    func appendReads(_ packets: [Data]) {
        lock.lock()
        reads.append(contentsOf: packets)
        lock.unlock()
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
            throw DeviceStreamError.timeout("fake tunnel read")
        }
        return reads.removeFirst()
    }

    func writeIPv6Packet(_ packet: Data) throws {
        lock.lock()
        writesStorage.append(packet)
        if autoRespondToSyn,
           let segment = try? CoreDeviceIPv6TCPCodec.decodeSegment(packet),
           segment.hasSyn {
            let synAck = try? CoreDeviceIPv6TCPCodec.encodeSegment(
                sourceAddress: segment.destinationAddress,
                destinationAddress: segment.sourceAddress,
                sourcePort: segment.destinationPort,
                destinationPort: segment.sourcePort,
                sequenceNumber: 900,
                acknowledgmentNumber: segment.sequenceNumber + 1,
                flags: CoreDeviceTCPFlags.syn | CoreDeviceTCPFlags.ack
            )
            if let synAck {
                reads.append(synAck)
            }
        }
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

    func close() {
        closed = true
    }
}

private final class FakeCoreDeviceAppLifecycleService: CoreDeviceAppLifecycleServicing {
    struct Launch: Equatable {
        let bundleID: String
        let terminateExisting: Bool
        let payloadURL: String?
        let activates: Bool?
    }

    var launches: [Launch] = []
    var processes: [CoreDeviceProcessToken] = []
    var killedProcessIdentifiers: [Int] = []
    var killErrors: [Int: Error] = [:]
    var launchOutput: RemoteXPCValue = .dictionary(["processIdentifier": .int64(222)])
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
        launches.append(Launch(
            bundleID: bundleID,
            terminateExisting: terminateExisting,
            payloadURL: payloadURL,
            activates: activates
        ))
        return launchOutput
    }

    func listProcesses() throws -> [CoreDeviceProcessToken] {
        processes
    }

    func kill(processIdentifier: Int) throws {
        killedProcessIdentifiers.append(processIdentifier)
        if let error = killErrors[processIdentifier] {
            throw error
        }
    }

    func close() {
        closed = true
    }
}

private final class FakeXCTestRunnerAppService: XCTestRunnerAppServicing {
    struct Launch: Equatable {
        let bundleID: String
        let arguments: [String]
        let environment: [String: String]
        let standardIOIdentifier: UUID?
    }

    let pid: Int
    private(set) var launches: [Launch] = []
    private(set) var killedProcessIdentifiers: [Int] = []
    private(set) var closed = false

    init(pid: Int) {
        self.pid = pid
    }

    func launchXCTestRunner(
        bundleID: String,
        arguments: [String],
        environment: [String: String],
        standardIOIdentifier: UUID?
    ) throws -> Int {
        launches.append(Launch(
            bundleID: bundleID,
            arguments: arguments,
            environment: environment,
            standardIOIdentifier: standardIOIdentifier
        ))
        return pid
    }

    func kill(processIdentifier: Int) throws {
        killedProcessIdentifiers.append(processIdentifier)
    }

    func close() {
        closed = true
    }
}
