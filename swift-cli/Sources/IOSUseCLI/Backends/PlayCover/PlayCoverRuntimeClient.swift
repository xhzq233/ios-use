import Darwin
import Foundation

enum PlayCoverRuntimeCommand: String, Codable, Sendable {
    case hello
    case ping
    case diagnostics
    case screenshot
    case dom
    case waitFor
    case tap
    case longPress
    case swipe
    case input
    case dismissAlert
    case open
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

struct PlayCoverRuntimeRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct PlayCoverRuntimeFrame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var rect: PlayCoverRuntimeRect {
        PlayCoverRuntimeRect(x: x, y: y, w: width, h: height)
    }
}

struct PlayCoverRuntimePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct PlayCoverRuntimeSize: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
}

struct PlayCoverRuntimeSafeArea: Codable, Equatable, Sendable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double
}

/// The public AppKit host is intentionally independent from the fixed UIKit
/// device canvas.  It is still part of Runtime readiness: without this
/// contract a resizable host could report a healthy 430x932 UIKit scene while
/// its visible canvas, title, capture crop, or inverse input transform is
/// invalid.
struct PlayCoverRuntimeHostCaptureGeometry: Codable, Equatable, Sendable {
    let ready: Bool
    let error: String?
    let hostContentCGWindowRect: PlayCoverRuntimeFrame
    let hostCGWindowBounds: PlayCoverRuntimeFrame
    let canvasCGWindowRect: PlayCoverRuntimeFrame
    let hostWindowNumber: Int64?
}

struct PlayCoverRuntimeHostGeometry: Codable, Equatable, Sendable {
    let status: String
    let hostPolicy: Bool
    let frame: PlayCoverRuntimeFrame
    let contentBounds: PlayCoverRuntimeFrame
    let canvasRect: PlayCoverRuntimeFrame
    let canvasBounds: PlayCoverRuntimeFrame
    let displayScale: Double
    let inverseDisplayScale: Double
    let opaque: Bool
    let publicTitleBar: Bool
    let titleVisible: Bool
    let resizable: Bool
    let title: String
    let titleExpected: String
    let capture: PlayCoverRuntimeHostCaptureGeometry
}

struct PlayCoverRuntimeGeometry: Codable, Equatable, Sendable {
    let logical: PlayCoverRuntimeSize
    let native: PlayCoverRuntimeSize
    let scale: Double
    let window: PlayCoverRuntimeSize
    let safeArea: PlayCoverRuntimeSafeArea
    let host: PlayCoverRuntimeHostGeometry?
}

struct PlayCoverRuntimeTarget: Codable, Equatable, Sendable {
    let label: String
    let point: PlayCoverRuntimePoint?
    let traits: String
    let cindex: Int32?
    let matchMode: Int32?

    init(
        label: String,
        point: PlayCoverRuntimePoint? = nil,
        traits: String = "",
        cindex: Int32? = nil,
        matchMode: Int32? = nil
    ) {
        self.label = label
        self.point = point
        self.traits = traits
        self.cindex = cindex
        self.matchMode = matchMode
    }
}

struct PlayCoverRuntimeEmptyArguments: Codable, Equatable, Sendable {}

struct PlayCoverRuntimeDOMArguments: Codable, Equatable, Sendable {
    let raw: Bool
    let fresh: Bool
    let waitQuiescence: Bool
}

typealias PlayCoverRuntimeWaitTarget = PlayCoverRuntimeTarget

struct PlayCoverRuntimeWaitForArguments: Codable, Equatable, Sendable {
    let target: PlayCoverRuntimeTarget
    let timeout: Double
    let gone: Bool
    let matchMode: Int32
}

struct PlayCoverRuntimeTapArguments: Codable, Equatable, Sendable {
    let target: PlayCoverRuntimeTarget
    let offset: PlayCoverRuntimePoint?
    let ratio: PlayCoverRuntimePoint
}

