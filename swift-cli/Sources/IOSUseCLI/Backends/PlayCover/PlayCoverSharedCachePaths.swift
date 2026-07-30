import Foundation

struct PlayCoverSharedCachePaths: Equatable, Sendable {
    let preparedSubstrateRoot: String
    let preparedSubstrateObjects: String
    let preparedSubstrateLocks: String

    /// The default uses the account home, not `IOS_USE_HOME` or the `HOME`
    /// environment value.
    static func resolve(
        preparedSubstrateRoot explicitRoot: String? = nil
    ) throws -> PlayCoverSharedCachePaths {
        let root: String
        if let explicitRoot {
            guard explicitRoot.hasPrefix("/") else {
                throw PlayCoverSharedSubstrateCacheError.unavailable(
                    "cache root must be absolute"
                )
            }
            root = URL(
                fileURLWithPath: explicitRoot,
                isDirectory: true
            ).standardizedFileURL.path
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/dev.ios-use")
                .appendingPathComponent("playcover")
                .appendingPathComponent("prepared-substrate-v1")
                .standardizedFileURL.path
        }
        guard root != "/" else {
            throw PlayCoverSharedSubstrateCacheError.unavailable(
                "cache root cannot be the filesystem root"
            )
        }
        return PlayCoverSharedCachePaths(
            preparedSubstrateRoot: root,
            preparedSubstrateObjects: "\(root)/objects",
            preparedSubstrateLocks: "\(root)/locks"
        )
    }
}
