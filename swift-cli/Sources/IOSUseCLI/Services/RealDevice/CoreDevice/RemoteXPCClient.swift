import Darwin
import Foundation

enum RemoteXPCError: Error, CustomStringConvertible, Equatable {
    case truncated
    case invalidLength(String)
    case invalidMagic(String)
    case invalidString
    case unsupportedType(UInt32)
    case missingField(String)
    case invalidHTTP2Frame

    var description: String {
        switch self {
        case .truncated:
            return "RemoteXPC frame is incomplete"
        case .invalidLength(let detail):
            return "RemoteXPC invalid length: \(detail)"
        case .invalidMagic(let detail):
            return "RemoteXPC invalid magic: \(detail)"
        case .invalidString:
            return "RemoteXPC invalid string"
        case .unsupportedType(let type):
            return "RemoteXPC unsupported XPC type: 0x\(String(type, radix: 16))"
        case .missingField(let field):
            return "RemoteXPC missing field: \(field)"
        case .invalidHTTP2Frame:
            return "RemoteXPC invalid HTTP/2 frame"
        }
    }
}

enum RemoteXPCValue: Equatable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case date(UInt64)
    case string(String)
    case data(Data)
    case uuid(UUID)
    case array([RemoteXPCValue])
    case dictionary([String: RemoteXPCValue])

    var dictionaryValue: [String: RemoteXPCValue]? {
        if case .dictionary(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int64(let value):
            return Int(value)
        case .uint64(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var isEmptyDictionary: Bool {
        if case .dictionary(let values) = self {
            return values.isEmpty
        }
        return false
    }
}

struct RemoteXPCMessage: Equatable {
    let flags: UInt32
    let messageID: UInt64
    let payload: RemoteXPCValue?
}

enum RemoteXPCFlags {
    static let alwaysSet: UInt32 = 0x0000_0001
    static let ping: UInt32 = 0x0000_0002
    static let dataPresent: UInt32 = 0x0000_0100
    static let rootChannelHandshake: UInt32 = 0x0000_0200
    static let wantingReply: UInt32 = 0x0001_0000
    static let reply: UInt32 = 0x0002_0000
    static let initHandshake: UInt32 = 0x0040_0000
}

enum RemoteXPCObjectType {
    static let null: UInt32 = 0x0000_1000
    static let bool: UInt32 = 0x0000_2000
    static let int64: UInt32 = 0x0000_3000
    static let uint64: UInt32 = 0x0000_4000
    static let double: UInt32 = 0x0000_5000
    static let date: UInt32 = 0x0000_7000
    static let data: UInt32 = 0x0000_8000
    static let string: UInt32 = 0x0000_9000
    static let uuid: UInt32 = 0x0000_a000
    static let array: UInt32 = 0x0000_e000
    static let dictionary: UInt32 = 0x0000_f000
}

enum RemoteXPCWrapper {
    static let wrapperMagic: UInt32 = 0x29b0_0b92
    static let payloadMagic: UInt32 = 0x4213_3742
    static let protocolVersion: UInt32 = 5

    static func encodeDictionary(
        _ dictionary: [String: RemoteXPCValue],
        messageID: UInt64 = 0,
        wantingReply: Bool = false
    ) throws -> Data {
        var flags = RemoteXPCFlags.alwaysSet
        if !dictionary.isEmpty {
            flags |= RemoteXPCFlags.dataPresent
        }
        if wantingReply {
            flags |= RemoteXPCFlags.wantingReply
        }
        return try encode(
            messageID: messageID,
            flags: flags,
            payload: .dictionary(dictionary)
        )
    }

    static func encodeEmpty(messageID: UInt64 = 0, flags: UInt32) -> Data {
        encode(messageID: messageID, flags: flags, payloadData: nil)
    }

    static func encode(messageID: UInt64, flags: UInt32, payload: RemoteXPCValue?) throws -> Data {
        guard let payload else {
            return encodeEmpty(messageID: messageID, flags: flags)
        }
        var payloadData = Data()
        payloadData.append(uint32LE(payloadMagic))
        payloadData.append(uint32LE(protocolVersion))
        try payloadData.append(encodeObject(payload))
        return encode(messageID: messageID, flags: flags, payloadData: payloadData)
    }

    static func decode(_ data: Data) throws -> RemoteXPCMessage {
        let (message, consumed) = try decodePrefix(data)
        guard consumed == data.count else {
            throw RemoteXPCError.invalidLength("wrapper has trailing bytes")
        }
        return message
    }

    static func decodePrefix(_ data: Data) throws -> (RemoteXPCMessage, Int) {
        guard data.count >= 16 else {
            throw RemoteXPCError.truncated
        }
        let payloadLength = readUInt64LE(data, 8)
        let consumed = Int(payloadLength) + 24
        guard data.count >= consumed else {
            throw RemoteXPCError.truncated
        }
        return (try decodeSingle(Data(data.prefix(consumed))), consumed)
    }

    private static func decodeSingle(_ data: Data) throws -> RemoteXPCMessage {
        var cursor = RemoteXPCDataCursor(data)
        let magic = try cursor.readUInt32LE()
        guard magic == wrapperMagic else {
            throw RemoteXPCError.invalidMagic("wrapper")
        }
        let flags = try cursor.readUInt32LE()
        let payloadLength = Int(try cursor.readUInt64LE())
        guard cursor.remaining >= 8 + payloadLength else {
            throw RemoteXPCError.truncated
        }
        guard cursor.remaining == 8 + payloadLength else {
            throw RemoteXPCError.invalidLength("wrapper has trailing bytes")
        }
        let messageID = try cursor.readUInt64LE()
        let payload: RemoteXPCValue?
        if payloadLength == 0 {
            payload = nil
        } else {
            guard cursor.remaining == payloadLength else {
                throw RemoteXPCError.invalidLength("wrapper payload length mismatch")
            }
            let payloadMagic = try cursor.readUInt32LE()
            guard payloadMagic == self.payloadMagic else {
                throw RemoteXPCError.invalidMagic("payload")
            }
            let version = try cursor.readUInt32LE()
            guard version == protocolVersion else {
                throw RemoteXPCError.invalidLength("unsupported protocol version \(version)")
            }
            payload = try decodeObject(&cursor)
            guard cursor.remaining == 0 else {
                throw RemoteXPCError.invalidLength("payload has trailing bytes")
            }
        }
        return RemoteXPCMessage(flags: flags, messageID: messageID, payload: payload)
    }

    private static func encode(messageID: UInt64, flags: UInt32, payloadData: Data?) -> Data {
        var message = Data()
        message.append(uint64LE(messageID))
        if let payloadData {
            message.append(payloadData)
        }

        var wrapper = Data()
        wrapper.append(uint32LE(wrapperMagic))
        wrapper.append(uint32LE(flags))
        wrapper.append(uint64LE(UInt64(payloadData?.count ?? 0)))
        wrapper.append(message)
        return wrapper
    }

    private static func encodeObject(_ value: RemoteXPCValue) throws -> Data {
        var data = Data()
        switch value {
        case .null:
            data.append(uint32LE(RemoteXPCObjectType.null))
        case .bool(let value):
            data.append(uint32LE(RemoteXPCObjectType.bool))
            data.append(uint32LE(value ? 1 : 0))
        case .int64(let value):
            data.append(uint32LE(RemoteXPCObjectType.int64))
            data.append(uint64LE(UInt64(bitPattern: value)))
        case .uint64(let value):
            data.append(uint32LE(RemoteXPCObjectType.uint64))
            data.append(uint64LE(value))
        case .double(let value):
            data.append(uint32LE(RemoteXPCObjectType.double))
            data.append(uint64LE(value.bitPattern))
        case .date(let value):
            data.append(uint32LE(RemoteXPCObjectType.date))
            data.append(uint64LE(value))
        case .string(let value):
            data.append(uint32LE(RemoteXPCObjectType.string))
            data.append(encodeLengthPrefixedAlignedString(value))
        case .data(let value):
            data.append(uint32LE(RemoteXPCObjectType.data))
            data.append(encodeLengthPrefixedAlignedData(value))
        case .uuid(let value):
            data.append(uint32LE(RemoteXPCObjectType.uuid))
            data.append(uuidData(value))
        case .array(let values):
            data.append(uint32LE(RemoteXPCObjectType.array))
            var body = Data()
            body.append(uint32LE(UInt32(values.count)))
            for value in values {
                try body.append(encodeObject(value))
            }
            data.append(uint32LE(UInt32(body.count)))
            data.append(body)
        case .dictionary(let values):
            data.append(uint32LE(RemoteXPCObjectType.dictionary))
            var body = Data()
            body.append(uint32LE(UInt32(values.count)))
            for key in values.keys.sorted() {
                body.append(encodeAlignedCString(key))
                try body.append(encodeObject(values[key]!))
            }
            data.append(uint32LE(UInt32(body.count)))
            data.append(body)
        }
        return data
    }

    private static func decodeObject(_ cursor: inout RemoteXPCDataCursor) throws -> RemoteXPCValue {
        let type = try cursor.readUInt32LE()
        switch type {
        case RemoteXPCObjectType.null:
            return .null
        case RemoteXPCObjectType.bool:
            return .bool(try cursor.readUInt32LE() != 0)
        case RemoteXPCObjectType.int64:
            return .int64(Int64(bitPattern: try cursor.readUInt64LE()))
        case RemoteXPCObjectType.uint64:
            return .uint64(try cursor.readUInt64LE())
        case RemoteXPCObjectType.double:
            return .double(Double(bitPattern: try cursor.readUInt64LE()))
        case RemoteXPCObjectType.date:
            return .date(try cursor.readUInt64LE())
        case RemoteXPCObjectType.string:
            return .string(try cursor.readLengthPrefixedAlignedString())
        case RemoteXPCObjectType.data:
            return .data(try cursor.readLengthPrefixedAlignedData())
        case RemoteXPCObjectType.uuid:
            return .uuid(try cursor.readUUID())
        case RemoteXPCObjectType.array:
            let body = try cursor.readLengthPrefixedCursor()
            var bodyCursor = body
            let count = Int(try bodyCursor.readUInt32LE())
            var values: [RemoteXPCValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                values.append(try decodeObject(&bodyCursor))
            }
            guard bodyCursor.remaining == 0 else {
                throw RemoteXPCError.invalidLength("array trailing bytes")
            }
            return .array(values)
        case RemoteXPCObjectType.dictionary:
            let body = try cursor.readLengthPrefixedCursor()
            var bodyCursor = body
            let count = Int(try bodyCursor.readUInt32LE())
            var values: [String: RemoteXPCValue] = [:]
            for _ in 0..<count {
                let key = try bodyCursor.readAlignedCString()
                values[key] = try decodeObject(&bodyCursor)
            }
            guard bodyCursor.remaining == 0 else {
                throw RemoteXPCError.invalidLength("dictionary trailing bytes")
            }
            return .dictionary(values)
        default:
            throw RemoteXPCError.unsupportedType(type)
        }
    }
}

struct RemoteXPCHTTP2Frame: Equatable {
    let type: UInt8
    let flags: UInt8
    let streamID: Int
    let payload: Data
}

enum RemoteXPCHTTP2 {
    static let connectionPreface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static let rootStreamID = 1
    static let replyStreamID = 3
    static let defaultMaxConcurrentStreams: UInt32 = 100
    static let defaultInitialWindowSize: UInt32 = 1_048_576
    static let defaultWindowIncrement: UInt32 = 983_041

    static let frameData: UInt8 = 0x0
    static let frameHeaders: UInt8 = 0x1
    static let frameRstStream: UInt8 = 0x3
    static let frameSettings: UInt8 = 0x4
    static let frameGoAway: UInt8 = 0x7
    static let frameWindowUpdate: UInt8 = 0x8
    static let flagEndHeaders: UInt8 = 0x4
    static let flagAck: UInt8 = 0x1

    static func clientHandshakeChunks() throws -> [Data] {
        [
            connectionPreface,
            settingsFrame(),
            windowUpdateFrame(streamID: 0, increment: defaultWindowIncrement),
            headersFrame(streamID: rootStreamID),
            dataFrame(streamID: rootStreamID, payload: try RemoteXPCWrapper.encodeDictionary([:])),
            dataFrame(
                streamID: rootStreamID,
                payload: RemoteXPCWrapper.encodeEmpty(messageID: 0, flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.rootChannelHandshake)
            ),
            headersFrame(streamID: replyStreamID),
            dataFrame(
                streamID: replyStreamID,
                payload: RemoteXPCWrapper.encodeEmpty(
                    messageID: 0,
                    flags: RemoteXPCFlags.alwaysSet | RemoteXPCFlags.initHandshake
                )
            ),
        ]
    }

    static func encodeClientHandshake() throws -> Data {
        var data = Data()
        for chunk in try clientHandshakeChunks() {
            data.append(chunk)
        }
        return data
    }

    static func settingsFrame(
        maxConcurrentStreams: UInt32 = defaultMaxConcurrentStreams,
        initialWindowSize: UInt32 = defaultInitialWindowSize,
        ack: Bool = false
    ) -> Data {
        if ack {
            return encodeFrame(type: frameSettings, flags: flagAck, streamID: 0, payload: Data())
        }
        var payload = Data()
        payload.append(uint16BE(0x0003))
        payload.append(uint32BE(maxConcurrentStreams))
        payload.append(uint16BE(0x0004))
        payload.append(uint32BE(initialWindowSize))
        return encodeFrame(type: frameSettings, flags: 0, streamID: 0, payload: payload)
    }

    static func headersFrame(streamID: Int, flags: UInt8 = flagEndHeaders) -> Data {
        encodeFrame(type: frameHeaders, flags: flags, streamID: streamID, payload: Data())
    }

    static func dataFrame(streamID: Int, payload: Data, flags: UInt8 = 0) -> Data {
        encodeFrame(type: frameData, flags: flags, streamID: streamID, payload: payload)
    }

    static func windowUpdateFrame(streamID: Int, increment: UInt32) -> Data {
        encodeFrame(type: frameWindowUpdate, flags: 0, streamID: streamID, payload: uint32BE(increment & 0x7fff_ffff))
    }

    static func encodeFrame(type: UInt8, flags: UInt8, streamID: Int, payload: Data) -> Data {
        var frame = Data()
        let length = payload.count
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
        frame.append(type)
        frame.append(flags)
        frame.append(uint32BE(UInt32(streamID) & 0x7fff_ffff))
        frame.append(payload)
        return frame
    }

    static func decodeFrame(_ data: Data) throws -> RemoteXPCHTTP2Frame {
        guard data.count >= 9 else {
            throw RemoteXPCError.truncated
        }
        let bytes = [UInt8](data)
        let length = (Int(bytes[0]) << 16) | (Int(bytes[1]) << 8) | Int(bytes[2])
        guard data.count == 9 + length else {
            throw data.count < 9 + length ? RemoteXPCError.truncated : RemoteXPCError.invalidHTTP2Frame
        }
        let streamID = Int(readUInt32BE(data, 5) & 0x7fff_ffff)
        return RemoteXPCHTTP2Frame(
            type: bytes[3],
            flags: bytes[4],
            streamID: streamID,
            payload: Data(data.dropFirst(9))
        )
    }
}

struct RemoteXPCService: Equatable {
    let name: String
    let port: Int
    let usesRemoteXPC: Bool
}

struct RemoteXPCPeerInfo: Equatable {
    let properties: [String: RemoteXPCValue]
    let services: [String: RemoteXPCService]

    var uniqueDeviceID: String? { properties["UniqueDeviceID"]?.stringValue }
    var productType: String? { properties["ProductType"]?.stringValue }
    var osVersion: String? { properties["OSVersion"]?.stringValue }

    func servicePort(_ name: String) throws -> Int {
        guard let service = services[name] else {
            throw RemoteXPCError.missingField("Services.\(name)")
        }
        return service.port
    }

    static func decode(_ value: RemoteXPCValue) throws -> RemoteXPCPeerInfo {
        guard let root = value.dictionaryValue else {
            throw RemoteXPCError.missingField("peerInfo")
        }
        guard let properties = root["Properties"]?.dictionaryValue else {
            throw RemoteXPCError.missingField("Properties")
        }
        guard let serviceValues = root["Services"]?.dictionaryValue else {
            throw RemoteXPCError.missingField("Services")
        }
        var services: [String: RemoteXPCService] = [:]
        for (name, serviceValue) in serviceValues {
            guard let serviceDict = serviceValue.dictionaryValue,
                  let port = parseServicePort(serviceDict["Port"]) else {
                continue
            }
            let usesRemoteXPC = serviceDict["Properties"]?.dictionaryValue?["UsesRemoteXPC"]?.boolValue ?? false
            services[name] = RemoteXPCService(name: name, port: port, usesRemoteXPC: usesRemoteXPC)
        }
        if services.isEmpty, !serviceValues.isEmpty {
            let samples = serviceValues.keys.sorted().prefix(5).map { name -> String in
                let portShape = serviceValues[name]?.dictionaryValue?["Port"].map(describeValueShape) ?? "missing"
                return "\(name).Port=\(portShape)"
            }
            throw RemoteXPCError.missingField("Services usable Port (\(samples.joined(separator: ", ")))")
        }
        return RemoteXPCPeerInfo(properties: properties, services: services)
    }

    private static func parseServicePort(_ value: RemoteXPCValue?) -> Int? {
        guard let value else { return nil }
        if let intValue = value.intValue {
            return intValue
        }
        guard let stringValue = value.stringValue, !stringValue.isEmpty else {
            return nil
        }
        return Int(stringValue)
    }

    private static func describeValueShape(_ value: RemoteXPCValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "bool"
        case .int64: return "int64"
        case .uint64: return "uint64"
        case .double: return "double"
        case .date: return "date"
        case .string: return "string"
        case .data(let data): return "data(\(data.count))"
        case .uuid: return "uuid"
        case .array(let values): return "array(\(values.count))"
        case .dictionary(let dictionary): return "dictionary(\(dictionary.keys.sorted().joined(separator: ",")))"
        }
    }
}

final class RemoteXPCClient {
    private let stream: DeviceStream
    private let eventSink: ((String) -> Void)?
    private let acknowledgeSettings: Bool
    private var pendingData = Data()
    private var nextRootMessageID: UInt64 = 0

    init(stream: DeviceStream, eventSink: ((String) -> Void)? = nil, acknowledgeSettings: Bool = true) {
        self.stream = stream
        self.eventSink = eventSink
        self.acknowledgeSettings = acknowledgeSettings
    }

    func sendClientHandshake() throws {
        for chunk in try RemoteXPCHTTP2.clientHandshakeChunks() {
            try stream.write(chunk)
        }
        nextRootMessageID = 1
    }

    func completeClientHandshake(timeoutSeconds: Double = 3) throws {
        try sendClientHandshake()
        let frame = try readFrame(timeoutSeconds: timeoutSeconds)
        guard frame.type == RemoteXPCHTTP2.frameSettings else {
            throw CLIParseError.invalidValue("RemoteXPC expected SETTINGS during handshake, got frame type \(frame.type)")
        }
        if acknowledgeSettings && frame.flags & RemoteXPCHTTP2.flagAck == 0 {
            try stream.write(RemoteXPCHTTP2.settingsFrame(ack: true))
        }
    }

    func sendReceiveRequest(_ request: [String: RemoteXPCValue], timeoutSeconds: Double = 10) throws -> RemoteXPCValue {
        try sendRequest(request, wantingReply: true)
        return try receiveResponse(timeoutSeconds: timeoutSeconds)
    }

    func sendRequest(_ request: [String: RemoteXPCValue], wantingReply: Bool = false) throws {
        let messageID = nextRootMessageID
        try stream.write(RemoteXPCHTTP2.dataFrame(
            streamID: RemoteXPCHTTP2.rootStreamID,
            payload: try RemoteXPCWrapper.encodeDictionary(
                request,
                messageID: messageID,
                wantingReply: wantingReply
            )
        ))
        nextRootMessageID = messageID + 1
    }

    func receiveResponse(timeoutSeconds: Double = 10) throws -> RemoteXPCValue {
        while true {
            let frame = try readFrame(timeoutSeconds: timeoutSeconds)
            if frame.type != RemoteXPCHTTP2.frameData {
                eventSink?("RemoteXPC frame type=\(frame.type) flags=0x\(String(frame.flags, radix: 16)) stream=\(frame.streamID) bytes=\(frame.payload.count)")
            }
            switch frame.type {
            case RemoteXPCHTTP2.frameSettings:
                if acknowledgeSettings && frame.flags & RemoteXPCHTTP2.flagAck == 0 {
                    try stream.write(RemoteXPCHTTP2.settingsFrame(ack: true))
                }
                continue
            case RemoteXPCHTTP2.frameGoAway:
                throw CLIParseError.invalidValue("RemoteXPC received GOAWAY")
            case RemoteXPCHTTP2.frameRstStream:
                throw CLIParseError.invalidValue("RemoteXPC received RST_STREAM for stream \(frame.streamID)")
            case RemoteXPCHTTP2.frameData:
                eventSink?("RemoteXPC DATA stream=\(frame.streamID) bytes=\(frame.payload.count) prefix=\(Self.hexPrefix(frame.payload))")
                pendingData.append(frame.payload)
                while true {
                    let message: RemoteXPCMessage
                    let consumed: Int
                    do {
                        (message, consumed) = try RemoteXPCWrapper.decodePrefix(pendingData)
                    } catch RemoteXPCError.truncated {
                        if pendingData.count >= 16 {
                            let expected = Int(readUInt64LE(pendingData, 8)) + 24
                            eventSink?("RemoteXPC wrapper truncated pending=\(pendingData.count) expected=\(expected)")
                        } else {
                            eventSink?("RemoteXPC wrapper truncated pending=\(pendingData.count)")
                        }
                        break
                    }
                    pendingData.removeFirst(consumed)
                    eventSink?("RemoteXPC wrapper stream=\(frame.streamID) id=\(message.messageID) flags=0x\(String(message.flags, radix: 16)) payload=\(message.payload != nil) pending=\(pendingData.count)")
                    if frame.streamID == RemoteXPCHTTP2.rootStreamID {
                        nextRootMessageID = max(nextRootMessageID, message.messageID + 1)
                    }
                    guard let payload = message.payload else {
                        continue
                    }
                    if payload.isEmptyDictionary {
                        eventSink?("RemoteXPC skipped empty dictionary payload")
                        continue
                    }
                    return payload
                }
            default:
                continue
            }
        }
    }

    func receivePeerInfo(timeoutSeconds: Double = 10) throws -> RemoteXPCPeerInfo {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let value = try receiveResponse(timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
            if Self.mayBePeerInfo(value) {
                return try RemoteXPCPeerInfo.decode(value)
            }
            eventSink?("RemoteXPC skipped non-peer-info payload: \(Self.describePayloadShape(value))")
        }
        throw CLIParseError.invalidValue("RemoteXPC peer info timeout")
    }

    func close() {
        stream.close()
    }

    private func readFrame(timeoutSeconds: Double) throws -> RemoteXPCHTTP2Frame {
        let header = try stream.readExact(byteCount: 9, timeoutSeconds: timeoutSeconds)
        let bytes = [UInt8](header)
        let length = (Int(bytes[0]) << 16) | (Int(bytes[1]) << 8) | Int(bytes[2])
        let payload = length == 0 ? Data() : try stream.readExact(byteCount: length, timeoutSeconds: timeoutSeconds)
        return try RemoteXPCHTTP2.decodeFrame(header + payload)
    }

    private static func hexPrefix(_ data: Data, count: Int = 24) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined()
    }

    private static func mayBePeerInfo(_ value: RemoteXPCValue) -> Bool {
        guard let dictionary = value.dictionaryValue else { return false }
        return dictionary.keys.contains("Properties") || dictionary.keys.contains("Services")
    }

    private static func describePayloadShape(_ value: RemoteXPCValue) -> String {
        switch value {
        case .dictionary(let dictionary):
            return "dictionary keys=[\(dictionary.keys.sorted().joined(separator: ", "))]"
        case .array(let values):
            return "array count=\(values.count)"
        case .null:
            return "null"
        case .bool:
            return "bool"
        case .int64, .uint64:
            return "integer"
        case .double:
            return "double"
        case .date:
            return "date"
        case .string:
            return "string"
        case .data(let data):
            return "data bytes=\(data.count)"
        case .uuid:
            return "uuid"
        }
    }
}

