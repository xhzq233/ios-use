import CoreGraphics
import Foundation
import IOSUseProtocol

enum DriverFailureEvidence {
    enum Profile: String, Equatable {
        case none
        case manifestOnly = "manifest-only"
        case uiSnapshot = "ui-snapshot"
    }

    private struct Failure {
        let message: String
        let renderedMessage: String
        let payload: ForyErrorPayload
        let mutationMayHaveApplied: Bool
    }

    private struct Manifest: Codable {
        struct Artifacts: Codable {
            let screenshot: String?
            let ocr: String?
            let dom: String?
        }

        struct Timing: Codable {
            let screenshotElapsedMs: Int?
            let screenshotOffsetMs: Int?
            let ocrElapsedMs: Int?
            let ocrOffsetMs: Int?
            let domElapsedMs: Int?
            let domOffsetMs: Int?
            let totalElapsedMs: Int
        }

        struct ErrorInfo: Codable {
            struct Target: Codable {
                let label: String
                let point: [Double]?
                let traits: String
                let cindex: Int32?
            }

            struct Candidate: Codable {
                let type: String
                let label: String
                let value: String
                let traits: [String]
                let frame: [Int32]?
                let ancestors: [String]
                let rejectedBy: [String]
            }

            let message: String
            let category: String
            let code: String
            let phase: String
            let retryable: Bool
            let fatal: Bool
            let mutationMayHaveApplied: Bool
            let target: Target?
            let candidateCount: Int32
            let suggestions: [String]
            let candidates: [Candidate]
        }

        let schemaVersion: Int
        let command: String
        let profile: String
        let capturedAt: String
        let error: ErrorInfo
        let timing: Timing
        let artifacts: Artifacts
        let warnings: [String]
    }

    typealias OCRRecognizer = (Data, CGSize?, Double?) throws -> OCRService.Result
    static var ocrRecognizerForTesting: OCRRecognizer?

    static func profile(action: DriverAction, errorPayload: ForyErrorPayload) -> Profile {
        guard collectsFailureEvidence(action: action), !errorPayload.fatal else { return .none }
        switch errorPayload.category {
        case IOSUseErrorCategory.lookup:
            return errorPayload.code == IOSUseErrorCode.elementAmbiguous ? .manifestOnly : .uiSnapshot
        case IOSUseErrorCategory.action, IOSUseErrorCategory.postcondition:
            return .uiSnapshot
        default:
            return .none
        }
    }

