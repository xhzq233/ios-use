//
//  KeyCover.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import Security
#if canImport(Darwin)
import Darwin
#endif

struct KeyCover {
    static var shared = KeyCover()
    static var playChainPath: URL {
        let playChainDir = PlayTools.playCoverContainer.appendingPathComponent("playchain")

        if !FileManager.default.fileExists(atPath: playChainDir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: playChainDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                Log.shared.error(error)
            }
        }

        return playChainDir
    }

    // This is only exposed while a managed App is running.
    var keyCoverPlainTextKey: String?

    func isKeyCoverEnabled() -> Bool {
        return KeyCoverPreferences.shared.keyCoverEnabled != .disabled
    }

    func listKeychains() -> [KeyCoverKey] {
        // Enumerate all the keychains
        let keychains = try? FileManager.default
            .contentsOfDirectory(at: KeyCover.playChainPath,
                                 includingPropertiesForKeys: nil,
                                 options: .skipsHiddenFiles)
        return Array(Set((keychains ?? []).map {
            $0.deletingPathExtension().lastPathComponent
        })).sorted().map(KeyCoverKey.init)
    }

    func unlockedCount() -> Int {
        var count = 0
        for keychain in listKeychains() where !keychain.chainEncryptionStatus {
            count += 1
        }
        return count
    }

    func unlockChain(_ keychain: KeyCoverKey) throws {
        if keychain.chainEncryptionStatus {
            try keychain.decryptKeyDB()
        }
    }

    func lockChain(_ keychain: KeyCoverKey) throws {
        if keyCoverPlainTextKey == nil {
            return
        }
        if !keychain.chainEncryptionStatus {
            try keychain.encryptKeyDB()
        }
    }

    mutating func restorePersistedKey() {
        keyCoverPlainTextKey = KeyCoverPassword.shared.getKeyCoverPassword()
    }
}

struct KeyCoverKey: Hashable {
    static let encryptedKeyExtension = "keyCover"

    var appBundleID: String

    var decryptedKeyDB: URL {
        KeyCover.playChainPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension("db")
    }
    var encryptedKeyDB: URL {
        KeyCover.playChainPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension(KeyCoverKey.encryptedKeyExtension)
    }

    private var transactionTemporaryDB: URL {
        KeyCover.playChainPath.appendingPathComponent(
            ".\(appBundleID).ios-use.tmp"
        )
    }

    var chainEncryptionStatus: Bool {
        return FileManager.default.fileExists(atPath: encryptedKeyDB.path)
    }

    func encryptKeyDB() throws {
        guard let plainTextKey = KeyCover.shared.keyCoverPlainTextKey else {
            throw PlayCoverUpstreamError.commandFailed(
                "KeyCover master key is unavailable"
            )
        }
        try atomicTransform(
            input: decryptedKeyDB,
            output: encryptedKeyDB,
            arguments: [
            "enc", "-aes-256-cbc", "-pbkdf2", "-A",
            "-k", plainTextKey,
            ]
        )
    }

    func decryptKeyDB() throws {
        guard let plainTextKey = KeyCover.shared.keyCoverPlainTextKey else {
            throw PlayCoverUpstreamError.commandFailed(
                "KeyCover master key is unavailable"
            )
        }
        try atomicTransform(
            input: encryptedKeyDB,
            output: decryptedKeyDB,
            arguments: [
            "enc", "-aes-256-cbc", "-pbkdf2", "-A", "-d",
            "-k", plainTextKey,
            ]
        )
    }

    func deleteKeyDB() throws {
        try FileManager.default.removeItem(at: decryptedKeyDB)
    }

    func deleteEncryptedKeyDB() throws {
        try FileManager.default.removeItem(at: encryptedKeyDB)
    }

    func removeInterruptedTemporary() throws {
        #if canImport(Darwin)
        var status = stat()
        if lstat(transactionTemporaryDB.path, &status) != 0 {
            guard errno == ENOENT else {
                throw PlayCoverUpstreamError.commandFailed(
                    "cannot inspect interrupted KeyCover transaction"
                )
            }
            return
        }
        guard status.st_mode & S_IFMT != S_IFDIR else {
            throw PlayCoverUpstreamError.commandFailed(
                "interrupted KeyCover transaction is a directory"
            )
        }
        try FileManager.default.removeItem(at: transactionTemporaryDB)
        #else
        try? FileManager.default.removeItem(
            at: transactionTemporaryDB
        )
        #endif
    }

