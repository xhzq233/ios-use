import Foundation

enum DVTClientError: Error, CustomStringConvertible, Equatable {
    case invalidReply(String)

    var description: String {
        switch self {
        case .invalidReply(let detail):
            return "DVT invalid reply: \(detail)"
        }
    }
}

protocol DVTInvoking {
    func invoke(_ invocation: DVTInvocation) throws -> Any?
}

struct DTXDecodedMessage: Equatable {
    let identifier: UInt32
    let conversationIndex: UInt32
    let channelCode: Int32
    let kind: DTXMessageKind
    let transportFlags: UInt32
    let aux: Data
    let payload: Data
}

enum DTXMessageDecoder {
    static func readMessage(from stream: DeviceStream, timeoutSeconds: Double = 10) throws -> DTXDecodedMessage {
        let firstFragment = try readFragment(from: stream, timeoutSeconds: timeoutSeconds)
        guard firstFragment.index == 0 else {
            throw DVTClientError.invalidReply("DTX first fragment index was \(firstFragment.index)")
        }

        let body: Data
        if firstFragment.count == 1 {
            body = firstFragment.payload
        } else {
            body = try readMultiFragmentBody(
                firstFragment: firstFragment,
                from: stream,
                timeoutSeconds: timeoutSeconds
            )
        }
        return try decodeBody(body, fragment: firstFragment)
    }

    private static func readFragment(from stream: DeviceStream, timeoutSeconds: Double) throws -> DTXFragment {
        let header = try stream.readExact(byteCount: 32, timeoutSeconds: timeoutSeconds)
        guard readUInt32LE(header, 0) == 0x1f3d5b79 else {
            throw DVTClientError.invalidReply("DTX fragment magic mismatch")
        }
        let headerSize = Int(readUInt32LE(header, 4))
        guard headerSize >= 32 else {
            throw DVTClientError.invalidReply("DTX fragment header too small: \(headerSize)")
        }
        if headerSize > 32 {
            _ = try stream.readExact(byteCount: headerSize - 32, timeoutSeconds: timeoutSeconds)
        }
        let index = readUInt16LE(header, 8)
        let count = readUInt16LE(header, 10)
        guard count > 0, index < count else {
            throw DVTClientError.invalidReply("DTX invalid fragment index \(index) of \(count)")
        }
        let bodySize = Int(readUInt32LE(header, 12))
        guard bodySize > 0 else {
            throw DVTClientError.invalidReply("DTX fragment body size was zero")
        }
        let body: Data
        if index == 0, count > 1 {
            body = Data()
        } else {
            body = try stream.readExact(byteCount: bodySize, timeoutSeconds: timeoutSeconds)
        }
        return DTXFragment(
            index: index,
            count: count,
            dataSize: bodySize,
            identifier: readUInt32LE(header, 16),
            conversationIndex: readUInt32LE(header, 20),
            channelCode: Int32(bitPattern: readUInt32LE(header, 24)),
            transportFlags: readUInt32LE(header, 28),
            payload: body
        )
    }

    private static func readMultiFragmentBody(
        firstFragment: DTXFragment,
        from stream: DeviceStream,
        timeoutSeconds: Double
    ) throws -> Data {
        guard firstFragment.dataSize >= 16 else {
            throw DVTClientError.invalidReply("DTX body too small: \(firstFragment.dataSize)")
        }

        var body = Data()
        body.reserveCapacity(firstFragment.dataSize)

        for expectedIndex in 1..<Int(firstFragment.count) {
            let fragment = try readFragment(from: stream, timeoutSeconds: timeoutSeconds)
            guard Int(fragment.index) == expectedIndex else {
                throw DVTClientError.invalidReply("DTX fragment index \(fragment.index) did not match expected \(expectedIndex)")
            }
            guard fragment.count == firstFragment.count else {
                throw DVTClientError.invalidReply("DTX fragment count changed from \(firstFragment.count) to \(fragment.count)")
            }
            guard fragment.identifier == firstFragment.identifier,
                  fragment.conversationIndex == firstFragment.conversationIndex,
                  fragment.channelCode == firstFragment.channelCode,
                  fragment.transportFlags == firstFragment.transportFlags else {
                throw DVTClientError.invalidReply("DTX fragment metadata mismatch")
            }
            body.append(fragment.payload)
            guard body.count <= firstFragment.dataSize else {
                throw DVTClientError.invalidReply("DTX assembled body exceeded declared size \(firstFragment.dataSize)")
            }
        }

        guard body.count == firstFragment.dataSize else {
            throw DVTClientError.invalidReply("DTX assembled body size \(body.count) did not match declared \(firstFragment.dataSize)")
        }
        return body
    }

