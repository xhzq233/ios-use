import Foundation

enum DriverLog {
    static func info(_ message: String) {
        NSLog("%@", message)
    }

    static func error(_ message: String) {
        NSLog("%@", message)
    }
}
