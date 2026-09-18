import Foundation
import CoreFoundation

/// Provider-established transport. Apple device protocols and the XCTest
/// process remain owned by ios-use; provider authentication stays outside it.
public struct RemoteDeviceConnection: Codable, Equatable, Sendable {
    public struct Endpoint: Codable, Equatable, Sendable {
        public let host: String
        public let port: Int

        func validate() throws {
            guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
                  !host.contains("/"), !host.contains("\0") else {
                throw CLIParseError.invalidValue("Connection host must be an IP address or hostname, without a URL scheme.")
            }
            guard (1...65535).contains(port) else {
                throw CLIParseError.invalidValue("Connection port must be between 1 and 65535.")
            }
        }
    }
    public let udid: String
    public let driverBundleID: String
    public let usbmux: Endpoint
    public let driver: Endpoint

    @TaskLocal static var current: RemoteDeviceConnection?

    static func load(path: String) throws -> Self {
        let connection = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try connection.validate()
        return connection
    }

    func validate() throws {
        guard !udid.isEmpty, !driverBundleID.isEmpty else {
            throw CLIParseError.invalidValue("Device connection requires udid and driverBundleID")
        }
        try usbmux.validate()
        try driver.validate()
    }

    static func decode(_ value: Any?) throws -> Self? {
        guard let value else { return nil }
        let connection = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        try connection.validate()
        return connection
    }
}
