//
//  KeyCover.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import Security

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

    var chainEncryptionStatus: Bool {
        return FileManager.default.fileExists(atPath: encryptedKeyDB.path)
    }

    func encryptKeyDB() throws {
        guard let plainTextKey = KeyCover.shared.keyCoverPlainTextKey else {
            throw PlayCoverUpstreamError.commandFailed(
                "KeyCover master key is unavailable"
            )
        }
        try runOpenSSL([
            "enc", "-aes-256-cbc", "-pbkdf2", "-A",
            "-in", decryptedKeyDB.path,
            "-out", encryptedKeyDB.path,
            "-k", plainTextKey,
        ])
        try deleteKeyDB()
    }

    func decryptKeyDB() throws {
        guard let plainTextKey = KeyCover.shared.keyCoverPlainTextKey else {
            throw PlayCoverUpstreamError.commandFailed(
                "KeyCover master key is unavailable"
            )
        }
        try runOpenSSL([
            "enc", "-aes-256-cbc", "-pbkdf2", "-A", "-d",
            "-in", encryptedKeyDB.path,
            "-out", decryptedKeyDB.path,
            "-k", plainTextKey,
        ])
        try FileManager.default.removeItem(at: encryptedKeyDB)
    }

    func deleteKeyDB() throws {
        try FileManager.default.removeItem(at: decryptedKeyDB)
    }

    func deleteEncryptedKeyDB() throws {
        try FileManager.default.removeItem(at: encryptedKeyDB)
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
/// password is held by the user's macOS Keychain and scoped to managed HOME.
public enum PlayCoverHeadlessKeyCover {
    public static func configure(managedHome: URL) throws -> URL {
        let container = managedHome
            .appendingPathComponent("mac", isDirectory: true)
        try PlayTools.configureManagedContainer(container)
        return KeyCover.playChainPath
    }

    public static func unlock(
        bundleIdentifier: String,
        managedHome: URL
    ) throws {
        _ = try configure(managedHome: managedHome)
        let lifecycle = PlayAppHeadlessLifecycle(
            bundleIdentifier: bundleIdentifier
        )
        try lifecycle.unlockKeyCover()
    }

    public static func lock(
        bundleIdentifier: String,
        managedHome: URL
    ) throws {
        _ = try configure(managedHome: managedHome)
        let lifecycle = PlayAppHeadlessLifecycle(
            bundleIdentifier: bundleIdentifier
        )
        try lifecycle.lockKeyCover()
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
