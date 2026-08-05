import Darwin
import Foundation
import Security
import SQLite3

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

private func insertionStatus(_ discriminator: String) -> OSStatus {
    PlayKeychain.add(
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String:
                "hardening-account-\(discriminator)",
            kSecAttrService as String:
                "hardening-service-\(discriminator)",
            kSecValueData as String: Data(discriminator.utf8)
        ],
        result: nil
    )
}

private func insertionQuery(_ discriminator: String) -> NSDictionary {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String:
            "hardening-account-\(discriminator)",
        kSecAttrService as String:
            "hardening-service-\(discriminator)",
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
}

private func createOwnerOnlyFile(
    at url: URL,
    contents: Data
) {
    require(
        FileManager.default.createFile(
            atPath: url.path,
            contents: contents,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ),
        "could not create fixture \(url.lastPathComponent)"
    )
}

private func requireRejectedStorage(
    databaseURL: URL,
    discriminator: String
) {
    PlayKeychain.configureDatabaseURLForTesting(databaseURL)
    require(
        insertionStatus(discriminator) == errSecIO,
        "unsafe database leaf was accepted for \(discriminator)"
    )
}

private func runLeafTypeChecks(
    primaryDatabaseURL: URL
) {
    let root = primaryDatabaseURL
        .deletingLastPathComponent()
        .appendingPathComponent("leaf-validation", isDirectory: true)
    do {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    } catch {
        fail("could not create leaf fixtures: \(error)")
    }
    defer {
        PlayKeychain.configureDatabaseURLForTesting(primaryDatabaseURL)
    }

    let sentinel = Data("playchain-victim-sentinel".utf8)
    for kind in ["symlink", "hardlink"] {
        let victim = root.appendingPathComponent("\(kind)-victim")
        let database = root.appendingPathComponent("\(kind).db")
        createOwnerOnlyFile(at: victim, contents: sentinel)
        let result = kind == "symlink"
            ? symlink(victim.path, database.path)
            : link(victim.path, database.path)
        require(result == 0, "could not create \(kind) fixture")
        requireRejectedStorage(
            databaseURL: database,
            discriminator: kind
        )
        require(
            (try? Data(contentsOf: victim)) == sentinel,
            "\(kind) victim was modified"
        )
    }
}

private func leaveHotRollbackJournal(
    databaseURL: URL
) -> Never {
    var sqlite3DB: OpaquePointer?
    let openResult = sqlite3_open_v2(
        databaseURL.path,
        &sqlite3DB,
        SQLITE_OPEN_READWRITE |
            SQLITE_OPEN_FULLMUTEX |
            SQLITE_OPEN_NOFOLLOW,
        nil
    )
    guard openResult == SQLITE_OK else {
        let detail = sqlite3DB.map {
            String(cString: sqlite3_errmsg($0))
        } ?? "no SQLite handle"
        fail(
            "could not open the hot-journal fixture database "
                + "\(databaseURL.path) (\(openResult)): \(detail)"
        )
    }
    guard let sqlite3DB else {
        fail("SQLite did not return a hot-journal fixture handle")
    }
    require(
        sqlite3_exec(
            sqlite3DB,
            "PRAGMA journal_mode = DELETE; "
                + "BEGIN IMMEDIATE; "
                + "UPDATE genp SET v_Data = X'6166746572';",
            nil,
            nil,
            nil
        ) == SQLITE_OK,
        "could not start the hot-journal fixture transaction"
    )
    require(
        sqlite3_db_cacheflush(sqlite3DB) == SQLITE_OK,
        "could not spill the hot-journal fixture transaction"
    )
    var journalStatus = stat()
    require(
        lstat(databaseURL.path + "-journal", &journalStatus) == 0,
        "hot rollback journal was not created"
    )
    _exit(0)
}

private func runHotRollbackRecoveryCheck(
    fixtureRoot: URL
) {
    let discriminator = "hot-journal-recovery"
    let databaseURL = fixtureRoot
        .appendingPathComponent("hot-journal-recovery.db")
    PlayKeychain.configureDatabaseURLForTesting(databaseURL)
    require(
        insertionStatus(discriminator) == errSecSuccess,
        "could not seed the hot-journal recovery fixture"
    )

    let child = Process()
    child.executableURL = URL(
        fileURLWithPath: CommandLine.arguments[0]
    )
    child.arguments = [
        databaseURL.path,
        "leave-hot-journal"
    ]
    do {
        try child.run()
    } catch {
        fail("could not launch the hot-journal child: \(error)")
    }
    child.waitUntilExit()
    require(
        child.terminationReason == .exit
            && child.terminationStatus == 0,
        "hot-journal child did not exit cleanly"
    )

    var journalStatus = stat()
    require(
        lstat(databaseURL.path + "-journal", &journalStatus) == 0,
        "hot rollback journal did not survive the child"
    )
    PlayKeychain.configureDatabaseURLForTesting(databaseURL)
    require(
        copiedData(insertionQuery(discriminator))
            == Data(discriminator.utf8),
        "hot rollback journal did not restore committed data"
    )
    require(
        lstat(databaseURL.path + "-journal", &journalStatus) != 0
            && errno == ENOENT,
        "hot rollback journal was not cleaned after recovery"
    )
}

@main
enum PlayChainPersistenceHarness {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fail(
                "usage: harness <database-path> "
                    + "<seed|update|delete>"
            )
        }
        let requestedDatabaseURL = URL(
            fileURLWithPath: CommandLine.arguments[1]
        ).standardizedFileURL
        var resolvedParent = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        require(
            realpath(
                requestedDatabaseURL
                    .deletingLastPathComponent().path,
                &resolvedParent
            ) != nil,
            "database parent could not be canonicalized"
        )
        let databaseURL = URL(
            fileURLWithPath: String(cString: resolvedParent),
            isDirectory: true
        ).appendingPathComponent(
            requestedDatabaseURL.lastPathComponent
        )
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

        let mode = CommandLine.arguments[2]
        if mode == "seed" {
            runLeafTypeChecks(primaryDatabaseURL: databaseURL)
            runHotRollbackRecoveryCheck(
                fixtureRoot:
                    databaseURL.deletingLastPathComponent()
            )
            PlayKeychain.configureDatabaseURLForTesting(databaseURL)
        }

        let account = "ios-use-playchain-account"
        let service = "ios-use-playchain-service"
        let query: NSDictionary = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
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
        case "leave-hot-journal":
            leaveHotRollbackJournal(databaseURL: databaseURL)
        default:
            fail("unknown mode \(mode)")
        }

        print("[playchain-harness] \(mode) PASS")
    }
}
