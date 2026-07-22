import Foundation
import IOSUseProtocol

enum ScreenshotArtifactService {
    typealias OCRRecognizer = (Data, CGSize?, Double?, OCRService.RecognitionLevel) throws -> OCRService.Result
    static var ocrRecognizerForTesting: OCRRecognizer?

    struct Result {
        let stdout: String
        let imagePath: String
        let ocrSidecarPath: String?
        let warning: String?
        let pixelSize: ForyPoint?
        let logicalSize: ForyPoint?
        let scale: Double?
        let geometrySource: String?
        let performance: ScreenshotCapturePerformance?
    }

    final class Work {
        private let capture: ScreenshotCapture
        private let path: String
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var imageError: Error?
        private var ocrOutput: String?
        private var ocrSidecarPath: String?

        fileprivate init(
            capture: ScreenshotCapture,
            paths: IOSUsePaths,
            name: String?,
            defaultName: String,
            ocr: Bool
        ) throws {
            self.capture = capture
            try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
            path = try ArtifactPaths.file(paths: paths, name: name, defaultName: defaultName, extension: "jpg")
            let sidecarPath = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("ocr.json").path
            try? FileManager.default.removeItem(atPath: sidecarPath)

            let data = capture.jpeg
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { group.leave() }
                do {
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                } catch {
                    lock.lock()
                    imageError = error
                    lock.unlock()
                }
            }

            guard ocr else { return }
            let recognizer = ScreenshotArtifactService.ocrRecognizerForTesting ?? { data, logicalSize, scale, recognitionLevel in
                try OCRService.recognize(
                    data: data,
                    logicalSize: logicalSize,
                    scale: scale,
                    recognitionLevel: recognitionLevel
                )
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { group.leave() }
                do {
                    let startedAt = CFAbsoluteTimeGetCurrent()
                    let logicalSize = capture.logicalSize.map { CGSize(width: $0.x, height: $0.y) }
                    let result = try recognizer(data, logicalSize, capture.scale, .accurate)
                    let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond)
                    let writtenPath = try OCRService.writeSidecar(result: result, imagePath: path, elapsedMs: elapsedMs)
                    let output = OCRService.format(result) + "OCR sidecar: \(writtenPath)\n"
                    lock.lock()
                    ocrOutput = output
                    ocrSidecarPath = writtenPath
                    lock.unlock()
                } catch {
                    lock.lock()
                    ocrOutput = "OCR (accurate): unavailable (\(error))\n"
                    lock.unlock()
                }
            }
        }

        func finish() throws -> Result {
            group.wait()
            lock.lock()
            let capturedImageError = imageError
            let capturedOCROutput = ocrOutput
            let capturedOCRSidecarPath = ocrSidecarPath
            lock.unlock()
            if let capturedImageError {
                throw capturedImageError
            }

            var stdout = "Screenshot saved: \(path)\n"
            if let warning = capture.warning {
                stdout += "Warning: \(warning)\n"
            }
            if let capturedOCROutput {
                stdout += capturedOCROutput
            }
            return Result(
                stdout: stdout,
                imagePath: path,
                ocrSidecarPath: capturedOCRSidecarPath,
                warning: capture.warning,
                pixelSize: capture.pixelSize,
                logicalSize: capture.logicalSize,
                scale: capture.scale,
                geometrySource: capture.geometrySource,
                performance: capture.performance
            )
        }
    }

    static func start(
        capture: ScreenshotCapture,
        paths: IOSUsePaths,
        name: String?,
        defaultName: String,
        ocr: Bool
    ) throws -> Work {
        try Work(capture: capture, paths: paths, name: name, defaultName: defaultName, ocr: ocr)
    }
}
