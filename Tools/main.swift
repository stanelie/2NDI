// Isolates the video path from Syphon. Two modes, so a failure can be attributed:
//   encoder_test cpu   <w> <h> <n>   plain CPU-filled CVPixelBuffers -> Encoder
//   encoder_test metal <w> <h> <n>   MTLTexture -> FramePool -> Encoder, the app's path
import Foundation
import CoreVideo
import Metal
import MetalPerformanceShaders

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "cpu"
let width = arguments.count > 2 ? Int(arguments[2])! : 640
let height = arguments.count > 3 ? Int(arguments[3])! : 360
let count = arguments.count > 4 ? Int(arguments[4])! : 60
// "max" submits as fast as the encoder will take frames, which measures throughput.
// Otherwise frames are paced at 30/s, which measures latency at that rate.
let unpaced = arguments.count > 5 && arguments[5] == "max"

let wantHEVC = ProcessInfo.processInfo.environment["ENC_CODEC"]?.lowercased() == "hevc"
let allowHardware = ProcessInfo.processInfo.environment["ENC_SOFTWARE"] != "1"
guard let encoder = Encoder(width: width, height: height, codec: wantHEVC ? .hevc : .h264,
                            bitrate: 8_000_000, fps: 30, keyframeIntervalSeconds: 1,
                            allowHardware: allowHardware) else {
    print("encoder create FAILED"); exit(1)
}
print("codec=\(wantHEVC ? "hevc" : "h264") \(width)x\(height) hardware=\(encoder.isHardware) (requested hw: \(allowHardware))")
let started = Date()

var received = 0, keyframes = 0, bytes = 0
var latencyTotal = 0.0, latencyPeak = 0.0
encoder.onFrame = { frame in
    received += 1
    bytes += frame.data.count
    if frame.isKeyframe { keyframes += 1 }
    latencyTotal += frame.encodeMilliseconds
    latencyPeak = max(latencyPeak, frame.encodeMilliseconds)
    if received <= 3 {
        print("  frame \(received): \(frame.data.count) B key=\(frame.isKeyframe) ps=\(frame.parameterSets.count) B \(String(format: "%.2f", frame.encodeMilliseconds)) ms")
    }
}

if mode == "metal" {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let pool = FramePool(device: device, commandQueue: queue, width: width, height: height) else {
        print("metal setup FAILED"); exit(1)
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    guard let source = device.makeTexture(descriptor: descriptor) else { print("texture FAILED"); exit(1) }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<count {
        for j in 0..<pixels.count { pixels[j] = UInt8((i * 4 + j) % 255) }
        pixels.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        guard let copied = pool.copy(from: source) else { print("pool.copy FAILED"); break }
        encoder.encode(pixelBuffer: copied.frame.pixelBuffer, pts: Int64(i) * 333_333, forceKeyframe: i == 0)
        if !unpaced { usleep(33_000) }
    }
} else {
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                             kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                             kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pool)
    for i in 0..<count {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
        guard let buffer else { break }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(i * 4 % 255), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        encoder.encode(pixelBuffer: buffer, pts: Int64(i) * 333_333, forceKeyframe: i == 0)
        if !unpaced { usleep(33_000) }
    }
}

let submitDone = Date()
usleep(300_000)
encoder.stop()
let elapsed = Date().timeIntervalSince(started)
print(String(format: "throughput: %d frames in %.2f s = %.1f fps", received, elapsed, Double(received) / elapsed))
print(String(format: "latency:    %.2f ms mean, %.2f ms peak", latencyTotal / Double(max(received, 1)), latencyPeak))
exit(received > 0 ? 0 : 2)
