import Foundation

// MARK: - Command

typealias Command = DriverCommand

// MARK: - DriverError

enum DriverError: Error {
    case noSession
    case invalidArgs(String)
    case appNotFound(String)
    case elementNotFound(String)
    case ambiguous(String)
    case timeout(String)
    case atBoundary(String)
    case screenshotFailed(String)
    case gestureFailed(String)
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
        case .screenshotFailed(let s): return "screenshot failed: \(s)"
        case .gestureFailed(let s): return "gesture failed: \(s)"
        case .serverError(let s): return "server error: \(s)"
        }
    }
}

extension DriverError {
    var errorCategory: String {
        switch self {
        case .invalidArgs:
            return IOSUseErrorCategory.validation
        case .noSession, .appNotFound:
            return IOSUseErrorCategory.session
        case .elementNotFound, .ambiguous:
            return IOSUseErrorCategory.lookup
        case .timeout:
            return IOSUseErrorCategory.timeout
        case .atBoundary, .gestureFailed:
            return IOSUseErrorCategory.action
        case .screenshotFailed, .serverError:
            return IOSUseErrorCategory.internalFailure
        }
    }

    var errorCode: String {
        switch self {
        case .noSession: return IOSUseErrorCode.noActiveSession
        case .invalidArgs: return IOSUseErrorCode.invalidArguments
        case .appNotFound: return IOSUseErrorCode.appNotFound
        case .elementNotFound: return IOSUseErrorCode.elementNotFound
        case .ambiguous: return IOSUseErrorCode.elementAmbiguous
        case .timeout: return IOSUseErrorCode.waitTimedOut
        case .atBoundary: return IOSUseErrorCode.scrollBoundary
        case .screenshotFailed: return IOSUseErrorCode.snapshotFailed
        case .gestureFailed: return IOSUseErrorCode.gestureFailed
        case .serverError: return IOSUseErrorCode.internalFailure
        }
    }

    var errorPhase: String {
        switch self {
        case .invalidArgs: return IOSUseErrorPhase.validation
        case .noSession, .appNotFound: return IOSUseErrorPhase.session
        case .elementNotFound, .ambiguous: return IOSUseErrorPhase.lookup
        case .timeout: return IOSUseErrorPhase.wait
        case .atBoundary, .gestureFailed: return IOSUseErrorPhase.interaction
        case .screenshotFailed: return IOSUseErrorPhase.snapshot
        case .serverError: return IOSUseErrorPhase.dispatch
        }
    }

    var isRetryable: Bool {
        switch self {
        case .noSession, .appNotFound, .elementNotFound, .ambiguous, .timeout,
             .atBoundary, .screenshotFailed, .gestureFailed:
            return true
        case .invalidArgs, .serverError:
            return false
        }
    }
}

// MARK: - Helpers

extension Double {
    var sanitized: Double {
        isFinite
            ? (self * IOSUseProtocol.sanitizedDecimalScale).rounded(.toNearestOrEven) / IOSUseProtocol.sanitizedDecimalScale
            : 0
    }
}