struct PlayCoverRuntimeLongPressArguments: Codable, Equatable, Sendable {
    let target: PlayCoverRuntimeTarget
    let durationMs: Int
}

struct PlayCoverRuntimeSwipeArguments: Codable, Equatable, Sendable {
    let toTarget: PlayCoverRuntimeTarget?
    let fromTarget: PlayCoverRuntimeTarget
    let distance: Double
    let direction: Int32
    let durationMs: Int?
}

struct PlayCoverRuntimeInputArguments: Codable, Equatable, Sendable {
    let target: PlayCoverRuntimeTarget?
    let content: String
    let deleteCount: Int
    let enter: Bool

    init(
        target: PlayCoverRuntimeTarget?,
        content: String,
        deleteCount: Int = 0,
        enter: Bool = false
    ) {
        self.target = target
        self.content = content
        self.deleteCount = deleteCount
        self.enter = enter
    }
}

struct PlayCoverRuntimeDismissAlertArguments: Codable, Equatable, Sendable {
    let index: Int?
}

struct PlayCoverRuntimeOpenArguments: Codable, Equatable, Sendable {
    let url: String
}

enum PlayCoverRuntimeRequestArguments: Encodable, Equatable, Sendable {
    case empty(PlayCoverRuntimeEmptyArguments = .init())
    case dom(PlayCoverRuntimeDOMArguments)
    case waitFor(PlayCoverRuntimeWaitForArguments)
    case tap(PlayCoverRuntimeTapArguments)
    case longPress(PlayCoverRuntimeLongPressArguments)
    case swipe(PlayCoverRuntimeSwipeArguments)
    case input(PlayCoverRuntimeInputArguments)
    case dismissAlert(PlayCoverRuntimeDismissAlertArguments)
    case open(PlayCoverRuntimeOpenArguments)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .empty(let arguments):
            try arguments.encode(to: encoder)
        case .dom(let arguments):
            try arguments.encode(to: encoder)
        case .waitFor(let arguments):
            try arguments.encode(to: encoder)
        case .tap(let arguments):
            try arguments.encode(to: encoder)
        case .longPress(let arguments):
            try arguments.encode(to: encoder)
        case .swipe(let arguments):
            try arguments.encode(to: encoder)
        case .input(let arguments):
            try arguments.encode(to: encoder)
        case .dismissAlert(let arguments):
            try arguments.encode(to: encoder)
        case .open(let arguments):
            try arguments.encode(to: encoder)
        }
    }
}

struct PlayCoverRuntimeDOMState: Codable, Equatable, Sendable {
    let enabled: Bool
    let visible: Bool
    let selected: Bool
    let focused: Bool
    let opaque: Bool
}

struct PlayCoverRuntimeDOMHierarchy: Codable, Equatable, Sendable {
    let parentID: String?
    let depth: Int32
    let index: Int32
    let path: [String]
}

struct PlayCoverRuntimeDOMElement: Codable, Equatable, Sendable {
    let nodeID: String
    let type: String
    let elementType: Int32
    let elemType: Int32
    let label: String
    let value: String
    let identifier: String
    let hint: String
    let `class`: String
    let traits: [String]
    let state: PlayCoverRuntimeDOMState
    let frame: PlayCoverRuntimeFrame?
    let rect: PlayCoverRuntimeRect?
    let hierarchy: PlayCoverRuntimeDOMHierarchy
    let ancestors: [String]
    let zOrder: Int32
    let snapshotGeneration: Int64

    var nodeId: String { nodeID }
    var childCount: Int32 { 0 }
    var effectiveRect: PlayCoverRuntimeRect? { rect ?? frame?.rect }
}

struct PlayCoverRuntimeDOMPayload: Codable, Equatable, Sendable {
    let app: String
    let windowSize: PlayCoverRuntimePoint
    let raw: String
    let snapshotGeneration: Int64
    let elements: [PlayCoverRuntimeDOMElement]
}

