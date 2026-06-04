import Foundation

final class DVTInstrumentsSession {
    private let stream: DeviceStream
    private let control: DTXControlChannelClient
    private var nextChannelCode: Int32 = 1

    init(stream: DeviceStream) {
        self.stream = stream
        control = DTXControlChannelClient(stream: stream)
    }

    func connect() throws {
        try control.notifyCapabilities()
    }

    func openProcessControl() throws -> DVTProcessControlClient {
        let code = nextChannelCode
        nextChannelCode += 1
        try control.requestChannel(
            code: code,
            identifier: DVTInstrumentsContract.ProcessControl.serviceIdentifier
        )
        return DVTProcessControlClient(invoker: control.invoker(channelCode: code))
    }

    func close() {
        stream.close()
    }
}

final class DVTProcessControlClient {
    private let invoker: DVTInvoking

    init(invoker: DVTInvoking) {
        self.invoker = invoker
    }

    func launch(
        bundleID: String,
        environment: [String: String],
        arguments: [String] = [],
        killExisting: Bool = true,
        startSuspended: Bool = false
    ) throws -> Int {
        let reply = try invoker.invoke(DVTInstrumentsContract.ProcessControl.launch(
            bundleID: bundleID,
            environment: environment,
            arguments: arguments,
            killExisting: killExisting,
            startSuspended: startSuspended
        ))
        if let value = reply as? Int {
            return value
        }
        if let value = reply as? NSNumber {
            return value.intValue
        }
        throw DVTClientError.invalidReply("processcontrol launch expected pid, got \(String(describing: reply))")
    }

    func kill(pid: Int) throws {
        _ = try invoker.invoke(DVTInstrumentsContract.ProcessControl.kill(pid: pid))
    }
}
