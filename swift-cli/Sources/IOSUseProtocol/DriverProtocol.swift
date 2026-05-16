import Foundation

public enum IOSUseProtocol {
    public static let defaultDriverPort: UInt16 = 8100
    public static let maxFrameSizeBytes = 50 * 1024 * 1024
    public static let commandTimeoutSeconds = 45
    public static let commandCompletionTimeoutSeconds = 120
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

public struct DriverFrameNames: Sendable {
    public static let request = "ForyRequestFrame"
    public static let response = "ForyResponseFrame"

    private init() {}
}
