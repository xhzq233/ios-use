import CoreGraphics
import Foundation
import ImageIO

/// A small, deterministic near-duplicate detector for screenshot sequences.
///
/// The driver returns JPEG data. JPEG bytes are not a suitable visual identity:
/// two captures of the same screen can have different compressed bytes. We
/// therefore decode both images, compare a grayscale logical-size raster, and
/// use block statistics similar to FFmpeg's `mpdecimate` filter.
struct ImageDiffService {
    struct Result {
        let changed: Bool
        let score: Double
        let changedPixelRatio: Double
        let changedTileRatio: Double
        let compareWidth: Int
        let compareHeight: Int

        static let firstFrame = Result(
            changed: true,
            score: 1,
            changedPixelRatio: 1,
            changedTileRatio: 1,
            compareWidth: 0,
            compareHeight: 0
        )
    }

    /// Values are intentionally conservative. The detector is used to decide
    /// which evidence frames to retain, so an uncertain frame must be kept.
    private static let pixelNoiseTolerance = 3
    private static let changedPixelRatioThreshold = 0.02
    private static let changedTileMeanThreshold = 8.0
    private static let tileSize = 8
    private static let fallbackLongSide = 874

    /// Stateful capture-sequence comparator. It keeps the previous decoded
    /// logical raster so each new JPEG is decoded only once.
    struct Detector {
        private var previousRaster: Raster?

        mutating func compare(current: Data, logicalSize: CGSize? = nil) throws -> Result {
            let currentRaster = try ImageDiffService.prepare(current, logicalSize: logicalSize)
            guard let previousRaster else {
                self.previousRaster = currentRaster
                return .firstFrame
            }
            self.previousRaster = currentRaster
            guard previousRaster.width == currentRaster.width,
                  previousRaster.height == currentRaster.height else {
                return Result(
                    changed: true,
                    score: 1,
                    changedPixelRatio: 1,
                    changedTileRatio: 1,
                    compareWidth: currentRaster.width,
                    compareHeight: currentRaster.height
                )
            }
            return ImageDiffService.compare(previousRaster, currentRaster)
        }
    }

    static func compare(
        previous: Data,
        current: Data,
        logicalSize: CGSize? = nil
    ) throws -> Result {
        var detector = Detector()
        _ = try detector.compare(current: previous, logicalSize: logicalSize)
        return try detector.compare(current: current, logicalSize: logicalSize)
    }

    private struct Raster {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    private static func prepare(_ data: Data, logicalSize: CGSize?) throws -> Raster {
        guard let image = decode(data) else { throw Error.invalidImage }
        let size = comparisonSize(image: image, logicalSize: logicalSize)
        guard let pixels = rasterize(image, size: size),
              pixels.count == size.width * size.height else {
            throw Error.invalidImage
        }
        return Raster(pixels: pixels, width: size.width, height: size.height)
    }

    private static func compare(_ previous: Raster, _ current: Raster) -> Result {
        let pixelCount = current.width * current.height

        var totalDifference = 0
        var changedPixels = 0
        var changedTiles = 0
        var tileCount = 0
        var maxTileMean = 0.0

        for tileY in stride(from: 0, to: current.height, by: tileSize) {
            let tileMaxY = min(tileY + tileSize, current.height)
            for tileX in stride(from: 0, to: current.width, by: tileSize) {
                let tileMaxX = min(tileX + tileSize, current.width)
                var tileDifference = 0
                var tilePixels = 0

                for y in tileY..<tileMaxY {
                    for x in tileX..<tileMaxX {
                        let index = y * current.width + x
                        let difference = abs(Int(current.pixels[index]) - Int(previous.pixels[index]))
                        totalDifference += difference
                        tileDifference += difference
                        tilePixels += 1
                        if difference > pixelNoiseTolerance {
                            changedPixels += 1
                        }
                    }
                }

                tileCount += 1
                let mean = Double(tileDifference) / Double(tilePixels)
                maxTileMean = max(maxTileMean, mean)
                if mean > changedTileMeanThreshold {
                    changedTiles += 1
                }
            }
        }

        let score = Double(totalDifference) / Double(pixelCount * 255)
        let changedPixelRatio = Double(changedPixels) / Double(pixelCount)
        let changedTileRatio = tileCount > 0 ? Double(changedTiles) / Double(tileCount) : 0
        let changed = changedPixelRatio >= changedPixelRatioThreshold
            || maxTileMean > changedTileMeanThreshold

        return Result(
            changed: changed,
            score: score,
            changedPixelRatio: changedPixelRatio,
            changedTileRatio: changedTileRatio,
            compareWidth: current.width,
            compareHeight: current.height
        )
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case invalidImage

        var description: String {
            switch self {
            case .invalidImage: return "image data is not a decodable image"
            }
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func comparisonSize(image: CGImage, logicalSize: CGSize?) -> (width: Int, height: Int) {
        if let logicalSize, logicalSize.width > 0, logicalSize.height > 0 {
            return (
                max(1, Int(logicalSize.width.rounded())),
                max(1, Int(logicalSize.height.rounded()))
            )
        }

        let longSide = max(image.width, image.height)
        let scale = min(1, Double(fallbackLongSide) / Double(max(1, longSide)))
        return (
            max(1, Int((Double(image.width) * scale).rounded())),
            max(1, Int((Double(image.height) * scale).rounded()))
        )
    }

    private static func rasterize(_ image: CGImage, size: (width: Int, height: Int)) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: size.width * size.height)
        guard let context = CGContext(
            data: &pixels,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: size.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return pixels
    }
}
