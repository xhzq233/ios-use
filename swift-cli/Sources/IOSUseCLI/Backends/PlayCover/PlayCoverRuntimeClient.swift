import Darwin
import Foundation

enum PlayCoverRuntimeCommand: String, Codable, Sendable {
    case hello
    case ping
    case diagnostics
    case screenshot
    case dom
    case waitFor
}

indirect enum PlayCoverRuntimeJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PlayCoverRuntimeJSONValue])
    case object([String: PlayCoverRuntimeJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PlayCoverRuntimeJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PlayCoverRuntimeJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported diagnostics JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

struct PlayCoverRuntimeResponsePayload: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let pid: Int32
    let bundleIdentifier: String
    let profileHash: String
    let preparedGenerationID: String
    let runtimeSocketPath: String
    let runtimeInstanceID: String
    let launchNonce: String
    let capabilities: [String]
    let logicalWidth: Double
    let logicalHeight: Double
    let nativeWidth: Double
    let nativeHeight: Double
    let scale: Double
    let windowWidth: Double?
    let windowHeight: Double?
    let stage: String
    let observed: [String: PlayCoverRuntimeJSONValue]?
    let diagnostics: [String: PlayCoverRuntimeJSONValue]?
    let screenshot: PlayCoverRuntimeScreenshotPayload?
    let dom: PlayCoverRuntimeDOMPayload?
    let waitFor: PlayCoverRuntimeWaitForPayload?

    init(
        protocolVersion: Int,
        pid: Int32,
        bundleIdentifier: String,
        profileHash: String,
        preparedGenerationID: String,
        runtimeSocketPath: String,
        runtimeInstanceID: String,
        launchNonce: String,
        capabilities: [String],
        logicalWidth: Double,
        logicalHeight: Double,
        nativeWidth: Double,
        nativeHeight: Double,
        scale: Double,
        windowWidth: Double?,
        windowHeight: Double?,
        stage: String,
        observed: [String: PlayCoverRuntimeJSONValue]?,
        diagnostics: [String: PlayCoverRuntimeJSONValue]?,
        screenshot: PlayCoverRuntimeScreenshotPayload? = nil,
        dom: PlayCoverRuntimeDOMPayload? = nil,
        waitFor: PlayCoverRuntimeWaitForPayload? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.profileHash = profileHash
        self.preparedGenerationID = preparedGenerationID
        self.runtimeSocketPath = runtimeSocketPath
        self.runtimeInstanceID = runtimeInstanceID
        self.launchNonce = launchNonce
        self.capabilities = capabilities
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.scale = scale
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.stage = stage
        self.observed = observed
        self.diagnostics = diagnostics
        self.screenshot = screenshot
        self.dom = dom
        self.waitFor = waitFor
    }
}

struct PlayCoverRuntimeScreenshotPayload: Codable, Equatable, Sendable {
    let jpegBase64: String
    let pixelWidth: Int
    let pixelHeight: Int
    let logicalWidth: Double
    let logicalHeight: Double
    let scale: Double
    let source: String
    let complete: Bool
}

struct PlayCoverRuntimeDOMArguments: Codable, Equatable, Sendable {
    let raw: Bool
    let fresh: Bool
    let waitQuiescence: Bool
}

struct PlayCoverRuntimeWaitTarget: Codable, Equatable, Sendable {
    let label: String
    let traits: String
    let cindex: Int32?
}

struct PlayCoverRuntimeWaitForArguments: Codable, Equatable, Sendable {
    let target: PlayCoverRuntimeWaitTarget
    let timeout: Double
    let gone: Bool
    let matchMode: Int32
}

enum PlayCoverRuntimeRequestArguments: Encodable, Equatable, Sendable {
    case dom(PlayCoverRuntimeDOMArguments)
    case waitFor(PlayCoverRuntimeWaitForArguments)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .dom(let arguments):
            try arguments.encode(to: encoder)
        case .waitFor(let arguments):
            try arguments.encode(to: encoder)
        }
    }
}