struct PlayCoverRuntimeElementSummary: Codable, Equatable, Sendable {
    let nodeID: String
    let type: String
    let elementType: Int32
    let elemType: Int32
    let label: String
    let value: String
    let identifier: String
    let hint: String
    let `class`: String
    let traits: [String]
    let state: PlayCoverRuntimeDOMState
    let frame: PlayCoverRuntimeFrame?
    let rect: PlayCoverRuntimeRect?
    let hierarchy: PlayCoverRuntimeDOMHierarchy
    let zOrder: Int32
    let snapshotGeneration: Int64
    let ancestors: [String]

    var effectiveRect: PlayCoverRuntimeRect? { rect ?? frame?.rect }
}

struct PlayCoverRuntimeWaitForPayload: Codable, Equatable, Sendable {
    let element: PlayCoverRuntimeElementSummary
    let waited: Double
    let snapshotGeneration: Int64
}

struct PlayCoverRuntimeHitView: Codable, Equatable, Sendable {
    let `class`: String
    let frame: PlayCoverRuntimeFrame?
    let accessibilityIdentifier: String
    let label: String
}

struct PlayCoverRuntimeFinalState: Codable, Equatable, Sendable {
    let point: PlayCoverRuntimePoint
    let touchID: Int64
    let phase: String
    let firstResponderClass: String?
}

struct PlayCoverRuntimeActionPayload: Codable, Equatable, Sendable {
    let element: PlayCoverRuntimeElementSummary
    let hitView: PlayCoverRuntimeHitView
    let finalState: PlayCoverRuntimeFinalState
}

struct PlayCoverRuntimeSwipePayload: Codable, Equatable, Sendable {
    let element: PlayCoverRuntimeElementSummary
    let hitView: PlayCoverRuntimeHitView
    let finalState: PlayCoverRuntimeFinalState
    let scrolls: Int32
    let direction: String
}

struct PlayCoverRuntimeAlertPayload: Codable, Equatable, Sendable {
    let dismissed: Bool
    let text: String
    let button: String
    let reason: String
    let hitView: PlayCoverRuntimeHitView?
    let finalState: PlayCoverRuntimeFinalState?
}

struct PlayCoverRuntimeOpenPayload: Codable, Equatable, Sendable {
    let delivered: Bool
    let url: String
}

struct PlayCoverRuntimeFullFrame: Codable, Equatable, Sendable {
    let logicalRect: PlayCoverRuntimeFrame
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    let uncropped: Bool
    let safeAreaCropped: Bool
    let identityMapping: Bool
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
    let syntheticChrome: Bool
    let fullFrame: PlayCoverRuntimeFullFrame
    let snapshotGeneration: Int64
    let captureGeneration: Int64
    let compositorWindowNumbers: [Int]?
    let sourceBackingSizes: [PlayCoverRuntimeJSONValue]?
    let appKitWindowEvidence: PlayCoverRuntimeJSONValue?
    let compositor: PlayCoverRuntimeJSONValue?

    init(
        jpegBase64: String,
        pixelWidth: Int,
        pixelHeight: Int,
        logicalWidth: Double,
        logicalHeight: Double,
        scale: Double,
        source: String,
        complete: Bool,
        syntheticChrome: Bool,
        fullFrame: PlayCoverRuntimeFullFrame,
        snapshotGeneration: Int64,
        captureGeneration: Int64,
        compositorWindowNumbers: [Int]? = nil,
        sourceBackingSizes:
            [PlayCoverRuntimeJSONValue]? = nil,
        appKitWindowEvidence:
            PlayCoverRuntimeJSONValue? = nil,
        compositor: PlayCoverRuntimeJSONValue? = nil
    ) {
        self.jpegBase64 = jpegBase64
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scale = scale
        self.source = source
        self.complete = complete
        self.syntheticChrome = syntheticChrome
        self.fullFrame = fullFrame
        self.snapshotGeneration = snapshotGeneration
        self.captureGeneration = captureGeneration
        self.compositorWindowNumbers = compositorWindowNumbers
        self.sourceBackingSizes = sourceBackingSizes
        self.appKitWindowEvidence = appKitWindowEvidence
        self.compositor = compositor
    }
}

