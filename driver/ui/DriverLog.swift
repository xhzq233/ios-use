import Foundation

enum DriverLog {
    typealias Sink = (String) -> Void

    private static let sinkLock = NSLock()
    private static var sink: Sink = { message in
        NSLog("%@", message)
    }

    static func info(_ message: String) {
        write(message)
    }

    static func error(_ message: String) {
        write(message)
    }

    private static func write(_ message: String) {
        sinkLock.lock()
        let currentSink = sink
        sinkLock.unlock()
        currentSink(message)
    }

    #if DEBUG
    static func withSinkForTesting<T>(_ replacement: @escaping Sink, body: () throws -> T) rethrows -> T {
        sinkLock.lock()
        let previousSink = sink
        sink = replacement
        sinkLock.unlock()
        defer {
            sinkLock.lock()
            sink = previousSink
            sinkLock.unlock()
        }
        return try body()
    }
    #endif
}
