import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit

struct PlayCoverWindowCaptureRequest: Equatable, Sendable {
    let pid: Int32
    let windowNumber: Int
    let windowFrame: CGRect
    let contentLayoutRect: CGRect
    let targetPixelSize: CGSize
}

protocol PlayCoverWindowScreenshotProviding: AnyObject {
    func captureWindow(_ request: PlayCoverWindowCaptureRequest) throws -> CGImage
}

enum PlayCoverScreenCaptureError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedOS
    case screenRecordingPermissionDenied
    case shareableContentFailed(String)
    case windowNotShareable(pid: Int32, windowNumber: Int)
    case windowIdentityMismatch
    case windowGeometryMismatch
    case captureTimedOut
    case captureFailed(String)
    case invalidGeometry(String)
    case cropFailed
    case imageCreationFailed
    case jpegEncodingFailed

    var description: String {
        switch self {
        case .unsupportedOS:
            return "PlayCover screenshot requires macOS 14 or later; macOS 15 uses SCScreenshotManager"
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required for PlayCover screenshots. Grant ios-use access in System Settings > Privacy & Security > Screen & System Audio Recording, then restart the command"
        case .shareableContentFailed(let detail):
            return "ScreenCaptureKit could not enumerate shareable windows: \(detail)"
        case .windowNotShareable(let pid, let windowNumber):
            return "PlayCover window \(windowNumber) for pid \(pid) is not currently shareable through ScreenCaptureKit"
        case .windowIdentityMismatch:
            return "the ScreenCaptureKit window does not match the Runtime PID/window identity"
        case .windowGeometryMismatch:
            return "the ScreenCaptureKit window frame does not match Runtime AppKit diagnostics"
        case .captureTimedOut:
            return "ScreenCaptureKit timed out while capturing the PlayCover window"
        case .captureFailed(let detail):
            return "ScreenCaptureKit failed to capture the PlayCover window: \(detail)"
        case .invalidGeometry(let detail):
            return "invalid PlayCover screenshot geometry: \(detail)"
        case .cropFailed:
            return "failed to crop the PlayCover AppKit content rectangle"
        case .imageCreationFailed:
            return "failed to normalize the PlayCover screenshot image"
        case .jpegEncodingFailed:
            return "failed to encode the normalized PlayCover screenshot as JPEG"
        }
    }
}

