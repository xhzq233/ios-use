import Darwin
import Foundation

struct PairRecord {
    let hostID: String
    let systemBUID: String
    let hostPrivateKey: Data
    let hostCertificate: Data

    static func load(udid: String) throws -> PairRecord {
        let fd = try Usbmux.openSocket()
        defer { Darwin.close(fd) }
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
        let pair = try parsePlist(pairData)
        guard let hostID = pair["HostID"] as? String,
              let systemBUID = pair["SystemBUID"] as? String else {
            throw CLIParseError.invalidValue("Invalid pair record for device \(udid)")
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
