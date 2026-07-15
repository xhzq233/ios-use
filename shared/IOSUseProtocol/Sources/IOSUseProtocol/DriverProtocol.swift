import Foundation
import Fory

public enum IOSUseProtocol {
    // MARK: Driver TCP / Fory frame limits

    /// TCP port used by the ios-use XCTest driver loopback server. Kept separate from WDA's common 8100.
    public static let defaultDriverPort: UInt16 = 8102
    /// Maximum length of one length-prefixed Fory frame. Must fit screenshot payloads.
    public static let maxFrameSizeBytes = 50 * 1024 * 1024
    /// Accept-loop backoff for the driver TCP server.
    public static let driverAcceptPollIntervalMicroseconds = 50_000
    /// Maximum time Simulator start waits for the driver TCP port after `simctl launch`.
    public static let simulatorDriverStartTimeoutSeconds = 10.0
    /// Simulator start port polling interval after `simctl launch`.
    public static let simulatorDriverStartPollIntervalMicroseconds = 100_000
    /// Maximum time Simulator config waits for the installed driver to answer after launch.
    public static let simulatorDriverConfigureProbeTimeoutSeconds = 10.0
    /// Simulator config probe polling interval after installing and launching the driver.
    public static let simulatorDriverConfigureProbePollMicroseconds = 200_000
    /// Time to wait from receiving a command until a driver response is ready.
    public static let commandTimeoutSeconds = 10
    /// Host-side socket read timeout. Must outlive the driver command watchdog long enough to receive the fatal frame.
    public static let commandSocketReadTimeoutSeconds = commandTimeoutSeconds + 2
    /// Initial delay before holder probes real-device driver TCP readiness after XCTest start returns.
    public static let realDeviceDriverReadinessInitialDelayMicroseconds = 200_000
    /// Poll interval while holder waits for real-device driver TCP readiness.
    public static let realDeviceDriverReadinessPollMicroseconds = 40_000
    /// Delay after a successful holder readiness probe before returning `start`.
    public static let realDeviceDriverReadinessPostSuccessDelayMicroseconds = 10_000
    /// Maximum time holder waits for the driver TCP port to accept connections after XCTest start returns.
    public static let realDeviceDriverReadinessTimeoutSeconds = 10.0
    /// Driver stop waits for the accept loop to exit for this many seconds.
    public static let serverStopTimeoutSeconds = 5
    /// TCP listen backlog for the driver server socket.
    public static let listenBacklog: Int32 = 5
    /// Shared conversion for elapsed-time log formatting.
    public static let millisecondsPerSecond = 1000.0
    /// Minimum explicit `--dom <ms>` delay. Bare `--dom` uses quiescence instead.
    public static let minimumPostDomMilliseconds = 100

    // MARK: Driver UI semantics