    private func atomicTransform(
        input: URL,
        output: URL,
        arguments: [String]
    ) throws {
        try removeInterruptedTemporary()
        var removeTemporary = true
        defer {
            if removeTemporary {
                try? FileManager.default.removeItem(
                    at: transactionTemporaryDB
                )
            }
        }
        guard FileManager.default.createFile(
            atPath: transactionTemporaryDB.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw PlayCoverUpstreamError.commandFailed(
                "cannot create KeyCover transaction output"
            )
        }
        try runOpenSSL(
            arguments + [
                "-in", input.path,
                "-out", transactionTemporaryDB.path,
            ]
        )
        #if canImport(Darwin)
        guard Darwin.renameatx_np(
            AT_FDCWD,
            transactionTemporaryDB.path,
            AT_FDCWD,
            output.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw PlayCoverUpstreamError.commandFailed(
                "cannot publish KeyCover transaction"
            )
        }
        removeTemporary = false
        try FileManager.default.removeItem(at: input)
        #else
        try FileManager.default.moveItem(
            at: transactionTemporaryDB,
            to: output
        )
        removeTemporary = false
        try FileManager.default.removeItem(at: input)
        #endif
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.currentDirectoryURL = KeyCover.playChainPath
        task.arguments = arguments
        let errorPipe = Pipe()
        task.standardError = errorPipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationReason == .exit,
              task.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw PlayCoverUpstreamError.commandFailed(
                "KeyCover openssl failed: \(detail)"
            )
        }
    }
}

class KeyCoverPassword {
    static let shared = KeyCoverPassword()

    var tag: String {
        let identity = Data(KeyCover.playChainPath.path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return "io.playcover.masterkey.\(identity)"
    }

    func setKeyCoverPassword(_ key: String) {
        // swiftlint: disable force_unwrapping
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecValueData as String: key.data(using: .utf8)!]
        // swiftlint: enable force_unwrapping
        // thank you apple very cool
        // Get the key
        let oldKey = getKeyCoverPassword()
        // if it is not nil, then we need to decrypt all the keychains
        if oldKey != nil {
            KeyCover.shared.keyCoverPlainTextKey = oldKey
            for keychain in KeyCover.shared.listKeychains() where keychain.chainEncryptionStatus {
                try? keychain.decryptKeyDB()
            }
            KeyCover.shared.keyCoverPlainTextKey = nil
            // Remove any existing master key
            SecItemDelete(query as CFDictionary)
        }

        // Store the master key in macOS keychain
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("Error storing master key in keychain: \(status)")
        }

        KeyCover.shared.keyCoverPlainTextKey = key

        // Encrypts all keychains
        for keychain in KeyCover.shared.listKeychains() where !keychain.chainEncryptionStatus {
            try? keychain.encryptKeyDB()
        }

    }

    func getKeyCoverPassword() -> String? {
        // Get the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecReturnData as String: kCFBooleanTrue as Any,
                                    kSecMatchLimit as String: kSecMatchLimitOne]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    func removeKeyCoverPassword() {
        // Decrypt all key dbs
        for chain in KeyCover.shared.listKeychains() where chain.chainEncryptionStatus {
                try? chain.decryptKeyDB()
        }

        // Remove the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Error removing master key from keychain: \(status)")
        }

        KeyCoverPreferences.shared.keyCoverEnabled = .disabled
        KeyCover.shared.keyCoverPlainTextKey = nil

    }

    func forceResetKeyCoverPassword() {
        // If a key is in memory, don't do anything (prevent accidental deletion)
        if KeyCover.shared.keyCoverPlainTextKey != nil {
            return
        }
        // Remove the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Error removing master key from keychain: \(status)")
        }

        KeyCoverPreferences.shared.keyCoverEnabled = .disabled
        KeyCover.shared.keyCoverPlainTextKey = nil

        // Being a force reset, we have to nuke everything (because it's useless otherwise)
        for chain in KeyCover.shared.listKeychains() {
            try? chain.deleteEncryptedKeyDB()
        }

    }

    func validatePassword(_ key: String) -> Bool {
        return key == getKeyCoverPassword()
    }

    func generateVerySecurePassword() -> String {
        // oh my god
        let length = 32
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+"
        return String((0..<length).map { _ in letters.randomElement() ?? "." })
    }
}

/// Headless form of PlayApp's launch/termination KeyCover behavior.
///
/// The encrypted `.keyCover` object is unlocked to the exact bundle `.db`
/// before launch and locked again after the exact process exits. The master
/// password is held by the user's macOS Keychain and scoped to the exact
/// account-global PlayChain directory.
public enum PlayCoverHeadlessKeyCover {
    private enum Operation {
        case unlock
        case lock
    }

    public static func configure(
        playChainDirectory: URL
    ) throws -> URL {
        let expected = lexicallyStandardizedFileURL(
            playChainDirectory
        )
        guard expected.lastPathComponent == "playchain" else {
            throw PlayCoverUpstreamError.commandFailed(
                "managed PlayChain path must end in playchain"
            )
        }
        try validatePlayChainDirectory(expected)
        let container = expected.deletingLastPathComponent()
        try PlayTools.configureManagedContainer(container)
        let actual = lexicallyStandardizedFileURL(
            KeyCover.playChainPath
        )
        guard actual.path == expected.path else {
            throw PlayCoverUpstreamError.commandFailed(
                "managed PlayChain path did not resolve exactly"
            )
        }
        try validatePlayChainDirectory(actual)
        return actual
    }

    public static func unlock(
        bundleIdentifier: String,
        playChainDirectory: URL
    ) throws {
        try perform(
            .unlock,
            bundleIdentifier: bundleIdentifier,
            playChainDirectory: playChainDirectory
        )
    }

