import Foundation
import CryptoKit
@testable import IOSUseCLI

/// Keeps every PlayCover test namespace below its fixture root. Production
/// path resolution deliberately has no environment override for the
/// account-global cache or fixed socket root.
func resolvePlayCoverTestPaths(
    environment: [String: String],
    accountHomeDirectory: String? = nil
) -> IOSUsePaths {
    let logicalHome =
        environment["IOS_USE_HOME"]
        ?? environment["HOME"].map { "\($0)/.ios-use" }
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "ios-use-test-\(UUID().uuidString)",
                isDirectory: true
            ).path
    let accountHome = accountHomeDirectory
        ?? URL(
            fileURLWithPath: logicalHome,
            isDirectory: true
        ).appendingPathComponent(
            ".account-global-test",
            isDirectory: true
        ).path
    let socketToken = SHA256.hash(
        data: Data(accountHome.utf8)
    ).map { String(format: "%02x", $0) }.joined()
    let socketRoot =
        "/private/tmp/ios-use-test-\(socketToken.prefix(16))"
    return IOSUsePaths.resolve(
        environment: environment,
        accountHomeDirectoryOverrideForTesting: accountHome,
        socketRootOverrideForTesting: socketRoot
    )
}
