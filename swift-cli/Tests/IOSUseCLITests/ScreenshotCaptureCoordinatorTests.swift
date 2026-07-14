import CoreGraphics
import Foundation
import ImageIO
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI

final class ScreenshotCaptureCoordinatorTests: XCTestCase {
    enum TestError: Error {
        case timedOut
        case displayUnavailable
    }

    override func tearDown() {
        ScreenshotCaptureCoordinator.displayInfoRequesterForTesting = nil
        super.tearDown()
    }

    func testRealDeviceScreenshotAndDisplayInfoRunConcurrently() throws {
        let (paths, root) = try realDevicePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let screenshotStarted = DispatchSemaphore(value: 0)
        let displayStarted = DispatchSemaphore(value: 0)
        ScreenshotCaptureCoordinator.displayInfoRequesterForTesting = { _ in
            displayStarted.signal()
            guard screenshotStarted.wait(timeout: .now() + 1) == .success else {
                throw TestError.timedOut
            }
            return ScreenshotCaptureCoordinator.DisplayInfoMeasurement(
                info: Self.displayInfo(scale: 2),
                roundTripElapsedMs: 7,
                serviceElapsedMs: 3
            )
        }
        let jpeg = try makeJPEG(width: 40, height: 80)

        let capture = try ScreenshotCaptureCoordinator.capture(paths: paths) {
            screenshotStarted.signal()
            guard displayStarted.wait(timeout: .now() + 1) == .success else {
                throw TestError.timedOut
            }
            return ScreenshotCapture(jpeg: jpeg, scale: 3)
        }

        XCTAssertEqual(capture.pixelSize?.x, 40)
        XCTAssertEqual(capture.pixelSize?.y, 80)
        XCTAssertEqual(capture.logicalSize?.x, 20)
        XCTAssertEqual(capture.logicalSize?.y, 40)
        XCTAssertEqual(capture.scale, 2)
        XCTAssertEqual(capture.geometrySource, "coredevice-display-info+screenshot-rect")
        XCTAssertNil(capture.warning)
        XCTAssertEqual(capture.performance?.displayInfoElapsedMs, 7)
        XCTAssertEqual(capture.performance?.displayInfoServiceElapsedMs, 3)
    }

    func testDisplayInfoFailureWarnsAndUsesScreenshotRectWithDriverScale() throws {
        let (paths, root) = try realDevicePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        ScreenshotCaptureCoordinator.displayInfoRequesterForTesting = { _ in
            throw TestError.displayUnavailable
        }
        let jpeg = try makeJPEG(width: 40, height: 80)

        let capture = try ScreenshotCaptureCoordinator.capture(paths: paths) {
            ScreenshotCapture(jpeg: jpeg, scale: 2)
        }

        XCTAssertEqual(capture.logicalSize?.x, 20)
        XCTAssertEqual(capture.logicalSize?.y, 40)
        XCTAssertEqual(capture.geometrySource, "screenshot-rect+driver-scale")
        XCTAssertTrue(capture.warning?.contains("CoreDevice Display Info unavailable") == true)
        XCTAssertNotNil(capture.performance?.displayInfoElapsedMs)
    }

    func testMissingDisplayInfoAndScaleUsesPixelCoordinateRect() throws {
        let (paths, root) = try realDevicePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        ScreenshotCaptureCoordinator.displayInfoRequesterForTesting = { _ in
            throw TestError.displayUnavailable
        }
        let jpeg = try makeJPEG(width: 40, height: 80)

        let capture = try ScreenshotCaptureCoordinator.capture(paths: paths) {
            ScreenshotCapture(jpeg: jpeg)
        }

        XCTAssertNil(capture.logicalSize)
        XCTAssertNil(capture.scale)
        XCTAssertEqual(capture.geometrySource, "screenshot-rect-pixels")
    }

    private func realDevicePaths() throws -> (IOSUsePaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-screenshot-coordinator-\(UUID().uuidString)", isDirectory: true)
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path])
        try DriverSessionStore.write(
            info: SessionService.Info(
                udid: "REAL-1",
                deviceName: "iPhone",
                deviceVersion: "26.0",
                deviceType: "real",
                startedAt: 1,
                holderPid: 1,
                runnerPid: 2,
                sessionIdentifier: "SESSION",
                bundleId: "com.example.driver",
                controlSocketPath: root.appendingPathComponent("holder.sock").path
            ),
            paths: paths
        )
        return (paths, root)
    }

    private static func displayInfo(scale: Double) -> CoreDeviceDisplayInfo {
        CoreDeviceDisplayInfo(
            displays: [
                CoreDeviceDisplayInfo.Display(
                    displayID: 1,
                    name: "LCD",
                    primary: true,
                    pointScale: scale,
                    bounds: [0, 0, 40, 80],
                    nativeSize: [40, 80],
                    currentOrientation: "rot0",
                    nativeOrientation: "rot0"
                ),
            ],
            currentDeviceOrientation: "portrait",
            currentDeviceNonFlatOrientation: "portrait",
            orientationLocked: false,
            backlightState: "on"
        )
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 240, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw XCTSkip("unable to create JPEG fixture")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("unable to create JPEG destination")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("unable to encode JPEG fixture")
        }
        return output as Data
    }
}
