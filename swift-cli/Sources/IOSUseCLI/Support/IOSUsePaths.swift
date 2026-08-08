import Foundation
import CryptoKit
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
    public let playcoverLaunching: String
    public let playcoverCurrentBundle: String
    public let playcoverApps: String
    public let playcoverLocks: String
    public let playcoverLegacyPrepared: String
    public let playcoverLegacyLaunchFacades: String
    public let playcoverHomeID: String
    public let accountCacheRoot: String
    public let accountApplicationSupportRoot: String
    public let knownHomes: String
    public let playcoverFridaSourceCache: String
    public let playcoverFridaBuildCache: String
    public let playcoverSocketRoot: String
    public let playcoverPlayChain: String
    public let playcoverSigningBinding: String

    public func macRuntimeSocketPath(
        sessionID: String
    ) throws -> String {
        try Self.macRuntimeSocketPath(
            sessionID: sessionID,
            homeID: playcoverHomeID,
            socketRoot: playcoverSocketRoot
        )
    }

    static func macRuntimeSocketPath(
        sessionID: String,
        homeID: String,
        socketRoot: String
    ) throws -> String {
        let token = sessionID
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        guard !token.isEmpty else {
            throw CLIParseError.invalidValue(
                "Mac sessionID cannot produce a runtime socket name."
            )
        }
        // `/tmp` is a root-owned symlink to `/private/tmp` on macOS.  The
        // injected App is sandboxed, so its socket path must use the same
        // canonical spelling as the SBPL entitlement generated at prepare
        // time. `launch` creates `playcoverSocketRoot` first;
        // resolving an otherwise non-existing prefix remains a no-op for
        // parser/unit-test paths.
        let canonicalRun = URL(
            fileURLWithPath: socketRoot,
            isDirectory: true
        ).standardizedFileURL.path
        let resolvedRun = canonicalExistingPath(canonicalRun)
        let socketIdentity = SHA256.hash(
            data: Data(
                "\(homeID)\u{0}\(token)".utf8
            )
        ).map { String(format: "%02x", $0) }.joined()
        let socket =
            "\(resolvedRun)/s-\(socketIdentity.prefix(32)).sock"
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

    private static func canonicalExistingPath(_ path: String) -> String {
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

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> IOSUsePaths {
        resolve(
            environment: environment,
            accountHomeDirectoryOverrideForTesting: nil,
            socketRootOverrideForTesting: nil
        )
    }

    static func resolve(
        environment: [String: String],
        accountHomeDirectoryOverrideForTesting: String?,
        socketRootOverrideForTesting: String? = nil
    ) -> IOSUsePaths {
        let configured = configuredRoot(environment: environment)
        let accountHome = accountHome(
            overrideForTesting:
                accountHomeDirectoryOverrideForTesting
        )
        let canonicalConfiguredRoot = canonicalExistingPrefix(
            configured.root
        )
        let homeID = SHA256.hash(
            data: Data(canonicalConfiguredRoot.utf8)
        ).map { String(format: "%02x", $0) }.joined()
        let accountCacheRoot =
            "\(accountHome)/Library/Caches/dev.ios-use"
        let accountApplicationSupportRoot =
            "\(accountHome)/Library/Application Support/dev.ios-use"
        let playChain =
            "\(accountApplicationSupportRoot)/mac/playchain"
        #if canImport(Darwin)
        let socketRoot = canonicalExistingPrefix(
            socketRootOverrideForTesting
            ?? "/private/tmp/dev.ios-use-\(geteuid())"
        )
        #else
        let socketRoot = "\(accountHome)/.ios-use-runtime"
        #endif
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
            playcover: "\(configured.root)/mac",
            playcoverRun: "\(configured.root)/mac/run",
            playcoverLogs: "\(configured.root)/logs/mac",
            playcoverLaunching:
                "\(configured.root)/mac/launching.json",
            playcoverCurrentBundle:
                "\(configured.root)/mac/current-bundle.json",
            playcoverApps: "\(accountCacheRoot)/mac/apps",
            playcoverLocks: "\(accountCacheRoot)/mac/locks",
            playcoverLegacyPrepared:
                "\(accountCacheRoot)/mac/prepared",
            playcoverLegacyLaunchFacades:
                "\(accountCacheRoot)/mac/launch-facades",
            playcoverHomeID: homeID,
            accountCacheRoot: accountCacheRoot,
            accountApplicationSupportRoot:
                accountApplicationSupportRoot,
            knownHomes: "\(accountApplicationSupportRoot)/homes",
            playcoverFridaSourceCache:
                "\(accountCacheRoot)/mac/frida-engine/source",
            playcoverFridaBuildCache:
                "\(accountCacheRoot)/mac/frida-engine/build",
            playcoverSocketRoot: socketRoot,
            playcoverPlayChain: playChain,
            playcoverSigningBinding:
                "\(accountApplicationSupportRoot)/mac-stable-signing-binding-v1.json",
        )
    }

    /// Production resolves account-scoped immutable/runtime storage from the
    /// real login account, never from HOME or IOS_USE_HOME. Tests may provide
    /// an explicit owner-only account root without changing production
    /// behavior.
    private static func accountHome(
        overrideForTesting: String?
    ) -> String {
        let raw: String
        if let override = overrideForTesting,
           override.hasPrefix("/") {
            raw = URL(
                fileURLWithPath: override,
                isDirectory: true
            ).standardizedFileURL.path
        } else {
            #if canImport(Darwin)
            guard let password = getpwuid(geteuid()),
                  let directory = password.pointee.pw_dir else {
                // `resolve` is intentionally non-throwing. `/dev/null` makes
                // every later managed-directory open fail closed without
                // consulting attacker-controlled HOME.
                return "/dev/null"
            }
            raw = String(cString: directory)
            #else
            raw = FileManager.default.homeDirectoryForCurrentUser
                .standardizedFileURL.path
            #endif
        }
        return canonicalExistingPrefix(raw)
    }

    private static func canonicalExistingPrefix(
        _ path: String
    ) -> String {
        var existing = URL(
            fileURLWithPath: path,
            isDirectory: true
        ).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let canonicalExisting: String
        #if canImport(Darwin)
        var buffer = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        if existing.path.withCString({
            Darwin.realpath($0, &buffer)
        }) != nil {
            canonicalExisting = String(cString: buffer)
        } else {
            canonicalExisting = existing.path
        }
        #else
        canonicalExisting =
            existing.resolvingSymlinksInPath().path
        #endif
        return suffix.reduce(canonicalExisting) {
            ($0 as NSString).appendingPathComponent($1)
        }
    }

    private static func configuredRoot(environment: [String: String]) -> (root: String, hasExplicitHome: Bool) {
        if let iosUseHome = environment["IOS_USE_HOME"], !iosUseHome.isEmpty {
            return (iosUseHome, true)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return ("\(home)/.ios-use", false)
    }
}
