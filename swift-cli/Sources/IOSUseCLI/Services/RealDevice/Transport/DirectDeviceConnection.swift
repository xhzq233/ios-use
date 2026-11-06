import Foundation

/// A device-side connection to local developer services, authenticated using an
/// imported host identity. Scoped to one operation, never persisted by the CLI.
struct DirectDeviceConnection {
    let host: String
    let pairRecord: PairRecord

    @TaskLocal static var current: DirectDeviceConnection?

    static func connect(udid: String, port: Int) throws -> Int32 {
        if let direct = current {
            return try TCPConnector.connect(host: direct.host, port: port)
        }
        return try Usbmux.connect(udid: udid, port: port)
    }
}
