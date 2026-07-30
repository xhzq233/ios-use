#if DEBUG && canImport(Darwin)
import Darwin
import Foundation

enum PlayCoverLaunchCrashCut {
    static let environmentKey =
        "IOS_USE_PLAYCOVER_LAUNCH_CRASH_CUT"
    static let aliasRootEnvironmentKey =
        "IOS_USE_PLAYCOVER_LAUNCH_CRASH_ALIAS_ROOT"
    static let exitStatus: Int32 = 86

    enum Point: String, CaseIterable {
        case afterPreparationPinned
        case afterSubmissionArmed
        case afterOpenReturned
        case beforeTerminalCallbackDurable
        case afterTerminalCallbackDurable
        case beforeCallbackOwnerDurable
        case afterCallbackOwnerDurable
        case beforeRuntimeOwnerDurable
        case afterRuntimeOwnerDurable
        case beforeOwnerDurable
        case afterOwnerDurable
        case afterReadyGate
        case afterDriverLockDurable
        case afterPendingDriverLockCommitted
        case afterPendingDriverLockRetired
        case afterPendingPinRetired
        case afterCleanupPendingPinCleared
        case afterCleanupActivePinCleared
        case afterPendingJournalRemoved
    }

    private static let configuredPoint = Point(
        rawValue:
            ProcessInfo.processInfo.environment[environmentKey]
                ?? ""
    )

    static var launchAliasRoot: URL? {
        guard let value = ProcessInfo.processInfo.environment[
            aliasRootEnvironmentKey
        ],
              value.hasPrefix("/"),
              !value.utf8.contains(0) else {
            return nil
        }
        return URL(
            fileURLWithPath: value,
            isDirectory: true
        ).standardizedFileURL
    }

    @inline(never)
    static func hit(_ point: Point) {
        guard configuredPoint == point else {
            return
        }
        Darwin._exit(exitStatus)
    }
}
#endif
