import UIKit
import XCTest

// MARK: - Screenshot (doc 1.2, 6.2 — binary two-frame protocol)

/// Result of a screenshot request: a JPEG-encoded bitmap plus the payload
/// byte size used for the JSON header frame (doc 6.2).
struct ScreenshotResult {
    let size: Int
    let jpegData: Data
}

enum ScreenCommands {

    /// doc 6.2 — caller sends no args. Returns raw JPEG bytes; Server is
    /// responsible for emitting the `{size: N}` JSON frame followed by the
    /// binary JPEG frame (no base64).
    static func screenshot() throws -> ScreenshotResult {
        var error: NSError?
        guard let jpeg = XCRequestScreenshotJPEG(0.8, &error) as Data? else {
            throw DriverError.serverError("screenshot JPEG capture failed: \(error?.localizedDescription ?? "unknown error")")
        }
        return ScreenshotResult(size: jpeg.count, jpegData: jpeg)
    }
}
