import Foundation
import Fory

public enum IOSUseProtocol {
    public static let defaultDriverPort: UInt16 = 8100
    public static let maxFrameSizeBytes = 50 * 1024 * 1024
    public static let maxDriverConnections = 1
    public static let driverAcceptPollIntervalMicroseconds = 50_000
    public static let commandTimeoutSeconds = 45
    public static let commandCompletionTimeoutSeconds = 120
    public static let serverStopTimeoutSeconds = 5
    public static let listenBacklog: Int32 = 5
    public static let millisecondsPerSecond = 1000.0

    public static let springboardBundleId = "com.apple.springboard"
    public static let appForegroundTimeoutSeconds = 10.0
    public static let appTerminationTimeoutSeconds = 5.0
    public static let appStatePollIntervalSeconds = 0.05
    public static let waitForDefaultTimeoutSeconds = 10.0
    public static let waitForPollIntervalMilliseconds = 100
    public static let microsecondsPerMillisecond = 1000
    public static let inputPostTapFocusSettleSeconds = 0.2
    public static let defaultLongPressDurationSeconds = 0.5
    public static let defaultTargetRatio = 0.5
    public static let scrollTouchProportion = 0.75
    public static let touchPressDuration = 0.03
    public static let touchHoldDuration = 0.07
    public static let touchVelocity = 350.0
    public static let scrollSettleInterval = 0.1
    public static let fuzzyPointThreshold = 20.0
    public static let preciseScrollMaxSegments = 20
    public static let maxScrollCount = 25
    public static let screenshotJpegQuality = 0.8
    public static let proxyCAPort: UInt16 = 9088
    public static let proxyCAPath = "/ca.cer"
    public static let snapshotCacheTTLSeconds = 1.0
    public static let rectApproxEqualEpsilon = 0.5
    public static let fuzzyMaxSuggestionCount = 3
    public static let fuzzyNoSuggestionMaxLength = 1
    public static let fuzzyNearTypoMaxLength = 4
    public static let fuzzyMediumTypoMaxLength = 8
    public static let fuzzyNearTypoThreshold = 1
    public static let fuzzyMediumTypoThreshold = 2
    public static let fuzzyLongTypoThreshold = 3
    public static let sanitizedDecimalScale = 10.0

    public static let oslogDefaultCollectTimeoutSeconds = 5.0
    public static let oslogDefaultSimulatorLastSeconds = 10.0
    public static let oslogMaxBufferLines = 5_000
    public static let nsloggerDefaultPort = 50_000
    public static let nsloggerDefaultBufferSize = 50_000
    public static let nsloggerMaxReceiveBufferBytes = 1024 * 1024
    public static let nslogLockStaleMilliseconds = 60 * 60 * 1000
    public static let flowNSLogConnectTimeoutMilliseconds = 15_000
    public static let flowNSLogConnectPollMilliseconds = 200
    public static let flowDefaultSleepMilliseconds = 1_000
    public static let proxyMitmdumpPort = 9080
    public static let proxyProcessGraceMilliseconds = 3_000
    public static let proxyWaitPortTimeoutMilliseconds = 5_000
    public static let proxyWaitPortPollMilliseconds = 200
    public static let mitmproxyCAGenerationTimeoutMilliseconds = 10_000
    public static let mitmproxyCAGenerationPollMilliseconds = 200
}

public enum DriverCommand: String, CaseIterable, Sendable {
    case activateApp
    case terminateApp
    case home
    case openURL
    case proxyCAPush
    case screenshot
    case dom
    case find
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

public enum OpenURLCommand: DriverCommandBinding {
    public typealias Args = ForyOpenURLArgs
    public typealias Payload = ForySimpleStringPayload
    public static let command = DriverCommand.openURL
}

public enum DomCommand: DriverCommandBinding {
    public typealias Args = ForyDomArgs
    public typealias Payload = ForyDomPayload
    public static let command = DriverCommand.dom
}

public enum FindCommand: DriverCommandBinding {
    public typealias Args = ForyFindArgs
    public typealias Payload = ForyFindPayload
    public static let command = DriverCommand.find
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
        case .openURL:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyOpenURLArgs.self), payloadTypeName: String(describing: ForySimpleStringPayload.self), mutatesUI: true)
        case .proxyCAPush:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyProxyCAPushArgs.self), payloadTypeName: String(describing: ForyProxyPayload.self), mutatesUI: true)
        case .screenshot:
            DriverCommandMetadata(command: self, argsTypeName: nil, payloadTypeName: String(describing: ForyScreenshotPayload.self), mutatesUI: false)
        case .dom:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyDomArgs.self), payloadTypeName: String(describing: ForyDomPayload.self), mutatesUI: false)
        case .find:
            DriverCommandMetadata(command: self, argsTypeName: String(describing: ForyFindArgs.self), payloadTypeName: String(describing: ForyFindPayload.self), mutatesUI: false)
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