    /// SpringBoard bundle id. Excluded from cached foreground app reuse.
    public static let springboardBundleId = "com.apple.springboard"
    /// `activateApp` wait budget for target app to become foreground.
    public static let appForegroundTimeoutSeconds = 10.0
    /// `terminateApp` wait budget for target app to leave foreground/running state.
    public static let appTerminationTimeoutSeconds = 5.0
    /// App lifecycle polling interval used by activate/terminate waits.
    public static let appStatePollIntervalSeconds = 0.05
    /// `waitFor` default timeout when caller omits `--timeout`.
    public static let waitForDefaultTimeoutSeconds = 10.0
    /// `waitFor` raw-find polling interval.
    public static let waitForPollIntervalMilliseconds = 100
    /// Conversion used by `usleep` callers.
    public static let microsecondsPerMillisecond = 1000
    /// Delay after tapping an input target before typing.
    public static let inputPostTapFocusSettleSeconds = 0.2
    /// Default long-press duration when caller omits `--duration`.
    public static let defaultLongPressDurationSeconds = 0.5
    /// Default target ratio for element-relative points when no axis-specific value is supplied.
    public static let defaultTargetRatio = 0.5
    /// Default gesture distance ratio for swipe/scroll relative to the scroll frame.
    public static let scrollTouchProportion = 0.75
    /// Press duration before scroll drag.
    public static let touchPressDuration = 0.03
    /// Hold duration after scroll drag.
    public static let touchHoldDuration = 0.07
    /// Scroll drag velocity.
    public static let touchVelocity = 350.0
    /// Delay between repeated scroll attempts.
    public static let scrollSettleInterval = 0.1
    /// Minimum useful point-swipe distance and reported min drag distance.
    public static let fuzzyPointThreshold = 20.0
    /// Maximum segments for precise vector scroll.
    public static let preciseScrollMaxSegments = 20
    /// Maximum scroll attempts for label/anchor based swipe.
    public static let maxScrollCount = 25
    /// JPEG quality used by screenshot command.
    public static let screenshotJpegQuality = 0.8
    /// Driver-side HTTP port used to serve proxy CA certificate to Settings.
    public static let proxyCAPort: UInt16 = 9088
    /// Driver-side HTTP path for proxy CA certificate download.
    public static let proxyCAPath = "/ca.cer"
    /// Shared cleaned DOM snapshot cache TTL.
    public static let snapshotCacheTTLSeconds = 1.0
    /// Same-rect merge tolerance for clean tree rule 4.
    public static let rectApproxEqualEpsilon = 0.5
    /// Maximum fuzzy suggestions returned by rawFind diagnostics.
    public static let fuzzyMaxSuggestionCount = 3
    /// Query length at or below this value disables fuzzy suggestions.
    public static let fuzzyNoSuggestionMaxLength = 1
    /// Query length at or below this value uses near-typo threshold.
    public static let fuzzyNearTypoMaxLength = 4
    /// Query length at or below this value uses medium-typo threshold.
    public static let fuzzyMediumTypoMaxLength = 8
    /// Edit distance threshold for short fuzzy queries.
    public static let fuzzyNearTypoThreshold = 1
    /// Edit distance threshold for medium fuzzy queries.
    public static let fuzzyMediumTypoThreshold = 2
    /// Edit distance threshold for long fuzzy queries.
    public static let fuzzyLongTypoThreshold = 3
    /// Maximum structured candidates attached to one driver error payload.
    public static let errorCandidateLimit = 5
    /// Scale used to round geometry values before serialization.
    public static let sanitizedDecimalScale = 10.0

    // MARK: Host-side logs / proxy

    /// Real-device oslog default collection window when caller omits timeout.
    public static let oslogDefaultCollectTimeoutSeconds = 5.0
    /// Simulator oslog default `log show --last` window.
    public static let oslogDefaultSimulatorLastSeconds = 10.0
    /// Legacy NSLogger TLS receiver port. Current host server binds an internal random port and publishes it via Bonjour.
    public static let nsloggerDefaultPort = 50_000
    /// Default NSLogger ring buffer capacity.
    public static let nsloggerDefaultBufferSize = 50_000
    /// Maximum unparsed NSLogger receive buffer before dropping old bytes.
    public static let nsloggerMaxReceiveBufferBytes = 1024 * 1024
    /// Legacy stale-lock age retained for compatibility with older lock files.
    public static let nslogLockStaleMilliseconds = 60 * 60 * 1000
    /// Foreground nslog command event-loop tick while streaming logs.
    public static let nslogForegroundRunLoopIntervalSeconds = 0.1
    /// Timeout while the nslog daemon child writes its capture lock.
    public static let nslogCaptureStartTimeoutSeconds = 3.0
    /// Poll interval while waiting for the nslog daemon child to write its capture lock.
    public static let nslogCaptureStartPollMicroseconds = 50_000
    /// Poll interval while waiting for nslog child process exit.
    public static let nslogProcessExitPollMicroseconds = 50_000
    /// App-side NSLogger connection polling interval.
    public static let nslogConnectPollMilliseconds = 200
    /// Default mitmdump listen port used by `proxy start`.
    public static let proxyMitmdumpPort = 9080
    /// Grace period before killing mitmdump with SIGKILL.
    public static let proxyProcessGraceMilliseconds = 3_000
    /// Poll interval while waiting for mitmdump to exit after SIGTERM.
    public static let proxyProcessExitPollMicroseconds = 100_000
    /// Timeout while waiting for mitmdump port readiness.
    public static let proxyWaitPortTimeoutMilliseconds = 5_000
    /// Poll interval while waiting for mitmdump port readiness.
    public static let proxyWaitPortPollMilliseconds = 200
    /// Timeout while waiting for mitmproxy to generate CA material.
    public static let mitmproxyCAGenerationTimeoutMilliseconds = 10_000
    /// Poll interval while waiting for mitmproxy CA generation.
    public static let mitmproxyCAGenerationPollMilliseconds = 200
    /// Timeout for os_trace_relay StartActivity acknowledgement.
    public static let osTraceActivityStartTimeoutSeconds = 5.0
    /// Short read slice used while streaming os_trace_relay activity.
    public static let osTraceActivityReadPollSeconds = 0.25
}

