import CryptoKit
import CoreGraphics
import Foundation

enum CaptureService {
    private static let maxFPS = 10.0

    private struct Manifest: Codable {
        struct Frame: Codable {
            let index: Int
            let capturedAt: String
            let sha256: String
            let changed: Bool
            let diffScore: Double?
            let changedPixelRatio: Double?
            let changedTileRatio: Double?
            let compareSize: [Int]?
            let diffError: String?
            let pixelSize: [Double]?
            let logicalSize: [Double]?
            let scale: Double?
            let geometrySource: String?
            let displayInfoWarning: String?
            let screenshotElapsedMs: Int?
            let displayInfoElapsedMs: Int?
            let displayInfoServiceElapsedMs: Int?
            let captureElapsedMs: Int?
            let path: String?

            func applying(diff: ImageDiffService.Result, diffError: String?, path: String?) -> Frame {
                Frame(
                    index: index,
                    capturedAt: capturedAt,
                    sha256: sha256,
                    changed: diff.changed,
                    diffScore: diff.score,
                    changedPixelRatio: diff.changedPixelRatio,
                    changedTileRatio: diff.changedTileRatio,
                    compareSize: diff.compareWidth > 0 && diff.compareHeight > 0
                        ? [diff.compareWidth, diff.compareHeight]
                        : nil,
                    diffError: diffError,
                    pixelSize: pixelSize,
                    logicalSize: logicalSize,
                    scale: scale,
                    geometrySource: geometrySource,
                    displayInfoWarning: displayInfoWarning,
                    screenshotElapsedMs: screenshotElapsedMs,
                    displayInfoElapsedMs: displayInfoElapsedMs,
                    displayInfoServiceElapsedMs: displayInfoServiceElapsedMs,
                    captureElapsedMs: captureElapsedMs,
                    path: path
                )
            }
        }

        let schemaVersion: Int
        let status: String
        let error: String?
        let name: String
        let duration: Double
        let requestedFPS: Double
        let startedAt: String
        let endedAt: String
        let requestedDurationMs: Int
        let actualDurationMs: Int
        let actualFPS: Double
        let missedSlots: Int
        let sampledFrames: Int
        let keptFrames: Int
        let keepChangedFrames: Bool
        let diffMethod: String
        let frames: [Frame]
    }

