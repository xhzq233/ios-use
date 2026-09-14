#if os(Linux)
import Foundation
import XCTest
@testable import IOSUseCLI

final class LinuxScreenshotTests: XCTestCase {
    func testJPEGDimensionsSkipMetadataSegments() {
        let jpeg = Data([
            0xff, 0xd8,
            0xff, 0xe0, 0, 6, 1, 2, 3, 4,
            0xff, 0xc2, 0, 11, 8, 0x0a, 0x3e, 0x04, 0xb6, 1, 1, 0x11, 0
        ])
        let size = ScreenshotCaptureCoordinator.jpegPixelSize(jpeg)
        XCTAssertEqual(size?.x, 1206)
        XCTAssertEqual(size?.y, 2622)
        for length in 0..<jpeg.count {
            XCTAssertNil(ScreenshotCaptureCoordinator.jpegPixelSize(jpeg.prefix(length)))
        }
    }

    func testMalformedJPEGDoesNotInventDimensions() {
        for bytes: [UInt8] in [[], [0xff, 0xd8, 0xff], [0xff, 0xd8, 0xff, 0xc0, 0, 1],
                              [0xff, 0xd8, 0xff, 0xda, 0, 8, 8, 1, 2, 3, 4, 5]] {
            XCTAssertNil(ScreenshotCaptureCoordinator.jpegPixelSize(Data(bytes)))
        }
    }
}
#endif
