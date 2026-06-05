import Foundation

struct DTXConnectionIdleListenerFailure: Error, CustomStringConvertible {
    let name: String
    let underlying: Error

    var description: String {
        "DTX \(name) idle listener ended: \(underlying)"
    }
}

final class DTXConnectionIdleListener {
    private let name: String
    private let channel: DTXChannelClient
    private let eventSink: ((String) -> Void)?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stopped = false
    private var listenerFailure: DTXConnectionIdleListenerFailure?
    private var failureReported = false

    init(name: String, channel: DTXChannelClient, eventSink: ((String) -> Void)? = nil) {
        self.name = name
        self.channel = channel
        self.eventSink = eventSink
        self.queue = DispatchQueue(label: "ios-use.dtx.idle-listener.\(name)")
    }

    func start() {
        queue.async { [weak self] in
            self?.run()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func takeFailure() -> DTXConnectionIdleListenerFailure? {
        lock.lock()
        defer { lock.unlock() }
        guard let listenerFailure, !failureReported else {
            return nil
        }
        failureReported = true
        return listenerFailure
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        eventSink?("\(name) idle listener started")
        while !shouldStop {
            do {
                let message = try channel.readMessage(timeoutSeconds: 1)
                try handle(message)
            } catch {
                if shouldStop {
                    return
                }
                if XCTestExecCallbackListener.isIdleTimeout(error) {
                    continue
                }
                recordFailure(error)
                return
            }
        }
    }

    private func handle(_ message: DTXDecodedMessage) throws {
        guard message.kind == .dispatch else {
            return
        }
        let selector = try DTXStreamTransport.unarchivePayload(message.payload) as? String
        if let selector {
            eventSink?("\(name) idle callback \(selector)")
        }
        if message.transportFlags & DTXTransportFlag.expectsReply != 0 {
            try channel.sendAckReply(to: message)
        }
    }

    private func recordFailure(_ error: Error) {
        lock.lock()
        if listenerFailure == nil {
            listenerFailure = DTXConnectionIdleListenerFailure(name: name, underlying: error)
        }
        lock.unlock()
    }
}