enum RemoteServiceDiscoveryClient {
    static let defaultPort = 58_783
    static var streamConnectorForTesting: ((String, Int) throws -> DeviceStream)?

    static func connect(host: String, port: Int = defaultPort) throws -> RemoteXPCPeerInfo {
        let stream: DeviceStream
        if let streamConnectorForTesting {
            stream = try streamConnectorForTesting(host, port)
        } else {
            let fd = try TCPConnector.connect(host: host, port: port)
            stream = OwnedFDDeviceStream(fd: fd)
        }
        defer { stream.close() }

        let client = RemoteXPCClient(stream: stream)
        try client.completeClientHandshake()
        return try client.receivePeerInfo()
    }

    static func connectRemoteXPCService(host: String, peerInfo: RemoteXPCPeerInfo, serviceName: String) throws -> RemoteXPCClient {
        let port = try peerInfo.servicePort(serviceName)
        let fd = try TCPConnector.connect(host: host, port: port)
        let client = RemoteXPCClient(stream: OwnedFDDeviceStream(fd: fd))
        do {
            try client.completeClientHandshake()
            return client
        } catch {
            client.close()
            throw error
        }
    }

    static func resetTestingOverrides() {
        streamConnectorForTesting = nil
    }
}

enum TCPConnector {
    static func connect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, "\(port)", &hints, &results)
        guard code == 0, let results else {
            throw CLIParseError.invalidValue("RSD TCP resolve failed for \(host):\(port): \(String(cString: gai_strerror(code)))")
        }
        defer { freeaddrinfo(results) }

        var cursor: UnsafeMutablePointer<addrinfo>? = results
        var lastErrno: Int32 = 0
        while let info = cursor {
            let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                setSocketNoSigPipe(fd)
                if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return fd
                }
                lastErrno = errno
                Darwin.close(fd)
            } else {
                lastErrno = errno
            }
            cursor = info.pointee.ai_next
        }
        throw CLIParseError.invalidValue("RSD TCP connect failed for \(host):\(port): errno \(lastErrno)")
    }
}