final class PlayCoverScreenCaptureKitProvider: PlayCoverWindowScreenshotProviding {
    private let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 10) {
        self.timeoutSeconds = timeoutSeconds
    }

    func captureWindow(_ request: PlayCoverWindowCaptureRequest) throws -> CGImage {
        guard #available(macOS 14.0, *) else {
            throw PlayCoverScreenCaptureError.unsupportedOS
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw PlayCoverScreenCaptureError.captureTimedOut
        }
        return try captureWindowAvailable(request)
    }

    @available(macOS 14.0, *)
    private func captureWindowAvailable(
        _ request: PlayCoverWindowCaptureRequest
    ) throws -> CGImage {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let content = try shareableContent(deadline: deadline)
        let sameWindowNumber = content.windows.filter {
            Int($0.windowID) == request.windowNumber
        }
        guard let window = sameWindowNumber.first(where: {
            $0.owningApplication?.processID == request.pid
        }) else {
            if sameWindowNumber.isEmpty {
                if !CGPreflightScreenCaptureAccess() {
                    throw PlayCoverScreenCaptureError.screenRecordingPermissionDenied
                }
                throw PlayCoverScreenCaptureError.windowNotShareable(
                    pid: request.pid,
                    windowNumber: request.windowNumber
                )
            }
            throw PlayCoverScreenCaptureError.windowIdentityMismatch
        }
        guard approximatelyEqual(
                  window.frame.width,
                  request.windowFrame.width
              ),
              approximatelyEqual(
                  window.frame.height,
                  request.windowFrame.height
              ) else {
            throw PlayCoverScreenCaptureError.windowGeometryMismatch
        }

        let configuration = try makeConfiguration(for: request)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let result = PlayCoverAsyncResultBox<CGImage>()
        let completion = DispatchSemaphore(value: 0)
        SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) { image, error in
            if let image {
                result.set(.success(image))
            } else if let error {
                result.set(
                    .failure(
                        Self.mapScreenCaptureKitError(
                            error,
                            hasScreenCaptureAccess: CGPreflightScreenCaptureAccess()
                        )
                    )
                )
            } else {
                result.set(
                    .failure(
                        PlayCoverScreenCaptureError.captureFailed(
                            "the capture returned neither an image nor an error"
                        )
                    )
                )
            }
            completion.signal()
        }
        let captureWait = try remainingTime(until: deadline)
        guard completion.wait(
            timeout: .now() + captureWait
        ) == .success else {
            throw PlayCoverScreenCaptureError.captureTimedOut
        }
        guard let captureResult = result.get() else {
            throw PlayCoverScreenCaptureError.captureFailed(
                "the capture completion did not publish a result"
            )
        }
        return try captureResult.get()
    }

    @available(macOS 14.0, *)
    private func shareableContent(
        deadline: TimeInterval
    ) throws -> SCShareableContent {
        let result = PlayCoverAsyncResultBox<SCShareableContent>()
        let completion = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        ) { content, error in
            if let content {
                result.set(.success(content))
            } else if let error {
                result.set(
                    .failure(
                        Self.mapShareableContentError(
                            error,
                            hasScreenCaptureAccess: CGPreflightScreenCaptureAccess()
                        )
                    )
                )
            } else {
                result.set(
                    .failure(
                        PlayCoverScreenCaptureError.shareableContentFailed(
                            "the query returned neither content nor an error"
                        )
                    )
                )
            }
            completion.signal()
        }
        let contentWait = try remainingTime(until: deadline)
        guard completion.wait(
            timeout: .now() + contentWait
        ) == .success else {
            throw PlayCoverScreenCaptureError.captureTimedOut
        }
        guard let contentResult = result.get() else {
            throw PlayCoverScreenCaptureError.shareableContentFailed(
                "the query completion did not publish a result"
            )
        }
        return try contentResult.get()
    }

    private func remainingTime(
        until deadline: TimeInterval
    ) throws -> TimeInterval {
        let remaining =
            deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            throw PlayCoverScreenCaptureError.captureTimedOut
        }
        return remaining
    }

    @available(macOS 14.0, *)
    private func makeConfiguration(
        for request: PlayCoverWindowCaptureRequest
    ) throws -> SCStreamConfiguration {
        let contentWidth = request.contentLayoutRect.width
        let contentHeight = request.contentLayoutRect.height
        guard contentWidth > 0, contentHeight > 0,
              request.windowFrame.width > 0,
              request.windowFrame.height > 0,
              request.targetPixelSize.width > 0,
              request.targetPixelSize.height > 0 else {
            throw PlayCoverScreenCaptureError.invalidGeometry(
                "window, content, and target sizes must be positive"
            )
        }
        let captureScale = try PlayCoverScreenshotNormalizer
            .uniformCaptureScale(
                targetPixelSize: request.targetPixelSize,
                contentSize: request.contentLayoutRect.size
            )

        let configuration = SCStreamConfiguration()
        configuration.width = max(
            1,
            Int((request.windowFrame.width * captureScale).rounded())
        )
        configuration.height = max(
            1,
            Int((request.windowFrame.height * captureScale).rounded())
        )
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = false
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 1
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = true
        return configuration
    }

    static func mapScreenCaptureKitError(
        _ error: Error,
        hasScreenCaptureAccess: Bool
    ) -> PlayCoverScreenCaptureError {
        if let error = error as? PlayCoverScreenCaptureError {
            return error
        }
        let cocoaError = error as NSError
        if !hasScreenCaptureAccess ||
            (cocoaError.domain == SCStreamErrorDomain && cocoaError.code == -3_801) {
            return .screenRecordingPermissionDenied
        }
        return .captureFailed(
            "\(cocoaError.domain) \(cocoaError.code): \(cocoaError.localizedDescription)"
        )
    }

    static func mapShareableContentError(
        _ error: Error,
        hasScreenCaptureAccess: Bool
    ) -> PlayCoverScreenCaptureError {
        let mapped = mapScreenCaptureKitError(
            error,
            hasScreenCaptureAccess: hasScreenCaptureAccess
        )
        if case .screenRecordingPermissionDenied = mapped {
            return mapped
        }
        let cocoaError = error as NSError
        return .shareableContentFailed(
            "\(cocoaError.domain) \(cocoaError.code): \(cocoaError.localizedDescription)"
        )
    }

    private func approximatelyEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat
    ) -> Bool {
        abs(lhs - rhs) < 0.5
    }

}

enum PlayCoverScreenshotNormalizer {
    static let jpegQuality = 0.9
    static let uniformScaleTolerance = 0.01