struct PlayCoverRuntimeRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct PlayCoverRuntimeDOMElement: Codable, Equatable, Sendable {
    let nodeId: String
    let elemType: Int32
    let traits: [String]
    let childCount: Int32
    let label: String
    let value: String
    let rect: PlayCoverRuntimeRect?
}

struct PlayCoverRuntimeDOMPayload: Codable, Equatable, Sendable {
    let app: String
    let windowSize: PlayCoverRuntimePoint
    let raw: String
    let snapshotGeneration: Int64
    let elements: [PlayCoverRuntimeDOMElement]
}

struct PlayCoverRuntimePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct PlayCoverRuntimeElementSummary: Codable, Equatable, Sendable {
    let elemType: Int32
    let label: String
    let rect: PlayCoverRuntimeRect?
    let ancestors: [String]
}

struct PlayCoverRuntimeWaitForPayload: Codable, Equatable, Sendable {
    let element: PlayCoverRuntimeElementSummary
    let waited: Double
    let snapshotGeneration: Int64
}

struct PlayCoverRuntimeErrorElement: Codable, Equatable, Sendable {
    let elemType: Int32
    let label: String
    let rect: PlayCoverRuntimeRect?
    let traits: [String]
    let value: String
    let ancestors: [String]
}

struct PlayCoverRuntimeErrorCandidate: Codable, Equatable, Sendable {
    let element: PlayCoverRuntimeErrorElement
    let rejectedBy: [String]
}

struct PlayCoverRuntimeErrorDetails: Codable, Equatable, Sendable {
    let category: String
    let phase: String
    let retryable: Bool
    let fatal: Bool
    let target: PlayCoverRuntimeWaitTarget?
    let candidateCount: Int32
    let candidates: [PlayCoverRuntimeErrorCandidate]
    let suggestions: [String]
}

enum PlayCoverRuntimeSocketPathError: Equatable, Sendable {
    case empty
    case containsNUL
    case tooLong(actualUTF8Bytes: Int, maximumUTF8Bytes: Int)
}

enum PlayCoverRuntimeClientError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidSocketPath(PlayCoverRuntimeSocketPathError)
    case invalidTimeout
    case socketCreateFailed(errno: Int32)
    case socketOptionFailed(option: String, errno: Int32)
    case connectFailed(errno: Int32)
    case peerCredentialFailed(errno: Int32)
    case peerUIDMismatch(expected: uid_t, actual: uid_t)
    case requestEncodingFailed
    case requestFrameTooLarge(actualBytes: Int, maximumBytes: Int)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case timeout(operation: String)
    case unexpectedEOF(operation: String, expectedBytes: Int, receivedBytes: Int)
    case emptyResponseFrame
    case responseFrameTooLarge(actualBytes: Int, maximumBytes: Int)
    case responseIsNotUTF8
    case responseDecodingFailed
    case unsupportedSchemaVersion(Int)
    case requestIDMismatch
    case launchNonceMismatch
    case malformedResponse(String)
    case remoteError(
        code: String,
        message: String,
        details: PlayCoverRuntimeErrorDetails?
    )

    var description: String {
        switch self {
        case .invalidSocketPath(.empty):
            return "PlayCover runtime socket path is empty"
        case .invalidSocketPath(.containsNUL):
            return "PlayCover runtime socket path contains a NUL byte"
        case .invalidSocketPath(.tooLong(let actual, let maximum)):
            return "PlayCover runtime socket path is too long: \(actual) UTF-8 bytes, maximum \(maximum)"
        case .invalidTimeout:
            return "PlayCover runtime socket timeout must be finite and greater than zero"
        case .socketCreateFailed(let code):
            return "PlayCover runtime Unix socket creation failed: errno \(code)"
        case .socketOptionFailed(let option, let code):
            return "PlayCover runtime Unix socket option \(option) failed: errno \(code)"
        case .connectFailed(let code):
            return "PlayCover runtime Unix socket connect failed: errno \(code)"
        case .peerCredentialFailed(let code):
            return "PlayCover runtime Unix peer credential lookup failed: errno \(code)"
        case .peerUIDMismatch(let expected, let actual):
            return "PlayCover runtime Unix peer UID mismatch: expected \(expected), received \(actual)"
        case .requestEncodingFailed:
            return "PlayCover runtime request JSON encoding failed"
        case .requestFrameTooLarge(let actual, let maximum):
            return "PlayCover runtime request frame is too large: \(actual) bytes, maximum \(maximum)"
        case .writeFailed(let code):
            return "PlayCover runtime Unix socket write failed: errno \(code)"
        case .readFailed(let code):
            return "PlayCover runtime Unix socket read failed: errno \(code)"
        case .timeout(let operation):
            return "PlayCover runtime Unix socket \(operation) timed out"
        case .unexpectedEOF(let operation, let expected, let received):
            return "PlayCover runtime Unix socket closed during \(operation): expected \(expected) bytes, received \(received)"
        case .emptyResponseFrame:
            return "PlayCover runtime response frame body is empty"
        case .responseFrameTooLarge(let actual, let maximum):
            return "PlayCover runtime response frame is too large: \(actual) bytes, maximum \(maximum)"
        case .responseIsNotUTF8:
            return "PlayCover runtime response is not valid UTF-8"
        case .responseDecodingFailed:
            return "PlayCover runtime response is not valid protocol JSON"
        case .unsupportedSchemaVersion(let version):
            return "unsupported PlayCover runtime response schemaVersion \(version)"
        case .requestIDMismatch:
            return "PlayCover runtime response requestId does not match the request"
        case .launchNonceMismatch:
            return "PlayCover runtime response launch nonce does not match the session"
        case .malformedResponse(let reason):
            return "malformed PlayCover runtime response: \(reason)"
        case .remoteError(let code, let message, _):
            return "PlayCover runtime error \(code): \(message)"
        }
    }
}