    static func append(
        to error: Error,
        action: DriverAction,
        session: LockedDriverClientSession,
        paths: IOSUsePaths
    ) -> String {
        guard let failure = failure(from: error) else { return String(describing: error) }
        let evidenceProfile = profile(action: action, errorPayload: failure.payload)
        guard evidenceProfile != .none else { return failure.renderedMessage }

        let collectionStarted = CFAbsoluteTimeGetCurrent()
        let capturedAt = Date()
        let directoryURL: URL
        do {
            let directoryName = try ArtifactPaths.safeArtifactName(
                "\(action.name)-failure-\(Int(capturedAt.timeIntervalSince1970 * 1000))",
                defaultName: "failure"
            )
            directoryURL = URL(fileURLWithPath: paths.artifacts, isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return failure.renderedMessage + "\nEvidence unavailable: \(error)"
        }

        var screenshotPath: String?
        var ocrPath: String?
        var domPath: String?
        var warnings: [String] = []
        var screenshotElapsedMs: Int?
        var screenshotOffsetMs: Int?
        var ocrElapsedMs: Int?
        var ocrOffsetMs: Int?
        var domElapsedMs: Int?
        var domOffsetMs: Int?

        if evidenceProfile == .uiSnapshot {
            let ocrGroup = DispatchGroup()
            let ocrLock = NSLock()
            var asynchronousOCRPath: String?
            var asynchronousOCRWarning: String?
            var asynchronousOCRElapsedMs: Int?
            var asynchronousOCROffsetMs: Int?

            do {
                let screenshotStarted = CFAbsoluteTimeGetCurrent()
                let capture = try session.run { client in
                    try ScreenshotCaptureCoordinator.capture(paths: paths) {
                        try client.screenshotCapture()
                    }
                }
                let imageURL = directoryURL.appendingPathComponent("screenshot.jpg")
                try capture.jpeg.write(to: imageURL, options: .atomic)
                screenshotPath = imageURL.path
                screenshotElapsedMs = elapsedMilliseconds(since: screenshotStarted)
                screenshotOffsetMs = elapsedMilliseconds(since: collectionStarted)
                if let warning = capture.warning {
                    warnings.append(warning)
                }

                let jpeg = capture.jpeg
                let logicalSize = capture.logicalSize.map { CGSize(width: $0.x, height: $0.y) }
                let scale = capture.scale
                ocrGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { ocrGroup.leave() }
                    let ocrStarted = CFAbsoluteTimeGetCurrent()
                    do {
                        let result = try recognizeOCR(data: jpeg, logicalSize: logicalSize, scale: scale)
                        let elapsed = elapsedMilliseconds(since: ocrStarted)
                        let writtenPath = try OCRService.writeSidecar(
                            result: result,
                            imagePath: imageURL.path,
                            elapsedMs: elapsed
                        )
                        ocrLock.lock()
                        asynchronousOCRPath = writtenPath
                        asynchronousOCRElapsedMs = elapsed
                        asynchronousOCROffsetMs = elapsedMilliseconds(since: collectionStarted)
                        ocrLock.unlock()
                    } catch {
                        ocrLock.lock()
                        asynchronousOCRWarning = "OCR unavailable: \(error)"
                        asynchronousOCRElapsedMs = elapsedMilliseconds(since: ocrStarted)
                        asynchronousOCROffsetMs = elapsedMilliseconds(since: collectionStarted)
                        ocrLock.unlock()
                    }
                }
            } catch {
                warnings.append("screenshot unavailable: \(error)")
            }

            do {
                let domStarted = CFAbsoluteTimeGetCurrent()
                let dom = try session.run { client in
                    try client.dom(raw: false, fresh: true, waitQuiescence: false)
                }
                domElapsedMs = elapsedMilliseconds(since: domStarted)
                let path = directoryURL.appendingPathComponent("dom.txt")
                try DriverOutput.formatDom(dom).write(to: path, atomically: true, encoding: .utf8)
                domPath = path.path
                domOffsetMs = elapsedMilliseconds(since: collectionStarted)
            } catch {
                warnings.append("DOM unavailable: \(error)")
            }

            ocrGroup.wait()
            ocrLock.lock()
            ocrPath = asynchronousOCRPath
            ocrElapsedMs = asynchronousOCRElapsedMs
            ocrOffsetMs = asynchronousOCROffsetMs
            let finalOCRWarning = asynchronousOCRWarning
            ocrLock.unlock()
            if let finalOCRWarning {
                warnings.append(finalOCRWarning)
            }
        }

        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let totalElapsedMs = elapsedMilliseconds(since: collectionStarted)
        let manifest = Manifest(
            schemaVersion: 2,
            command: action.name,
            profile: evidenceProfile.rawValue,
            capturedAt: ISO8601DateFormatter().string(from: capturedAt),
            error: errorInfo(from: failure),
            timing: Manifest.Timing(
                screenshotElapsedMs: screenshotElapsedMs,
                screenshotOffsetMs: screenshotOffsetMs,
                ocrElapsedMs: ocrElapsedMs,
                ocrOffsetMs: ocrOffsetMs,
                domElapsedMs: domElapsedMs,
                domOffsetMs: domOffsetMs,
                totalElapsedMs: totalElapsedMs
            ),
            artifacts: Manifest.Artifacts(
                screenshot: screenshotPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                ocr: ocrPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                dom: domPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ),
            warnings: warnings
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            return failure.renderedMessage + "\nEvidence manifest unavailable: \(error)"
        }

        var available: [String] = []
        if screenshotPath != nil { available.append("screenshot") }
        if ocrPath != nil { available.append("ocr") }
        if domPath != nil { available.append("dom") }
        let summary = available.isEmpty ? "" : " (\(available.joined(separator: ", ")))"
        return failure.renderedMessage + "\nEvidence: \(manifestURL.path)\(summary)"
    }

