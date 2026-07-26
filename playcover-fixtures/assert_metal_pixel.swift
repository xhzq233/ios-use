import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2 else {
    fputs("usage: assert_metal_pixel.swift <screenshot.jpg>\n", stderr)
    exit(64)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fputs("could not decode screenshot\n", stderr)
    exit(65)
}

var pixel = [UInt8](repeating: 0, count: 4)
guard
    let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    fputs("could not create pixel context\n", stderr)
    exit(70)
}

let sampleX = image.width * 80 / 430
let sampleY = image.height * 500 / 932
context.translateBy(x: -CGFloat(sampleX), y: -CGFloat(sampleY))
context.draw(
    image,
    in: CGRect(
        x: 0,
        y: 0,
        width: image.width,
        height: image.height
    )
)

let red = Int(pixel[0])
let green = Int(pixel[1])
let blue = Int(pixel[2])
let alpha = Int(pixel[3])
print(
    "metal sample x=\(sampleX) y=\(sampleY) "
        + "rgba=\(red),\(green),\(blue),\(alpha)"
)
guard red < 100, blue > green + 15, alpha > 240 else {
    fputs("sample does not match the opaque animated Metal canvas\n", stderr)
    exit(1)
}
