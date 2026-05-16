import UIKit
import XCTest
import Fory

// MARK: - Screenshot (doc 1.2, 6.2)

enum ScreenCommands {

    /// Captures a JPEG screenshot and returns it as a ForyResponseFrame.
    static func screenshot() throws -> ForyResponseFrame {
        var error: NSError?
        guard let jpeg = XCRequestScreenshotJPEG(CGFloat(IOSUseProtocol.screenshotJpegQuality), &error) as Data? else {
            throw DriverError.serverError("screenshot JPEG capture failed: \(error?.localizedDescription ?? "unknown error")")
        }
        let payload = ForyScreenshotPayload(jpeg: jpeg)
        return try Codec.foryOK(payload)
    }
}
