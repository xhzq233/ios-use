import Foundation
import IOSUseProtocol

enum ScreenshotCaptureCoordinator {
    static func capture(paths: IOSUsePaths, screenshot: () throws -> ScreenshotCapture) throws -> ScreenshotCapture {
        let start = ProcessInfo.processInfo.systemUptime
        let capture = try screenshot()
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        // The driver supplies logical points and scale alongside the JPEG.
        let pixels = capture.logicalSize.flatMap { logical in
            capture.scale.map { ForyPoint(x: logical.x * $0, y: logical.y * $0) }
        }
        return ScreenshotCapture(
            jpeg: capture.jpeg, pixelSize: pixels,
            logicalSize: capture.logicalSize, scale: capture.scale,
            geometrySource: "driver-logical-size+scale",
            performance: ScreenshotCapturePerformance(
                screenshotElapsedMs: elapsed, displayInfoElapsedMs: nil,
                displayInfoServiceElapsedMs: nil, totalElapsedMs: elapsed
            )
        )
    }
}
