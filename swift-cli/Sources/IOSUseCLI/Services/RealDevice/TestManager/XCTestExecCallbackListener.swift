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

    var description: String {
        "XCTest exec callback listener \(reasonDescription) during \(phaseDescription): \(underlying)"
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
                let message = try channel.readMessage(timeoutSeconds: IOSUseProtocol.XCConstants.xctestCallbackReadTimeoutSeconds)
                try handle(message)
            } catch {
                if shouldStop {
                    return
                }
                if Self.isIdleTimeout(error) {
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
        if XCTestCallbackTrace.enabled, let selector {
            eventSink?("exec callback \(selector)")
        }

        if selector == Self.runnerReadySelector {
            try channel.sendRawObjectReply(to: message, payload: configurationPayload)
            eventSink?("sent XCTestConfiguration reply")
            markConfigurationSent()
            return
        }

        if message.transportFlags & DTXTransportFlag.expectsReply != 0 {
            try channel.sendAckReply(to: message)
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
        lock.lock()
        if listenerFailure == nil {
            listenerFailure = XCTestExecCallbackListenerFailure(
                phase: configurationSent ? .afterConfiguration : .waitingForConfiguration,
                reason: Self.failureReason(for: error),
                underlying: error
            )
        }
        lock.unlock()
        semaphore.signal()
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
