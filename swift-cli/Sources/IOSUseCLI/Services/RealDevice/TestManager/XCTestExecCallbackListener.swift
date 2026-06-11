import Foundation
import IOSUseProtocol

private enum XCTestCallbackTrace {
    static let enabled = ProcessInfo.processInfo.environment["IOS_USE_COREDEVICE_TRACE"] == "1"
}

struct XCTestExecCallbackListenerFailure: Error, CustomStringConvertible {
    enum Phase: Equatable {
        case waitingForConfiguration
        case afterConfiguration
    }

    enum Reason: Equatable {
        case transportEnded
        case protocolError
    }

    let phase: Phase
    let reason: Reason
    let underlying: Error
    let listenerState: String?

    var description: String {
        let stateDescription = listenerState.map { " listenerState={\($0)}" } ?? ""
        return "XCTest exec callback listener \(reasonDescription) during \(phaseDescription): \(underlying)\(stateDescription)"
    }

    private var phaseDescription: String {
        switch phase {
        case .waitingForConfiguration:
            return "startup"
        case .afterConfiguration:
            return "post-configuration hold"
        }
    }

    private var reasonDescription: String {
        switch reason {
        case .transportEnded:
            return "transport ended"
        case .protocolError:
            return "protocol error"
        }
    }
}

final class XCTestExecCallbackListener {
    private static let runnerReadySelector = "_XCT_testRunnerReadyWithCapabilities:"

    private enum RuntimeState: String {
        case idle
        case readingMessage
        case unarchivingSelector
        case sendingConfigurationReply
        case sendingAck
    }

    private let channel: DTXChannelClient
    private let configurationPayload: Data
    private let eventSink: ((String) -> Void)?
    private let queue = DispatchQueue(label: "ios-use.xctest.exec-listener")
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private var configurationSent = false
    private var listenerFailure: XCTestExecCallbackListenerFailure?
    private var postConfigurationFailureReported = false
    private var runtimeState: RuntimeState = .idle
    private var lastSelector: String?
    private var lastMessageIdentifier: UInt32?
    private var lastAckAt: Date?
    private var lastMessageAt: Date?
    private var lastErrorDescription: String?

    init(channel: DTXChannelClient, configurationPayload: Data, eventSink: ((String) -> Void)? = nil) {
        self.channel = channel
        self.configurationPayload = configurationPayload
        self.eventSink = eventSink
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

    func waitUntilConfigurationSent(timeoutSeconds: Double) throws {
        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        if result == .success {
            if isConfigurationSent {
                return
            }
            if let error = currentError {
                throw error
            }
            return
        }
        if let error = currentError {
            throw error
        }
        throw CLIParseError.invalidValue("Timed out waiting for XCTest runner ready callback")
    }

    var startupFailure: Error? {
        guard let failure = currentFailure,
              failure.phase == .waitingForConfiguration else {
            return nil
        }
        return failure
    }

    func takePostConfigurationFailure() -> XCTestExecCallbackListenerFailure? {
        lock.lock()
        defer { lock.unlock() }
        guard let failure = listenerFailure,
              failure.phase == .afterConfiguration,
              !postConfigurationFailureReported else {
            return nil
        }
        postConfigurationFailureReported = true
        return failure
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private var currentError: Error? {
        currentFailure
    }

    private var currentFailure: XCTestExecCallbackListenerFailure? {
        lock.lock()
        defer { lock.unlock() }
        return listenerFailure
    }

    private var isConfigurationSent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return configurationSent
    }

    private func run() {
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
                if Self.isIdleTimeout(error) {
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
        if XCTestCallbackTrace.enabled, let selector {
            eventSink?("exec callback \(selector)")
        }

        if selector == Self.runnerReadySelector {
            updateState(.sendingConfigurationReply)
            try channel.sendRawObjectReply(to: message, payload: configurationPayload)
            eventSink?("sent XCTestConfiguration reply")
            markConfigurationSent()
            return
        }

        if message.transportFlags & DTXTransportFlag.expectsReply != 0 {
            updateState(.sendingAck)
            try channel.sendAckReply(to: message)
            recordAck()
        }
    }

    private func markConfigurationSent() {
        lock.lock()
        if !configurationSent {
            configurationSent = true
            lock.unlock()
            semaphore.signal()
            return
        }
        lock.unlock()
    }

    private func recordFailure(_ error: Error) {
        let state = stateSnapshot(recording: error)
        lock.lock()
        if listenerFailure == nil {
            listenerFailure = XCTestExecCallbackListenerFailure(
                phase: configurationSent ? .afterConfiguration : .waitingForConfiguration,
                reason: Self.failureReason(for: error),
                underlying: error,
                listenerState: state
            )
        }
        lock.unlock()
        semaphore.signal()
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

    static func isIdleTimeout(_ error: Error) -> Bool {
        if case CoreDeviceTCPError.connectionTimeout = error {
            return true
        }
        if let streamError = error as? DeviceStreamError {
            return streamError.isTimeout
        }
        return false
    }

    private static func failureReason(for error: Error) -> XCTestExecCallbackListenerFailure.Reason {
        if case CoreDeviceTCPError.connectionReset = error {
            return .transportEnded
        }
        if case CoreDeviceTCPError.connectionClosed = error {
            return .transportEnded
        }
        if let streamError = error as? DeviceStreamError {
            switch streamError {
            case .closed, .readFailed, .writeFailed, .writeFailedWithError:
                return .transportEnded
            case .timeout:
                return .protocolError
            }
        }
        return .protocolError
    }
}
