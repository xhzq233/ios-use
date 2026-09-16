import Foundation
import CoreFoundation

/// Provider-established transport. Apple device protocols and the XCTest
/// process remain owned by ios-use; provider authentication stays outside it.
public struct RemoteDeviceConnection: Codable, Equatable, Sendable {
    public struct Endpoint: Codable, Equatable, Sendable {
        public let host: String
        public let port: Int
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
        try TCPAttachService.validateEndpoint(host: usbmux.host, port: usbmux.port)
        try TCPAttachService.validateEndpoint(host: driver.host, port: driver.port)
    }

    static func decode(_ value: Any?) throws -> Self? {
        guard let value else { return nil }
        let connection = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        try connection.validate()
        return connection
    }
}
