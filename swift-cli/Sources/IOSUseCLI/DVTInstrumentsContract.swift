import Foundation

enum DTXMessageKind: UInt8 {
    case ok = 0
    case data = 1
    case dispatch = 2
    case object = 3
    case error = 4
}

enum DTXTransportFlag {
    static let expectsReply: UInt32 = 1
}

enum DTXAuxArgument: Equatable {
    case primitiveString(String)
    case primitiveBuffer(Data)
    case primitiveInt32(Int32)
    case primitiveInt64(Int64)
    case primitiveDouble(Double)

    static func emptyBuffer() -> DTXAuxArgument {
        .primitiveBuffer(Data())
    }

    static func archived(_ object: Any) throws -> DTXAuxArgument {
        let bridged = bridgeForArchiver(object)
        let data = try NSKeyedArchiver.archivedData(withRootObject: bridged, requiringSecureCoding: false)
        return .primitiveBuffer(data)
    }

    private static func bridgeForArchiver(_ object: Any) -> Any {
        switch object {
        case let value as String:
            return value as NSString
        case let value as Bool:
            return NSNumber(value: value)
        case let value as Int:
            return NSNumber(value: value)
        case let value as Int32:
            return NSNumber(value: value)
        case let value as Int64:
            return NSNumber(value: value)
        case let value as UInt:
            return NSNumber(value: value)
        case let value as UInt32:
            return NSNumber(value: value)
        case let value as UInt64:
            return NSNumber(value: value)
        case let value as Double:
            return NSNumber(value: value)
        case let value as Float:
            return NSNumber(value: value)
        case let value as [Any]:
            return value.map(bridgeForArchiver) as NSArray
        case let value as [String: Any]:
            let bridged = NSMutableDictionary()
            for (key, entry) in value {
                bridged[key] = bridgeForArchiver(entry)
            }
            return bridged
        default:
            return object
        }
    }
}

enum DTXPrimitiveDictionary {
    private static let dictionaryMagic: UInt32 = 0x1f0
    private static let nullType: UInt32 = 10
    private static let stringType: UInt32 = 1
    private static let bufferType: UInt32 = 2
    private static let int32Type: UInt32 = 3
    private static let int64Type: UInt32 = 6
    private static let doubleType: UInt32 = 9

    static func encodeAux(_ arguments: [DTXAuxArgument]) -> Data {
        guard !arguments.isEmpty else { return Data() }

        var body = Data()
        for argument in arguments {
            body.append(uint32LE(nullType))
            body.append(encodePrimitive(argument))
        }

        var data = Data()
        data.append(uint32LE(dictionaryMagic))
        data.append(uint32LE(0))
        data.append(uint64LE(UInt64(body.count)))
        data.append(body)
        return data
    }

    private static func encodePrimitive(_ argument: DTXAuxArgument) -> Data {
        var data = Data()
        switch argument {
        case .primitiveString(let value):
            let raw = Data(value.utf8)
            data.append(uint32LE(stringType))
            data.append(uint32LE(UInt32(raw.count)))
            data.append(raw)
        case .primitiveBuffer(let value):
            data.append(uint32LE(bufferType))
            data.append(uint32LE(UInt32(value.count)))
            data.append(value)
        case .primitiveInt32(let value):
            data.append(uint32LE(int32Type))
            data.append(uint32LE(UInt32(bitPattern: value)))
        case .primitiveInt64(let value):
            data.append(uint32LE(int64Type))
            data.append(uint64LE(UInt64(bitPattern: value)))
        case .primitiveDouble(let value):
            data.append(uint32LE(doubleType))
            data.append(uint64LE(value.bitPattern))
        }
        return data
    }
}

struct DTXEncodedMessage: Equatable {
    let identifier: UInt32
    let conversationIndex: UInt32
    let channelCode: Int32
    let kind: DTXMessageKind
    let transportFlags: UInt32
    let aux: Data
    let payload: Data
    let wireData: Data
}

enum DTXMessageEncoder {
    private static let fragmentMagic: UInt32 = 0x1f3d5b79
    private static let fragmentHeaderSize: UInt32 = 32

    static func dispatch(
        identifier: UInt32,
        channelCode: Int32,
        selector: String,
        arguments: [DTXAuxArgument],
        expectsReply: Bool = true
    ) throws -> DTXEncodedMessage {
        try encode(
            identifier: identifier,
            conversationIndex: 0,
            channelCode: channelCode,
            kind: .dispatch,
            transportFlags: expectsReply ? DTXTransportFlag.expectsReply : 0,
            payload: archive(selector),
            aux: DTXPrimitiveDictionary.encodeAux(arguments)
        )
    }

    static func objectReply(
        identifier: UInt32,
        conversationIndex: UInt32,
        channelCode: Int32,
        object: Any
    ) throws -> DTXEncodedMessage {
        try encode(
            identifier: identifier,
            conversationIndex: conversationIndex,
            channelCode: channelCode,
            kind: .object,
            transportFlags: 0,
            payload: archive(object),
            aux: Data()
        )
    }

    static func okReply(
        identifier: UInt32,
        conversationIndex: UInt32,
        channelCode: Int32
    ) throws -> DTXEncodedMessage {
        try encode(
            identifier: identifier,
            conversationIndex: conversationIndex,
            channelCode: channelCode,
            kind: .ok,
            transportFlags: 0,
            payload: Data(),
            aux: Data()
        )
    }