/// One-request-per-connection client for the injected PlayCover runtime.
///
/// The transport is intentionally Unix-domain-only. Every request creates a
/// fresh AF_UNIX/SOCK_STREAM connection, authenticates the peer UID, exchanges
/// exactly one bounded JSON frame, and closes the connection.
final class PlayCoverRuntimeClient {
    static let schemaVersion = 1
    static let maximumRequestBodyBytes = 64 * 1024
    static let maximumResponseBodyBytes = 16 * 1024 * 1024
    static let defaultTimeoutSeconds: TimeInterval = 5
    static let screenshotTimeoutSeconds: TimeInterval = 15

    private let socketPath: String
    private let launchNonce: String
    private let timeoutSeconds: TimeInterval

    init(socketPath: String, launchNonce: String) {
        self.socketPath = socketPath
        self.launchNonce = launchNonce
        self.timeoutSeconds = Self.defaultTimeoutSeconds
    }

    init(
        socketPath: String,
        launchNonce: String,
        timeoutSeconds: TimeInterval
    ) {
        self.socketPath = socketPath
        self.launchNonce = launchNonce
        self.timeoutSeconds = timeoutSeconds
    }

    func hello() throws -> PlayCoverRuntimeResponsePayload {
        try request(.hello)
    }

    func ping() throws -> PlayCoverRuntimeResponsePayload {
        try request(.ping)
    }

    func diagnostics() throws -> PlayCoverRuntimeResponsePayload {
        try request(.diagnostics)
    }

    func screenshot() throws -> PlayCoverRuntimeResponsePayload {
        try request(.screenshot)
    }

    func dom(
        _ arguments: PlayCoverRuntimeDOMArguments
    ) throws -> PlayCoverRuntimeResponsePayload {
        try request(.dom, arguments: .dom(arguments))
    }

    func waitFor(
        _ arguments: PlayCoverRuntimeWaitForArguments
    ) throws -> PlayCoverRuntimeResponsePayload {
        try request(.waitFor, arguments: .waitFor(arguments))
    }

    func request(_ command: PlayCoverRuntimeCommand) throws -> PlayCoverRuntimeResponsePayload {
        try request(command, arguments: nil)
    }

