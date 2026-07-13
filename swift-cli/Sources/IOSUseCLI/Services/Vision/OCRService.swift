import CoreGraphics
import Foundation
import ImageIO
import Vision

struct OCRService {
    struct Observation {
        let text: String
        let confidence: Float
        let boundingBox: CGRect
    }

    struct Result {
        let imageWidth: Int
        let imageHeight: Int
        let observations: [Observation]

        var text: String {
            observations.map(\.text).joined(separator: "\n")
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case invalidImage
        case recognitionFailed(String)

        var description: String {
            switch self {
            case .invalidImage: return "image data is not a decodable image"
            case .recognitionFailed(let message): return message
            }
        }
    }

    static func recognize(data: Data) throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Error.invalidImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.01

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Error.recognitionFailed(error.localizedDescription)
        }

        let observations = (request.results ?? []).compactMap { observation -> Observation? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return Observation(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }.sorted {
            // Vision coordinates are bottom-left based; sort visually top-to-bottom,
            // then left-to-right so an agent receives the natural reading order.
            let yDelta = abs($0.boundingBox.midY - $1.boundingBox.midY)
            if yDelta > 0.02 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return Result(imageWidth: image.width, imageHeight: image.height, observations: observations)
    }

    static func format(_ result: Result) -> String {
        guard !result.observations.isEmpty else { return "OCR (accurate): none\n" }
        var lines = ["OCR (accurate):"]
        lines += result.observations.map { observation in
            let box = observation.boundingBox
            // Vision uses a bottom-left origin; expose the same top-left origin
            // used by screenshots, DOM frames, and the JSON sidecar.
            let topLeftY = 1 - box.maxY
            let confidence = String(format: "%.2f", observation.confidence)
            return String(format: "- %@ [x=%.3f,y=%.3f,w=%.3f,h=%.3f] confidence=%@", observation.text, box.minX, topLeftY, box.width, box.height, confidence)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func writeSidecar(result: Result, imagePath: String, elapsedMs: Int = 0) throws -> String {
        struct PixelFrame: Codable {
            let x: Int
            let y: Int
            let width: Int
            let height: Int
        }
        struct NormalizedFrame: Codable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }
        struct Element: Codable {
            let text: String
            let confidence: Double
            let framePixels: PixelFrame
            let frameNormalized: NormalizedFrame
        }
        struct Image: Codable {
            let file: String
            let width: Int
            let height: Int
        }
        struct Sidecar: Codable {
            let schemaVersion: Int
            let engine: String
            let recognitionLevel: String
            let image: Image
            let elapsedMs: Int
            let elements: [Element]
        }

        let imageURL = URL(fileURLWithPath: imagePath)
        let imageName = imageURL.lastPathComponent
        let elements = result.observations.map { observation -> Element in
            let box = observation.boundingBox
            let normalized = NormalizedFrame(
                x: Double(box.minX),
                y: Double(1 - box.maxY),
                width: Double(box.width),
                height: Double(box.height)
            )
            let pixels = PixelFrame(
                x: Int((normalized.x * Double(result.imageWidth)).rounded()),
                y: Int((normalized.y * Double(result.imageHeight)).rounded()),
                width: Int((normalized.width * Double(result.imageWidth)).rounded()),
                height: Int((normalized.height * Double(result.imageHeight)).rounded())
            )
            return Element(
                text: observation.text,
                confidence: Double(observation.confidence),
                framePixels: pixels,
                frameNormalized: normalized
            )
        }
        let sidecar = Sidecar(
            schemaVersion: 1,
            engine: "macOS Vision",
            recognitionLevel: "accurate",
            image: Image(file: imageName, width: result.imageWidth, height: result.imageHeight),
            elapsedMs: elapsedMs,
            elements: elements
        )
        let url = imageURL.deletingPathExtension().appendingPathExtension("ocr.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url, options: .atomic)
        return url.path
    }
}
