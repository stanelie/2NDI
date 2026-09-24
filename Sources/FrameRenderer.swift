import Foundation
import Metal
import CoreImage

/// How the incoming Syphon texture has to be corrected before it goes out.
///
/// Syphon carries no orientation metadata, and servers genuinely disagree: measured on
/// this machine, a Metal-published source (`Tools/pattern`) arrives the right way up,
/// while Millumin 2's OpenGL server arrives vertically flipped — the classic bottom-left
/// versus top-left origin mismatch. There is no way to detect which, so it is a setting.
enum FrameOrientation: Int, CaseIterable {
    case none = 0
    case flipVertical = 1
    case flipHorizontal = 2
    case rotate180 = 3

    var label: String {
        switch self {
        case .none:          return "As received"
        case .flipVertical:  return "Flip vertical (OpenGL sources)"
        case .flipHorizontal: return "Flip horizontal"
        case .rotate180:     return "Rotate 180°"
        }
    }
}

/// Scales a source texture into a destination, preserving aspect ratio with black
/// letterbox bars, and applying an orientation correction.
///
/// This is CoreImage rather than MetalPerformanceShaders for two reasons. MPS cannot flip
/// — `MPSScaleTransform` with a negative scale silently produces an all-zero image
/// (measured) — and writing a shader to do it is not an option, because this project
/// builds under Command Line Tools, which ship no Metal compiler. CoreImage benchmarked
/// at the same cost as the MPS path it replaced (1.5–1.8 ms at HD, 4.3 ms at 4K, versus
/// 1.6–1.9 ms and 4.1 ms), since both are dominated by the command-buffer round trip.
final class FrameRenderer {

    private let context: CIContext
    /// Opaque black behind the fitted image, which is what forms the letterbox bars and
    /// also guarantees the result is fully opaque — a receiver told to honour alpha would
    /// otherwise see through the bars.
    private let background = CIImage(color: .black)

    init(commandQueue: MTLCommandQueue) {
        // Working colour space disabled: this is a passthrough, and any conversion would
        // shift the pixels being measured.
        context = CIContext(mtlCommandQueue: commandQueue,
                            options: [.cacheIntermediates: false,
                                      .workingColorSpace: NSNull()])
    }

    func render(source: MTLTexture,
                into destination: MTLTexture,
                orientation: FrameOrientation,
                on commandBuffer: MTLCommandBuffer) {
        guard var image = CIImage(mtlTexture: source, options: [.colorSpace: NSNull()]) else { return }

        let sourceWidth = Double(source.width), sourceHeight = Double(source.height)
        let destinationWidth = Double(destination.width), destinationHeight = Double(destination.height)

        // CoreImage works bottom-left-origin, and both the texture it reads and the
        // texture it writes use that same convention, so an identity transform is a
        // faithful copy and these are true image-space flips.
        switch orientation {
        case .none:
            break
        case .flipVertical:
            image = image.transformed(by: CGAffineTransform(1, 0, 0, -1, 0, sourceHeight))
        case .flipHorizontal:
            image = image.transformed(by: CGAffineTransform(-1, 0, 0, 1, sourceWidth, 0))
        case .rotate180:
            image = image.transformed(by: CGAffineTransform(-1, 0, 0, -1, sourceWidth, sourceHeight))
        }

        let scale = min(destinationWidth / sourceWidth, destinationHeight / sourceHeight)
        let fittedWidth = (sourceWidth * scale).rounded()
        let fittedHeight = (sourceHeight * scale).rounded()
        let originX = ((destinationWidth - fittedWidth) / 2).rounded()
        let originY = ((destinationHeight - fittedHeight) / 2).rounded()

        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: originX, y: originY))

        let bounds = CGRect(x: 0, y: 0, width: destinationWidth, height: destinationHeight)
        let composited = image.composited(over: background.cropped(to: bounds))

        context.render(composited,
                       to: destination,
                       commandBuffer: commandBuffer,
                       bounds: bounds,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
