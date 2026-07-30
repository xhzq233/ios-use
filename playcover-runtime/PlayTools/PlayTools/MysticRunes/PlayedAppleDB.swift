//
//  PlayedAppleBackend.swift
//  PlayTools
//
//  Created by Ryu-ga on 2/20/24.
//

import Darwin
import Foundation
import Security
import SQLite3

struct IOSUsePlayChainManagedLocation {
    let appBundleURL: URL
    let generationKey: String
    let playcoverRootURL: URL
    let databaseURL: URL
}

enum IOSUsePlayChainLocation {
#if IOS_USE_PLAYCHAIN_TESTING
    static var testingDatabaseURL: URL?
#endif

    static func resolve() throws -> IOSUsePlayChainManagedLocation {
#if IOS_USE_PLAYCHAIN_TESTING
        if let testingDatabaseURL {
            return IOSUsePlayChainManagedLocation(
                appBundleURL: Bundle.main.bundleURL,
                generationKey: String(repeating: "0", count: 64),
                playcoverRootURL:
                    testingDatabaseURL
                        .deletingLastPathComponent()
                        .deletingLastPathComponent(),
                databaseURL: testingDatabaseURL
            )
        }
#endif
        let appBundleURL = Bundle.main.bundleURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard appBundleURL.isFileURL,
              appBundleURL.pathExtension == "app" else {
            throw NSError(
                domain: "IOSUsePlayChain",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "main bundle is not a managed .app"
                ]
            )
        }
        let generationURL =
            appBundleURL.deletingLastPathComponent()
        let generationKey = generationURL.lastPathComponent
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdefABCDEF"
        )
        guard generationKey.count == 64,
              generationKey.unicodeScalars.allSatisfy({
                  hexadecimal.contains($0)
              }) else {
            throw NSError(
                domain: "IOSUsePlayChain",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "App is not under a verified prepared generation"
                ]
            )
        }
        let preparedURL =
            generationURL.deletingLastPathComponent()
        let macCacheURL =
            preparedURL.deletingLastPathComponent()
        let cacheURL =
            macCacheURL.deletingLastPathComponent()
        let managedHomeURL =
            cacheURL.deletingLastPathComponent()
        guard preparedURL.lastPathComponent == "prepared",
              macCacheURL.lastPathComponent == "mac",
              cacheURL.lastPathComponent == "cache" else {
            throw NSError(
                domain: "IOSUsePlayChain",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "prepared generation is outside "
                            + "IOS_USE_HOME/cache/mac"
                ]
            )
        }
        let playcoverRootURL = managedHomeURL
            .appendingPathComponent("mac", isDirectory: true)
        let bundleID =
            Bundle.main.bundleIdentifier ?? "Shared"
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !bundleID.isEmpty,
              bundleID.unicodeScalars.allSatisfy({
                  allowed.contains($0)
              }) else {
            throw NSError(
                domain: "IOSUsePlayChain",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "bundle identifier cannot form a PlayChain filename"
                ]
            )
        }
        let databaseURL = playcoverRootURL
            .appendingPathComponent(
                "playchain",
                isDirectory: true
            )
            .appendingPathComponent("\(bundleID).db")
        return IOSUsePlayChainManagedLocation(
            appBundleURL: appBundleURL,
            generationKey: generationKey.lowercased(),
            playcoverRootURL: playcoverRootURL,
            databaseURL: databaseURL
        )
    }

    static func identity() -> [String: Any] {
        do {
            let location = try resolve()
            let runtimeBundle = Bundle(for: PlayKeychain.self)
            let runtimeBinary =
                runtimeBundle.executableURL?.standardizedFileURL.path
                ?? ""
            return [
                "status": "ready",
                "bundleIdentifier":
                    Bundle.main.bundleIdentifier ?? "",
                "preparedAppPath": location.appBundleURL.path,
                "generationKey": location.generationKey,
                "playcoverRootPath":
                    location.playcoverRootURL.path,
                "databasePath": location.databaseURL.path,
                "runtimeBinaryPath": runtimeBinary
            ]
        } catch {
            return [
                "status": "invalid-managed-location",
                "error": error.localizedDescription
            ]
        }
    }
}

class PlayKeychainDB: NSObject {
    public static let shared = PlayKeychainDB()

    private let dbLock: DispatchSemaphore = .init(value: 1)
    private let dbVersion: Int = 1

#if IOS_USE_PLAYCHAIN_TESTING
    static func configureDatabaseURLForTesting(_ url: URL) {
        IOSUsePlayChainLocation.testingDatabaseURL = url
    }
#endif

