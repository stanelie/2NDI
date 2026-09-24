import Cocoa
import MetalKit

// Shows what is actually being sent — the pooled frame after scaling, not the raw Syphon
// texture — so the preview confirms the output rather than the input.
//
// Drawing is driven by MTKView's own timer at a deliberately modest rate: this is a
// measurement tool, and a 4K preview redrawing at source rate would compete with the
// encoder for the same GPU and skew the numbers next to it.
final class PreviewView: MTKView {

    private let lock = NSLock()
    private var latest: MTLTexture?
    private var renderer: FrameRenderer?
    private var commandQueue: MTLCommandQueue?
    /// CoreImage renders into a CAMetalLayer drawable **vertically flipped** relative to an
    /// ordinary texture — measured, and the cause of a regression where the preview
    /// silently cancelled the source's own flip and made a wrong setting look right. So
    /// the frame is rendered here first and then blitted, a copy that cannot reorder rows.
    private var offscreen: MTLTexture?

    init(device: MTLDevice) {
        super.init(frame: .zero, device: device)
        commandQueue = device.makeCommandQueue()
        if let commandQueue { renderer = FrameRenderer(commandQueue: commandQueue) }
        colorPixelFormat = .bgra8Unorm
        // CoreImage writes into the drawable directly, which a framebuffer-only texture forbids.
        framebufferOnly = false
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0.08, 0.08, 0.09, 1.0)
        layer?.isOpaque = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// Safe to call from the capture queue.
    func present(_ texture: MTLTexture) {
        lock.lock()
        latest = texture
        lock.unlock()
    }

    func clear() {
        lock.lock(); latest = nil; lock.unlock()
    }

    private func scratchTexture(like drawable: MTLTexture) -> MTLTexture? {
        if let offscreen, offscreen.width == drawable.width, offscreen.height == drawable.height {
            return offscreen
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: drawable.pixelFormat, width: drawable.width, height: drawable.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        offscreen = device?.makeTexture(descriptor: descriptor)
        return offscreen
    }

    override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable,
              let commandQueue,
              let renderer,
              let buffer = commandQueue.makeCommandBuffer() else { return }

        lock.lock()
        let texture = latest
        lock.unlock()

        if let texture, let scratch = scratchTexture(like: drawable.texture) {
            // The frame is already corrected and letterboxed by the pipeline; the preview
            // only fits it to the view, so it never applies an orientation of its own.
            renderer.render(source: texture, into: scratch, orientation: .none, on: buffer)
            if let blit = buffer.makeBlitCommandEncoder() {
                blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: scratch.width, height: scratch.height, depth: 1),
                          to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
        } else if let descriptor = currentRenderPassDescriptor,
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }

        buffer.present(drawable)
        buffer.commit()
    }
}