public enum IOSUseErrorCategory {
    public static let validation = "validation"
    public static let session = "session"
    public static let protocolFailure = "protocol"
    public static let lookup = "lookup"
    public static let action = "action"
    public static let timeout = "timeout"
    public static let postcondition = "postcondition"
    public static let internalFailure = "internal"

}

public enum IOSUseErrorCode {
    public static let invalidArguments = "invalid_arguments"
    public static let noActiveSession = "no_active_session"
    public static let appNotFound = "app_not_found"
    public static let elementNotFound = "element_not_found"
    public static let elementAmbiguous = "element_ambiguous"
    public static let elementNotActionable = "element_not_actionable"
    public static let snapshotFailed = "snapshot_failed"
    public static let gestureFailed = "gesture_failed"
    public static let inputFailed = "input_failed"
    public static let scrollBoundary = "scroll_boundary"
    public static let scrollUnavailable = "scroll_unavailable"
    public static let scrollLimitReached = "scroll_limit_reached"
    public static let waitTimedOut = "wait_timed_out"
    public static let proxyConfigurationFailed = "proxy_configuration_failed"
    public static let unknownCommand = "unknown_command"
    public static let driverWatchdogTimeout = "driver_watchdog_timeout"
    public static let dispatchFailed = "dispatch_failed"
    public static let internalFailure = "internal_failure"
    public static let postconditionFailed = "postcondition_failed"

}

public enum IOSUseErrorPhase {
    public static let validation = "validation"
    public static let session = "session"
    public static let lookup = "lookup"
    public static let snapshot = "snapshot"
    public static let interaction = "interaction"
    public static let wait = "wait"
    public static let dispatch = "dispatch"
    public static let postcondition = "postcondition"

}

public enum IOSUseCandidateRejection {
    public static let snapshotInvisible = "snapshot_invisible"
    public static let emptyVisibleFrame = "empty_visible_frame"
    public static let outsideAppBounds = "outside_app_bounds"
    public static let zeroAreaFrame = "zero_area_frame"
    public static let traitMismatch = "trait_mismatch"
    public static let childIndexOutOfRange = "child_index_out_of_range"

}

public enum DriverCommand: String, CaseIterable, Sendable {
    case activateApp
    case terminateApp
    case home
    case proxyCAPush
    case screenshot
    case dom
    case tap
    case longPress
    case input
    case swipe
    case waitFor
    case dismissAlert
}

public struct DriverCommandMetadata: Equatable, Sendable {
    public let command: DriverCommand
    public let argsTypeName: String?
    public let payloadTypeName: String?
    public let mutatesUI: Bool

    public init(command: DriverCommand, argsTypeName: String?, payloadTypeName: String?, mutatesUI: Bool) {
        self.command = command
        self.argsTypeName = argsTypeName
        self.payloadTypeName = payloadTypeName
        self.mutatesUI = mutatesUI
    }
}

