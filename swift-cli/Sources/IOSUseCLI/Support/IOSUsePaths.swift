import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
    public let playcover: String
    public let playcoverRun: String
    public let playcoverLogs: String
    public let playcoverPendingLaunch: String
    public let playcoverPendingLaunchLock: String
    public let playcoverLastPrepared: String
    public let playcoverPrepared: String
    public let playcoverRuntime: String

    public func playCoverRuntimeSocketPath(
        sessionID: String
    ) throws -> String {
        let token = sessionID
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        guard !token.isEmpty else {
            throw CLIParseError.invalidValue(
                "PlayCover sessionID cannot produce a runtime socket name."
            )
        }
        // `/tmp` is a root-owned symlink to `/private/tmp` on macOS.  The
        // injected App is sandboxed, so its socket path must use the same
        // canonical spelling as the SBPL entitlement generated at prepare
        // time.  `launch` creates `playcoverRun` before calling this method;
        // resolving an otherwise non-existing prefix remains a no-op for
        // parser/unit-test paths.
        let canonicalRun = URL(
            fileURLWithPath: playcoverRun,
            isDirectory: true
        ).standardizedFileURL.path
        let resolvedRun = canonicalExistingPath(canonicalRun)
        let socket =
            "\(resolvedRun)/s-\(token.prefix(32)).sock"
        let maximumUTF8Bytes = 103
        guard socket.utf8.count <= maximumUTF8Bytes else {
            throw CLIParseError.invalidValue(
                "IOS_USE_HOME is too long for a Mac Runtime Unix socket "
                    + "(\(socket.utf8.count) UTF-8 bytes; maximum "
                    + "\(maximumUTF8Bytes))."
            )
        }
        return socket
    }

    private func canonicalExistingPath(_ path: String) -> String {
        #if canImport(Darwin)
        var buffer = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        let result = path.withCString {
            Darwin.realpath($0, &buffer)
        }
        if result != nil {
            return String(cString: buffer)
        }
        #endif
        return path
    }

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
            artifacts: "\(configured.root)/artifacts",
            playcover: "\(configured.root)/playcover",
            playcoverRun: "\(configured.root)/playcover/run",
            playcoverLogs: "\(configured.root)/playcover/logs",
            playcoverPendingLaunch:
                "\(configured.root)/playcover/pending-launch.json",
            playcoverPendingLaunchLock:
                "\(configured.root)/playcover/pending-launch.lock",
            playcoverLastPrepared: "\(configured.root)/playcover/last-prepared.json",
            playcoverPrepared: "\(configured.root)/playcover/prepared",
            playcoverRuntime: "\(configured.root)/playcover/IOSUsePlayRuntime.framework"
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
