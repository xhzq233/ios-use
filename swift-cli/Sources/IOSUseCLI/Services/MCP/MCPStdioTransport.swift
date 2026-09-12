import Darwin
import Foundation
import Logging
import MCP

/// Keep the SDK protocol layer, but wake on pipe readiness instead of its
/// 10ms EAGAIN polling. Serialize whole messages across partial stdout writes.
actor MCPStdioTransport: Transport {
    nonisolated let logger = Logger(label: "ios-use.mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    private let queue = DispatchQueue(label: "ios-use.mcp.stdio", qos: .userInitiated)
    private let messages = AsyncThrowingStream<Data, Error>.makeStream()
    private var input: DispatchIO?
    private var output: DispatchIO?
    private var sending = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {
        guard input == nil else { return }
        // DispatchIO owns descriptor flags until cleanup. Duplicate stdio so
        // cancellation can release our channels without closing process stdio.
        let readFD = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 0)
        guard readFD >= 0 else { throw Self.ioError(errno) }
        let writeFD = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 0)
        guard writeFD >= 0 else {
            let error = errno
            Darwin.close(readFD)
            throw Self.ioError(error)
        }
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        let reader = DispatchIO(type: .stream, fileDescriptor: readFD, queue: queue) { _ in Darwin.close(readFD) }
        let writer = DispatchIO(type: .stream, fileDescriptor: writeFD, queue: queue) { _ in Darwin.close(writeFD) }
        input = reader
        output = writer
        let frames = InputFrames(continuation: messages.continuation)
        reader.setLimit(lowWater: 1)
        reader.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            frames.receive(data, done: done, error: error)
        }
    }

    func disconnect() async {
        messages.continuation.finish()
        input?.close(flags: .stop)
        output?.close(flags: .stop)
        input = nil
        output = nil
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        messages.stream
    }

    func send(_ data: Data) async throws {
        if sending {
            await withCheckedContinuation { waiting.append($0) }
        } else { sending = true }
        defer {
            if waiting.isEmpty { sending = false }
            else { waiting.removeFirst().resume() }
        }
        guard let output else { throw Self.ioError(ENOTCONN) }
        var framed = data
        framed.append(0x0A)
        let bytes = framed.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            output.write(offset: 0, data: bytes, queue: queue) { done, _, error in
                guard done else { return }
                if error != 0 { continuation.resume(throwing: Self.ioError(error)) }
                else { continuation.resume() }
            }
        }
    }

    private nonisolated static func ioError(_ code: Int32) -> MCPError {
        .transportError(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
    }

    // DispatchIO invokes this reader only on the serial I/O queue. Parse bytes
    // there, before yielding, to preserve ordering and split UTF-8 sequences.
    private final class InputFrames: @unchecked Sendable {
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private var pending = Data()
        private var scanned = 0

        init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.continuation = continuation
        }

        func receive(_ data: DispatchData?, done: Bool, error: Int32) {
            if let data {
                pending.append(contentsOf: data)
                while let newline = pending[scanned...].firstIndex(of: 0x0A) {
                    if newline > pending.startIndex { continuation.yield(Data(pending[..<newline])) }
                    pending.removeSubrange(...newline)
                    scanned = pending.startIndex
                }
                scanned = pending.endIndex
            }
            if error != 0 { continuation.finish(throwing: MCPStdioTransport.ioError(error)) }
            else if done { continuation.finish() }
        }
    }
}