protocol PlayCoverRuntimeIdentifiedPayload {
    var pid: Int32 { get }
    var bundleIdentifier: String { get }
    var executablePath: String { get }
}

struct PlayCoverRuntimeHelloPayload:
    Codable,
    Equatable,
    Sendable,
    PlayCoverRuntimeIdentifiedPayload
{
    let pid: Int32
    let bundleIdentifier: String
    let executablePath: String
    let capabilities: [String]
    let geometry: PlayCoverRuntimeGeometry
    let stage: String
    let observed: [String: PlayCoverRuntimeJSONValue]
}

struct PlayCoverRuntimeDiagnosticsPayload:
    Codable,
    Equatable,
    Sendable,
    PlayCoverRuntimeIdentifiedPayload
{
    let pid: Int32
    let bundleIdentifier: String
    let executablePath: String
    let capabilities: [String]
    let geometry: PlayCoverRuntimeGeometry
    let stage: String
    let diagnostics: [String: PlayCoverRuntimeJSONValue]
}

struct PlayCoverRuntimePingPayload: Codable, Equatable, Sendable {
    let pong: Bool
}

struct PlayCoverRuntimeScreenshotResult:
    Codable,
    Equatable,
    Sendable
{
    let screenshot: PlayCoverRuntimeScreenshotPayload
    let dom: PlayCoverRuntimeDOMPayload
}

private struct PlayCoverRuntimeDOMResult: Codable {
    let dom: PlayCoverRuntimeDOMPayload
}

private struct PlayCoverRuntimeWaitForResult: Codable {
    let waitFor: PlayCoverRuntimeWaitForPayload
}

private struct PlayCoverRuntimeTapResult: Codable {
    let tap: PlayCoverRuntimeActionPayload
}

private struct PlayCoverRuntimeLongPressResult: Codable {
    let longPress: PlayCoverRuntimeActionPayload
}

private struct PlayCoverRuntimeInputResult: Codable {
    let input: PlayCoverRuntimeActionPayload
}

private struct PlayCoverRuntimeSwipeResult: Codable {
    let swipe: PlayCoverRuntimeSwipePayload
}

private struct PlayCoverRuntimeAlertResult: Codable {
    let dismissAlert: PlayCoverRuntimeAlertPayload
}

private struct PlayCoverRuntimeOpenResult: Codable {
    let open: PlayCoverRuntimeOpenPayload
}

enum PlayCoverRuntimeResponsePayload: Equatable, Sendable {
    case hello(PlayCoverRuntimeHelloPayload)
    case ping(PlayCoverRuntimePingPayload)
    case diagnostics(PlayCoverRuntimeDiagnosticsPayload)
    case screenshot(PlayCoverRuntimeScreenshotResult)
    case dom(PlayCoverRuntimeDOMPayload)
    case waitFor(PlayCoverRuntimeWaitForPayload)
    case tap(PlayCoverRuntimeActionPayload)
    case longPress(PlayCoverRuntimeActionPayload)
    case swipe(PlayCoverRuntimeSwipePayload)
    case input(PlayCoverRuntimeActionPayload)
    case dismissAlert(PlayCoverRuntimeAlertPayload)
    case open(PlayCoverRuntimeOpenPayload)
}

typealias PlayCoverRuntimeErrorElement = PlayCoverRuntimeElementSummary

struct PlayCoverRuntimeErrorCandidate: Codable, Equatable, Sendable {
    let element: PlayCoverRuntimeErrorElement
    let rejectedBy: [String]
}

