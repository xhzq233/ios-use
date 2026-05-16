import CoreGraphics
import Foundation

enum DriverBundleConstants {
    static let springboardBundleId = IOSUseProtocol.springboardBundleId
}

enum AppLifecycleConstants {
    static let foregroundTimeoutSeconds: CFTimeInterval = IOSUseProtocol.appForegroundTimeoutSeconds
    static let terminationTimeoutSeconds: CFTimeInterval = IOSUseProtocol.appTerminationTimeoutSeconds
    static let statePollIntervalSeconds: TimeInterval = IOSUseProtocol.appStatePollIntervalSeconds
}

enum WaitForConstants {
    static let defaultTimeoutSeconds = IOSUseProtocol.waitForDefaultTimeoutSeconds
    static let pollIntervalMilliseconds = IOSUseProtocol.waitForPollIntervalMilliseconds
    static let microsecondsPerMillisecond = IOSUseProtocol.microsecondsPerMillisecond
}

enum InputConstants {
    static let postTapFocusSettleSeconds: TimeInterval = IOSUseProtocol.inputPostTapFocusSettleSeconds
}

enum TouchConstants {
    static let defaultLongPressDurationSeconds = IOSUseProtocol.defaultLongPressDurationSeconds
    static let defaultTargetRatio = IOSUseProtocol.defaultTargetRatio
}

enum ScrollConstants {
    static let scrollTouchProportion: CGFloat = IOSUseProtocol.scrollTouchProportion
    static let touchPressDuration = IOSUseProtocol.touchPressDuration
    static let touchHoldDuration = IOSUseProtocol.touchHoldDuration
    static let touchVelocity = IOSUseProtocol.touchVelocity
    static let settleInterval = IOSUseProtocol.scrollSettleInterval
    static let fuzzyPointThreshold: CGFloat = IOSUseProtocol.fuzzyPointThreshold
    static let preciseScrollMaxSegments = IOSUseProtocol.preciseScrollMaxSegments
    static let maxScrollCount = IOSUseProtocol.maxScrollCount
}

enum ScreenConstants {
    static let jpegQuality = IOSUseProtocol.screenshotJpegQuality
}

enum ProxyConstants {
    static let caServerPort = IOSUseProtocol.proxyCAPort
    static let caServerPath = IOSUseProtocol.proxyCAPath
}

enum SnapshotConstants {
    static let cacheTTLSeconds: TimeInterval = IOSUseProtocol.snapshotCacheTTLSeconds
    static let rectApproxEqualEpsilon: CGFloat = IOSUseProtocol.rectApproxEqualEpsilon
}

enum FuzzySearchConstants {
    static let maxSuggestionCount = IOSUseProtocol.fuzzyMaxSuggestionCount
    static let noSuggestionMaxLength = IOSUseProtocol.fuzzyNoSuggestionMaxLength
    static let nearTypoMaxLength = IOSUseProtocol.fuzzyNearTypoMaxLength
    static let mediumTypoMaxLength = IOSUseProtocol.fuzzyMediumTypoMaxLength
    static let nearTypoThreshold = IOSUseProtocol.fuzzyNearTypoThreshold
    static let mediumTypoThreshold = IOSUseProtocol.fuzzyMediumTypoThreshold
    static let longTypoThreshold = IOSUseProtocol.fuzzyLongTypoThreshold
}

enum NumericConstants {
    static let sanitizedDecimalScale = IOSUseProtocol.sanitizedDecimalScale
}
