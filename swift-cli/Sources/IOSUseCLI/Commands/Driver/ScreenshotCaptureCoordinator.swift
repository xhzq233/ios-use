import Foundation
import ImageIO
import IOSUseProtocol

enum ScreenshotCaptureCoordinator {
    struct DisplayInfoMeasurement {
        let info: CoreDeviceDisplayInfo
        let roundTripElapsedMs: Int
        let serviceElapsedMs: Int?
    }

    enum DisplayInfoError: Error, CustomStringConvertible {
        case missingControlSocket
        case unavailable(String)
        case missingPayload

        var description: String {
            switch self {
            case .missingControlSocket:
                return "the active real-device session has no holder control socket"
            case .unavailable(let detail):
                return detail
            case .missingPayload:
                return "the XCTest holder returned no Display Info payload"
            }
        }
    }

    static var displayInfoRequesterForTesting: ((IOSUsePaths) throws -> DisplayInfoMeasurement)?

    private final class Results {
        let lock = NSLock()
        var displayInfo: DisplayInfoMeasurement?
        var displayInfoError: Error?
        var displayInfoElapsedMs: Int?
    }

    static func capture(
        paths: IOSUsePaths,
        screenshot: () throws -> ScreenshotCapture
    ) throws -> ScreenshotCapture {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let sessionInfo = try? DriverSessionStore.readInfo(paths: paths)
        let shouldRequestDisplayInfo = sessionInfo?.deviceType == "real"
        let results = Results()
        let work = DispatchGroup()

        if shouldRequestDisplayInfo {
            work.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { work.leave() }
                let branchStartedAt = CFAbsoluteTimeGetCurrent()
                do {
                    let value = try (displayInfoRequesterForTesting ?? requestDisplayInfo)(paths)
                    results.lock.lock()
                    results.displayInfo = value
                    results.displayInfoElapsedMs = value.roundTripElapsedMs
                    results.lock.unlock()
                } catch {
                    results.lock.lock()
                    results.displayInfoError = error
                    results.displayInfoElapsedMs = elapsedMilliseconds(since: branchStartedAt)
                    results.lock.unlock()
                }
            }
        }

        // Keep the driver client on its caller thread. Display Info was already
        // scheduled above, so the two device requests still overlap without
        // sending the driver session across a DispatchQueue boundary.
        let screenshotStartedAt = CFAbsoluteTimeGetCurrent()
        let rawScreenshot: ScreenshotCapture
        do {
            rawScreenshot = try screenshot()
        } catch {
            work.wait()
            throw error
        }
        let screenshotElapsedMs = elapsedMilliseconds(since: screenshotStartedAt)
        work.wait()
        results.lock.lock()
        let displayMeasurement = results.displayInfo
        let displayInfoError = results.displayInfoError
        let displayInfoElapsedMs = results.displayInfoElapsedMs
        results.lock.unlock()

