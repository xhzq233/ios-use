import Foundation

/// Owned by the XCTest main thread. Use the same monotonic deadline as the
/// socket watchdog, including time spent queued before execution.
enum CommandDeadline {
    static var current: DispatchTime?

    static func withDeadline<T>(_ deadline: DispatchTime, body: () throws -> T) rethrows -> T {
        let previous = current
        current = deadline
        defer { current = previous }
        return try body()
    }

    static func check() throws {
        if let current, DispatchTime.now() >= current {
            throw DriverError.timeout("Command deadline expired; no further input was dispatched")
        }
    }
}