    static func uniformCaptureScale(
        targetPixelSize: CGSize,
        contentSize: CGSize
    ) throws -> CGFloat {
        guard targetPixelSize.width > 0, targetPixelSize.height > 0,
              contentSize.width > 0, contentSize.height > 0 else {
            throw PlayCoverScreenCaptureError.invalidGeometry(
                "capture target and content sizes must be positive"
            )
        }
        let horizontal = targetPixelSize.width / contentSize.width
        let vertical = targetPixelSize.height / contentSize.height
        let largest = max(horizontal, vertical)
        guard largest > 0,
              abs(horizontal - vertical) / largest
                <= uniformScaleTolerance else {
            throw PlayCoverScreenCaptureError.invalidGeometry(
                "content-to-target capture scale is not approximately uniform"
            )
        }
        return (horizontal + vertical) / 2
    }

    static func normalizeJPEG(
        image: CGImage,
        windowFrame: CGRect,
        contentLayoutRect: CGRect,
        targetPixelSize: CGSize
    ) throws -> Data {
        let normalized = try normalizedImage(
            image: image,
            windowFrame: windowFrame,
            contentLayoutRect: contentLayoutRect,
            targetPixelSize: targetPixelSize
        )
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw PlayCoverScreenCaptureError.jpegEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            normalized,
            [
                kCGImageDestinationLossyCompressionQuality: jpegQuality,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PlayCoverScreenCaptureError.jpegEncodingFailed
        }
        return output as Data
    }

    static func normalizedImage(
        image: CGImage,
        windowFrame: CGRect,
        contentLayoutRect: CGRect,
        targetPixelSize: CGSize
    ) throws -> CGImage {
        let crop = try cropRectangle(
            imagePixelSize: CGSize(width: image.width, height: image.height),
            windowFrame: windowFrame,
            contentLayoutRect: contentLayoutRect
        )
        guard let contentImage = image.cropping(to: crop) else {
            throw PlayCoverScreenCaptureError.cropFailed
        }
        let targetWidth = Int(targetPixelSize.width.rounded())
        let targetHeight = Int(targetPixelSize.height.rounded())
        guard targetWidth > 0, targetHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: targetWidth,
                  height: targetHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: targetWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw PlayCoverScreenCaptureError.imageCreationFailed
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(
            CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        )
        context.draw(
            contentImage,
            in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        )
        guard let normalized = context.makeImage() else {
            throw PlayCoverScreenCaptureError.imageCreationFailed
        }
        return normalized
    }

    static func cropRectangle(
        imagePixelSize: CGSize,
        windowFrame: CGRect,
        contentLayoutRect: CGRect
    ) throws -> CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              windowFrame.width > 0, windowFrame.height > 0,
              contentLayoutRect.width > 0, contentLayoutRect.height > 0 else {
            throw PlayCoverScreenCaptureError.invalidGeometry(
                "image, window, and content sizes must be positive"
            )
        }
        let tolerance = 0.5
        guard contentLayoutRect.minX >= -tolerance,
              contentLayoutRect.minY >= -tolerance,
              contentLayoutRect.maxX <= windowFrame.width + tolerance,
              contentLayoutRect.maxY <= windowFrame.height + tolerance else {
            throw PlayCoverScreenCaptureError.invalidGeometry(
                "contentLayoutRect is outside the AppKit window"
            )
        }

        let horizontalScale = imagePixelSize.width / windowFrame.width
        let verticalScale = imagePixelSize.height / windowFrame.height
        let largestScale = max(horizontalScale, verticalScale)
        guard horizontalScale.isFinite,
              verticalScale.isFinite,
              largestScale > 0,
              abs(horizontalScale - verticalScale) / largestScale
                <= uniformScaleTolerance else {
            throw PlayCoverScreenCaptureError.invalidGeometry(
                "captured image-to-window scale is not approximately uniform"
            )
        }
        let minimumX = max(
            0,
            floor(contentLayoutRect.minX * horizontalScale)
        )
        // AppKit window coordinates are bottom-left based, while CGImage crop
        // coordinates address the captured raster from its top-left edge.
        let minimumY = max(
            0,
            floor(
                (windowFrame.height - contentLayoutRect.maxY)
                    * verticalScale
            )
        )
        let maximumX = min(
            imagePixelSize.width,
            ceil(contentLayoutRect.maxX * horizontalScale)
        )
        let maximumY = min(
            imagePixelSize.height,
            ceil(
                (windowFrame.height - contentLayoutRect.minY)
                    * verticalScale
            )
        )
        guard maximumX > minimumX, maximumY > minimumY else {
            throw PlayCoverScreenCaptureError.invalidGeometry(
                "contentLayoutRect maps to an empty pixel crop"
            )
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }
}

private final class PlayCoverAsyncResultBox<Value> {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func get() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