    private static func collectsFailureEvidence(action: DriverAction) -> Bool {
        switch action {
        case .tap, .longPress, .input, .swipe, .dismissAlert:
            return true
        case .dom, .screenshot, .waitFor, .activateApp, .terminateApp, .home:
            return false
        }
    }

    private static func failure(from error: Error) -> Failure? {
        if case DriverClientError.driverError(let message, let payload) = error {
            return Failure(
                message: message,
                renderedMessage: formatDriverError(message: message, payload: payload),
                payload: payload,
                mutationMayHaveApplied: mutationMayHaveApplied(errorPayload: payload)
            )
        }
        guard case DriverCommandExecutionError.postconditionFailed(let label, let underlying) = error,
              case DriverClientError.driverError(let message, let underlyingPayload) = underlying else {
            return nil
        }
        let postconditionMessage = "\(label) failed after mutation: \(message)"
        let payload = ForyErrorPayload(
            category: IOSUseErrorCategory.postcondition,
            code: IOSUseErrorCode.postconditionFailed,
            phase: IOSUseErrorPhase.postcondition,
            retryable: underlyingPayload.retryable,
            fatal: underlyingPayload.fatal,
            target: underlyingPayload.target,
            candidateCount: underlyingPayload.candidateCount,
            suggestions: underlyingPayload.suggestions,
            candidates: underlyingPayload.candidates
        )
        return Failure(
            message: postconditionMessage,
            renderedMessage: formatDriverError(message: postconditionMessage, payload: payload),
            payload: payload,
            mutationMayHaveApplied: true
        )
    }

    static func mutationMayHaveApplied(errorPayload: ForyErrorPayload) -> Bool {
        switch errorPayload.category {
        case IOSUseErrorCategory.action, IOSUseErrorCategory.postcondition:
            return true
        default:
            return false
        }
    }

    private static func errorInfo(from failure: Failure) -> Manifest.ErrorInfo {
        let target = failure.payload.target.map { target in
            Manifest.ErrorInfo.Target(
                label: target.label,
                point: target.point.map { [$0.x, $0.y] },
                traits: target.traits,
                cindex: target.cindex
            )
        }
        let candidates = failure.payload.candidates.map { candidate in
            let element = candidate.element
            return Manifest.ErrorInfo.Candidate(
                type: IOSUseElementTypes.displayName(rawType: element.elemType),
                label: element.label,
                value: element.value,
                traits: element.traits,
                frame: element.rect.map { [$0.x, $0.y, $0.w, $0.h] },
                ancestors: element.ancestors,
                rejectedBy: candidate.rejectedBy
            )
        }
        return Manifest.ErrorInfo(
            message: failure.message,
            category: failure.payload.category,
            code: failure.payload.code,
            phase: failure.payload.phase,
            retryable: failure.payload.retryable,
            fatal: failure.payload.fatal,
            mutationMayHaveApplied: failure.mutationMayHaveApplied,
            target: target,
            candidateCount: failure.payload.candidateCount,
            suggestions: failure.payload.suggestions,
            candidates: candidates
        )
    }

    private static func recognizeOCR(data: Data, logicalSize: CGSize?, scale: Double?) throws -> OCRService.Result {
        if let ocrRecognizerForTesting {
            return try ocrRecognizerForTesting(data, logicalSize, scale)
        }
        return try OCRService.recognize(data: data, logicalSize: logicalSize, scale: scale)
    }

    private static func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond)
    }
}