    private func request(
        _ command: PlayCoverRuntimeCommand,
        arguments: PlayCoverRuntimeRequestArguments?
    ) throws -> PlayCoverRuntimeResponsePayload {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw PlayCoverRuntimeClientError.invalidTimeout
        }
        let address = try makeAddress()
        let requestID = UUID().uuidString
        let request = RequestEnvelope(
            schemaVersion: Self.schemaVersion,
            requestId: requestID,
            command: command,
            launchNonce: launchNonce,
            arguments: arguments
        )

        let requestBody: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            requestBody = try encoder.encode(request)
        } catch {
            throw PlayCoverRuntimeClientError.requestEncodingFailed
        }
        guard !requestBody.isEmpty,
              requestBody.count <= Self.maximumRequestBodyBytes else {
            throw PlayCoverRuntimeClientError.requestFrameTooLarge(
                actualBytes: requestBody.count,
                maximumBytes: Self.maximumRequestBodyBytes
            )
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PlayCoverRuntimeClientError.socketCreateFailed(errno: errno)
        }
        defer { Darwin.close(descriptor) }

        let deadline =
            ProcessInfo.processInfo.systemUptime + timeoutSeconds
        try configure(descriptor)
        try connect(descriptor, to: address, deadline: deadline)
        try authenticatePeer(descriptor)
        try writeFrame(requestBody, to: descriptor, deadline: deadline)
        let responseBody = try readFrame(
            from: descriptor,
            deadline: deadline
        )
        return try decodeResponse(responseBody, expectedRequestID: requestID)
    }

    private func makeAddress() throws -> sockaddr_un {
        guard !socketPath.isEmpty else {
            throw PlayCoverRuntimeClientError.invalidSocketPath(.empty)
        }
        let pathBytes = Array(socketPath.utf8)
        guard !pathBytes.contains(0) else {
            throw PlayCoverRuntimeClientError.invalidSocketPath(.containsNUL)
        }

        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count + 1 <= capacity else {
            throw PlayCoverRuntimeClientError.invalidSocketPath(
                .tooLong(
                    actualUTF8Bytes: pathBytes.count,
                    maximumUTF8Bytes: capacity - 1
                )
            )
        }

        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        return address
    }

    private func configure(_ descriptor: Int32) throws {
        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw PlayCoverRuntimeClientError.socketOptionFailed(
                option: "FD_CLOEXEC",
                errno: errno
            )
        }
        var enabled: Int32 = 1
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw PlayCoverRuntimeClientError.socketOptionFailed(
                option: "SO_NOSIGPIPE",
                errno: errno
            )
        }

        let wholeSeconds = floor(timeoutSeconds)
        let fractionalMicroseconds = (timeoutSeconds - wholeSeconds) * 1_000_000
        var timeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32(
                max(
                    wholeSeconds == 0 ? 1 : 0,
                    fractionalMicroseconds.rounded(.down)
                )
            )
        )
        for (option, name) in [(SO_SNDTIMEO, "SO_SNDTIMEO"), (SO_RCVTIMEO, "SO_RCVTIMEO")] {
            guard Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw PlayCoverRuntimeClientError.socketOptionFailed(
                    option: name,
                    errno: errno
                )
            }
        }
    }

    private func connect(
        _ descriptor: Int32,
        to address: sockaddr_un,
        deadline: TimeInterval
    ) throws {
        let originalFlags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard originalFlags >= 0 else {
            throw PlayCoverRuntimeClientError.socketOptionFailed(
                option: "F_GETFL",
                errno: errno
            )
        }
        guard Darwin.fcntl(
            descriptor,
            F_SETFL,
            originalFlags | O_NONBLOCK
        ) == 0 else {
            throw PlayCoverRuntimeClientError.socketOptionFailed(
                option: "F_SETFL(O_NONBLOCK)",
                errno: errno
            )
        }

        var mutableAddress = address
        let result = withUnsafePointer(to: &mutableAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        var connectError: PlayCoverRuntimeClientError?
        if result != 0 {
            let code = errno
            if code == EINPROGRESS || code == EAGAIN ||
                code == EWOULDBLOCK || code == EINTR {
                do {
                    try waitForConnect(descriptor, deadline: deadline)
                } catch let error as PlayCoverRuntimeClientError {
                    connectError = error
                } catch {
                    connectError = .connectFailed(errno: EIO)
                }
            } else {
                connectError = .connectFailed(errno: code)
            }
        }

        if let connectError {
            throw connectError
        }
    }

    private func waitForConnect(
        _ descriptor: Int32,
        deadline: TimeInterval
    ) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw PlayCoverRuntimeClientError.timeout(operation: "connect")
            }
            let milliseconds = Int32(
                min(
                    Double(Int32.max),
                    ceil(remaining * 1_000)
                )
            )
            var state = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let result = Darwin.poll(&state, 1, milliseconds)
            if result == 0 {
                throw PlayCoverRuntimeClientError.timeout(operation: "connect")
            }
            if result < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                throw PlayCoverRuntimeClientError.connectFailed(errno: code)
            }

            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &size
            ) == 0 else {
                throw PlayCoverRuntimeClientError.socketOptionFailed(
                    option: "SO_ERROR",
                    errno: errno
                )
            }
            guard socketError == 0 else {
                throw PlayCoverRuntimeClientError.connectFailed(
                    errno: socketError
                )
            }
            return
        }
    }

    private func authenticatePeer(_ descriptor: Int32) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard Darwin.getpeereid(descriptor, &peerUID, &peerGID) == 0 else {
            throw PlayCoverRuntimeClientError.peerCredentialFailed(errno: errno)
        }
        let expectedUID = Darwin.geteuid()
        guard peerUID == expectedUID else {
            throw PlayCoverRuntimeClientError.peerUIDMismatch(
                expected: expectedUID,
                actual: peerUID
            )
        }
    }

    private func writeFrame(
        _ body: Data,
        to descriptor: Int32,
        deadline: TimeInterval
    ) throws {
        var length = UInt32(body.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(
            header,
            to: descriptor,
            operation: "request header write",
            deadline: deadline
        )
        try writeAll(
            body,
            to: descriptor,
            operation: "request body write",
            deadline: deadline
        )
    }

    private func readFrame(
        from descriptor: Int32,
        deadline: TimeInterval
    ) throws -> Data {
        let header = try readExactly(
            byteCount: MemoryLayout<UInt32>.size,
            from: descriptor,
            operation: "response header read",
            deadline: deadline
        )
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else {
            throw PlayCoverRuntimeClientError.emptyResponseFrame
        }
        guard length <= UInt32(Self.maximumResponseBodyBytes) else {
            throw PlayCoverRuntimeClientError.responseFrameTooLarge(
                actualBytes: Int(length),
                maximumBytes: Self.maximumResponseBodyBytes
            )
        }
        return try readExactly(
            byteCount: Int(length),
            from: descriptor,
            operation: "response body read",
            deadline: deadline
        )
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        operation: String,
        deadline: TimeInterval
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                try ensureTimeRemaining(
                    until: deadline,
                    operation: operation
                )
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    throw PlayCoverRuntimeClientError.writeFailed(errno: EIO)
                }
                let code = errno
                if code == EINTR {
                    continue
                }
                if code == EAGAIN || code == EWOULDBLOCK {
                    try waitForIO(
                        descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline,
                        operation: operation
                    )
                    continue
                }
                throw PlayCoverRuntimeClientError.writeFailed(errno: code)
            }
        }
    }

    private func readExactly(
        byteCount: Int,
        from descriptor: Int32,
        operation: String,
        deadline: TimeInterval
    ) throws -> Data {
        var result = Data(count: byteCount)
        var offset = 0
        try result.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            while offset < byteCount {
                try ensureTimeRemaining(
                    until: deadline,
                    operation: operation
                )
                let received = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset
                )
                if received > 0 {
                    offset += received
                    continue
                }
                if received == 0 {
                    throw PlayCoverRuntimeClientError.unexpectedEOF(
                        operation: operation,
                        expectedBytes: byteCount,
                        receivedBytes: offset
                    )
                }
                let code = errno
                if code == EINTR {
                    continue
                }
                if code == EAGAIN || code == EWOULDBLOCK {
                    try waitForIO(
                        descriptor,
                        events: Int16(POLLIN),
                        deadline: deadline,
                        operation: operation
                    )
                    continue
                }
                throw PlayCoverRuntimeClientError.readFailed(errno: code)
            }
        }
        return result
    }

    private func ensureTimeRemaining(
        until deadline: TimeInterval,
        operation: String
    ) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw PlayCoverRuntimeClientError.timeout(operation: operation)
        }
    }

    private func waitForIO(
        _ descriptor: Int32,
        events: Int16,
        deadline: TimeInterval,
        operation: String
    ) throws {
        while true {
            let remaining =
                deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw PlayCoverRuntimeClientError.timeout(
                    operation: operation
                )
            }
            var state = pollfd(
                fd: descriptor,
                events: events,
                revents: 0
            )
            let milliseconds = Int32(
                min(
                    Double(Int32.max),
                    max(1, ceil(remaining * 1_000))
                )
            )
            let result = Darwin.poll(&state, 1, milliseconds)
            if result > 0 {
                return
            }
            if result == 0 {
                throw PlayCoverRuntimeClientError.timeout(
                    operation: operation
                )
            }
            let code = errno
            if code == EINTR {
                continue
            }
            throw PlayCoverRuntimeClientError.readFailed(errno: code)
        }
    }

    private func decodeResponse(
        _ body: Data,
        expectedRequestID: String
    ) throws -> PlayCoverRuntimeResponsePayload {
        guard let text = String(data: body, encoding: .utf8) else {
            throw PlayCoverRuntimeClientError.responseIsNotUTF8
        }
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(
                ResponseEnvelope.self,
                from: Data(text.utf8)
            )
        } catch {
            throw PlayCoverRuntimeClientError.responseDecodingFailed
        }

        guard envelope.schemaVersion == Self.schemaVersion else {
            throw PlayCoverRuntimeClientError.unsupportedSchemaVersion(
                envelope.schemaVersion
            )
        }
        guard envelope.requestId == expectedRequestID else {
            throw PlayCoverRuntimeClientError.requestIDMismatch
        }
        if envelope.ok {
            guard envelope.error == nil else {
                throw PlayCoverRuntimeClientError.malformedResponse(
                    "ok response must not contain error"
                )
            }
            guard let payload = envelope.payload else {
                throw PlayCoverRuntimeClientError.malformedResponse(
                    "ok response is missing payload"
                )
            }
            guard payload.launchNonce == launchNonce else {
                throw PlayCoverRuntimeClientError.launchNonceMismatch
            }
            return payload
        }

        guard envelope.payload == nil else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "error response must not contain payload"
            )
        }
        guard let remote = envelope.error else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "error response is missing error"
            )
        }
        throw PlayCoverRuntimeClientError.remoteError(
            code: redact(remote.code),
            message: redact(remote.message),
            details: remote.details
        )
    }

    private func redact(_ value: String) -> String {
        guard !launchNonce.isEmpty else {
            return value
        }
        return value.replacingOccurrences(of: launchNonce, with: "<redacted>")
    }
}

private extension PlayCoverRuntimeClient {
    struct RequestEnvelope: Encodable {
        let schemaVersion: Int
        let requestId: String
        let command: PlayCoverRuntimeCommand
        let launchNonce: String
        let arguments: PlayCoverRuntimeRequestArguments?
    }

    struct ResponseEnvelope: Codable {
        let schemaVersion: Int
        let requestId: String
        let ok: Bool
        let payload: PlayCoverRuntimeResponsePayload?
        let error: RemoteError?
    }

    struct RemoteError: Codable {
        let code: String
        let message: String
        let details: PlayCoverRuntimeErrorDetails?
    }
}
