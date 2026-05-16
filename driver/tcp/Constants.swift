import Foundation

enum DriverConstants {
    static let defaultPort = IOSUseProtocol.defaultDriverPort
    static let maxFrameSizeBytes = IOSUseProtocol.maxFrameSizeBytes
    static let maxConnections = IOSUseProtocol.maxDriverConnections
    static let acceptPollIntervalMicroseconds = useconds_t(IOSUseProtocol.driverAcceptPollIntervalMicroseconds)
    static let commandTimeoutSeconds = IOSUseProtocol.commandTimeoutSeconds
    static let commandCompletionTimeoutSeconds = IOSUseProtocol.commandCompletionTimeoutSeconds
    static let serverStopTimeoutSeconds = IOSUseProtocol.serverStopTimeoutSeconds
    static let listenBacklog = IOSUseProtocol.listenBacklog
    static let millisecondsPerSecond = IOSUseProtocol.millisecondsPerSecond
}
