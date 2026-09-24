import Foundation
import Metal
import CoreVideo
import CoreImage
import CoreGraphics
import CoreText

/// A generated source, so the app can be exercised without any other program running.
///
/// It is built to answer three questions at a glance:
///
/// - **Is the orientation right?** A static "2NDI" wordmark and a `TOP` marker. The text
///   does not rotate: text at an arbitrary angle tells you nothing about which way up the
///   frame is, which is the one thing it is there to show.
/// - **Is it stuttering?** A hand sweeping once per second. Motion is what makes a dropped
///   or repeated frame visible; a still image never will.
/// - **Is there video at all?** A coloured background, never black, so "no signal" and
///   "signal showing black" cannot be confused.
///
/// The background and text are drawn once; only the hand is composited per frame, so the
/// generator stays cheap enough not to become the bottleneck it is meant to measure.
final class TestPatternInput: VideoInput {

    static let width = 1920
    static let height = 1080
    static let fps = 60.0
    static let displayName = "Test pattern — generated \(width)×\(height) \(Int(fps)) fps"

    /// Where the dial sits, as a fraction of height in CoreGraphics' y-up coordinates.
    private static let dialCentreFraction: CGFloat = 0.26
    private static let dialRadiusFraction: CGFloat = 0.15

    /// The blink square, in the same y-up coordinates. A hard on/off edge once a second is
    /// far easier to compare between two screens than continuous motion, which is what
    /// makes it usable for eyeballing end-to-end delay: film both displays and count the
    /// frames between the square lighting up on each.
    private static func blinkRect(width: Int, height: Int) -> CGRect {
        let h = CGFloat(height), w = CGFloat(width)
        let size = h * 0.13
        return CGRect(x: w - size - h * 0.04, y: h - size - h * 0.04, width: size, height: size)
    }

    private let context: CIContext
    private let commandQueue: MTLCommandQueue
    private let background: CIImage
    private let hand: CIImage
    private let blink: CIImage
    /// The size caption, rebuilt whenever the pipeline's output resolution changes. Kept
    /// as its own layer so a change costs one small text render rather than redrawing the
    /// whole background.
    private var caption: CIImage?
    private var captionedSize: (width: Int, height: Int)?
    private let captionLock = NSLock()
    private var outputs: [MTLTexture] = []
    private var buffers: [CVPixelBuffer] = []

    private let lock = NSLock()
    private var current = 0
    private var running = true

    private(set) var isValid = false

