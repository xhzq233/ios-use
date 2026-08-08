#if DEBUG && canImport(Darwin)
import Darwin
import Foundation

enum PlayCoverLaunchCrashCut {
    static let environmentKey =
        "IOS_USE_PLAYCOVER_LAUNCH_CRASH_CUT"
    static let exitStatus: Int32 = 86

    enum Point: String, CaseIterable {
        case afterOpenReturned
        case afterDriverLockDurable
    }

    private static let configuredPoint = Point(
        rawValue:
            ProcessInfo.processInfo.environment[environmentKey]
                ?? ""
    )

    @inline(never)
    static func hit(_ point: Point) {
        guard configuredPoint == point else {
            return
        }
        Darwin._exit(exitStatus)
    }
}
#endif
