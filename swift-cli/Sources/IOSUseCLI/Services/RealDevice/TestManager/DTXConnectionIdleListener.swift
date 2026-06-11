import Foundation
import IOSUseProtocol

private enum DTXIdleTrace {
    static let enabled = ProcessInfo.processInfo.environment["IOS_USE_COREDEVICE_TRACE"] == "1"
}

struct DTXConnectionIdleListenerFailure: Error, CustomStringConvertible {
    let name: String
    let underlying: Error
    let listenerState: String?

    var description: String {
        let stateDescription = listenerState.map { " listenerState={\($0)}" } ?? ""
        return "DTX \(name) idle listener ended: \(underlying)\(stateDescription)"
    }
}

final class DTXConnectionIdleListener {
    private enum RuntimeState: String {
        case idle
        case readingMessage
        case unarchivingSelector
        case sendingAck
    }

    private let name: String
    private let channel: DTXChannelClient
    private let eventSink: ((String) -> Void)?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stopped = false
    private var listenerFailure: DTXConnectionIdleListenerFailure?
    private var failureReported = false
    private var runtimeState: RuntimeState = .idle
    private var lastSelector: String?
    private var lastMessageIdentifier: UInt32?
    private var lastAckAt: Date?
    private var lastMessageAt: Date?
    private var lastErrorDescription: String?

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
                updateState(.readingMessage)
                let message = try channel.readMessage(timeoutSeconds: IOSUseProtocol.XCConstants.xctestCallbackReadTimeoutSeconds)
                recordMessage(message)
                try handle(message)
                updateState(.idle)
            } catch {
                if shouldStop {
                    return
                }
                if XCTestExecCallbackListener.isIdleTimeout(error) {
                    updateState(.idle)
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
        updateState(.unarchivingSelector)
        let selector = try DTXStreamTransport.unarchivePayload(message.payload) as? String
        recordSelector(selector)
        if DTXIdleTrace.enabled, let selector {
            eventSink?("\(name) idle callback \(selector)")
        }
        if message.transportFlags & DTXTransportFlag.expectsReply != 0 {
            updateState(.sendingAck)
            try channel.sendAckReply(to: message)
            recordAck()
        }
    }

    private func recordFailure(_ error: Error) {
        let state = stateSnapshot(recording: error)
        lock.lock()
        if listenerFailure == nil {
            listenerFailure = DTXConnectionIdleListenerFailure(name: name, underlying: error, listenerState: state)
        }
        lock.unlock()
    }

    private func updateState(_ state: RuntimeState) {
        lock.lock()
        runtimeState = state
        lock.unlock()
    }

    private func recordMessage(_ message: DTXDecodedMessage) {
        lock.lock()
        lastMessageIdentifier = message.identifier
        lastMessageAt = Date()
        lock.unlock()
    }

    private func recordSelector(_ selector: String?) {
        lock.lock()
        lastSelector = selector
        lock.unlock()
    }

    private func recordAck() {
        lock.lock()
        lastAckAt = Date()
        lock.unlock()
    }

    private func stateSnapshot(recording error: Error? = nil) -> String {
        lock.lock()
        if let error {
            lastErrorDescription = String(describing: error)
        }
        let state = runtimeState.rawValue
        let selector = lastSelector
        let messageIdentifier = lastMessageIdentifier
        let ackAge = ageMilliseconds(since: lastAckAt)
        let messageAge = ageMilliseconds(since: lastMessageAt)
        let errorDescription = lastErrorDescription
        lock.unlock()

        var parts = ["state=\(state)"]
        if let messageIdentifier {
            parts.append("lastMessage=\(messageIdentifier)")
        }
        if let selector {
            parts.append("lastSelector=\(selector)")
        }
        if let messageAge {
            parts.append("lastMessageAgeMs=\(messageAge)")
        }
        if let ackAge {
            parts.append("lastAckAgeMs=\(ackAge)")
        }
        if let errorDescription {
            parts.append("lastError=\(errorDescription)")
        }
        return parts.joined(separator: " ")
    }

    private func ageMilliseconds(since date: Date?) -> Int? {
        guard let date else { return nil }
        return max(0, Int(Date().timeIntervalSince(date) * 1000))
    }
}
