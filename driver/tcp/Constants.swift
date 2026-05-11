import Foundation

enum DriverConstants {
    static let defaultPort: UInt16 = 8100
    static let maxConnections = 1
    static let acceptPollIntervalMicroseconds: useconds_t = 50_000
    static let commandTimeoutSeconds = 45
    static let commandCompletionTimeoutSeconds = 120
    static let serverStopTimeoutSeconds = 5
    static let listenBacklog: Int32 = 5
}
