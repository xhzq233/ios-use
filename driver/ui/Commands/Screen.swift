import UIKit
import XCTest
import Fory

// MARK: - Screenshot (doc 1.2, 6.2)

enum ScreenCommands {
    /// Captures a JPEG screenshot and returns it as a ForyResponseFrame.
    static func screenshot() throws -> ForyResponseFrame {
        var error: NSError?
        guard let jpeg = XCRequestScreenshotJPEG(CGFloat(IOSUseProtocol.screenshotJpegQuality), &error) as Data? else {
            throw DriverError.screenshotFailed("JPEG capture failed: \(error?.localizedDescription ?? "unknown error")")
        }
        let screen = UIScreen.main
        let payload = ForyScreenshotPayload(
            jpeg: jpeg,
            // Some real-device XCTest runners report a synthetic 320×480
            // UIScreen bounds. The host resolves logical geometry from
            // CoreDevice Display Info in parallel with this request, so do not
            // take an expensive AX snapshot on the screenshot hot path.
            logicalSize: ForyPoint(),
            scale: Double(screen.scale)
        )
        return try Codec.foryOK(payload)
    }
}
