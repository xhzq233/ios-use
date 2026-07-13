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
            let frame = [box.minX, topLeftY, box.width, box.height]
                .map { fixed4(Double($0)) }
                .joined(separator: ",")
            return "- \(observation.text) [\(frame)] confidence=\(fixed4(Double(observation.confidence)))"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func writeSidecar(result: Result, imagePath: String, elapsedMs: Int = 0) throws -> String {
        let imageURL = URL(fileURLWithPath: imagePath)
        let imageName = imageURL.lastPathComponent
        let elements = try result.observations.map { observation -> String in
            let box = observation.boundingBox
            let normalized = [
                Double(box.minX),
                Double(1 - box.maxY),
                Double(box.width),
                Double(box.height)
            ]
            let pixels = [
                Int((normalized[0] * Double(result.imageWidth)).rounded()),
                Int((normalized[1] * Double(result.imageHeight)).rounded()),
                Int((normalized[2] * Double(result.imageWidth)).rounded()),
                Int((normalized[3] * Double(result.imageHeight)).rounded())
            ]
            let normalizedJSON = normalized.map(fixed4).joined(separator: ",")
            let pixelsJSON = pixels.map(String.init).joined(separator: ",")
            return "    {\"text\":\(try jsonString(observation.text)),\"confidence\":\(fixed4(Double(observation.confidence))),\"frame\":[\(pixelsJSON)],\"frameNorm\":[\(normalizedJSON)]}"
        }

        var json = [
            "{",
            "  \"schemaVersion\":1,",
            "  \"recognitionLevel\":\"accurate\",",
            "  \"image\":{\"file\":\(try jsonString(imageName)),\"width\":\(result.imageWidth),\"height\":\(result.imageHeight)},",
            "  \"elapsedMs\":\(elapsedMs),",
            "  \"elements\":["
        ]
        for (index, element) in elements.enumerated() {
            let suffix = index == elements.count - 1 ? "" : ","
            json.append("    \(element)\(suffix)")
        }
        json += [
            "  ]",
            "}",
            ""
        ]

        let url = imageURL.deletingPathExtension().appendingPathExtension("ocr.json")
        try json.joined(separator: "\n").data(using: .utf8)!.write(to: url, options: .atomic)
        return url.path
    }

    private static func fixed4(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
