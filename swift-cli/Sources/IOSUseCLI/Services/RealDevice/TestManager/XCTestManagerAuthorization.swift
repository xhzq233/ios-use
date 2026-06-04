import Foundation

protocol DriverAuthorizationProviding {
    func authorizeDriver(udid: String, pid: Int) throws
}

final class XCTestManagerSession {
    private let stream: DeviceStream
    private let control: DTXControlChannelClient
    private var nextChannelCode: Int32 = 1

    init(stream: DeviceStream) {
        self.stream = stream
        self.control = DTXControlChannelClient(stream: stream)
    }

    func connect() throws {
        try control.notifyCapabilities()
    }

    func openDaemonConnection() throws -> XCTestManagerDaemonClient {
        XCTestManagerDaemonClient(channel: try openDaemonChannel())
    }

    func openDaemonChannel() throws -> DTXChannelClient {
        let code = nextChannelCode
        nextChannelCode += 1
        try control.requestChannel(
            code: code,
            identifier: DVTInstrumentsContract.XCTestManagerDaemon.proxyServiceIdentifier
        )
        return control.channel(code: code)
    }

    func close() {
        stream.close()
    }
}

final class XCTestManagerAuthorizationProvider: DriverAuthorizationProviding {
    struct Dependencies {
        var connectTestManager: (String) throws -> DeviceStream
        var productMajorVersion: (String) throws -> Int

        static let live = live(eventSink: nil)

        static func live(eventSink: ((String) -> Void)?) -> Dependencies {
            Dependencies(
                connectTestManager: { udid in
                    eventSink?("opening testmanagerd service \(DVTInstrumentsContract.XCTestManagerDaemon.secureServiceName)")
                    return try LockdownSession.connectToService(
                        DVTInstrumentsContract.XCTestManagerDaemon.secureServiceName,
                        udid: udid
                    )
                },
                productMajorVersion: { udid in
                    let values = try LockdownSession.getValue(udid: udid, key: "ProductVersion")
                    guard let version = values["ProductVersion"] as? String,
                          let major = Int(version.split(separator: ".").first ?? "") else {
                        throw CLIParseError.invalidValue("Unable to determine ProductVersion for device \(udid)")
                    }
                    return major
                }
            )
        }
    }

    private let dependencies: Dependencies
    private let eventSink: ((String) -> Void)?

    init(dependencies: Dependencies = .live, eventSink: ((String) -> Void)? = nil) {
        self.dependencies = dependencies
        self.eventSink = eventSink
    }

    convenience init(eventSink: ((String) -> Void)?) {
        self.init(dependencies: .live(eventSink: eventSink), eventSink: eventSink)
    }

    func authorizeDriver(udid: String, pid: Int) throws {
        let productMajorVersion = try dependencies.productMajorVersion(udid)
        eventSink?("testmanagerd product major version=\(productMajorVersion)")
        let session = try XCTestManagerSession(stream: dependencies.connectTestManager(udid))
        defer { session.close() }

        try session.connect()
        let daemon = try session.openDaemonConnection()
        eventSink?("initiating testmanagerd control session")
        _ = try daemon.initiateControlSession(productMajorVersion: productMajorVersion)
        eventSink?("authorizing test session pid=\(pid)")
        guard try daemon.authorizeTestSession(productMajorVersion: productMajorVersion, pid: pid) else {
            throw CLIParseError.invalidValue("testmanagerd authorization returned false for pid \(pid)")
        }
    }
}

final class CoreDeviceTunnelXCTestManagerAuthorizationProvider {
    struct Dependencies {
        var productMajorVersion: (String) throws -> Int

        static let live = live(eventSink: nil)

        static func live(eventSink _: ((String) -> Void)?) -> Dependencies {
            Dependencies(
                productMajorVersion: { udid in
                    let values = try LockdownSession.getValue(udid: udid, key: "ProductVersion")
                    guard let version = values["ProductVersion"] as? String,
                          let major = Int(version.split(separator: ".").first ?? "") else {
                        throw CLIParseError.invalidValue("Unable to determine ProductVersion for device \(udid)")
                    }
                    return major
                }
            )
        }
    }

    private let dependencies: Dependencies
    private let eventSink: ((String) -> Void)?

    init(dependencies: Dependencies = .live, eventSink: ((String) -> Void)? = nil) {
        self.dependencies = dependencies
        self.eventSink = eventSink
    }

    convenience init(eventSink: ((String) -> Void)?) {
        self.init(dependencies: .live(eventSink: eventSink), eventSink: eventSink)
    }

    func authorizeDriver(udid: String, pid: Int, tunnelSession: CoreDeviceLifecycleTunnelSession) throws {
        let productMajorVersion = try dependencies.productMajorVersion(udid)
        eventSink?("testmanagerd product major version=\(productMajorVersion)")
        eventSink?("opening RSD testmanagerd service \(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName)")
        let stream = try tunnelSession.connectService(DVTInstrumentsContract.XCTestManagerDaemon.rsdServiceName)
        let session = XCTestManagerSession(stream: stream)
        defer { session.close() }

        try session.connect()
        let daemon = try session.openDaemonConnection()
        eventSink?("initiating RSD testmanagerd control session")
        _ = try daemon.initiateControlSession(productMajorVersion: productMajorVersion)
        eventSink?("authorizing test session pid=\(pid)")
        guard try daemon.authorizeTestSession(productMajorVersion: productMajorVersion, pid: pid) else {
            throw CLIParseError.invalidValue("testmanagerd authorization returned false for pid \(pid)")
        }
    }
}
