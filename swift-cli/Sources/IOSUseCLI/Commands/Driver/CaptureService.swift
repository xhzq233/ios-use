import CryptoKit
import Foundation

enum CaptureService {
    private static let maxFPS = 10.0

    private struct Manifest: Codable {
        struct Frame: Codable {
            let index: Int
            let capturedAt: String
            let sha256: String
            let changed: Bool
            let path: String?
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
        let deadline = started.addingTimeInterval(options.duration)
        var nextSample = started
        var previousHash: String?

        var captureError: Error?
        var interruption: CLIExitSignal?
        let interruptMonitor = InterruptMonitor()
        interruptMonitor.start()
        defer { interruptMonitor.stop() }
        do {
            try DriverCommandExecution.withLockedClient(paths: paths) { client in
                while true {
                    try interruptMonitor.throwIfInterrupted()
                    let now = Date()
                    if !frames.isEmpty && now >= deadline {
                        break
                    }

                    if now < nextSample {
                        Thread.sleep(forTimeInterval: nextSample.timeIntervalSince(now))
                    }

                    // Sleeping can land exactly on (or just after) the deadline.
                    // Do not take an extra sample outside the requested window;
                    // still allow the first frame for very short captures.
                    if !frames.isEmpty && Date() >= deadline {
                        break
                    }

                    let image = try client.screenshot()
                    try interruptMonitor.throwIfInterrupted()
                    let index = frames.count + 1
                    let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
                    let changed = previousHash == nil || previousHash != hash
                    let shouldKeep = !options.keepChangedFrames || changed
                    var imagePath: String?
                    if shouldKeep {
                        let path = directory.appendingPathComponent(String(format: "frame-%06d.jpg", index))
                        try image.write(to: path, options: .atomic)
                        imagePath = path.path
                    }
                    frames.append(Manifest.Frame(
                        index: index,
                        capturedAt: ISO8601DateFormatter().string(from: Date()),
                        sha256: hash,
                        changed: changed,
                        path: imagePath
                    ))
                    previousHash = hash
                    nextSample = nextSample.addingTimeInterval(interval)
                }
            }
        } catch let signal as CLIExitSignal {
            interruption = signal
            captureError = signal
        } catch {
            captureError = error
        }

        let ended = Date()
        let actualDuration = max(0, ended.timeIntervalSince(started))
        let requestedSlots = max(1, Int(ceil(options.duration * options.fps)))
        let manifest = Manifest(
            schemaVersion: 1,
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
        return "Capture complete: sampled \(frames.count) frame(s), kept \(manifest.keptFrames) image(s)\nDirectory: \(directory.path)\nManifest: \(manifestURL.path)\n"
    }

    private static func captureTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }
}
