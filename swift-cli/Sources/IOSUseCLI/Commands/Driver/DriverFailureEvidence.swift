import CoreGraphics
import Foundation
import IOSUseProtocol

enum DriverFailureEvidence {
    private struct Manifest: Codable {
        struct Artifacts: Codable {
            let screenshot: String?
            let ocr: String?
            let dom: String?
        }

        let schemaVersion: Int
        let command: String
        let error: String
        let capturedAt: String
        let screenshotCapturedAtMs: Int?
        let domCapturedAtMs: Int?
        let artifacts: Artifacts
        let warnings: [String]
    }

    static func shouldCapture(action: DriverAction) -> Bool {
        switch action {
        case .tap, .longPress, .input, .swipe, .dismissAlert, .home:
            return true
        case .dom, .screenshot, .waitFor, .activateApp, .terminateApp:
            return false
        }
    }

    static func append(
        to message: String,
        action: DriverAction,
        session: LockedDriverClientSession,
        paths: IOSUsePaths
    ) -> String {
        guard shouldCapture(action: action), shouldCapture(error: message) else { return message }

        var lines = [message, "", "Failure evidence (\(action.name)):"]
        let capturedAt = Date()
        let timestamp = String(Int(capturedAt.timeIntervalSince1970 * 1000))
        let directoryURL: URL
        do {
            let directoryName = try ArtifactPaths.safeArtifactName("\(action.name)-failure-\(timestamp)", defaultName: "failure")
            directoryURL = URL(fileURLWithPath: paths.artifacts, isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return lines.joined(separator: "\n") + "\nEvidence unavailable: \(error)"
        }

        var screenshotPath: String?
        var ocrPath: String?
        var domPath: String?
        var dom: ForyDomPayload?
        var errors: [String] = []
        let screenshotStarted = CFAbsoluteTimeGetCurrent()
        var screenshotCapturedAtMs: Int?
        var domCapturedAtMs: Int?

        do {
            try session.run { client in
                do {
                    let capture = try ScreenshotCaptureCoordinator.capture(paths: paths) {
                        try client.screenshotCapture()
                    }
                    let data = capture.jpeg
                    let pathURL = directoryURL.appendingPathComponent("screenshot.jpg")
                    try data.write(to: pathURL, options: .atomic)
                    screenshotPath = pathURL.path
                    screenshotCapturedAtMs = Int((CFAbsoluteTimeGetCurrent() - screenshotStarted) * 1000)
                    if let warning = capture.warning {
                        errors.append(warning)
                    }
                    do {
                        let ocrStarted = CFAbsoluteTimeGetCurrent()
                        let logicalSize = capture.logicalSize.map { CGSize(width: $0.x, height: $0.y) }
                        let ocr = try OCRService.recognize(data: data, logicalSize: logicalSize, scale: capture.scale)
                        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - ocrStarted) * 1000)
                        ocrPath = try OCRService.writeSidecar(result: ocr, imagePath: pathURL.path, elapsedMs: elapsedMs)
                    } catch {
                        errors.append("OCR unavailable: \(error)")
                    }
                } catch {
                    errors.append("screenshot unavailable: \(error)")
                }

                do {
                    let domStarted = CFAbsoluteTimeGetCurrent()
                    dom = try client.dom(raw: false, fresh: true, waitQuiescence: false)
                    domCapturedAtMs = Int((CFAbsoluteTimeGetCurrent() - domStarted) * 1000)
                } catch {
                    errors.append("DOM unavailable: \(error)")
                }
            }
        } catch {
            errors.append("driver evidence request failed: \(error)")
        }

        if let screenshotPath {
            lines.append("Screenshot: \(screenshotPath)")
        }
        if let ocrPath {
            lines.append("OCR sidecar: \(ocrPath)")
        }
        if let dom {
            let path = directoryURL.appendingPathComponent("dom.txt")
            do {
                try DriverOutput.formatDom(dom).write(to: path, atomically: true, encoding: .utf8)
                domPath = path.path
                lines.append("DOM file: \(path.path)")
            } catch {
                errors.append("DOM file unavailable: \(error)")
            }
            lines.append("DOM:")
            lines.append(DriverOutput.formatDom(dom).trimmingCharacters(in: .newlines))
        }
        lines.append(contentsOf: errors)

        let manifest = Manifest(
            schemaVersion: 1,
            command: action.name,
            error: message,
            capturedAt: ISO8601DateFormatter().string(from: capturedAt),
            screenshotCapturedAtMs: screenshotCapturedAtMs,
            domCapturedAtMs: domCapturedAtMs,
            artifacts: Manifest.Artifacts(screenshot: screenshotPath.map { URL(fileURLWithPath: $0).lastPathComponent }, ocr: ocrPath.map { URL(fileURLWithPath: $0).lastPathComponent }, dom: domPath.map { URL(fileURLWithPath: $0).lastPathComponent }),
            warnings: errors
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: directoryURL.appendingPathComponent("manifest.json"), options: .atomic)
            lines.append("Evidence manifest: \(directoryURL.appendingPathComponent("manifest.json").path)")
        } catch {
            lines.append("Evidence manifest unavailable: \(error)")
        }
        if screenshotPath == nil && dom == nil && errors.isEmpty {
            lines.append("unavailable")
        }
        return lines.joined(separator: "\n")
    }

    private static func shouldCapture(error message: String) -> Bool {
        // The driver wraps semantic command failures in driverError. Host-side
        // validation, missing locks, and transport failures should preserve their
        // original concise diagnostics instead of starting a second command.
        let lowercased = message.lowercased()
        if lowercased.contains("driver tcp") || lowercased.contains("socket ") || lowercased.contains("driver frame") {
            return false
        }
        if lowercased.contains("driver lock") || lowercased.contains("driver.lock") {
            return false
        }
        if message.hasPrefix("Invalid ") || message.contains("argument") || message.contains("option '") {
            return false
        }
        return true
    }
}
