import XCTest
import CoreGraphics
import ImageIO
@testable import IOSUseCLI

final class ImageDiffServiceTests: XCTestCase {
    func testNearIdenticalImagesWithDifferentJPEGBytesAreUnchanged() throws {
        let first = try makeJPEG(quality: 0.8)
        let second = try makeJPEG(quality: 0.95)
        XCTAssertNotEqual(first, second)

        let result = try ImageDiffService.compare(
            previous: first,
            current: second,
            logicalSize: CGSize(width: 402, height: 874)
        )

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.compareWidth, 402)
        XCTAssertEqual(result.compareHeight, 874)
        XCTAssertLessThan(result.score, 0.01)
    }

    func testSmallStronglyChangedTileIsRetained() throws {
        let first = try makeJPEG(quality: 0.8, changedTile: false)
        let second = try makeJPEG(quality: 0.8, changedTile: true)

        let result = try ImageDiffService.compare(
            previous: first,
            current: second,
            logicalSize: CGSize(width: 402, height: 874)
        )

        XCTAssertTrue(result.changed)
        XCTAssertGreaterThan(result.changedTileRatio, 0)
        XCTAssertLessThan(result.changedTileRatio, 0.01)
    }

    func testStatefulDetectorHandlesUnchangedThenChangedFrames() throws {
        let first = try makeJPEG(quality: 0.8)
        let sameVisual = try makeJPEG(quality: 0.95)
        let changed = try makeJPEG(quality: 0.8, changedTile: true)
        var detector = ImageDiffService.Detector()

        XCTAssertTrue(try detector.compare(current: first, logicalSize: CGSize(width: 402, height: 874)).changed)
        XCTAssertFalse(try detector.compare(current: sameVisual, logicalSize: CGSize(width: 402, height: 874)).changed)
        XCTAssertTrue(try detector.compare(current: changed, logicalSize: CGSize(width: 402, height: 874)).changed)
    }

    private func makeJPEG(quality: CGFloat, changedTile: Bool = false) throws -> Data {
        let width = 402
        let height = 874
        var pixels = [UInt8](repeating: 245, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("unable to create test bitmap context")
        }
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if changedTile {
            context.setFillColor(CGColor(gray: 0.05, alpha: 1))
            context.fill(CGRect(x: 170, y: 410, width: 24, height: 24))
        }
        guard let image = context.makeImage() else {
            throw XCTSkip("unable to create test image")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("unable to create JPEG destination")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("unable to encode test JPEG")
        }
        return output as Data
    }
}
