import Foundation

public struct IOSUsePaths: Equatable, Sendable {
    public let root: String
    public let hasExplicitHome: Bool
    public let config: String
    public let session: String
    public let driverLock: String
    public let nslogLock: String
    public let nslogState: String
    public let appLogState: String
    public let logs: String
    public let artifacts: String

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> IOSUsePaths {
        let configured = configuredRoot(environment: environment)
        return IOSUsePaths(
            root: configured.root,
            hasExplicitHome: configured.hasExplicitHome,
            config: "\(configured.root)/config.json",
            session: "\(configured.root)/state/session.json",
            driverLock: "\(configured.root)/state/driver.lock",
            nslogLock: "\(configured.root)/state/nslog.lock",
            nslogState: "\(configured.root)/state/nslog-state.json",
            appLogState: "\(configured.root)/state/app-log.json",
            logs: "\(configured.root)/logs",
            artifacts: "\(configured.root)/artifacts"
        )
    }

    private static func configuredRoot(environment: [String: String]) -> (root: String, hasExplicitHome: Bool) {
        if let iosUseHome = environment["IOS_USE_HOME"], !iosUseHome.isEmpty {
            return (iosUseHome, true)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return ("\(home)/.ios-use", false)
    }
}
