import Foundation
import IOSUseProtocol

enum ScreenshotCaptureCoordinator {
    static func capture(paths: IOSUsePaths, screenshot: () throws -> ScreenshotCapture) throws -> ScreenshotCapture {
        let start = ProcessInfo.processInfo.systemUptime
        let capture = try screenshot()
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        // XCTest can return a zero logical rect. Use the actual JPEG dimensions,
        // just as the Mac coordinator does through ImageIO, and the driver scale.
        let pixels = jpegPixelSize(capture.jpeg) ?? capture.pixelSize
        let logical = pixels.flatMap { pixels in
            capture.scale.map { ForyPoint(x: pixels.x / $0, y: pixels.y / $0) }
        } ?? capture.logicalSize
        return ScreenshotCapture(
            jpeg: capture.jpeg, pixelSize: pixels,
            logicalSize: logical, scale: capture.scale,
            geometrySource: pixels == nil ? "unavailable" : "screenshot-rect+driver-scale",
            performance: ScreenshotCapturePerformance(
                screenshotElapsedMs: elapsed, displayInfoElapsedMs: nil,
                displayInfoServiceElapsedMs: nil, totalElapsedMs: elapsed
            )
        )
    }

    /// Read dimensions from JPEG Start Of Frame; no pixel decoding is needed.
    static func jpegPixelSize(_ data: Data) -> ForyPoint? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }
        var offset = 2
        while offset + 1 < bytes.count {
            guard bytes[offset] == 0xff else { return nil }
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { return nil }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xd9 || marker == 0xda { return nil }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
            guard offset + 1 < bytes.count else { return nil }
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset else { return nil }
            if (0xc0...0xcf).contains(marker), ![0xc4, 0xc8, 0xcc].contains(marker) {
                guard length >= 8 else { return nil }
                let height = Int(bytes[offset + 3]) * 256 + Int(bytes[offset + 4])
                let width = Int(bytes[offset + 5]) * 256 + Int(bytes[offset + 6])
                guard width > 0, height > 0 else { return nil }
                return ForyPoint(x: Double(width), y: Double(height))
            }
            offset += length
        }
        return nil
    }
}
