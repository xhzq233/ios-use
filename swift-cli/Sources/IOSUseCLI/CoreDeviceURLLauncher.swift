import Foundation

protocol RealDeviceURLLaunching {
    func open(url: String, udid: String) throws
}

final class CoreDeviceURLLauncher: RealDeviceURLLaunching {
    struct Dependencies {
        var startTunnel: (String) throws -> CoreDeviceLifecycleTunnelSession
        var openAppService: (CoreDeviceLifecycleTunnelSession) throws -> CoreDeviceAppManaging

        static let live = live(eventSink: nil)

        static func live(eventSink: ((String) -> Void)?) -> Dependencies {
            Dependencies(
                startTunnel: { try CoreDeviceDirectTunnelRuntime(eventSink: eventSink).start(udid: $0) },
                openAppService: { session in
                    try CoreDeviceAppService(client: session.connectRemoteXPCService(CoreDeviceAppService.serviceName))
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

    func open(url: String, udid: String) throws {
        let session = try dependencies.startTunnel(udid)
        defer {
            session.close()
            _ = session.waitForClose(timeoutSeconds: 1)
        }
        guard session.peerInfo != nil else {
            throw CLIParseError.invalidValue("CoreDevice tunnel did not return RSD peer info")
        }
        eventSink?("opening CoreDevice appservice")
        let appService = try dependencies.openAppService(session)
        defer { appService.close() }

        eventSink?("opening URL through CoreDevice appservice payloadURL")
        _ = try appService.launchApplication(
            bundleID: "com.apple.springboard",
            arguments: [],
            terminateExisting: false,
            startSuspended: false,
            environment: [:],
            payloadURL: url,
            activates: true
        )
    }
}