final class OwnedFDDeviceStream: DeviceStream {
    private let fd: Int32
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func write(_ data: Data) throws {
        try writeAll(fd: fd, data: data)
    }

    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while out.count < byteCount {
            let chunk = try readAvailable(maxBytes: byteCount - out.count, timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { throw CLIParseError.invalidValue("RSD TCP read timeout") }
            out.append(chunk)
        }
        return out
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        guard waitForReadable(fd: fd, timeoutSeconds: timeoutSeconds) else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = Darwin.read(fd, &buffer, maxBytes)
        if n > 0 { return Data(buffer.prefix(n)) }
        if n == 0 { throw CLIParseError.invalidValue("RSD TCP stream closed") }
        if errno == EINTR || errno == EAGAIN { return Data() }
        throw CLIParseError.invalidValue("RSD TCP read failed: errno \(errno)")
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

private struct RemoteXPCDataCursor {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int {
        data.count - offset
    }

    mutating func readUInt32LE() throws -> UInt32 {
        let bytes = try readBytes(4)
        let raw = [UInt8](bytes)
        return UInt32(raw[0])
            | (UInt32(raw[1]) << 8)
            | (UInt32(raw[2]) << 16)
            | (UInt32(raw[3]) << 24)
    }

    mutating func readUInt64LE() throws -> UInt64 {
        let bytes = try readBytes(8)
        let raw = [UInt8](bytes)
        return UInt64(raw[0])
            | (UInt64(raw[1]) << 8)
            | (UInt64(raw[2]) << 16)
            | (UInt64(raw[3]) << 24)
            | (UInt64(raw[4]) << 32)
            | (UInt64(raw[5]) << 40)
            | (UInt64(raw[6]) << 48)
            | (UInt64(raw[7]) << 56)
    }

    mutating func readLengthPrefixedCursor() throws -> RemoteXPCDataCursor {
        let size = Int(try readUInt32LE())
        return RemoteXPCDataCursor(try readBytes(size))
    }

    mutating func readLengthPrefixedAlignedString() throws -> String {
        let size = Int(try readUInt32LE())
        let raw = try readBytes(size)
        try align4()
        guard raw.last == 0 else {
            throw RemoteXPCError.invalidString
        }
        guard let value = String(data: raw.dropLast(), encoding: .utf8) else {
            throw RemoteXPCError.invalidString
        }
        return value
    }

    mutating func readLengthPrefixedAlignedData() throws -> Data {
        let size = Int(try readUInt32LE())
        let raw = try readBytes(size)
        try align4()
        return raw
    }

    mutating func readUUID() throws -> UUID {
        let raw = [UInt8](try readBytes(16))
        return UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3],
            raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11],
            raw[12], raw[13], raw[14], raw[15]
        ))
    }

    mutating func readAlignedCString() throws -> String {
        var bytes: [UInt8] = []
        while true {
            let byte = try readByte()
            if byte == 0 { break }
            bytes.append(byte)
        }
        try align4()
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw RemoteXPCError.invalidString
        }
        return value
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw RemoteXPCError.truncated
        }
        let byte = data[offset]
        offset += 1
        return byte
    }

    private mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else {
            throw RemoteXPCError.truncated
        }
        let out = Data(data[offset..<(offset + count)])
        offset += count
        return out
    }

    private mutating func align4() throws {
        let padding = (4 - (offset % 4)) % 4
        guard remaining >= padding else {
            throw RemoteXPCError.truncated
        }
        offset += padding
    }
}

private func encodeLengthPrefixedAlignedString(_ value: String) -> Data {
    encodeLengthPrefixedAlignedData(Data(value.utf8) + Data([0]))
}

private func encodeLengthPrefixedAlignedData(_ value: Data) -> Data {
    var data = Data()
    data.append(uint32LE(UInt32(value.count)))
    data.append(value)
    data.append(alignmentPadding(forCount: value.count))
    return data
}

private func encodeAlignedCString(_ value: String) -> Data {
    var data = Data(value.utf8)
    data.append(0)
    data.append(alignmentPadding(forCount: data.count))
    return data
}

private func uuidData(_ value: UUID) -> Data {
    var uuid = value.uuid
    return withUnsafeBytes(of: &uuid) { Data($0) }
}

private func alignmentPadding(forCount count: Int) -> Data {
    Data(repeating: 0, count: (4 - (count % 4)) % 4)
}

private func uint16BE(_ value: UInt16) -> Data {
    Data([
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ])
}
