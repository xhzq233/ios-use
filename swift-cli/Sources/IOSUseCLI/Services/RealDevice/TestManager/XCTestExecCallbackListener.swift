import Foundation

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
    private var listenerError: Error?

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

    var terminalError: Error? {
        currentError
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private var currentError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return listenerError
    }

    private var isConfigurationSent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return configurationSent
    }

    private func run() {
        while !shouldStop {
            do {
                let message = try channel.readMessage(timeoutSeconds: 1)
                try handle(message)
            } catch {
                if shouldStop {
                    return
                }
                if Self.isIdleTimeout(error) {
                    continue
                }
                recordError(error)
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
            eventSink?("exec callback \(selector)")
        }

        if selector == Self.runnerReadySelector {
            try channel.sendRawObjectReply(to: message, payload: configurationPayload)
            eventSink?("sent XCTestConfiguration reply")
            markConfigurationSent()
            return
        }

        if message.transportFlags & DTXTransportFlag.expectsReply != 0 {
            try channel.sendRawObjectReply(to: message)
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

    private func recordError(_ error: Error) {
        lock.lock()
        if listenerError == nil {
            listenerError = error
        }
        lock.unlock()
        semaphore.signal()
    }

    static func isIdleTimeout(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.localizedCaseInsensitiveContains("timeout")
            || message.localizedCaseInsensitiveContains("timed out")
    }
}
