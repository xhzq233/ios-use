import CryptoKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Account-wide launch exclusion for one Mac bundle identifier.
///
/// A Home selects the prepared generation and session state, but it does not
/// create another copy of a running macOS bundle.  The lock is deliberately
/// outside IOS_USE_HOME so two Homes cannot race into the same LaunchServices
/// identity.  The process census is checked while the lock is held.
final class PlayCoverBundleStartLock {
    #if canImport(Darwin)
    private let descriptor: Int32
    #endif

    #if canImport(Darwin)
    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }
    #else
    private init() {}
    #endif

    deinit {
        #if canImport(Darwin)
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        #endif
    }

    #if canImport(AppKit)
    static var runningBundlePIDsOverrideForTesting:
        ((String) -> [Int32])?
    #endif

    static func acquire(
        bundleIdentifier: String,
        paths: IOSUsePaths
    ) throws -> PlayCoverBundleStartLock {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= 200 else {
            throw PlayCoverBackendError.launchFailed(
                "bundle identifier cannot form an account launch lock"
            )
        }
        try PlayCoverManagedAppService.withSecureManagedDirectories(
            paths: paths
        ) { _ in () }
        #if canImport(Darwin)
        let digest = SHA256.hash(data: Data(bundleIdentifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let lockPath = "\(paths.playcoverGlobalLocks)/bundle-\(digest).lock"
        let descriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot open account launch lock: errno \(errno)"
            )
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            let errorNumber = errno
            Darwin.close(descriptor)
            throw PlayCoverBackendError.launchFailed(
                "cannot secure account launch lock: errno \(errorNumber)"
            )
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let errorNumber = errno
            Darwin.close(descriptor)
            throw PlayCoverBackendError.launchFailed(
                "cannot acquire account launch lock: errno \(errorNumber)"
            )
        }
        let lock = PlayCoverBundleStartLock(descriptor: descriptor)
        let pids = try runningBundlePIDs(bundleIdentifier)
        if let pid = pids.first {
            throw PlayCoverBackendError.bundleAlreadyRunning(
                bundleIdentifier: bundleIdentifier,
                pid: pid
            )
        }
        return lock
        #else
        return PlayCoverBundleStartLock()
        #endif
    }

    #if canImport(Darwin)
    private static func runningBundlePIDs(
        _ bundleIdentifier: String
    ) throws -> [Int32] {
        if let runningBundlePIDsOverrideForTesting {
            return runningBundlePIDsOverrideForTesting(bundleIdentifier)
        }
        var pids = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        .filter { !$0.isTerminated }
        .map(\.processIdentifier)
        .filter { $0 > 0 }
        for pid in try processCensusPIDs(bundleIdentifier)
            where !pids.contains(pid) {
            pids.append(pid)
        }
        return pids.sorted()
    }

    /// LaunchServices does not enumerate every executable owner (for example
    /// an owner with stale registration). Walk the current user's process
    /// table and inspect each accessible App Info.plist as a second census.
    /// System-owned and transient/inaccessible processes are excluded; a
    /// failure to enumerate the process table itself remains fail-closed.
    private static func processCensusPIDs(
        _ bundleIdentifier: String
    ) throws -> [Int32] {
        var capacity = 512
        for _ in 0..<4 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(
                    UInt32(PROC_ALL_PIDS),
                    0,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            guard byteCount >= 0 else {
                throw PlayCoverBackendError.launchFailed(
                    "cannot enumerate account processes for bundle preflight: "
                        + "errno \(errno)"
                )
            }
            let returnedCount = Int(byteCount) / MemoryLayout<pid_t>.size
            if returnedCount >= pids.count {
                capacity *= 2
                continue
            }
            var matches: [Int32] = []
            for pid in pids.prefix(returnedCount) where pid > 0 {
                guard currentUserProcess(pid) else { continue }
                guard let executable = PlayCoverRuntimeClient
                    .executablePath(for: pid) else { continue }
                // Non-App helper processes cannot match a bundle identifier;
                // only an executable below an App bundle requires plist proof.
                guard executable.contains(".app/") else { continue }
                guard let identifier = bundleIdentifierForExecutable(
                    forExecutablePath: executable
                ) else { continue }
                if identifier == bundleIdentifier {
                    matches.append(Int32(pid))
                }
            }
            return matches
        }
        throw PlayCoverBackendError.launchFailed(
            "account process census did not fit its bounded buffer"
        )
    }

    private static func currentUserProcess(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        return actualSize == expectedSize && info.pbi_uid == geteuid()
    }

    private static func bundleIdentifierForExecutable(
        forExecutablePath executablePath: String
    ) -> String? {
        var candidate = URL(
            fileURLWithPath: executablePath,
            isDirectory: false
        ).deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                let plistURL = candidate.appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: plistURL),
                      let plist = try? PropertyListSerialization
                          .propertyList(
                              from: data,
                              options: [],
                              format: nil
                          ),
                      let dictionary = plist as? [String: Any] else {
                    return nil
                }
                return dictionary["CFBundleIdentifier"] as? String
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
    #endif
}
