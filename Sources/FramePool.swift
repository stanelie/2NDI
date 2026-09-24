import Foundation
import Metal
import CoreVideo
import IOSurface

// A recycled BGRA surface plus the two views the rest of the pipeline needs of it: a
// MTLTexture for the GPU scale, and a CVPixelBuffer for VideoToolbox.
struct PooledFrame {
    let pixelBuffer: CVPixelBuffer
    let texture: MTLTexture
    let surface: IOSurfaceRef
}

// Frames arrive as textures belonging to the Syphon server's own surface ring, which the
// server is free to overwrite as soon as it publishes the next one. Every frame is
// therefore scaled (or straight-copied) into a surface we own before it reaches the
// encoder — that also gives us the arbitrary output resolution the comparison needs.
final class FramePool {

    let width: Int
    let height: Int

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderer: FrameRenderer
    private let pool: CVPixelBufferPool
    private let storageMode: MTLStorageMode

    // The pool cycles through a handful of surfaces, so caching the texture view by
    // surface pointer avoids rebuilding one on every frame.
    private var textureCache = [UnsafeMutableRawPointer: MTLTexture]()

    init?(device: MTLDevice, commandQueue: MTLCommandQueue, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.width = width
        self.height = height
        self.storageMode = device.hasUnifiedMemory ? .shared : .managed
        self.renderer = FrameRenderer(commandQueue: commandQueue)

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        // Four in flight is enough to cover one frame being encoded while the next is
        // being scaled, without letting a stalled consumer accumulate a queue.
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]

        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                      poolAttributes as CFDictionary,
                                      attributes as CFDictionary,
                                      &created) == kCVReturnSuccess,
              let pool = created else { return nil }
        self.pool = pool
    }

    /// Scales `source` into a pool frame and calls `completion` once the GPU has finished.
    ///
    /// Asynchronous on purpose. Waiting here held the capture queue for the whole render —
    /// measured at 14 ms per 1080p frame while Millumin kept the same GPU busy, against a
    /// 16.7 ms budget at 60 fps — so a frame arriving meanwhile was always dropped. Handing
    /// off lets the next capture overlap the previous frame's GPU work.
    ///
    /// The source is fitted, not stretched: sending a 4:3 composition at a 16:9 output size
    /// letterboxes it rather than distorting the picture being measured. The orientation
    /// correction happens here too, so the flip reaches the NDI output and not just the
    /// preview.
    /// - Returns: false if no frame was available, in which case `completion` never runs.
    @discardableResult
    func copy(from source: MTLTexture,
              orientation: FrameOrientation = .none,
              completion: @escaping (PooledFrame, Double) -> Void) -> Bool {
        guard let frame = nextFrame(), let buffer = commandQueue.makeCommandBuffer() else { return false }

        // The renderer composites over opaque black, so it paints the letterbox bars
        // itself and no separate clear pass is needed.
        renderer.render(source: source, into: frame.texture, orientation: orientation, on: buffer)

        // A managed texture lives in VRAM until explicitly synchronised; without this the
        // CPU-side read that the SpeedHQ path does would see stale or garbage pixels.
        if storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: frame.texture)
            blit.endEncoding()
        }

        let started = CFAbsoluteTimeGetCurrent()
        // Retaining `frame` here keeps the pool from recycling it before the consumer has
        // finished with it.
        buffer.addCompletedHandler { _ in
            completion(frame, (CFAbsoluteTimeGetCurrent() - started) * 1000.0)
        }
        buffer.commit()
        return true
    }

    private func nextFrame() -> PooledFrame? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
              let pixelBuffer = created,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return nil }

        let key = unsafeBitCast(surface, to: UnsafeMutableRawPointer.self)
        if let cached = textureCache[key] {
            return PooledFrame(pixelBuffer: pixelBuffer, texture: cached, surface: surface)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = storageMode

        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
        textureCache[key] = texture
        return PooledFrame(pixelBuffer: pixelBuffer, texture: texture, surface: surface)
    }
}
