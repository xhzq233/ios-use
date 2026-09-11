import Darwin
import Foundation
import Logging
import MCP

/// The SDK transport can suspend during a partial stdout write. Queue whole
/// messages so a concurrent ping/list reply cannot split an image response.
actor MCPStdioTransport: Transport {
    private let transport = StdioTransport()
    nonisolated var logger: Logging.Logger { transport.logger }
    private var sending = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
        try await transport.connect()
    }
    func disconnect() async { await transport.disconnect() }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in await transport.receive() {
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ data: Data) async throws {
        if sending {
            await withCheckedContinuation { waiting.append($0) }
        } else { sending = true }
        defer {
            if waiting.isEmpty { sending = false }
            else { waiting.removeFirst().resume() }
        }
        try await transport.send(data)
    }
}
