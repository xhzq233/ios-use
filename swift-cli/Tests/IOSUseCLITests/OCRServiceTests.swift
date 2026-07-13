import XCTest
import CoreGraphics
@testable import IOSUseCLI

final class OCRServiceTests: XCTestCase {
    func testFormatUsesCompactFourDecimalCoordinates() {
        let result = OCRService.Result(
            imageWidth: 100,
            imageHeight: 200,
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
            "OCR (accurate):\n- 按钮 [0.1235,0.2000,0.2500,0.1000] confidence=0.5000\n"
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
        let frameNorm = try XCTUnwrap(element["frameNorm"] as? [NSNumber])

        XCTAssertNil(object["engine"])
        XCTAssertNil(element["framePixels"])
        XCTAssertNil(element["frameNormalized"])
        XCTAssertEqual(frame.map(\.intValue), [12, 40, 25, 20])
        XCTAssertEqual(frameNorm.map(\.doubleValue), [0.1235, 0.2, 0.25, 0.1])
        XCTAssertTrue(json.contains("\"confidence\":0.5000"))
        XCTAssertTrue(json.contains("\"frame\":[12,40,25,20]"))
        XCTAssertTrue(json.contains("\"frameNorm\":[0.1235,0.2000,0.2500,0.1000]"))
        XCTAssertFalse(json.contains("\"engine\""))
    }
}
