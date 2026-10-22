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

private func runKeyDecodingChecks() {
    // Use the production database to exercise malformed persisted records too;
    // SecItemAdd emulation may reject a malformed key before it can be queried.
    func checkFailure(_ name: String, attributes: [String: Any], reference: Bool) {
        let item = NSMutableDictionary(dictionary: attributes)
        item[kSecAttrAccessGroup as String] = name
        require(PlayKeychainDB.shared.insert(item) != nil, "could not seed \(name)")
        let query = NSMutableDictionary(dictionary: [
            kSecClass as String: attributes[kSecClass as String]!,
            kSecAttrAccessGroup as String: name
        ])
        let before = PlayKeychainDB.shared.query(query)?.first
        require(before != nil, "could not read \(name)")
        if reference { query[kSecReturnRef as String] = true }
        var result: Unmanaged<CFTypeRef>?
        require(
            PlayKeychain.copyMatching(query, result: &result) == errSecDecode,
            "\(name) did not return errSecDecode"
        )
        require(result == nil, "\(name) wrote a result on failure")
        require(
            PlayKeychain.copyMatching(query, result: nil) == errSecDecode,
            "\(name) failed with a nil output pointer"
        )
        require(
            PlayKeychainDB.shared.query(query)?.first == before,
            "\(name) changed stored data on decode failure"
        )
        require(PlayKeychain.delete(query) == errSecSuccess, "could not delete \(name)")
    }

    let password: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: "synthetic-key-decode",
        kSecAttrService as String: "ios-use-key-decode",
        kSecValueData as String: Data("not-a-key".utf8)
    ]
    checkFailure("password-reference", attributes: password, reference: true)
    var invalidType = password
    invalidType[kSecValueData as String] = "not-data"
    checkFailure("password-reference-type", attributes: invalidType, reference: true)
    var persistent = password
    persistent[kSecValuePersistentRef as String] = Data("invalid-persistent-reference".utf8)
    checkFailure("persistent-reference", attributes: persistent, reference: true)

    let keyAttributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 2048
    ]
    guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, nil),
          let publicKey = SecKeyCopyPublicKey(privateKey),
          let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
        fail("could not generate an ephemeral RSA key")
    }
    let keyItem: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        kSecValueData as String: publicData
    ]
    for reference in [false, true] {
        for data: Any in [Data("not-a-key".utf8), "not-data"] {
            var invalidKey = keyItem
            invalidKey[kSecValueData as String] = data
            checkFailure("invalid-key-\(reference)", attributes: invalidKey, reference: reference)
        }
    }
    for missing in [kSecAttrKeyType, kSecAttrKeyClass] {
        var incomplete = keyItem
        incomplete.removeValue(forKey: missing as String)
        checkFailure("missing-\(missing)", attributes: incomplete, reference: false)
    }

    for metadata in [kSecAttrKeyType, kSecAttrKeyClass] {
        var malformed = keyItem
        malformed[metadata as String] = Data("invalid-metadata".utf8)
        for reference in [false, true] {
            checkFailure("metadata-\(metadata)-\(reference)", attributes: malformed, reference: reference)
        }
    }

    // Valid decoding must still produce a usable key, including the existing
    // RSA/public defaults in the reference-return branch.
    for defaults in [false, true] {
        var valid = defaults ? password : keyItem
        valid[kSecValueData as String] = publicData
        valid[kSecAttrAccessGroup as String] = "valid-round-trip"
        require(PlayKeychainDB.shared.insert(valid as NSDictionary) != nil, "could not seed valid key")
        let query = NSMutableDictionary(dictionary: [
            kSecClass as String: valid[kSecClass as String]!,
            kSecAttrAccessGroup as String: "valid-round-trip"
        ])
        for reference in defaults ? [true] : [false, true] {
            if reference { query[kSecReturnRef as String] = true }
            var result: Unmanaged<CFTypeRef>?
            require(PlayKeychain.copyMatching(query, result: &result) == errSecSuccess, "valid key failed")
            guard let value = result?.takeRetainedValue() else { fail("valid key was not returned") }
            require(CFGetTypeID(value) == SecKeyGetTypeID(), "returned value is not a SecKey")
            let copiedKey = value as! SecKey
            require(
                SecKeyCopyExternalRepresentation(copiedKey, nil) as Data? == publicData,
                "key bytes changed during decoding"
            )
            let message = Data("synthetic-key-round-trip".utf8)
            guard let signature = SecKeyCreateSignature(
                privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil
            ) else { fail("could not sign test message") }
            require(
                SecKeyVerifySignature(copiedKey, .rsaSignatureMessagePKCS1v15SHA256,
                                      message as CFData, signature, nil),
                "decoded key could not verify a signature"
            )
            require(PlayKeychain.copyMatching(query, result: nil) == errSecSuccess, "valid nil result failed")
        }
        require(PlayKeychain.delete(query) == errSecSuccess, "could not delete valid key")
    }
}

@main
enum PlayChainPersistenceHarness {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fail(
                "usage: harness <database-path> "
                    + "<seed|update|delete|key-decoding>"
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
        case "key-decoding":
            runKeyDecodingChecks()
        case "leave-hot-journal":
            leaveHotRollbackJournal(databaseURL: databaseURL)
        default:
            fail("unknown mode \(mode)")
        }

        print("[playchain-harness] \(mode) PASS")
    }
}