        let pixelSize = imagePixelSize(rawScreenshot.jpeg) ?? rawScreenshot.pixelSize
        let geometry = resolveGeometry(
            pixelSize: pixelSize,
            driverLogicalSize: rawScreenshot.logicalSize,
            driverScale: rawScreenshot.scale,
            displayInfo: displayMeasurement?.info,
            displayInfoError: shouldRequestDisplayInfo ? displayInfoError : nil
        )
        let totalElapsedMs = elapsedMilliseconds(since: startedAt)
        let performance = ScreenshotCapturePerformance(
            screenshotElapsedMs: screenshotElapsedMs,
            displayInfoElapsedMs: displayInfoElapsedMs,
            displayInfoServiceElapsedMs: displayMeasurement?.serviceElapsedMs,
            totalElapsedMs: totalElapsedMs
        )
        log(
            paths: paths,
            performance: performance,
            geometrySource: geometry.source,
            warning: geometry.warning
        )
        return ScreenshotCapture(
            jpeg: rawScreenshot.jpeg,
            pixelSize: pixelSize,
            logicalSize: geometry.logicalSize,
            scale: geometry.scale,
            geometrySource: geometry.source,
            warning: geometry.warning,
            performance: performance
        )
    }

    static func requestDisplayInfo(paths: IOSUsePaths) throws -> DisplayInfoMeasurement {
        let session = try DriverSessionStore.requireInfo(paths: paths)
        guard let controlSocketPath = session.controlSocketPath, !controlSocketPath.isEmpty else {
            throw DisplayInfoError.missingControlSocket
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let response = try XCTestSessionHolderControlClient.request(
            socketPath: controlSocketPath,
            command: "displayInfo",
            timeoutSeconds: IOSUseProtocol.XCConstants.coreDeviceDisplayInfoControlTimeoutSeconds
        )
        let elapsedMs = elapsedMilliseconds(since: startedAt)
        guard response.status == "ok" else {
            throw DisplayInfoError.unavailable(response.error ?? "CoreDevice Display Info request failed")
        }
        guard let info = response.displayInfo else {
            throw DisplayInfoError.missingPayload
        }
        return DisplayInfoMeasurement(
            info: info,
            roundTripElapsedMs: elapsedMs,
            serviceElapsedMs: response.displayInfoElapsedMs
        )
    }

    private static func resolveGeometry(
        pixelSize: ForyPoint?,
        driverLogicalSize: ForyPoint?,
        driverScale: Double?,
        displayInfo: CoreDeviceDisplayInfo?,
        displayInfoError: Error?
    ) -> (logicalSize: ForyPoint?, scale: Double?, source: String, warning: String?) {
        let displayScale = displayInfo?.primaryDisplay?.pointScale.flatMap { $0 > 0 ? $0 : nil }
        let scale = displayScale ?? driverScale.flatMap { $0 > 0 ? $0 : nil }
        let logicalSize: ForyPoint?
        let source: String

        if let pixelSize, let scale {
            logicalSize = ForyPoint(x: pixelSize.x / scale, y: pixelSize.y / scale)
            source = displayScale != nil
                ? "coredevice-display-info+screenshot-rect"
                : "screenshot-rect+driver-scale"
        } else if let driverLogicalSize,
                  driverLogicalSize.x > 0, driverLogicalSize.y > 0 {
            logicalSize = driverLogicalSize
            source = "driver-logical-size"
        } else if pixelSize != nil {
            // Keep logicalSize nil when no trustworthy scale exists. OCR will
            // still use the screenshot rect, but correctly label it as pixels
            // instead of presenting pixel coordinates as logical points.
            logicalSize = nil
            source = "screenshot-rect-pixels"
        } else {
            logicalSize = nil
            source = "unavailable"
        }

        let warning: String?
        if let displayInfoError {
            warning = "CoreDevice Display Info unavailable (\(displayInfoError)); using \(source)"
        } else if displayInfo != nil && displayScale == nil {
            warning = "CoreDevice Display Info has no positive pointScale; using \(source)"
        } else {
            warning = nil
        }
        return (logicalSize, scale, source, warning)
    }

    private static func imagePixelSize(_ data: Data) -> ForyPoint? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        return ForyPoint(x: width, y: height)
    }

    private static func log(
        paths: IOSUsePaths,
        performance: ScreenshotCapturePerformance,
        geometrySource: String,
        warning: String?
    ) {
        let displayInfo = performance.displayInfoElapsedMs.map { "\($0)ms" } ?? "n/a"
        let service = performance.displayInfoServiceElapsedMs.map { "\($0)ms" } ?? "n/a"
        CLILogService.append(paths: paths, [
            "[screenshot-perf] screenshot=\(performance.screenshotElapsedMs)ms displayInfo=\(displayInfo) displayInfoService=\(service) total=\(performance.totalElapsedMs)ms geometry=\(geometrySource) warning=\(warning != nil)"
        ])
    }

    private static func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond)
    }
}