    private static func decodeBody(_ body: Data, fragment: DTXFragment) throws -> DTXDecodedMessage {
        guard body.count >= 16 else {
            throw DVTClientError.invalidReply("DTX body too small: \(body.count)")
        }
        guard let kind = DTXMessageKind(rawValue: body[0]) else {
            throw DVTClientError.invalidReply("unknown DTX message kind \(body[0])")
        }
        let auxSize = Int(readUInt32LE(body, 4))
        let totalSize = Int(readUInt32LE(body, 8))
        guard totalSize == body.count - 16, auxSize <= totalSize else {
            throw DVTClientError.invalidReply("DTX body size mismatch")
        }
        let auxStart = body.index(body.startIndex, offsetBy: 16)
        let payloadStart = body.index(auxStart, offsetBy: auxSize)
        return DTXDecodedMessage(
            identifier: fragment.identifier,
            conversationIndex: fragment.conversationIndex,
            channelCode: fragment.channelCode,
            kind: kind,
            transportFlags: fragment.transportFlags,
            aux: Data(body[auxStart..<payloadStart]),
            payload: Data(body[payloadStart..<body.endIndex])
        )
    }

    private struct DTXFragment {
        let index: UInt16
        let count: UInt16
        let dataSize: Int
        let identifier: UInt32
        let conversationIndex: UInt32
        let channelCode: Int32
        let transportFlags: UInt32
        let payload: Data
    }
}

final class DTXStreamTransport {
    private let stream: DeviceStream
    private var nextIdentifier: UInt32
    private let stateLock = NSLock()
    private let writeLock = NSLock()

    init(stream: DeviceStream, firstIdentifier: UInt32 = 1) {
        self.stream = stream
        self.nextIdentifier = firstIdentifier
    }

    func dispatch(channelCode: Int32, invocation: DVTInvocation) throws -> Any? {
        let identifier = reserveIdentifier()
        let message = try DTXMessageEncoder.dispatch(
            identifier: identifier,
            channelCode: channelCode,
            selector: invocation.selector,
            arguments: invocation.arguments,
            expectsReply: invocation.expectsReply
        )
        try write(message.wireData)
        guard invocation.expectsReply else {
            return nil
        }

        let reply = try readReply(for: identifier)
        guard reply.identifier == identifier else {
            throw DVTClientError.invalidReply("reply identifier \(reply.identifier) did not match request \(identifier)")
        }
        switch reply.kind {
        case .ok:
            return nil
        case .object:
            return try DTXStreamTransport.unarchivePayload(reply.payload)
        case .error:
            if let error = try DTXStreamTransport.unarchivePayload(reply.payload) {
                throw DVTClientError.invalidReply("remote error: \(error)")
            }
            throw DVTClientError.invalidReply("remote error with empty payload")
        default:
            throw DVTClientError.invalidReply("unexpected reply kind \(reply.kind)")
        }
    }

    func readMessage(timeoutSeconds: Double = 10) throws -> DTXDecodedMessage {
        try DTXMessageDecoder.readMessage(from: stream, timeoutSeconds: timeoutSeconds)
    }

    func sendRawObjectReply(to message: DTXDecodedMessage, payload: Data = Data()) throws {
        let reply = try DTXMessageEncoder.rawObjectReply(
            identifier: message.identifier,
            conversationIndex: message.conversationIndex + 1,
            channelCode: message.channelCode,
            payload: payload
        )
        try write(reply.wireData)
    }

    private func readReply(for identifier: UInt32) throws -> DTXDecodedMessage {
        while true {
            let message = try readMessage()
            if try handleIncomingDispatch(message) {
                continue
            }
            if message.identifier == identifier, message.conversationIndex != 0 {
                return message
            }
            throw DVTClientError.invalidReply("received unrelated DTX message id \(message.identifier) while waiting for \(identifier)")
        }
    }

    private func handleIncomingDispatch(_ message: DTXDecodedMessage) throws -> Bool {
        guard message.kind == .dispatch else {
            return false
        }
        let selector = try Self.unarchivePayload(message.payload) as? String
        if message.channelCode == DVTInstrumentsContract.Control.channelCode,
           selector == "_notifyOfPublishedCapabilities:" {
            if message.transportFlags & DTXTransportFlag.expectsReply != 0 {
                let ack = try DTXMessageEncoder.okReply(
                    identifier: message.identifier,
                    conversationIndex: message.conversationIndex + 1,
                    channelCode: message.channelCode
                )
                try write(ack.wireData)
            }
            return true
        }

        if message.transportFlags & DTXTransportFlag.expectsReply != 0 {
            try sendRawObjectReply(to: message)
        }
        return true
    }

    static func unarchivePayload(_ data: Data) throws -> Any? {
        guard !data.isEmpty else { return nil }
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    }

    private func reserveIdentifier() -> UInt32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let identifier = nextIdentifier
        nextIdentifier += 1
        return identifier
    }

    private func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try stream.write(data)
    }
}

