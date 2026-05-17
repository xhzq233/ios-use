import Darwin
import Dispatch
import Foundation

public struct CLIExitSignal: Error, CustomStringConvertible {
    public let exitCode: Int32
    public let message: String

    public var description: String { message }
}

final class InterruptMonitor {
    private let lock = NSLock()
    private var interruptedValue = false
    private var exitCodeValue: Int32 = 0
    private var sources: [DispatchSourceSignal] = []
    private let signalExitCodes: [Int32: Int32]
    private let onInterrupt: (() -> Void)?

    init(signalExitCodes: [Int32: Int32] = [SIGINT: 130, SIGTERM: 143], onInterrupt: (() -> Void)? = nil) {
        self.signalExitCodes = signalExitCodes
        self.onInterrupt = onInterrupt
    }

    var interrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interruptedValue
    }

    var exitCode: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return exitCodeValue == 0 ? 130 : exitCodeValue
    }

    func start() {
        guard sources.isEmpty else { return }
        for (signalNumber, exitCode) in signalExitCodes {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                self?.markInterrupted(exitCode: exitCode)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll(keepingCapacity: true)
        for signalNumber in signalExitCodes.keys {
            signal(signalNumber, SIG_DFL)
        }
    }

    func throwIfInterrupted(_ message: String = "Interrupted by Ctrl+C") throws {
        if interrupted {
            throw CLIExitSignal(exitCode: exitCode, message: message)
        }
    }

    private func markInterrupted(exitCode: Int32) {
        lock.lock()
        let firstInterrupt = !interruptedValue
        interruptedValue = true
        exitCodeValue = exitCode
        lock.unlock()
        if firstInterrupt {
            onInterrupt?()
        } else {
            Foundation.exit(exitCode)
        }
    }
}
