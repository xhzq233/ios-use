#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation
import CoreFoundation

struct PairRecord {
    let hostID: String
    let systemBUID: String
    let hostPrivateKey: Data
    let hostCertificate: Data

    static func load(udid: String) throws -> PairRecord {
        if let direct = DirectDeviceConnection.current { return direct.pairRecord }
        let fd = try Usbmux.openSocket()
        defer { posixClose(fd) }
        let payload: [String: Any] = [
            "MessageType": "ReadPairRecord",
            "PairRecordID": udid,
            "ProgName": "ios-use",
            "ClientVersionString": "1.0",
        ]
        let response = try Usbmux.request(fd: fd, payload: payload, tag: 0)
        guard let rawPair = response["PairRecordData"] else {
            throw CLIParseError.invalidValue("No pair record found for device \(udid). Please pair with the device first.")
        }
        let pairData = try plistData(rawPair)
        return try decode(pairData)
    }

    static func decode(_ data: Data) throws -> PairRecord {
        let pair = try parsePlist(data)
        guard let hostID = pair["HostID"] as? String,
              let systemBUID = pair["SystemBUID"] as? String else {
            throw CLIParseError.invalidValue("Pair record requires HostID and SystemBUID")
        }
        return PairRecord(
            hostID: hostID,
            systemBUID: systemBUID,
            hostPrivateKey: try plistData(pair["HostPrivateKey"] as Any),
            hostCertificate: try plistData(pair["HostCertificate"] as Any)
        )
    }

    private static func plistData(_ value: Any) throws -> Data {
        if let data = value as? Data { return data }
        if let string = value as? String, let data = Data(base64Encoded: string) { return data }
        throw CLIParseError.invalidValue("Invalid pair record data")
    }
}
