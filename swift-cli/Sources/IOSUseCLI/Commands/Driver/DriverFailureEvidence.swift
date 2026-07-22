import CoreGraphics
import Foundation
import IOSUseProtocol

enum DriverFailureEvidence {
    struct CollectionResult {
        let renderedMessage: String
        let manifestPath: String?
    }

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

    private struct ScreenshotEvidence {
        var screenshotPath: String?
        var ocrPath: String?
        var screenshotElapsedMs: Int?
        var screenshotOffsetMs: Int?
        var ocrElapsedMs: Int?
        var ocrOffsetMs: Int?
        var warnings: [String] = []
    }

    private struct DOMEvidence {
        var path: String?
        var elapsedMs: Int?
        var offsetMs: Int?
        var warning: String?
    }

    typealias OCRRecognizer = (Data, CGSize?, Double?, OCRService.RecognitionLevel) throws -> OCRService.Result
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
        collect(to: error, action: action, session: session, paths: paths).renderedMessage
    }

    static func collect(
        to error: Error,
        action: DriverAction,
        session: LockedDriverClientSession,
        paths: IOSUsePaths
    ) -> CollectionResult {
        guard let failure = failure(from: error) else {
            return CollectionResult(renderedMessage: String(describing: error), manifestPath: nil)
        }
        let evidenceProfile = profile(action: action, errorPayload: failure.payload)
        guard evidenceProfile != .none else {
            return CollectionResult(renderedMessage: failure.renderedMessage, manifestPath: nil)
        }

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
            return CollectionResult(
                renderedMessage: failure.renderedMessage + "\nEvidence unavailable: \(error)",
                manifestPath: nil
            )
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
            let group = DispatchGroup()
            let resultLock = NSLock()
            let domSession = LockedDriverClientSession(paths: paths)
            var screenshotEvidence = ScreenshotEvidence()
            var domEvidence = DOMEvidence()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = collectScreenshotEvidence(
                    session: session,
                    paths: paths,
                    directoryURL: directoryURL,
                    collectionStarted: collectionStarted
                )
                resultLock.lock()
                screenshotEvidence = result
                resultLock.unlock()
                group.leave()
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = collectDOMEvidence(
                    session: domSession,
                    directoryURL: directoryURL,
                    collectionStarted: collectionStarted
                )
                resultLock.lock()
                domEvidence = result
                resultLock.unlock()
                group.leave()
            }

            group.wait()
            domSession.close()

            screenshotPath = screenshotEvidence.screenshotPath
            ocrPath = screenshotEvidence.ocrPath
            screenshotElapsedMs = screenshotEvidence.screenshotElapsedMs
            screenshotOffsetMs = screenshotEvidence.screenshotOffsetMs
            ocrElapsedMs = screenshotEvidence.ocrElapsedMs
            ocrOffsetMs = screenshotEvidence.ocrOffsetMs
            warnings.append(contentsOf: screenshotEvidence.warnings)

            domPath = domEvidence.path
            domElapsedMs = domEvidence.elapsedMs
            domOffsetMs = domEvidence.offsetMs
            if let warning = domEvidence.warning {
                warnings.append(warning)
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
            return CollectionResult(
                renderedMessage: failure.renderedMessage + "\nEvidence manifest unavailable: \(error)",
                manifestPath: nil
            )
        }

        var available: [String] = []
        if screenshotPath != nil { available.append("screenshot") }
        if ocrPath != nil { available.append("ocr") }
        if domPath != nil { available.append("dom") }
        let summary = available.isEmpty ? "" : " (\(available.joined(separator: ", ")))"
        return CollectionResult(
            renderedMessage: failure.renderedMessage + "\nEvidence: \(manifestURL.path)\(summary)",
            manifestPath: manifestURL.path
        )
    }

    private static func collectsFailureEvidence(action: DriverAction) -> Bool {
        switch action {
        case .tap, .longPress, .input, .swipe, .dismissAlert:
            return true
        case .dom, .inspect, .screenshot, .waitFor, .activateApp, .terminateApp, .home:
            return false
        }
    }

    private static func collectScreenshotEvidence(
        session: LockedDriverClientSession,
        paths: IOSUsePaths,
        directoryURL: URL,
        collectionStarted: CFAbsoluteTime
    ) -> ScreenshotEvidence {
        var evidence = ScreenshotEvidence()
        do {
            let screenshotStarted = CFAbsoluteTimeGetCurrent()
            let capture = try session.run { client in
                try ScreenshotCaptureCoordinator.capture(paths: paths) {
                    try client.screenshotCapture()
                }
            }
            let imageURL = directoryURL.appendingPathComponent("screenshot.jpg")
            try capture.jpeg.write(to: imageURL, options: .atomic)
            evidence.screenshotPath = imageURL.path
            evidence.screenshotElapsedMs = elapsedMilliseconds(since: screenshotStarted)
            evidence.screenshotOffsetMs = elapsedMilliseconds(since: collectionStarted)
            if let warning = capture.warning {
                evidence.warnings.append(warning)
            }

            let ocrStarted = CFAbsoluteTimeGetCurrent()
            do {
                let logicalSize = capture.logicalSize.map { CGSize(width: $0.x, height: $0.y) }
                let result = try recognizeOCR(
                    data: capture.jpeg,
                    logicalSize: logicalSize,
                    scale: capture.scale,
                    recognitionLevel: .fast
                )
                let elapsed = elapsedMilliseconds(since: ocrStarted)
                evidence.ocrPath = try OCRService.writeSidecar(
                    result: result,
                    imagePath: imageURL.path,
                    elapsedMs: elapsed
                )
                evidence.ocrElapsedMs = elapsed
                evidence.ocrOffsetMs = elapsedMilliseconds(since: collectionStarted)
            } catch {
                evidence.ocrElapsedMs = elapsedMilliseconds(since: ocrStarted)
                evidence.ocrOffsetMs = elapsedMilliseconds(since: collectionStarted)
                evidence.warnings.append("OCR unavailable: \(error)")
            }
        } catch {
            evidence.warnings.append("screenshot unavailable: \(error)")
        }
        return evidence
    }

    private static func collectDOMEvidence(
        session: LockedDriverClientSession,
        directoryURL: URL,
        collectionStarted: CFAbsoluteTime
    ) -> DOMEvidence {
        do {
            let domStarted = CFAbsoluteTimeGetCurrent()
            let dom = try session.run { client in
                try client.dom(raw: false, fresh: true, waitQuiescence: false)
            }
            let elapsed = elapsedMilliseconds(since: domStarted)
            let path = directoryURL.appendingPathComponent("dom.txt")
            try DriverOutput.formatDom(dom).write(to: path, atomically: true, encoding: .utf8)
            return DOMEvidence(
                path: path.path,
                elapsedMs: elapsed,
                offsetMs: elapsedMilliseconds(since: collectionStarted),
                warning: nil
            )
        } catch {
            return DOMEvidence(warning: "DOM unavailable: \(error)")
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

    private static func recognizeOCR(
        data: Data,
        logicalSize: CGSize?,
        scale: Double?,
        recognitionLevel: OCRService.RecognitionLevel
    ) throws -> OCRService.Result {
        if let ocrRecognizerForTesting {
            return try ocrRecognizerForTesting(data, logicalSize, scale, recognitionLevel)
        }
        return try OCRService.recognize(
            data: data,
            logicalSize: logicalSize,
            scale: scale,
            recognitionLevel: recognitionLevel
        )
    }

    private static func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond)
    }
}
