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
        let logicalWidth: Double?
        let logicalHeight: Double?
        let scale: Double?
        let observations: [Observation]

        init(
            imageWidth: Int,
            imageHeight: Int,
            logicalSize: CGSize? = nil,
            scale: Double? = nil,
            observations: [Observation]
        ) {
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
            self.logicalWidth = logicalSize.map { Double($0.width) }
            self.logicalHeight = logicalSize.map { Double($0.height) }
            self.scale = scale
            self.observations = observations
        }

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

    static func recognize(data: Data, logicalSize: CGSize? = nil, scale: Double? = nil) throws -> Result {
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
        return Result(
            imageWidth: image.width,
            imageHeight: image.height,
            logicalSize: logicalSize,
            scale: scale,
            observations: observations
        )
    }

    static func format(_ result: Result) -> String {
        guard !result.observations.isEmpty else { return "OCR (accurate): none\n" }
        var lines = ["OCR (accurate):"]
        lines += result.observations.map { observation in
            let box = observation.boundingBox
            // Vision uses a bottom-left origin; expose the same top-left origin
            // used by screenshots, DOM frames, and the JSON sidecar.
            let frame = logicalFrame(box, result: result)
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
            let frameJSON = logicalFrame(box, result: result).map { fixed4(Double($0)) }.joined(separator: ",")
            return "    {\"text\":\(try jsonString(observation.text)),\"confidence\":\(fixed4(Double(observation.confidence))),\"frame\":[\(frameJSON)]}"
        }

        let coordinateSpace = result.logicalWidth != nil && result.logicalHeight != nil ? "logical" : "pixel"
        let sizeJSON = "[\(result.imageWidth),\(result.imageHeight)]"
        var imageFields = [
            "\"file\":\(try jsonString(imageName))",
            "\"size\":\(sizeJSON)"
        ]
        if let logicalWidth = result.logicalWidth, let logicalHeight = result.logicalHeight {
            imageFields.append("\"logicalSize\":[\(fixed4(logicalWidth)),\(fixed4(logicalHeight))]")
            let effectiveScale = result.scale ?? min(
                Double(result.imageWidth) / max(logicalWidth, 1),
                Double(result.imageHeight) / max(logicalHeight, 1)
            )
            imageFields.append("\"scale\":\(fixed4(effectiveScale))")
        }

        var json = [
            "{",
            "  \"schemaVersion\":2,",
            "  \"recognitionLevel\":\"accurate\",",
            "  \"coordinateSpace\":\"\(coordinateSpace)\",",
            "  \"image\":{\(imageFields.joined(separator: ","))},",
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

    private static func logicalFrame(_ box: CGRect, result: Result) -> [Double] {
        let width = result.logicalWidth ?? Double(result.imageWidth)
        let height = result.logicalHeight ?? Double(result.imageHeight)
        return [
            Double(box.minX) * width,
            Double(1 - box.maxY) * height,
            Double(box.width) * width,
            Double(box.height) * height
        ]
    }

    private static func fixed4(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