    func query(_ attributes: NSDictionary) -> [NSMutableDictionary]? {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString] else {
            return nil
        }

        let selectWhere = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil } // use only requested ones
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // non null-termination in db
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")
        guard selectWhere.count > 0 else { return nil }
        let selectLimit = attributes[kSecMatchLimit] as? String == kSecMatchLimitOne as String ? 1 : Int.max

        let selectQuery = "SELECT * FROM \(tableName) WHERE \(selectWhere) LIMIT \(selectLimit)"
        var stmt: OpaquePointer?

        var dictArr: [NSMutableDictionary] = []
        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, selectQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(selectQuery)")
                PlayKeychain.debugLogger("Failed to query to db table: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            while sqlite3_step(stmt) == SQLITE_ROW && dictArr.count < selectLimit {
                let newDict: NSMutableDictionary = [:]
                let columns = sqlite3_column_count(stmt)
                newDict[kSecClass] = tableName
                newDict[kSecAttrSynchronizable] = attributes[kSecAttrSynchronizable]
                for index in 0..<columns {
                    let name = String(cString: sqlite3_column_name(stmt, index))
                    if let value = decodeData(stmt: stmt, index: index) {
                        newDict[name] = value
                    }
                }
                dictArr.append(newDict)
            }

            return true
        }) else { return nil }

        return dictArr
    }

    func insert(_ attributes: NSDictionary) -> NSMutableDictionary? {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return nil
        }

        let normalizedAttributes =
            NSMutableDictionary(dictionary: attributes)
        for primaryColumn in primaryColumns
        where normalizedAttributes[primaryColumn] == nil {
            // Public SecItem calls commonly omit access-group and other
            // class-specific primary columns.  The pinned schema requires
            // every primary column, so use one deterministic empty value
            // instead of force-casting nil.
            normalizedAttributes[primaryColumn] = ""
        }
        var columnsQuery = primaryColumns.map({ "\($0)" })
        columnsQuery.append(contentsOf: secondaryColumns.compactMap({
            normalizedAttributes[$0] != nil ? "\($0)" : nil
        }))
        columnsQuery.append(contentsOf: PlayedAppleDBConstants.values.compactMap({
            normalizedAttributes[$0] != nil ? "\($0)" : nil
        }))

        let insertValues = columnsQuery.map({
            normalizedAttributes[$0] as CFTypeRef
        })

        let insertColumns = columnsQuery.joined(separator: ", ")
        let insertPlaceholders = Array(repeating: "?", count: insertValues.count).joined(separator: ", ")

        let insertQuery = "INSERT INTO \(tableName) (\(insertColumns)) VALUES (\(insertPlaceholders))"
        var stmt: OpaquePointer?

        let newDict: NSMutableDictionary = [:]
        newDict[kSecClass] = tableName
        for column in columnsQuery {
            newDict[column] = normalizedAttributes[column]
        }

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, insertQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(insertQuery)")
                PlayKeychain.debugLogger("Failed to make query: \(errorMessage)")
                return false
            }

            for (index, value) in insertValues.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                let erorrMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to insert into db: \(erorrMessage)")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_DONE
        }) else { return nil }

        return newDict
    }

    func update(_ attributes: NSDictionary) -> Bool {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return false
        }

        var columnsQuery = primaryColumns.map({ "\($0)" })
        columnsQuery.append(contentsOf: secondaryColumns.compactMap({
            attributes[$0] != nil ? "\($0)" : nil
        }))
        columnsQuery.append(contentsOf: PlayedAppleDBConstants.values.compactMap({
            attributes[$0] != nil ? "\($0)" : nil
        }))

        let updateValues = columnsQuery.map({ attributes[$0] as CFTypeRef })

        let updateColumns = columnsQuery.map({ return "\($0) = ?" }).joined(separator: ", ")
        let updateWhere = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil }
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ return String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // \0 does not exists in db due to casting
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")

        let updateQuery = "UPDATE \(tableName) SET \(updateColumns) WHERE \(updateWhere)"
        var stmt: OpaquePointer?

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, updateQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(updateQuery)")
                PlayKeychain.debugLogger("Failed to make query: \(errorMessage)")
                return false
            }

            for (index, value) in updateValues.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to update into db: \(errorMessage)")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_DONE
        }) else { return false }

        return true
    }

    func delete(_ attributes: NSDictionary) -> Bool {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString] else {
            return false
        }

        let deleteWhere = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil } // use only requested ones
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ return String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // non null-termination in db
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")

        let deleteQuery = "DELETE FROM \(tableName) where \(deleteWhere)"
        var stmt: OpaquePointer?

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, deleteQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(deleteQuery)")
                PlayKeychain.debugLogger("Failed to delte items from db table: \(errorMessage)")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_DONE
        }) else { return false }

        return true
    }

    private func structDB(_ sqlite3DB: OpaquePointer) -> Bool {
        for (key, value) in PlayedAppleDBConstants.primaries {
            var columns: [CFString] = value
            columns.append(contentsOf: PlayedAppleDBConstants.attributes[key]!)
            columns.append(contentsOf: PlayedAppleDBConstants.values)
            let columnsSetting = columns.map({ return "\($0) TEXT" }).joined(separator: ", ")
            let primaryKeysSetting = "PRIMARY KEY (\(value.map({ return "\($0)" }).joined(separator: ", ")))"
            let createTableQuery = "CREATE TABLE IF NOT EXISTS \(key) (\(columnsSetting), \(primaryKeysSetting));"
            guard sqlite3_exec(sqlite3DB, createTableQuery, nil, nil, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(createTableQuery)")
                PlayKeychain.debugLogger("Failed to create db table: \(errorMessage)")
                return false
            }
        }

        sqlite3_exec(sqlite3DB, "PRAGMA user_version = \(dbVersion)", nil, nil, nil)

        return true
    }

    private func usingDB(_ callback: (OpaquePointer) -> Bool) -> Bool {
        dbLock.wait()
        defer { dbLock.signal() }

        guard let sqlite3DB = connectToDB() else { return false }
        let result = callback(sqlite3DB)
        guard disconnectFromDB(sqlite3DB) else { return false }
        return result
    }

    private func connectToDB() -> OpaquePointer? {
        var sqlite3DB: OpaquePointer?
        let location: IOSUsePlayChainManagedLocation
        do {
            location = try IOSUsePlayChainLocation.resolve()
            try FileManager.default.createDirectory(
                at: location.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: 0o700
                ]
            )
        } catch {
            PlayKeychain.debugLogger(
                "PlayChain storage location rejected: \(error)"
            )
            return nil
        }

        guard sqlite3_open_v2(
                location.databaseURL.path,
                &sqlite3DB,
                SQLITE_OPEN_READWRITE |
                    SQLITE_OPEN_CREATE |
                    SQLITE_OPEN_FULLMUTEX,
                nil
              ) == SQLITE_OK,
              let sqlite3DB = sqlite3DB else {
            PlayKeychain.debugLogger("Failed to connect to DB")
            if sqlite3DB != nil {
                sqlite3_close(sqlite3DB)
            }
            return nil
        }
        chmod(location.databaseURL.path, 0o600)
        guard sqlite3_busy_timeout(sqlite3DB, 5000) == SQLITE_OK,
              structDB(sqlite3DB) else {
            _ = disconnectFromDB(sqlite3DB)
            return nil
        }

        return sqlite3DB
    }

    private func disconnectFromDB(_ sqlite3DB: OpaquePointer?) -> Bool {
        guard sqlite3_close(sqlite3DB) == SQLITE_OK else {
            PlayKeychain.debugLogger("Failed to disconnect from DB")
            return false
        }

        return true
    }

    private func encodeData(stmt: OpaquePointer, index: Int32, value: CFTypeRef) -> Bool {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result = SQLITE_FAIL
        switch CFGetTypeID(value) {
        case CFStringGetTypeID():
            let string = value as! String // swiftlint:disable:this force_cast
            result = sqlite3_bind_text(stmt, index, string, -1, sqliteTransient)
        case CFDataGetTypeID():
            let data = value as! CFData // swiftlint:disable:this force_cast
            let ptr = CFDataGetBytePtr(data)
            let size = CFDataGetLength(data)
            result = sqlite3_bind_blob(stmt, index, ptr, Int32(size), sqliteTransient)
        case CFNullGetTypeID():
            result = sqlite3_bind_null(stmt, index)
        default:
            PlayKeychain.debugLogger("Cannot encode this data type: \(CFGetTypeID(value))")
            result = sqlite3_bind_null(stmt, index)
        }

        return result == SQLITE_OK
    }

    private func decodeData(stmt: OpaquePointer, index: Int32) -> CFTypeRef? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
            return CFStringCreateWithCString(nil, ptr, kCFStringEncodingASCII)
        case SQLITE_BLOB:
            guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
            let size = sqlite3_column_bytes(stmt, index)
            return CFDataCreate(nil, ptr, CFIndex(size))
        case SQLITE_NULL:
            return nil
        default:
            PlayKeychain.debugLogger("Cannot decode this data \(sqlite3_column_type(stmt, index))")
            return nil
        }
    }
}
