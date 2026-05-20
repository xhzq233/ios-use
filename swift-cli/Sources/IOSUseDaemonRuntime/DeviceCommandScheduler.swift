import Foundation

public enum CommandKind: String, Codable, Equatable, Sendable {
    case ui
    case flow
    case config
    case stop
    case proxyUI
    case streaming
    case local
}

public actor DeviceCommandScheduler {
    private struct Tail {
        var id: UUID
        var gate: AsyncGate
    }

    private var tails: [String: Tail] = [:]

    public init() {}

    public func enqueue<T: Sendable>(
        udid: String,
        kind: CommandKind,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        if kind == .streaming || kind == .local {
            return try await operation()
        }

        let previous = tails[udid]?.gate
        let id = UUID()
        let gate = AsyncGate()
        tails[udid] = Tail(id: id, gate: gate)

        if let previous {
            await previous.wait()
        }

        do {
            let result = try await operation()
            await finish(udid: udid, id: id, gate: gate)
            return result
        } catch {
            await finish(udid: udid, id: id, gate: gate)
            throw error
        }
    }

    public func hasQueuedWork(for udid: String) -> Bool {
        tails[udid] != nil
    }

    private func finish(udid: String, id: UUID, gate: AsyncGate) async {
        await gate.finish()
        if tails[udid]?.id == id {
            tails.removeValue(forKey: udid)
        }
    }
}

private actor AsyncGate {
    private var finished = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation in
            if finished {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
