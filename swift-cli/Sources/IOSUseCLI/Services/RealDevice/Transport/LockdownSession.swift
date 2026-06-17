import Foundation

struct LockdownService {
    let port: Int
    let enableServiceSSL: Bool
}

struct LockdownServiceConnection {
    let pairRecord: PairRecord
    let service: LockdownService
}

enum LockdownSession {
    static func getValue(udid: String, domain: String? = nil, key: String? = nil) throws -> [String: Any] {
        let pairRecord = try PairRecord.load(udid: udid)
        let lockdown = try LockdownClient(udid: udid, pairRecord: pairRecord)
        let sslError: Error
        do {
            try lockdown.startSession()
            try lockdown.enableSessionSSL()
            let values = try lockdown.getValue(domain: domain, key: key)
            lockdown.disconnect()
            return values
        } catch {
            sslError = error
            lockdown.disconnect()
        }

        let fallback = try LockdownClient(udid: udid, pairRecord: pairRecord)
        do {
            try fallback.startSession()
            let values = try fallback.getValue(domain: domain, key: key)
            fallback.disconnect()
            return values
        } catch {
            fallback.disconnect()
            throw combinedLockdownFallbackError(operation: "GetValue", sslError: sslError, plainError: error)
        }
    }

    static func startService(_ serviceName: String, udid: String) throws -> LockdownServiceConnection {
        let pairRecord = try PairRecord.load(udid: udid)
        return try startService(serviceName, udid: udid, pairRecord: pairRecord)
    }

    static func startService(_ serviceName: String, udid: String, pairRecord: PairRecord) throws -> LockdownServiceConnection {
        let lockdown = try LockdownClient(udid: udid, pairRecord: pairRecord)
        let sslError: Error
        do {
            try lockdown.startSession()
            try lockdown.enableSessionSSL()
            let service = try lockdown.startService(serviceName)
            lockdown.disconnect()
            return LockdownServiceConnection(pairRecord: pairRecord, service: service)
        } catch {
            sslError = error
            lockdown.disconnect()
        }

        let fallback = try LockdownClient(udid: udid, pairRecord: pairRecord)
        do {
            try fallback.startSession()
            let service = try fallback.startService(serviceName)
            fallback.disconnect()
            return LockdownServiceConnection(pairRecord: pairRecord, service: service)
        } catch {
            fallback.disconnect()
            throw combinedLockdownFallbackError(operation: "StartService(\(serviceName))", sslError: sslError, plainError: error)
        }
    }

    static func connectToService(_ serviceName: String, udid: String) throws -> DeviceStream {
        let connection = try startService(serviceName, udid: udid)
        return try connectToStartedService(connection, udid: udid)
    }

    static func connectToStartedService(
        _ connection: LockdownServiceConnection,
        udid: String,
        usbmuxConnect: (String, Int) throws -> Int32 = Usbmux.connect,
        tlsStreamFactory: (Int32, PairRecord) throws -> DeviceStream = { fd, pairRecord in
            try NIOSSLDeviceStream(fd: fd, pairRecord: pairRecord)
        },
        plainStreamFactory: (Int32) -> DeviceStream = { fd in
            PlainDeviceStream(fd: fd)
        }
    ) throws -> DeviceStream {
        let fd = try usbmuxConnect(udid, connection.service.port)
        if connection.service.enableServiceSSL {
            return try tlsStreamFactory(fd, connection.pairRecord)
        }
        return plainStreamFactory(fd)
    }

    private static func combinedLockdownFallbackError(operation: String, sslError: Error, plainError: Error) -> Error {
        CLIParseError.invalidValue("\(operation) failed over lockdownd SSL and plain fallback. SSL error: \(sslError); plain fallback error: \(plainError)")
    }
}
