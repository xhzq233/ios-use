import UIKit
import XCTest
import Fory

// MARK: - Screenshot (doc 1.2, 6.2)

enum ScreenCommands {
    /// Captures a JPEG screenshot and returns it as a ForyResponseFrame.
    static func screenshot() throws -> ForyResponseFrame {
        var error: NSError?
        var screen = XCPrimaryScreen()
        var scale = Double(UIScreen.main.scale)
        if XCHasMultipleDisplays() {
            let app = try Session.shared.refreshActive()
            guard let context = XCResolveDisplayContext(app, nil, &error),
                  let appScreen = XCDisplayScreen(context, &error) else {
                throw DriverError.screenshotFailed(error?.localizedDescription ?? "Active display is unavailable")
            }
            screen = appScreen
            scale = (screen.value(forKey: "scale") as? NSNumber)?.doubleValue ?? 0
        }
        guard let jpeg = XCRequestScreenshotJPEG(CGFloat(IOSUseProtocol.screenshotJpegQuality), screen, &error) as Data? else {
            throw DriverError.screenshotFailed("JPEG capture failed: \(error?.localizedDescription ?? "unknown error")")
        }
        let payload = ForyScreenshotPayload(
            jpeg: jpeg,
            // Some real-device XCTest runners report a synthetic 320×480
            // UIScreen bounds. The host resolves logical geometry from
            // CoreDevice Display Info in parallel with this request, so do not
            // take an expensive AX snapshot on the screenshot hot path.
            logicalSize: ForyPoint(),
            scale: scale
        )
        return try Codec.foryOK(payload)
    }
}