struct PlayCoverRuntimeErrorDetails: Codable, Equatable, Sendable {
    let category: String
    let phase: String
    let retryable: Bool
    let fatal: Bool
    let target: PlayCoverRuntimeTarget?
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
    case peerPIDCredentialFailed(errno: Int32)
    case peerPIDMismatch(expected: pid_t, actual: pid_t)
    case processExecutableLookupFailed(pid: pid_t)
    case processExecutableMismatch
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
    case sessionIDMismatch
    case responseIdentityMismatch(String)
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
        case .peerPIDCredentialFailed(let code):
            return "PlayCover runtime Unix peer PID lookup failed: errno \(code)"
        case .peerPIDMismatch(let expected, let actual):
            return "PlayCover runtime Unix peer PID mismatch: expected \(expected), received \(actual)"
        case .processExecutableLookupFailed(let pid):
            return "cannot resolve the executable for PlayCover Runtime PID \(pid)"
        case .processExecutableMismatch:
            return "PlayCover Runtime process executable does not match the active session"
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
        case .sessionIDMismatch:
            return "PlayCover runtime response sessionID does not match the active session"
        case .responseIdentityMismatch(let field):
            return "PlayCover runtime response \(field) does not match the active session"
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
    static let schemaVersion = 3
    static let maximumRequestBodyBytes = 64 * 1024
    static let maximumResponseBodyBytes = 16 * 1024 * 1024
    static let defaultTimeoutSeconds: TimeInterval = 5
    static let screenshotTimeoutSeconds: TimeInterval = 15

    private let socketPath: String
    private let sessionID: String
    private let expectedPID: pid_t
    private let expectedBundleIdentifier: String
    private let expectedExecutablePath: String
    private let timeoutSeconds: TimeInterval

    init(
        socketPath: String,
        sessionID: String,
        expectedPID: pid_t,
        expectedBundleIdentifier: String,
        expectedExecutablePath: String,
        timeoutSeconds: TimeInterval = PlayCoverRuntimeClient
            .defaultTimeoutSeconds
    ) {
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.expectedPID = expectedPID
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedExecutablePath = expectedExecutablePath
        self.timeoutSeconds = timeoutSeconds
    }

