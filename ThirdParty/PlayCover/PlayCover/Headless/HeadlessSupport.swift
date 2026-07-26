import Foundation

/// Headless replacement for PlayCover's UI log sink. The source ports keep
/// their original call sites and emit bounded process diagnostics.
final class Log {
    static let shared = Log()

    func log(_ value: Any) {
        Swift.print("[PlayCover] \(value)")
    }

    func error(_ value: Any) {
        Swift.print("[PlayCover] error: \(value)")
    }
}

enum KeyCoverStatus {
    case disabled
    case selfGeneratedPassword
    case userProvidedPassword
}

/// The CLI has no KeyCover settings UI. Defaults match a fresh PlayCover
/// installation; callers may opt in programmatically in a future explicit API.
final class KeyCoverPreferences {
    static let shared = KeyCoverPreferences()
    var keyCoverEnabled: KeyCoverStatus = .disabled
    var promptForKeyCoverPasswordAtLaunch = false
}
