import Darwin
import Foundation
import IOSUseProtocol

final class LockdownClient {
    private let fd: Int32
    private let pairRecord: PairRecord
    private var stream: DeviceStream

    init(udid: String, pairRecord: PairRecord) throws {
        self.fd = try Usbmux.connect(udid: udid, port: IOSUseProtocol.XCConstants.lockdownPort)
        self.pairRecord = pairRecord
        self.stream = PlainDeviceStream(fd: fd, ownsFD: false)
    }

    func startSession() throws {
        let response = try request([
            "Request": "StartSession",
            "HostID": pairRecord.hostID,
            "SystemBUID": pairRecord.systemBUID,
        ])
        if let error = response["Error"] {
            throw CLIParseError.invalidValue("StartSession failed: \(Self.errorDescription(error, response: response))")
        }
        guard response["SessionID"] != nil else {
            throw CLIParseError.invalidValue("StartSession returned no SessionID")
        }
    }

    func enableSessionSSL() throws {
        stream = try OpenSSLDeviceStream(fd: fd, pairRecord: pairRecord, ownsFD: false)
    }

    func startService(_ serviceName: String) throws -> LockdownService {
        let response = try request([
            "Request": "StartService",
            "Service": serviceName,
        ])
        if let error = response["Error"] {
            throw CLIParseError.invalidValue("StartService(\(serviceName)) failed: \(Self.errorDescription(error, response: response))")
        }
        guard let port = response["Port"] as? Int else {
            throw CLIParseError.invalidValue("StartService(\(serviceName)) returned no port")
        }
        return LockdownService(port: port, enableServiceSSL: (response["EnableServiceSSL"] as? Bool) ?? false)
    }

    func getValue(domain: String? = nil, key: String? = nil) throws -> [String: Any] {
        var body: [String: Any] = ["Request": "GetValue"]
        if let domain {
            body["Domain"] = domain
        }
        if let key {
            body["Key"] = key
        }
        let response = try request(body)
        if let error = response["Error"] {
            throw CLIParseError.invalidValue("GetValue failed: \(Self.errorDescription(error, response: response))")
        }
        guard let value = response["Value"] else {
            return response
        }
        if let dict = value as? [String: Any] {
            return dict
        }
        if let key {
            return [key: value]
        }
        return ["Value": value]
    }

    func disconnect() {
        stream.close()
        Darwin.close(fd)
    }

    func request(_ body: [String: Any]) throws -> [String: Any] {
        var request = body
        request["Label"] = "ios-use"
        request["ProtocolVersion"] = "2"
        let xml = try serializePlist(request)
        try stream.write(uint32BE(UInt32(xml.count)) + xml)
        let header = try stream.readExact(byteCount: 4, timeoutSeconds: IOSUseProtocol.XCConstants.lockdownRequestTimeoutSeconds)
        let size = Int(readUInt32BE(header, 0))
        guard size > 0, size <= IOSUseProtocol.XCConstants.lockdownMaxPlistSizeBytes else {
            throw CLIParseError.invalidValue("lockdown plist invalid size: \(size)")
        }
        return try parsePlist(try stream.readExact(byteCount: size, timeoutSeconds: IOSUseProtocol.XCConstants.lockdownRequestTimeoutSeconds))
    }

    private static func errorDescription(_ error: Any, response: [String: Any]) -> String {
        let description = response["ErrorDescription"].map { String(describing: $0) } ?? String(describing: error)
        return "\(description); response: \(plistResponseSummary(response))"
    }
}
