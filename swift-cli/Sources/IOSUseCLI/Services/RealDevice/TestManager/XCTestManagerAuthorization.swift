import Foundation

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