    public static func lock(
        bundleIdentifier: String,
        playChainDirectory: URL
    ) throws {
        try perform(
            .lock,
            bundleIdentifier: bundleIdentifier,
            playChainDirectory: playChainDirectory
        )
    }

    private static func perform(
        _ operation: Operation,
        bundleIdentifier: String,
        playChainDirectory: URL
    ) throws {
        let expected = lexicallyStandardizedFileURL(
            playChainDirectory
        )
        guard expected.lastPathComponent == "playchain" else {
            throw PlayCoverUpstreamError.commandFailed(
                "managed PlayChain path must end in playchain"
            )
        }
        try validatePlayChainDirectory(expected)
        try PlayTools.withExistingManagedContainer(
            expected.deletingLastPathComponent()
        ) {
            let actual = lexicallyStandardizedFileURL(
                KeyCover.playChainPath
            )
            guard actual.path == expected.path else {
                throw PlayCoverUpstreamError.commandFailed(
                    "managed PlayChain path did not resolve exactly"
                )
            }
            try validatePlayChainDirectory(actual)
            try validateBundleIdentifier(bundleIdentifier)
            guard KeyCover.shared.isKeyCoverEnabled() else {
                return
            }
            let key = KeyCoverKey(
                appBundleID: bundleIdentifier
            )
            try key.removeInterruptedTemporary()
            let hasPlaintext = FileManager.default.fileExists(
                atPath: key.decryptedKeyDB.path
            )
            let hasEncrypted = FileManager.default.fileExists(
                atPath: key.encryptedKeyDB.path
            )
            if hasPlaintext && hasEncrypted {
                switch operation {
                case .lock:
                    // Plaintext is the input to lock.  Retire the
                    // possibly stale encrypted output, then recompute it.
                    try key.deleteEncryptedKeyDB()
                case .unlock:
                    // Encrypted data is the input to unlock.  Retire the
                    // possibly stale plaintext output, then recompute it.
                    try key.deleteKeyDB()
                }
            }
            let lifecycle = PlayAppHeadlessLifecycle(
                bundleIdentifier: bundleIdentifier
            )
            switch operation {
            case .unlock:
                try lifecycle.unlockKeyCover()
            case .lock:
                try lifecycle.lockKeyCover()
            }
        }
    }

    private static func validatePlayChainDirectory(
        _ directory: URL
    ) throws {
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              !directory.path.utf8.contains(0) else {
            throw PlayCoverUpstreamError.commandFailed(
                "managed PlayChain path is not an absolute file path"
            )
        }
        #if canImport(Darwin)
        var status = stat()
        let lexical = lexicallyStandardizedFileURL(directory)
        var resolved = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        guard lexical.path == directory.path,
              realpath(lexical.path, &resolved) != nil,
              String(cString: resolved) == lexical.path,
              lstat(lexical.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else {
            throw PlayCoverUpstreamError.commandFailed(
                "managed PlayChain is not an owner-only exact directory"
            )
        }
        #else
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw PlayCoverUpstreamError.commandFailed(
                "managed PlayChain directory is missing"
            )
        }
        #endif
    }

    private static func lexicallyStandardizedFileURL(
        _ url: URL
    ) -> URL {
        var components: [Substring] = []
        for component in url.path.split(separator: "/") {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(component)
        }
        return URL(
            fileURLWithPath: "/" + components.joined(separator: "/"),
            isDirectory: true
        )
    }

    private static func validateBundleIdentifier(
        _ bundleIdentifier: String
    ) throws {
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyz"
                + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= 200,
              bundleIdentifier.unicodeScalars.allSatisfy({
                  allowed.contains($0)
              }) else {
            throw PlayCoverUpstreamError.commandFailed(
                "bundle identifier cannot form a managed PlayChain file"
            )
        }
    }
}

struct PlayAppHeadlessLifecycle {
    let bundleIdentifier: String

    func unlockKeyCover() throws {
        guard KeyCover.shared.isKeyCoverEnabled() else {
            return
        }
        KeyCover.shared.restorePersistedKey()
        let key = KeyCoverKey(appBundleID: bundleIdentifier)
        if key.chainEncryptionStatus {
            guard KeyCover.shared.keyCoverPlainTextKey != nil else {
                throw PlayCoverUpstreamError.commandFailed(
                    "KeyCover password is unavailable for "
                        + bundleIdentifier
                )
            }
            try KeyCover.shared.unlockChain(key)
        }
    }

    func lockKeyCover() throws {
        guard KeyCover.shared.isKeyCoverEnabled() else {
            return
        }
        KeyCover.shared.restorePersistedKey()
        defer {
            KeyCover.shared.keyCoverPlainTextKey = nil
        }
        let key = KeyCoverKey(appBundleID: bundleIdentifier)
        if FileManager.default.fileExists(
            atPath: key.decryptedKeyDB.path
        ) {
            guard KeyCover.shared.keyCoverPlainTextKey != nil else {
                throw PlayCoverUpstreamError.commandFailed(
                    "KeyCover password is unavailable for "
                        + bundleIdentifier
                )
            }
            try KeyCover.shared.lockChain(key)
        }
    }
}
