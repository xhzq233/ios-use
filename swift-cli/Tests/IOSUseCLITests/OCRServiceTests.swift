import XCTest
import CoreGraphics
@testable import IOSUseCLI

final class OCRServiceTests: XCTestCase {
    func testRecognitionLevelConfiguresVisionPerformanceMode() {
        XCTAssertEqual(OCRService.RecognitionLevel.accurate.visionValue, .accurate)
        XCTAssertTrue(OCRService.RecognitionLevel.accurate.usesLanguageCorrection)
        XCTAssertEqual(OCRService.RecognitionLevel.fast.visionValue, .fast)
        XCTAssertFalse(OCRService.RecognitionLevel.fast.usesLanguageCorrection)
    }

    func testFormatUsesCompactFourDecimalCoordinates() {
        let result = OCRService.Result(
            imageWidth: 100,
            imageHeight: 200,
            logicalSize: CGSize(width: 50, height: 100),
            scale: 2,
            observations: [
                OCRService.Observation(
                    text: "按钮",
                    confidence: 0.5,
                    boundingBox: CGRect(x: 0.123456, y: 0.7, width: 0.25, height: 0.1)
                )
            ]
        )

        XCTAssertEqual(
            OCRService.format(result),
            "OCR (accurate):\n- 按钮 [6.1728,20.0000,12.5000,10.0000] confidence=0.5000\n"
        )
    }

    func testSidecarUsesCompactFramesAndOmitsEngine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imagePath = root.appendingPathComponent("screen.jpg").path
        let result = OCRService.Result(
            imageWidth: 100,
            imageHeight: 200,
            logicalSize: CGSize(width: 50, height: 100),
            scale: 2,
            observations: [
                OCRService.Observation(
                    text: "按钮\"",
                    confidence: 0.5,
                    boundingBox: CGRect(x: 0.123456, y: 0.7, width: 0.25, height: 0.1)
                )
            ]
        )

        let sidecarPath = try OCRService.writeSidecar(result: result, imagePath: imagePath, elapsedMs: 12)
        let data = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        let json = String(decoding: data, as: UTF8.self)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let element = try XCTUnwrap((object["elements"] as? [[String: Any]])?.first)
        let frame = try XCTUnwrap(element["frame"] as? [NSNumber])
        let image = try XCTUnwrap(object["image"] as? [String: Any])
        let logicalSize = try XCTUnwrap(image["logicalSize"] as? [NSNumber])

        XCTAssertNil(object["engine"])
        XCTAssertEqual(object["recognitionLevel"] as? String, "accurate")
        XCTAssertNil(element["framePixels"])
        XCTAssertNil(element["frameNormalized"])
        XCTAssertNil(element["frameNorm"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["coordinateSpace"] as? String, "logical")
        XCTAssertEqual(frame.map(\.doubleValue), [6.1728, 20, 12.5, 10])
        XCTAssertEqual(logicalSize.map(\.doubleValue), [50, 100])
        XCTAssertTrue(json.contains("\"confidence\":0.5000"))
        XCTAssertTrue(json.contains("\"frame\":[6.1728,20.0000,12.5000,10.0000]"))
        XCTAssertTrue(json.contains("\"logicalSize\":[50.0000,100.0000]"))
        XCTAssertFalse(json.contains("\"frameNorm\""))
        XCTAssertFalse(json.contains("\"engine\""))
    }

    func testSidecarLabelsScreenshotRectFallbackAsPixels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-ocr-pixels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = OCRService.Result(
            imageWidth: 1206,
            imageHeight: 2622,
            observations: [
                OCRService.Observation(
                    text: "Fallback",
                    confidence: 1,
                    boundingBox: CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)
                )
            ]
        )
        let sidecarPath = try OCRService.writeSidecar(
            result: result,
            imagePath: root.appendingPathComponent("screen.jpg").path,
            elapsedMs: 1
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let image = try XCTUnwrap(object["image"] as? [String: Any])
        let element = try XCTUnwrap((object["elements"] as? [[String: Any]])?.first)

        XCTAssertEqual(object["coordinateSpace"] as? String, "pixel")
        XCTAssertNil(image["logicalSize"])
        XCTAssertEqual((element["frame"] as? [NSNumber])?.map(\.doubleValue), [603, 655.5, 301.5, 655.5])
    }
}
