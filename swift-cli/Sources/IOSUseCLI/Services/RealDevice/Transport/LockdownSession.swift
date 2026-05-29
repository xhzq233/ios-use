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
        do {
            try lockdown.startSession()
            try lockdown.enableSessionSSL()
            let values = try lockdown.getValue(domain: domain, key: key)
            lockdown.disconnect()
            return values
        } catch {
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
            throw error
        }
    }

    static func startService(_ serviceName: String, udid: String) throws -> LockdownServiceConnection {
        let pairRecord = try PairRecord.load(udid: udid)
        return try startService(serviceName, udid: udid, pairRecord: pairRecord)
    }

    static func startService(_ serviceName: String, udid: String, pairRecord: PairRecord) throws -> LockdownServiceConnection {
        let lockdown = try LockdownClient(udid: udid, pairRecord: pairRecord)
        do {
            try lockdown.startSession()
            try lockdown.enableSessionSSL()
            let service = try lockdown.startService(serviceName)
            lockdown.disconnect()
            return LockdownServiceConnection(pairRecord: pairRecord, service: service)
        } catch {
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
            throw error
        }
    }

    static func connectToService(_ serviceName: String, udid: String) throws -> DeviceStream {
        let connection = try startService(serviceName, udid: udid)
        let fd = try Usbmux.connect(udid: udid, port: connection.service.port)
        if connection.service.enableServiceSSL {
            return try OpenSSLDeviceStream(fd: fd, pairRecord: connection.pairRecord)
        }
        return PlainDeviceStream(fd: fd)
    }
}
