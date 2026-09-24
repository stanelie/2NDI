import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writes the exact frame being sent to a PNG.
///
/// This exists because a preview is not evidence. CoreImage silently flipped the frame on
/// its way into the preview's drawable, which cancelled a wrong orientation setting and
/// made the picture on screen look right while the wire was upside down. A file written
/// straight from the texture that NDI reads cannot lie in that way.
enum Snapshot {

    static func write(texture: MTLTexture, to url: URL, commandQueue: MTLCommandQueue) -> Bool {
        // A managed texture holds the current pixels in VRAM until synchronised.
        if texture.storageMode == .managed,
           let buffer = commandQueue.makeCommandBuffer(),
           let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }

        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                                  CGBitmapInfo.byteOrder32Little.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }

        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
