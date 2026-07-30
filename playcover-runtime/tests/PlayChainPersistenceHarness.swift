import Foundation
import Security

@objc(PlaySettings)
@objcMembers
final class PlaySettings: NSObject {
    static let shared = PlaySettings()
    let playChainDebugging = false
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
        Data("[playchain-harness] FAIL: \(message)\n".utf8)
    )
    exit(1)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        fail(message)
    }
}

private func copiedData(_ query: NSDictionary) -> Data? {
    var result: Unmanaged<CFTypeRef>?
    let status = PlayKeychain.copyMatching(query, result: &result)
    guard status == errSecSuccess else {
        return nil
    }
    return result?.takeRetainedValue() as? Data
}

@main
enum PlayChainPersistenceHarness {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fail("usage: harness <database-path> <seed|update|delete>")
        }
        let databaseURL = URL(
            fileURLWithPath: CommandLine.arguments[1]
        ).standardizedFileURL
        PlayKeychain.configureDatabaseURLForTesting(databaseURL)
        let storageIdentity = PlayKeychain.storageIdentity()
        require(
            storageIdentity["macRootPath"] as? String
                == databaseURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .path,
            "storage identity did not expose macRootPath"
        )
        require(
            storageIdentity["playcoverRootPath"] == nil,
            "storage identity exposed the pre-release playcoverRootPath"
        )

        let account = "ios-use-playchain-account"
        let service = "ios-use-playchain-service"
        let query: NSDictionary = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let mode = CommandLine.arguments[2]
        switch mode {
        case "seed":
            let attributes = NSMutableDictionary(dictionary: query)
            attributes.removeObject(forKey: kSecMatchLimit)
            attributes[kSecValueData as String] = Data("before".utf8)
            require(
                PlayKeychain.add(
                    attributes,
                    result: nil
                ) == errSecSuccess,
                "SecItemAdd emulation failed"
            )
            require(
                copiedData(query) == Data("before".utf8),
                "SecItemCopyMatching did not read newly added data"
            )
        case "update":
            require(
                copiedData(query) == Data("before".utf8),
                "add did not persist across process restart"
            )
            require(
                PlayKeychain.update(
                    query,
                    attributesToUpdate: [
                        kSecValueData as String:
                            Data("after".utf8)
                    ]
                ) == errSecSuccess,
                "SecItemUpdate emulation failed"
            )
            require(
                copiedData(query) == Data("after".utf8),
                "updated data was not readable"
            )
        case "delete":
            require(
                copiedData(query) == Data("after".utf8),
                "update did not persist across process restart"
            )
            require(
                PlayKeychain.delete(query) == errSecSuccess,
                "SecItemDelete emulation failed"
            )
            var deletedResult: Unmanaged<CFTypeRef>?
            require(
                PlayKeychain.copyMatching(
                    query,
                    result: &deletedResult
                ) == errSecItemNotFound,
                "deleted item remained readable"
            )
        default:
            fail("unknown mode \(mode)")
        }

        print("[playchain-harness] \(mode) PASS")
    }
}
