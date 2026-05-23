import Foundation

public struct IOSUsePaths: Equatable, Sendable {
    public let root: String
    public let config: String
    public let session: String
    public let driverLock: String
    public let nslogLock: String
    public let nslogState: String
    public let logs: String
    public let artifacts: String

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> IOSUsePaths {
        let root = configuredRoot(environment: environment)
        return IOSUsePaths(
            root: root,
            config: "\(root)/config.json",
            session: "\(root)/state/session.json",
            driverLock: "\(root)/state/driver.lock",
            nslogLock: "\(root)/state/nslog.lock",
            nslogState: "\(root)/state/nslog-state.json",
            logs: "\(root)/logs",
            artifacts: "\(root)/artifacts"
        )
    }

    private static func configuredRoot(environment: [String: String]) -> String {
        if let iosUseHome = environment["IOS_USE_HOME"], !iosUseHome.isEmpty {
            return iosUseHome
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return "\(home)/.ios-use"
    }
}