public protocol DriverCommandBinding {
    associatedtype Args: Serializer
    associatedtype Payload: Serializer

    static var command: DriverCommand { get }
}

public enum ActivateAppCommand: DriverCommandBinding {
    public typealias Args = ForyActivateAppArgs
    public typealias Payload = ForyEmptyPayload
    public static let command = DriverCommand.activateApp
}

public enum TerminateAppCommand: DriverCommandBinding {
    public typealias Args = ForyTerminateAppArgs
    public typealias Payload = ForyEmptyPayload
    public static let command = DriverCommand.terminateApp
}

public enum DomCommand: DriverCommandBinding {
    public typealias Args = ForyDomArgs
    public typealias Payload = ForyDomPayload
    public static let command = DriverCommand.dom
}

public enum WaitForCommand: DriverCommandBinding {
    public typealias Args = ForyWaitForArgs
    public typealias Payload = ForyWaitForPayload
    public static let command = DriverCommand.waitFor
}

public enum TapCommand: DriverCommandBinding {
    public typealias Args = ForyTapArgs
    public typealias Payload = ForyElementPayload
    public static let command = DriverCommand.tap
}

public enum LongPressCommand: DriverCommandBinding {
    public typealias Args = ForyLongPressArgs
    public typealias Payload = ForyElementPayload
    public static let command = DriverCommand.longPress
}

public enum InputCommand: DriverCommandBinding {
    public typealias Args = ForyInputArgs
    public typealias Payload = ForyEmptyPayload
    public static let command = DriverCommand.input
}

public enum SwipeCommand: DriverCommandBinding {
    public typealias Args = ForySwipeArgs
    public typealias Payload = ForySwipePayload
    public static let command = DriverCommand.swipe
}

public enum DismissAlertCommand: DriverCommandBinding {
    public typealias Args = ForyDismissAlertArgs
    public typealias Payload = ForyAlertPayload
    public static let command = DriverCommand.dismissAlert
}

public enum ProxyCAPushCommand: DriverCommandBinding {
    public typealias Args = ForyProxyCAPushArgs
    public typealias Payload = ForyProxyPayload
    public static let command = DriverCommand.proxyCAPush
}

public extension DriverCommand {
    var metadata: DriverCommandMetadata {
        switch self {
        case .activateApp:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyActivateAppArgs.self), payloadTypeName: nil, mutatesUI: true)
        case .terminateApp:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyTerminateAppArgs.self), payloadTypeName: nil, mutatesUI: true)
        case .home:
            DriverCommandMetadata(command: self, argsTypeName: nil, payloadTypeName: nil, mutatesUI: true)
        case .proxyCAPush:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyProxyCAPushArgs.self), payloadTypeName: String(describing: ForyProxyPayload.self), mutatesUI: true)
        case .screenshot:
            DriverCommandMetadata(command: self, argsTypeName: nil, payloadTypeName: String(describing: ForyScreenshotPayload.self), mutatesUI: false)
        case .dom:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyDomArgs.self), payloadTypeName: String(describing: ForyDomPayload.self), mutatesUI: false)
        case .tap:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyTapArgs.self), payloadTypeName: String(describing: ForyElementPayload.self), mutatesUI: true)
        case .longPress:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyLongPressArgs.self), payloadTypeName: String(describing: ForyElementPayload.self), mutatesUI: true)
        case .input:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyInputArgs.self), payloadTypeName: nil, mutatesUI: true)
        case .swipe:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForySwipeArgs.self), payloadTypeName: String(describing: ForySwipePayload.self), mutatesUI: true)
        case .waitFor:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyWaitForArgs.self), payloadTypeName: String(describing: ForyWaitForPayload.self), mutatesUI: false)
        case .dismissAlert:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyDismissAlertArgs.self), payloadTypeName: String(describing: ForyAlertPayload.self), mutatesUI: true)
        }
    }
}

public struct DriverFrameNames: Sendable {
    public static let request = "ForyRequestFrame"
    public static let response = "ForyResponseFrame"

    private init() {}
}