    private static func encode(
        identifier: UInt32,
        conversationIndex: UInt32,
        channelCode: Int32,
        kind: DTXMessageKind,
        transportFlags: UInt32,
        payload: Data,
        aux: Data
    ) throws -> DTXEncodedMessage {
        var messageBody = Data()
        messageBody.append(kind.rawValue)
        messageBody.append(contentsOf: [0, 0, 0])
        messageBody.append(uint32LE(UInt32(aux.count)))
        messageBody.append(uint32LE(UInt32(aux.count + payload.count)))
        messageBody.append(uint32LE(0))
        messageBody.append(aux)
        messageBody.append(payload)

        var wire = Data()
        wire.append(uint32LE(fragmentMagic))
        wire.append(uint32LE(fragmentHeaderSize))
        wire.append(uint16LE(0))
        wire.append(uint16LE(1))
        wire.append(uint32LE(UInt32(messageBody.count)))
        wire.append(uint32LE(identifier))
        wire.append(uint32LE(conversationIndex))
        wire.append(uint32LE(UInt32(bitPattern: channelCode)))
        wire.append(uint32LE(transportFlags))
        wire.append(messageBody)

        return DTXEncodedMessage(
            identifier: identifier,
            conversationIndex: conversationIndex,
            channelCode: channelCode,
            kind: kind,
            transportFlags: transportFlags,
            aux: aux,
            payload: payload,
            wireData: wire
        )
    }

    private static func archive(_ object: Any) throws -> Data {
        guard case .primitiveBuffer(let data) = try DTXAuxArgument.archived(object) else {
            preconditionFailure("archived object should always return primitive buffer")
        }
        return data
    }
}

struct DVTInvocation: Equatable {
    let serviceIdentifier: String
    let selector: String
    let arguments: [DTXAuxArgument]
    let expectsReply: Bool
}

enum DVTInstrumentsContract {
    enum Provider {
        static let secureServiceName = "com.apple.instruments.remoteserver.DVTSecureSocketProxy"
        static let rsdServiceName = "com.apple.instruments.dtservicehub"
        static let oldServiceName = "com.apple.instruments.remoteserver"
        static let terminationCallbackCapability = "com.apple.instruments.client.processcontrol.capability.terminationCallback"

        static let capabilities: [String: Int] = [
            "com.apple.private.DTXBlockCompression": 0,
            "com.apple.private.DTXConnection": 1,
            terminationCallbackCapability: 1,
        ]
    }

    enum Control {
        static let serviceIdentifier = "DTXControl"
        static let channelCode: Int32 = 0

        static func notifyCapabilities(_ capabilities: [String: Int] = Provider.capabilities) throws -> DVTInvocation {
            try DVTInvocation(
                serviceIdentifier: serviceIdentifier,
                selector: "_notifyOfPublishedCapabilities:",
                arguments: [.archived(capabilities)],
                expectsReply: false
            )
        }

        static func requestChannel(code: Int32, identifier: String) throws -> DVTInvocation {
            try DVTInvocation(
                serviceIdentifier: serviceIdentifier,
                selector: "_requestChannelWithCode:identifier:",
                arguments: [.primitiveInt32(code), .archived(identifier)],
                expectsReply: true
            )
        }

        static func cancelChannel(code: Int32) -> DVTInvocation {
            DVTInvocation(
                serviceIdentifier: serviceIdentifier,
                selector: "_channelCanceled:",
                arguments: [.primitiveInt32(code)],
                expectsReply: true
            )
        }
    }

    enum XCTestManagerDaemon {
        static let secureServiceName = "com.apple.testmanagerd.lockdown.secure"
        static let rsdServiceName = "com.apple.dt.testmanagerd.remote"
        static let oldServiceName = "com.apple.testmanagerd.lockdown"
        static let ideServiceIdentifier = "XCTestManager_IDEInterface"
        static let serviceIdentifier = "XCTestManager_DaemonConnectionInterface"
        static let xcodeVersion = 36

        static var proxyServiceIdentifier: String {
            "dtxproxy:\(ideServiceIdentifier):\(serviceIdentifier)"
        }

        static func initiateControlSession(productMajorVersion: Int) throws -> DVTInvocation? {
            if productMajorVersion >= 17 {
                return try DVTInvocation(
                    serviceIdentifier: serviceIdentifier,
                    selector: "_IDE_initiateControlSessionWithCapabilities:",
                    arguments: [.archived([String: Any]())],
                    expectsReply: true
                )
            }
            if productMajorVersion >= 11 {
                return try DVTInvocation(
                    serviceIdentifier: serviceIdentifier,
                    selector: "_IDE_initiateControlSessionWithProtocolVersion:",
                    arguments: [.archived(xcodeVersion)],
                    expectsReply: true
                )
            }
            return nil
        }

        static func authorizeTestSession(productMajorVersion: Int, pid: Int) throws -> DVTInvocation {
            if productMajorVersion >= 12 {
                return try DVTInvocation(
                    serviceIdentifier: serviceIdentifier,
                    selector: "_IDE_authorizeTestSessionWithProcessID:",
                    arguments: [.archived(pid)],
                    expectsReply: true
                )
            }
            if productMajorVersion >= 10 {
                return try DVTInvocation(
                    serviceIdentifier: serviceIdentifier,
                    selector: "_IDE_initiateControlSessionForTestProcessID:protocolVersion:",
                    arguments: [.archived(pid), .archived(xcodeVersion)],
                    expectsReply: true
                )
            }
            return try DVTInvocation(
                serviceIdentifier: serviceIdentifier,
                selector: "_IDE_initiateControlSessionForTestProcessID:",
                arguments: [.archived(pid)],
                expectsReply: true
            )
        }
    }
}

private func uint16LE(_ value: UInt16) -> Data {
    Data([
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
    ])
}