    func hello() throws -> PlayCoverRuntimeHelloPayload {
        guard case .hello(let payload) = try request(.hello) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "hello response type mismatch"
            )
        }
        return payload
    }

    func ping() throws -> PlayCoverRuntimePingPayload {
        guard case .ping(let payload) = try request(.ping) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "ping response type mismatch"
            )
        }
        return payload
    }

    func diagnostics() throws -> PlayCoverRuntimeDiagnosticsPayload {
        guard case .diagnostics(let payload) =
                try request(.diagnostics) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "diagnostics response type mismatch"
            )
        }
        return payload
    }

    func screenshot() throws -> PlayCoverRuntimeScreenshotResult {
        guard case .screenshot(let payload) =
                try request(.screenshot) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "screenshot response type mismatch"
            )
        }
        return payload
    }

    func dom(
        _ arguments: PlayCoverRuntimeDOMArguments
    ) throws -> PlayCoverRuntimeDOMPayload {
        guard case .dom(let payload) =
                try request(.dom, arguments: .dom(arguments)) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "dom response type mismatch"
            )
        }
        return payload
    }

    func waitFor(
        _ arguments: PlayCoverRuntimeWaitForArguments
    ) throws -> PlayCoverRuntimeWaitForPayload {
        guard case .waitFor(let payload) =
                try request(
                    .waitFor,
                    arguments: .waitFor(arguments)
                ) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "waitFor response type mismatch"
            )
        }
        return payload
    }

    func tap(
        _ arguments: PlayCoverRuntimeTapArguments
    ) throws -> PlayCoverRuntimeActionPayload {
        guard case .tap(let payload) =
                try request(.tap, arguments: .tap(arguments)) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "tap response type mismatch"
            )
        }
        return payload
    }

    func longPress(
        _ arguments: PlayCoverRuntimeLongPressArguments
    ) throws -> PlayCoverRuntimeActionPayload {
        guard case .longPress(let payload) =
                try request(
                    .longPress,
                    arguments: .longPress(arguments)
                ) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "longPress response type mismatch"
            )
        }
        return payload
    }

    func swipe(
        _ arguments: PlayCoverRuntimeSwipeArguments
    ) throws -> PlayCoverRuntimeSwipePayload {
        guard case .swipe(let payload) =
                try request(.swipe, arguments: .swipe(arguments)) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "swipe response type mismatch"
            )
        }
        return payload
    }

    func input(
        _ arguments: PlayCoverRuntimeInputArguments
    ) throws -> PlayCoverRuntimeActionPayload {
        guard case .input(let payload) =
                try request(.input, arguments: .input(arguments)) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "input response type mismatch"
            )
        }
        return payload
    }

    func dismissAlert(
        _ arguments: PlayCoverRuntimeDismissAlertArguments
    ) throws -> PlayCoverRuntimeAlertPayload {
        guard case .dismissAlert(let payload) =
                try request(
                    .dismissAlert,
                    arguments: .dismissAlert(arguments)
                ) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "dismissAlert response type mismatch"
            )
        }
        return payload
    }

    func open(
        _ arguments: PlayCoverRuntimeOpenArguments
    ) throws -> PlayCoverRuntimeOpenPayload {
        guard case .open(let payload) =
                try request(.open, arguments: .open(arguments)) else {
            throw PlayCoverRuntimeClientError.malformedResponse(
                "open response type mismatch"
            )
        }
        return payload
    }

    func request(_ command: PlayCoverRuntimeCommand) throws -> PlayCoverRuntimeResponsePayload {
        try request(command, arguments: .empty())
    }

    func request(
        _ command: PlayCoverRuntimeCommand,
        arguments: PlayCoverRuntimeRequestArguments
    ) throws -> PlayCoverRuntimeResponsePayload {
        switch command {
        case .hello:
            let payload: PlayCoverRuntimeHelloPayload =
                try performRequest(command, arguments: arguments)
            try validateIdentity(payload)
            return .hello(payload)
        case .ping:
            let payload: PlayCoverRuntimePingPayload =
                try performRequest(command, arguments: arguments)
            guard payload.pong else {
                throw PlayCoverRuntimeClientError.malformedResponse(
                    "ping acknowledgement is false"
                )
            }
            return .ping(payload)
        case .diagnostics:
            let payload: PlayCoverRuntimeDiagnosticsPayload =
                try performRequest(command, arguments: arguments)
            try validateIdentity(payload)
            return .diagnostics(payload)
        case .screenshot:
            let payload: PlayCoverRuntimeScreenshotResult =
                try performRequest(command, arguments: arguments)
            return .screenshot(payload)
        case .dom:
            let payload: PlayCoverRuntimeDOMResult =
                try performRequest(command, arguments: arguments)
            return .dom(payload.dom)
        case .waitFor:
            let payload: PlayCoverRuntimeWaitForResult =
                try performRequest(command, arguments: arguments)
            return .waitFor(payload.waitFor)
        case .tap:
            let payload: PlayCoverRuntimeTapResult =
                try performRequest(command, arguments: arguments)
            return .tap(payload.tap)
        case .longPress:
            let payload: PlayCoverRuntimeLongPressResult =
                try performRequest(command, arguments: arguments)
            return .longPress(payload.longPress)
        case .swipe:
            let payload: PlayCoverRuntimeSwipeResult =
                try performRequest(command, arguments: arguments)
            return .swipe(payload.swipe)
        case .input:
            let payload: PlayCoverRuntimeInputResult =
                try performRequest(command, arguments: arguments)
            return .input(payload.input)
        case .dismissAlert:
            let payload: PlayCoverRuntimeAlertResult =
                try performRequest(command, arguments: arguments)
            return .dismissAlert(payload.dismissAlert)
        case .open:
            let payload: PlayCoverRuntimeOpenResult =
                try performRequest(command, arguments: arguments)
            return .open(payload.open)
        }
    }

    private func performRequest<Payload: Decodable>(
        _ command: PlayCoverRuntimeCommand,
        arguments: PlayCoverRuntimeRequestArguments
    ) throws -> Payload {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw PlayCoverRuntimeClientError.invalidTimeout
        }
        let address = try makeAddress()
        let requestID = UUID().uuidString
        let request = RequestEnvelope(
            schemaVersion: Self.schemaVersion,
            requestId: requestID,
            sessionID: sessionID,
            command: command,
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
        return try decodeResponse(
            responseBody,
            expectedRequestID: requestID
        )
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

        var peerPID: pid_t = 0
        var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
        if Darwin.getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerPID,
            &peerPIDSize
        ) == 0 {
            guard peerPID == expectedPID else {
                throw PlayCoverRuntimeClientError.peerPIDMismatch(
                    expected: expectedPID,
                    actual: peerPID
                )
            }
        } else {
            let code = errno
            guard code == ENOPROTOOPT || code == EINVAL else {
                throw PlayCoverRuntimeClientError
                    .peerPIDCredentialFailed(errno: code)
            }
        }

        guard let actualExecutablePath = Self.executablePath(
            for: expectedPID
        ) else {
            throw PlayCoverRuntimeClientError
                .processExecutableLookupFailed(pid: expectedPID)
        }
        guard Self.canonicalPath(actualExecutablePath)
                == Self.canonicalPath(expectedExecutablePath) else {
            throw PlayCoverRuntimeClientError.processExecutableMismatch
        }
    }

    static func executablePath(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN) * 4
        )
        let count = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(
                pid,
                $0.baseAddress,
                UInt32($0.count)
            )
        }
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
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

    private func decodeResponse<Payload: Decodable>(
        _ body: Data,
        expectedRequestID: String
    ) throws -> Payload {
        guard let text = String(data: body, encoding: .utf8) else {
            throw PlayCoverRuntimeClientError.responseIsNotUTF8
        }
        let envelope: ResponseEnvelope<Payload>
        do {
            envelope = try JSONDecoder().decode(
                ResponseEnvelope<Payload>.self,
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
        guard envelope.sessionID == sessionID else {
            throw PlayCoverRuntimeClientError.sessionIDMismatch
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

    private func validateIdentity(
        _ payload: some PlayCoverRuntimeIdentifiedPayload
    ) throws {
        guard payload.pid == expectedPID else {
            throw PlayCoverRuntimeClientError
                .responseIdentityMismatch("PID")
        }
        guard payload.bundleIdentifier == expectedBundleIdentifier else {
            throw PlayCoverRuntimeClientError
                .responseIdentityMismatch("bundle identifier")
        }
        guard Self.canonicalPath(payload.executablePath)
                == Self.canonicalPath(expectedExecutablePath) else {
            throw PlayCoverRuntimeClientError
                .responseIdentityMismatch("executable")
        }
    }

    private func redact(_ value: String) -> String {
        guard !sessionID.isEmpty else {
            return value
        }
        return value.replacingOccurrences(
            of: sessionID,
            with: "<redacted>"
        )
    }
}

private extension PlayCoverRuntimeClient {
    struct RequestEnvelope: Encodable {
        let schemaVersion: Int
        let requestId: String
        let sessionID: String
        let command: PlayCoverRuntimeCommand
        let arguments: PlayCoverRuntimeRequestArguments
    }

    struct ResponseEnvelope<Payload: Decodable>: Decodable {
        let schemaVersion: Int
        let requestId: String
        let sessionID: String
        let ok: Bool
        let payload: Payload?
        let error: RemoteError?
    }

    struct RemoteError: Codable {
        let code: String
        let message: String
        let details: PlayCoverRuntimeErrorDetails?
    }
}
