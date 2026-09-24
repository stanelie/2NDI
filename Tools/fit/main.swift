// Measures what FramePool.copy actually produces, by pushing a marked pattern through it
// and writing the result to PNG. The markers make a translation or a clip obvious:
//   left edge   RED      right edge  BLUE
//   top edge    GREEN    bottom edge YELLOW
// A correct aspect-fit shows all four bars, centred, with black letterbox where needed.
import Foundation
import Metal
import MetalPerformanceShaders
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 5 else {
    print("usage: fit_test <srcW> <srcH> <dstW> <dstH> <out.png> [orientation 0-3]"); exit(1)
}
let sourceWidth = Int(arguments[1])!, sourceHeight = Int(arguments[2])!
let destinationWidth = Int(arguments[3])!, destinationHeight = Int(arguments[4])!
let outputPath = arguments[5]
let orientation = FrameOrientation(rawValue: arguments.count > 6 ? Int(arguments[6])! : 0)!

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue(),
      let pool = FramePool(device: device, commandQueue: queue,
                           width: destinationWidth, height: destinationHeight) else {
    print("metal setup failed"); exit(1)
}

let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: sourceWidth, height: sourceHeight, mipmapped: false)
descriptor.usage = [.shaderRead, .renderTarget]
guard let source = device.makeTexture(descriptor: descriptor) else { print("texture failed"); exit(1) }

// BGRA byte order.
var pixels = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
let edgeX = max(1, sourceWidth / 10), edgeY = max(1, sourceHeight / 10)
for y in 0..<sourceHeight {
    for x in 0..<sourceWidth {
        let i = (y * sourceWidth + x) * 4
        var b: UInt8 = 40, g: UInt8 = 40, r: UInt8 = 40
        if x < edgeX { (b, g, r) = (0, 0, 255) }              // left  red
        else if x >= sourceWidth - edgeX { (b, g, r) = (255, 0, 0) }   // right blue
        else if y < edgeY { (b, g, r) = (0, 255, 0) }         // top   green
        else if y >= sourceHeight - edgeY { (b, g, r) = (0, 255, 255) } // bottom yellow
        pixels[i] = b; pixels[i + 1] = g; pixels[i + 2] = r; pixels[i + 3] = 255
    }
}
pixels.withUnsafeBytes {
    source.replace(region: MTLRegionMake2D(0, 0, sourceWidth, sourceHeight), mipmapLevel: 0,
                   withBytes: $0.baseAddress!, bytesPerRow: sourceWidth * 4)
}

guard let copied = pool.copy(from: source, orientation: orientation) else { print("pool.copy failed"); exit(1) }

var out = [UInt8](repeating: 0, count: destinationWidth * destinationHeight * 4)
out.withUnsafeMutableBytes {
    copied.frame.texture.getBytes($0.baseAddress!, bytesPerRow: destinationWidth * 4,
                                  from: MTLRegionMake2D(0, 0, destinationWidth, destinationHeight),
                                  mipmapLevel: 0)
}

// Report the span of written pixels in both axes, which is the number the eye is after.
// Alpha counts too: MPS writing zeros outside the source range leaves transparent pixels
// that look black but are not the letterbox we painted.
func isPainted(_ i: Int) -> Bool { out[i] > 8 || out[i + 1] > 8 || out[i + 2] > 8 }

var firstColumn = -1, lastColumn = -1
let midRow = destinationHeight / 2
for x in 0..<destinationWidth where isPainted((midRow * destinationWidth + x) * 4) {
    if firstColumn < 0 { firstColumn = x }
    lastColumn = x
}
var firstRow = -1, lastRow = -1
let midColumn = destinationWidth / 2
for y in 0..<destinationHeight where isPainted((y * destinationWidth + midColumn) * 4) {
    if firstRow < 0 { firstRow = y }
    lastRow = y
}
var transparent = 0
for i in stride(from: 3, to: out.count, by: 4) where out[i] < 255 { transparent += 1 }
let expectedScale = min(Double(destinationWidth) / Double(sourceWidth),
                        Double(destinationHeight) / Double(sourceHeight))
let expectedWidth = Int((Double(sourceWidth) * expectedScale).rounded())
let expectedHeight = Int((Double(sourceHeight) * expectedScale).rounded())
let expectedFirst = (destinationWidth - expectedWidth) / 2
let expectedFirstRow = (destinationHeight - expectedHeight) / 2
print("\(sourceWidth)x\(sourceHeight) -> \(destinationWidth)x\(destinationHeight)")
print("  columns \(firstColumn)…\(lastColumn)  expected \(expectedFirst)…\(expectedFirst + expectedWidth - 1)")
print("  rows    \(firstRow)…\(lastRow)  expected \(expectedFirstRow)…\(expectedFirstRow + expectedHeight - 1)")
print("  non-opaque pixels \(transparent)")

// Which edge each marker colour ended up on, which is what makes an orientation change
// legible without opening the PNG. Sampled just inside the fitted rectangle.
func colourName(_ x: Int, _ y: Int) -> String {
    let i = (y * destinationWidth + x) * 4
    let (b, g, r) = (Int(out[i]), Int(out[i + 1]), Int(out[i + 2]))
    if r > 200 && g < 60 && b < 60 { return "RED(left)" }
    if b > 200 && g < 60 && r < 60 { return "BLUE(right)" }
    if g > 200 && r < 60 && b < 60 { return "GREEN(top)" }
    if g > 200 && b > 200 && r < 60 { return "YELLOW(bottom)" }
    return "r\(r) g\(g) b\(b)"
}
let insetX = firstColumn + (lastColumn - firstColumn) / 40 + 1
let insetY = firstRow + (lastRow - firstRow) / 40 + 1
print("  left edge   \(colourName(insetX, (firstRow + lastRow) / 2))")
print("  right edge  \(colourName(lastColumn - (lastColumn - firstColumn) / 40 - 1, (firstRow + lastRow) / 2))")
print("  top edge    \(colourName((firstColumn + lastColumn) / 2, insetY))")
print("  bottom edge \(colourName((firstColumn + lastColumn) / 2, lastRow - (lastRow - firstRow) / 40 - 1))")

let context = CGContext(data: &out, width: destinationWidth, height: destinationHeight,
                        bitsPerComponent: 8, bytesPerRow: destinationWidth * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                    CGBitmapInfo.byteOrder32Little.rawValue)!
let url = URL(fileURLWithPath: outputPath)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("  wrote \(outputPath)")