final class DTXStreamInvoker: DVTInvoking {
    private let transport: DTXStreamTransport
    private let channelCode: Int32

    init(stream: DeviceStream, channelCode: Int32, firstIdentifier: UInt32 = 1) {
        self.transport = DTXStreamTransport(stream: stream, firstIdentifier: firstIdentifier)
        self.channelCode = channelCode
    }

    init(transport: DTXStreamTransport, channelCode: Int32) {
        self.transport = transport
        self.channelCode = channelCode
    }

    func invoke(_ invocation: DVTInvocation) throws -> Any? {
        try transport.dispatch(channelCode: channelCode, invocation: invocation)
    }
}

final class DTXControlChannelClient {
    private let transport: DTXStreamTransport

    init(stream: DeviceStream, firstIdentifier: UInt32 = 1) {
        self.transport = DTXStreamTransport(stream: stream, firstIdentifier: firstIdentifier)
    }

    init(transport: DTXStreamTransport) {
        self.transport = transport
    }

    func notifyCapabilities(_ capabilities: [String: Int] = DVTInstrumentsContract.Provider.capabilities) throws {
        _ = try transport.dispatch(
            channelCode: DVTInstrumentsContract.Control.channelCode,
            invocation: DVTInstrumentsContract.Control.notifyCapabilities(capabilities)
        )
    }

    @discardableResult
    func requestChannel(code: Int32, identifier: String) throws -> Any? {
        try transport.dispatch(
            channelCode: DVTInstrumentsContract.Control.channelCode,
            invocation: DVTInstrumentsContract.Control.requestChannel(code: code, identifier: identifier)
        )
    }

    @discardableResult
    func cancelChannel(code: Int32) throws -> Any? {
        try transport.dispatch(
            channelCode: DVTInstrumentsContract.Control.channelCode,
            invocation: DVTInstrumentsContract.Control.cancelChannel(code: code)
        )
    }

    func invoker(channelCode: Int32) -> DTXStreamInvoker {
        DTXStreamInvoker(transport: transport, channelCode: channelCode)
    }

    func channel(code: Int32) -> DTXChannelClient {
        DTXChannelClient(transport: transport, channelCode: code)
    }
}

final class DTXChannelClient: DVTInvoking {
    let channelCode: Int32
    private let transport: DTXStreamTransport

    init(transport: DTXStreamTransport, channelCode: Int32) {
        self.transport = transport
        self.channelCode = channelCode
    }

    func invoke(_ invocation: DVTInvocation) throws -> Any? {
        try transport.dispatch(channelCode: channelCode, invocation: invocation)
    }

    func readMessage(timeoutSeconds: Double = 10) throws -> DTXDecodedMessage {
        try transport.readMessage(timeoutSeconds: timeoutSeconds)
    }

    func sendRawObjectReply(to message: DTXDecodedMessage, payload: Data = Data()) throws {
        try transport.sendRawObjectReply(to: message, payload: payload)
    }

    func siblingChannel(code: Int32) -> DTXChannelClient {
        DTXChannelClient(transport: transport, channelCode: code)
    }
}

final class XCTestManagerDaemonClient {
    let channel: DTXChannelClient?
    private let invoker: DVTInvoking

    init(channel: DTXChannelClient) {
        self.channel = channel
        self.invoker = channel
    }

    init(invoker: DVTInvoking) {
        self.channel = nil
        self.invoker = invoker
    }

    func initiateControlSession(productMajorVersion: Int) throws -> Any? {
        guard let invocation = try DVTInstrumentsContract.XCTestManagerDaemon.initiateControlSession(productMajorVersion: productMajorVersion) else {
            return nil
        }
        return try invoker.invoke(invocation)
    }

    func authorizeTestSession(productMajorVersion: Int, pid: Int) throws -> Bool {
        let reply = try invoker.invoke(DVTInstrumentsContract.XCTestManagerDaemon.authorizeTestSession(
            productMajorVersion: productMajorVersion,
            pid: pid
        ))
        if let value = reply as? Bool {
            return value
        }
        if let value = reply as? NSNumber {
            return value.boolValue
        }
        throw DVTClientError.invalidReply("authorize test session expected boolean, got \(String(describing: reply))")
    }

    func initiateExecSession(sessionIdentifier: UUID) throws {
        _ = try invoker.invoke(DVTInstrumentsContract.XCTestManagerDaemon.initiateSession(sessionIdentifier: sessionIdentifier))
    }

    func startExecutingTestPlan() throws {
        let target = channel?.siblingChannel(code: -1) ?? invoker
        _ = try target.invoke(DVTInstrumentsContract.XCTestManagerDaemon.startExecutingTestPlan())
    }
}

private func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
    let bytes = [UInt8](data)
    return UInt16(bytes[offset])
        | (UInt16(bytes[offset + 1]) << 8)
}
