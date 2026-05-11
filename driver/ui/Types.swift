import Foundation

// MARK: - Command

enum Command: String, Codable {
    case createSession
    case deleteSession
    case activateApp
    case terminateApp
    case openURL
    case probeFetch
    case proxyCAPush
    case screenshot
    case dom
    case find
    case tap
    case longPress
    case input
    case swipe
    case waitFor
    case dismissAlert
}

// MARK: - DriverError

enum DriverError: Error {
    case noSession
    case invalidArgs(String)
    case appNotFound(String)
    case elementNotFound(String)
    case ambiguous(String)
    case timeout(String)
    case atBoundary(String)
    case serverError(String)
}

extension DriverError: CustomStringConvertible {
    var description: String {
        switch self {
        case .noSession: return "no active session"
        case .invalidArgs(let s): return "invalid arguments: \(s)"
        case .appNotFound(let s): return "app not found: \(s)"
        case .elementNotFound(let s): return "element not found: \(s)"
        case .ambiguous(let s): return "ambiguous: \(s)"
        case .timeout(let s): return "timeout: \(s)"
        case .atBoundary(let s): return "at boundary: \(s)"
        case .serverError(let s): return "server error: \(s)"
        }
    }
}

// MARK: - Helpers

extension Double {
    var sanitized: Double { isFinite ? (self * 10).rounded(.toNearestOrEven) / 10 : 0 }
}
