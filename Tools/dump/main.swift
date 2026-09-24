// Dumps one frame straight off a Syphon source to PNG, before anything in the app touches
// it. Syphon carries no orientation metadata, so this is the only way to know whether a
// given server's surface arrives the right way up for Metal.
//
//   syphon_dump <name substring> <out.png>
import Cocoa
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 2 else { print("usage: syphon_dump <name substring> <out.png>"); exit(1) }
let wanted = arguments[1], outputPath = arguments[2]

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    print("no Metal device"); exit(1)
}

// The directory needs a live run loop to answer announcements.
let deadline = Date().addingTimeInterval(3)
while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }

let servers = SyphonServerDirectory.shared().servers
guard let description = servers.first(where: {
    let name = ($0[SyphonServerDescriptionNameKey] as? String ?? "")
    let app = ($0[SyphonServerDescriptionAppNameKey] as? String ?? "")
    return name.localizedCaseInsensitiveContains(wanted) || app.localizedCaseInsensitiveContains(wanted)
}) else {
    print("no source matching \"\(wanted)\" among \(servers.count)"); exit(1)
}

let client = SyphonMetalClient(serverDescription: description as [String: Any],
                               device: device, options: nil, newFrameHandler: nil)

var texture: MTLTexture?
let frameDeadline = Date().addingTimeInterval(5)
while Date() < frameDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    if let image = client.newFrameImage() { texture = image; break }
}
guard let texture else { print("no frame arrived within 5 s"); exit(2) }

print("texture \(texture.width)x\(texture.height) format=\(texture.pixelFormat.rawValue) storage=\(texture.storageMode.rawValue) iosurface=\(texture.iosurface != nil)")

// A managed texture holds the current pixels in VRAM until synchronised.
if texture.storageMode == .managed, let buffer = queue.makeCommandBuffer(),
   let blit = buffer.makeBlitCommandEncoder() {
    blit.synchronize(resource: texture)
    blit.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
}

let width = texture.width, height = texture.height
var out = [UInt8](repeating: 0, count: width * height * 4)
out.withUnsafeMutableBytes {
    texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
}

// Mean luminance of the top and bottom eighth. Real content is rarely symmetric, so this
// is a hint, not proof — the PNG is the actual evidence.
func meanLuma(rows: Range<Int>) -> Double {
    var total = 0.0, count = 0
    for y in rows {
        for x in stride(from: 0, to: width, by: 8) {
            let i = (y * width + x) * 4
            total += 0.114 * Double(out[i]) + 0.587 * Double(out[i + 1]) + 0.299 * Double(out[i + 2])
            count += 1
        }
    }
    return count > 0 ? total / Double(count) : 0
}
print("mean luma  top eighth \(String(format: "%.1f", meanLuma(rows: 0..<(height / 8))))  bottom eighth \(String(format: "%.1f", meanLuma(rows: (height - height / 8)..<height)))")

let bitmap = CGContext(data: &out, width: width, height: height, bitsPerComponent: 8,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                   CGBitmapInfo.byteOrder32Little.rawValue)!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("wrote \(outputPath) — row 0 of the texture is the top row of this PNG")
