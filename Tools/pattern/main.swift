// A Syphon source that actually keeps publishing. The stock "Simple Server" only draws
// when its window redraws, which is useless for measuring a sustained frame rate — this
// publishes a moving pattern at a fixed rate until interrupted.
//
//   syphon_pattern [width] [height] [fps]
import Foundation
import Metal
import Cocoa

let arguments = CommandLine.arguments
let width = arguments.count > 1 ? Int(arguments[1])! : 1920
let height = arguments.count > 2 ? Int(arguments[2])! : 1080
let fps = arguments.count > 3 ? Double(arguments[3])! : 60

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    print("no Metal device"); exit(1)
}

let server = SyphonMetalServer(name: "Test Pattern", device: device, options: nil)

// A fixed set of frames, built once on the GPU-visible side and then cycled.
//
// Earlier versions scrolled a CPU buffer and re-uploaded it every frame, which could not
// hold 60 fps at HD — the tool became the bottleneck and every measurement taken against
// it was really measuring this. Pre-building the frames costs memory instead of time, so
// the publish rate is steady at any resolution.
let frameCount = 8
let rowBytes = width * 4
var textures: [MTLTexture] = []
do {
    var pixels = [UInt8](repeating: 255, count: rowBytes * height)
    for step in 0..<frameCount {
        let shift = step * 24
        for y in 0..<height {
            for x in 0..<width {
                let index = y * rowBytes + x * 4
                let sx = (x + shift) % width
                pixels[index]     = UInt8(sx * 255 / width)                        // B
                pixels[index + 1] = UInt8(y * 255 / height)                        // G
                pixels[index + 2] = UInt8((sx + y) * 255 / (width + height))       // R
                if sx % 160 < 8 || y % 160 < 8 {
                    pixels[index] = 255; pixels[index + 1] = 255; pixels[index + 2] = 255
                }
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        guard let t = device.makeTexture(descriptor: d) else { log("texture allocation failed"); exit(1) }
        pixels.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: rowBytes)
        }
        textures.append(t)
    }
}

let frameInterval = 1.0 / fps
var frame = 0
let started = Date()

func log(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}
log("publishing “Test Pattern” at \(width)×\(height) \(fps) fps — ctrl-C to stop")

// The publishing loop runs on its own thread: Syphon announces itself and answers
// directory queries through distributed notifications, which need a live main run loop.
// Without one the server exists but no client can ever discover it.
Thread.detachNewThread {
    var nextDeadline = Date().timeIntervalSinceReferenceDate
    while true {

        if let buffer = queue.makeCommandBuffer() {
            server.publishFrameTexture(textures[frame % frameCount], on: buffer,
                                       imageRegion: NSRect(x: 0, y: 0, width: width, height: height),
                                       flipped: false)
            buffer.commit()
        }

        frame += 1
        if frame % Int(fps) == 0 {
            let elapsed = Date().timeIntervalSince(started)
            log("published \(frame) frames, \(String(format: "%.1f", Double(frame) / elapsed)) fps actual")
        }

        // Sleep to an absolute deadline, not for "whatever is left of this frame".
        // Sleeping by duration accumulates the scheduler's overshoot every frame: measured
        // at 19 ms per iteration against a 16.67 ms target, which capped this tool at 52 fps
        // regardless of resolution and quietly limited every measurement taken against it.
        nextDeadline += frameInterval
        let now = Date().timeIntervalSinceReferenceDate
        if nextDeadline > now {
            Thread.sleep(forTimeInterval: nextDeadline - now)
        } else {
            // Fallen behind; give up the missed frames rather than sprinting to catch up.
            nextDeadline = now
        }
    }
}

RunLoop.main.run()
