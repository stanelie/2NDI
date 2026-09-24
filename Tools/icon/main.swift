// Generates the app icon: yellow "2NDI" on black. Run via Tools/icon/build.sh, which
// renders every size into an .iconset and folds it into Resources/AppIcon.icns.
//
// Generated rather than drawn by hand so the wordmark can be changed in one place and
// every size stays consistent.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = CommandLine.arguments[1]
let text = "2NDI"

func render(_ size: Int, to url: URL) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

    // macOS icons sit in a rounded square with a little breathing room, so the artwork
    // does not run to the very edge of the tile.
    let inset = CGFloat(size) * 0.055
    let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    let radius = rect.width * 0.2237   // Apple's squircle is close to this at icon sizes
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.addPath(path)
    context.fillPath()

    // Fit the wordmark to the tile width by measuring at a reference size and scaling.
    let yellow = CGColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1)
    let reference = CGFloat(100)
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, reference, nil)
    let probe = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary))
    let probeWidth = CTLineGetTypographicBounds(probe, nil, nil, nil)
    let targetWidth = rect.width * 0.80
    let scaled = CTFontCreateCopyWithAttributes(font, reference * targetWidth / CGFloat(probeWidth), nil, nil)

    // kCTForegroundColorAttributeName rather than the AppKit key, since this does not
    // link AppKit.
    let attributes: [CFString: Any] = [kCTFontAttributeName: scaled,
                                       kCTForegroundColorAttributeName: yellow]
    let line = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    context.textPosition = CGPoint(x: rect.midX - width / 2,
                                   y: rect.midY - (ascent - descent) / 2)
    CTLineDraw(line, context)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// The set of sizes an .icns needs, as name -> pixel size.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    render(size, to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name).png"))
}
print("rendered \(variants.count) sizes into \(outputDirectory)")