    init?(device: MTLDevice, frameHandler: @escaping () -> Void) {
        guard let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])

        let width = Self.width, height = Self.height
        guard let still = Self.drawStillFrame(width: width, height: height) else { return nil }
        background = CIImage(cgImage: still)

        // The sweeping hand lives in its own dial rather than across the wordmark, so the
        // motion reads clearly and the text stays legible.
        let handLength = CGFloat(height) * Self.dialRadiusFraction * 0.88
        let handWidth = CGFloat(height) * 0.016
        hand = CIImage(color: CIColor(red: 1.0, green: 0.84, blue: 0.0))
            .cropped(to: CGRect(x: 0, y: -handWidth / 2, width: handLength, height: handWidth))
        blink = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: Self.blinkRect(width: width, height: height))

        // Three buffers so the pipeline can still be reading one while the next is drawn.
        for _ in 0..<3 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                 kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
            guard let buffer, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
            else { return nil }
            buffers.append(buffer)
            outputs.append(texture)
        }
        isValid = true

        let interval = 1.0 / Self.fps
        let framesPerTurn = Self.fps   // one revolution a second, so a stall is obvious
        Thread.detachNewThread { [weak self] in
            var frame = 0
            // Sleep to an absolute deadline. Sleeping for "what is left of this frame"
            // accumulates the scheduler's overshoot and caps the generator well below its
            // target, which silently limits anything measured against it.
            var deadline = Date().timeIntervalSinceReferenceDate
            while true {
                guard let self, self.running else { return }
                // On for the first half of each second, off for the second half.
                let blinkOn = Double(frame).truncatingRemainder(dividingBy: Self.fps) < Self.fps / 2
                self.renderFrame(angle: Double(frame) / framesPerTurn * 2 * .pi, blinkOn: blinkOn)
                frame += 1
                frameHandler()

                deadline += interval
                let now = Date().timeIntervalSinceReferenceDate
                if deadline > now { Thread.sleep(forTimeInterval: deadline - now) } else { deadline = now }
            }
        }
    }

    /// Told by the pipeline what is actually going out, so the caption cannot claim the
    /// generator's own resolution after the frame has been scaled down.
    func describeOutput(width: Int, height: Int) {
        captionLock.lock()
        let changed = captionedSize == nil || captionedSize! != (width, height)
        captionLock.unlock()
        guard changed else { return }

        guard let image = Self.drawCaption("\(width) × \(height)",
                                           width: Self.width, height: Self.height) else { return }

        captionLock.lock()
        caption = CIImage(cgImage: image)
        captionedSize = (width, height)
        captionLock.unlock()
    }

    /// The caption as a full-frame transparent image, so it composites without any further
    /// positioning maths.
    private static func drawCaption(_ text: String, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)

        func draw(_ string: String, size: CGFloat, colour: CGColor, y: CGFloat) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(
                nil, string as CFString,
                [kCTFontAttributeName: font, kCTForegroundColorAttributeName: colour] as CFDictionary))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            context.textPosition = CGPoint(x: w / 2 - textWidth / 2, y: y - (ascent - descent) / 2)
            CTLineDraw(line, context)
        }

        draw(text, size: h * 0.045, colour: CGColor(red: 1, green: 1, blue: 1, alpha: 1), y: h * 0.50)
        return context.makeImage()
    }

    private func renderFrame(angle: Double, blinkOn: Bool) {
        lock.lock()
        let index = (current + 1) % outputs.count
        lock.unlock()

        let centre = CGAffineTransform(translationX: CGFloat(Self.width) / 2,
                                       y: CGFloat(Self.height) * Self.dialCentreFraction)
        let rotated = hand.transformed(by: CGAffineTransform(rotationAngle: angle).concatenating(centre))
        // CIImage(cgImage:) lands in CoreImage's y-up space while the renderer writes
        // texture row 0 as its bottom, so a CGImage-sourced frame arrives inverted. The
        // texture-to-texture path elsewhere is identity and needs no such flip; this one
        // starts from a CGImage and does.
        captionLock.lock()
        let caption = self.caption
        captionLock.unlock()

        var composed = background
        if let caption { composed = caption.composited(over: composed) }
        composed = rotated.composited(over: composed)
        if blinkOn { composed = blink.composited(over: composed) }
        composed = composed.transformed(by: CGAffineTransform(1, 0, 0, -1, 0, CGFloat(Self.height)))

        guard let buffer = commandQueue.makeCommandBuffer() else { return }
        context.render(composed, to: outputs[index], commandBuffer: buffer,
                       bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        buffer.commit()
        // The consumer reads this texture directly, so it must be finished first.
        buffer.waitUntilCompleted()

        lock.lock()
        current = index
        lock.unlock()
    }

    /// Background, wordmark and orientation markers — everything that does not move.
    private static func drawStillFrame(width: Int, height: Int) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)

        // A deep blue ground with a grid: obviously "a picture", never mistakable for the
        // black of no signal.
        context.setFillColor(CGColor(red: 0.07, green: 0.11, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let step = h / 12
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
        context.setLineWidth(max(1, h / 900))
        var x = CGFloat(0)
        while x <= w { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: h)); x += step }
        var y = CGFloat(0)
        while y <= h { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: w, y: y)); y += step }
        context.strokePath()

        // Colour bars down the left edge, so a colour or channel-order problem shows up.
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1), (1, 1, 1),
        ]
        let barHeight = h / CGFloat(bars.count)
        for (i, colour) in bars.enumerated() {
            context.setFillColor(CGColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1))
            context.fill(CGRect(x: 0, y: h - CGFloat(i + 1) * barHeight, width: w * 0.025, height: barHeight))
        }

        func draw(_ text: String, size: CGFloat, colour: CGColor, centeredAt point: CGPoint) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(
                nil, text as CFString,
                [kCTFontAttributeName: font, kCTForegroundColorAttributeName: colour] as CFDictionary))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            context.textPosition = CGPoint(x: point.x - textWidth / 2, y: point.y - (ascent - descent) / 2)
            CTLineDraw(line, context)
        }

        // The dial the hand sweeps around: a ring with a tick every 30°, so a stall or a
        // repeated frame shows up against a fixed reference.
        let dialCentre = CGPoint(x: w / 2, y: h * dialCentreFraction)
        let radius = h * dialRadiusFraction
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
        context.setLineWidth(max(1, h / 450))
        context.addArc(center: dialCentre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()
        for tick in 0..<12 {
            let angle = CGFloat(tick) / 12 * .pi * 2
            let inner = tick % 3 == 0 ? radius * 0.82 : radius * 0.91
            context.move(to: CGPoint(x: dialCentre.x + cos(angle) * inner,
                                     y: dialCentre.y + sin(angle) * inner))
            context.addLine(to: CGPoint(x: dialCentre.x + cos(angle) * radius,
                                        y: dialCentre.y + sin(angle) * radius))
        }
        context.strokePath()

        let blink = blinkRect(width: width, height: height)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.4))
        context.setLineWidth(max(1, h / 450))
        context.stroke(blink.insetBy(dx: -h * 0.012, dy: -h * 0.012))

        let yellow = CGColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        // CoreGraphics is y-up, so "TOP" goes at the high y.
        draw("TOP", size: h * 0.075, colour: white, centeredAt: CGPoint(x: w / 2, y: h * 0.93))
        draw("BOTTOM", size: h * 0.055, colour: CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
             centeredAt: CGPoint(x: w / 2, y: h * 0.055))
        draw("2NDI", size: h * 0.22, colour: yellow, centeredAt: CGPoint(x: w / 2, y: h * 0.66))
        return context.makeImage()
    }

    func newFrameTexture() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return outputs.isEmpty ? nil : outputs[current]
    }

    func stop() {
        running = false
        isValid = false
    }

    deinit { stop() }
}
