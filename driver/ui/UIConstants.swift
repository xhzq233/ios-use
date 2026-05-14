import CoreGraphics
import Foundation

enum DriverBundleConstants {
    static let springboardBundleId = "com.apple.springboard"
}

enum AppLifecycleConstants {
    static let foregroundTimeoutSeconds: CFTimeInterval = 10
    static let terminationTimeoutSeconds: CFTimeInterval = 5
    static let statePollIntervalSeconds: TimeInterval = 0.05
}

enum WaitForConstants {
    static let defaultTimeoutSeconds: Double = 10.0
    static let pollIntervalMilliseconds = 100
    static let microsecondsPerMillisecond = 1000
}

enum InputConstants {
    static let postTapFocusSettleSeconds: TimeInterval = 0.2
}

enum TouchConstants {
    static let defaultLongPressDurationSeconds = 0.5
    static let defaultTargetRatio = 0.5
}

enum ScrollConstants {
    static let scrollTouchProportion: CGFloat = 0.75
    static let touchPressDuration: Double = 0.03
    static let touchHoldDuration: Double = 0.07
    static let touchVelocity: Double = 350
    static let settleInterval: Double = 0.1
    static let fuzzyPointThreshold: CGFloat = 20
    static let preciseScrollMaxSegments = 20
    static let maxScrollCount = 25
}

enum ScreenConstants {
    static let jpegQuality = 0.8
}

enum ProxyConstants {
    static let caServerPort: UInt16 = 9088
    static let caServerPath = "/ca.cer"
}

enum SnapshotConstants {
    static let cacheTTLSeconds: TimeInterval = 1.0
    static let rectApproxEqualEpsilon: CGFloat = 0.5
}

enum FuzzySearchConstants {
    static let maxSuggestionCount = 3
    static let noSuggestionMaxLength = 1
    static let nearTypoMaxLength = 4
    static let mediumTypoMaxLength = 8
    static let nearTypoThreshold = 1
    static let mediumTypoThreshold = 2
    static let longTypoThreshold = 3
}

enum NumericConstants {
    static let sanitizedDecimalScale = 10.0
}