    static func run(options: CaptureOptions, paths: IOSUsePaths) throws -> String {
        guard options.duration > 0, options.duration.isFinite else {
            throw CLIParseError.invalidValue("--duration must be greater than 0")
        }
        guard options.fps > 0, options.fps.isFinite, options.fps <= maxFPS else {
            throw CLIParseError.invalidValue("--fps must be greater than 0 and at most \(Int(maxFPS))")
        }

        let safeName = try ArtifactPaths.safeArtifactName(options.name, defaultName: "capture")
        let started = Date()
        let timestamp = captureTimestamp(started)
        let directory = URL(fileURLWithPath: paths.artifacts, isDirectory: true)
            .appendingPathComponent("capture-\(safeName)-\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        var frames: [Manifest.Frame] = []
        let interval = 1.0 / options.fps
        let monotonicStartedAt = monotonicSeconds()
        let deadline = monotonicStartedAt + options.duration
        var nextSample = monotonicStartedAt
        let diffMethod = "logical-tile-mae-v1"

        var captureError: Error?
        var interruption: CLIExitSignal?
        let interruptMonitor = InterruptMonitor()
        interruptMonitor.start()
        defer { interruptMonitor.stop() }
        do {
            try DriverCommandExecution.withLockedClient(paths: paths) { client in
                while true {
                    try interruptMonitor.throwIfInterrupted()
                    let now = monotonicSeconds()
                    if !frames.isEmpty && now >= deadline {
                        break
                    }

                    if now < nextSample {
                        Thread.sleep(forTimeInterval: nextSample - now)
                    }

                    // Sleeping can land exactly on (or just after) the deadline.
                    // Do not take an extra sample outside the requested window;
                    // still allow the first frame for very short captures.
                    if !frames.isEmpty && monotonicSeconds() >= deadline {
                        break
                    }

                    let capture = try ScreenshotCaptureCoordinator.capture(paths: paths) {
                        try client.screenshotCapture()
                    }
                    let image = capture.jpeg
                    try interruptMonitor.throwIfInterrupted()
                    let index = frames.count + 1
                    let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
                    let path = directory.appendingPathComponent(String(format: "frame-%06d.jpg", index))
                    // Always persist on the sampling path. Visual filtering runs
                    // after the fixed window so JPEG decode latency cannot cause
                    // missed samples or catch-up bursts.
                    try image.write(to: path, options: .atomic)
                    frames.append(Manifest.Frame(
                        index: index,
                        capturedAt: ISO8601DateFormatter().string(from: Date()),
                        sha256: hash,
                        changed: true,
                        diffScore: nil,
                        changedPixelRatio: nil,
                        changedTileRatio: nil,
                        compareSize: nil,
                        diffError: nil,
                        pixelSize: capture.pixelSize.map { [$0.x, $0.y] },
                        logicalSize: capture.logicalSize.map { [$0.x, $0.y] },
                        scale: capture.scale,
                        geometrySource: capture.geometrySource,
                        displayInfoWarning: capture.warning,
                        screenshotElapsedMs: capture.performance?.screenshotElapsedMs,
                        displayInfoElapsedMs: capture.performance?.displayInfoElapsedMs,
                        displayInfoServiceElapsedMs: capture.performance?.displayInfoServiceElapsedMs,
                        captureElapsedMs: capture.performance?.totalElapsedMs,
                        path: path.path
                    ))
                    nextSample = nextScheduledSample(
                        current: nextSample,
                        completedAt: monotonicSeconds(),
                        interval: interval
                    )
                }
            }
        } catch let signal as CLIExitSignal {
            interruption = signal
            captureError = signal
        } catch {
            captureError = error
        }

        let ended = Date()
        let actualDuration = max(0, monotonicSeconds() - monotonicStartedAt)
        frames = applyVisualDiff(
            frames: frames,
            keepChangedFrames: options.keepChangedFrames
        )
        let requestedSlots = max(1, Int(ceil(options.duration * options.fps)))
        let manifest = Manifest(
            schemaVersion: 2,
            status: interruption != nil ? "interrupted" : (captureError == nil ? "complete" : "partial"),
            error: captureError.map { String(describing: $0) },
            name: safeName,
            duration: options.duration,
            requestedFPS: options.fps,
            startedAt: ISO8601DateFormatter().string(from: started),
            endedAt: ISO8601DateFormatter().string(from: ended),
            requestedDurationMs: Int((options.duration * 1000).rounded()),
            actualDurationMs: Int((actualDuration * 1000).rounded()),
            actualFPS: actualDuration > 0 ? Double(frames.count) / actualDuration : 0,
            missedSlots: max(0, requestedSlots - frames.count),
            sampledFrames: frames.count,
            keptFrames: frames.filter { $0.path != nil }.count,
            keepChangedFrames: options.keepChangedFrames,
            diffMethod: diffMethod,
            frames: frames
        )
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        if let interruption {
            throw CLIExitSignal(
                exitCode: interruption.exitCode,
                message: "capture interrupted after \(frames.count) frame(s). Manifest: \(manifestURL.path)"
            )
        }
        if let captureError {
            throw CLIParseError.invalidValue("capture failed after \(frames.count) frame(s): \(captureError). Manifest: \(manifestURL.path)")
        }
        let displayInfoWarnings = Array(Set(frames.compactMap(\.displayInfoWarning))).sorted()
        let warnings = displayInfoWarnings
            .map { "Warning: \($0)\n" }
            .joined()
        return "Capture complete: sampled \(frames.count) frame(s), kept \(manifest.keptFrames) image(s)\nDirectory: \(directory.path)\nManifest: \(manifestURL.path)\n\(warnings)"
    }

    private static func captureTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static func applyVisualDiff(
        frames: [Manifest.Frame],
        keepChangedFrames: Bool
    ) -> [Manifest.Frame] {
        var detector = ImageDiffService.Detector()
        var previousHash: String?

        return frames.map { frame in
            guard let path = frame.path else { return frame }
            let logicalSize = frame.logicalSize.flatMap { values -> CGSize? in
                guard values.count == 2, values[0] > 0, values[1] > 0 else { return nil }
                return CGSize(width: values[0], height: values[1])
            }
            let diff: ImageDiffService.Result
            var diffError: String?

            if previousHash == frame.sha256 {
                diff = ImageDiffService.Result(
                    changed: false,
                    score: 0,
                    changedPixelRatio: 0,
                    changedTileRatio: 0,
                    compareWidth: logicalSize.map { max(1, Int($0.width.rounded())) } ?? 0,
                    compareHeight: logicalSize.map { max(1, Int($0.height.rounded())) } ?? 0
                )
            } else {
                do {
                    let image = try Data(contentsOf: URL(fileURLWithPath: path))
                    diff = try detector.compare(current: image, logicalSize: logicalSize)
                } catch {
                    diffError = String(describing: error)
                    diff = ImageDiffService.Result(
                        changed: true,
                        score: 1,
                        changedPixelRatio: 1,
                        changedTileRatio: 1,
                        compareWidth: 0,
                        compareHeight: 0
                    )
                }
            }

            previousHash = diffError == nil ? frame.sha256 : nil
            var retainedPath: String? = path
            if keepChangedFrames && !diff.changed {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    retainedPath = nil
                } catch {
                    diffError = [diffError, "unable to remove unchanged frame: \(error)"]
                        .compactMap { $0 }
                        .joined(separator: "; ")
                }
            }
            return frame.applying(diff: diff, diffError: diffError, path: retainedPath)
        }
    }

    /// Advance to the first sampling slot strictly after a completed frame.
    /// This skips deadlines missed by an overrun instead of issuing a burst of
    /// back-to-back catch-up screenshots.
    static func nextScheduledSample(current: Double, completedAt: Double, interval: Double) -> Double {
        var next = current + interval
        if next <= completedAt {
            let missed = floor((completedAt - next) / interval) + 1
            next += missed * interval
        }
        return next
    }

    private static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
