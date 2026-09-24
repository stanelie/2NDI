import Foundation
import AVFoundation
import CoreVideo
import Metal

/// A capture device presented to the pipeline exactly like a Syphon server.
///
/// AVFoundation pushes frames at us while Syphon is pull-based, so the newest frame is
/// held here and handed over when the pipeline asks. Frames that arrive before the
/// previous one was collected are simply overwritten — the pipeline already counts those
/// as drops through the same path it uses for Syphon, and holding a queue would inflate
/// the latency this app exists to measure.
final class CameraInput: NSObject, VideoInput, AVCaptureVideoDataOutputSampleBufferDelegate {

    struct Camera {
        let id: String
        let name: String
    }

    static func availableCameras() -> [Camera] {
        // .externalUnknown covers USB/UVC cameras, which is most of what gets used here.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified)
        return discovery.devices.map { Camera(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Whether the user has granted camera access. `.notDetermined` prompts on first use.
    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ca.exmachina.syphonndi.camera")
    private var textureCache: CVMetalTextureCache?

    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    /// Kept alive for as long as the pipeline might still be using the texture it wraps.
    private var handedOut: CVMetalTexture?

    private(set) var isValid = false

    init?(deviceID: String, device: MTLDevice, frameHandler: @escaping () -> Void) {
        super.init()

        guard let captureDevice = AVCaptureDevice(uniqueID: deviceID),
              let deviceInput = try? AVCaptureDeviceInput(device: captureDevice),
              session.canAddInput(deviceInput) else { return nil }

        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess
        else { return nil }

        self.frameHandler = frameHandler

        session.beginConfiguration()
        session.addInput(deviceInput)

        let output = AVCaptureVideoDataOutput()
        // BGRA and Metal-compatible, so the frame reaches the same code path a Syphon
        // texture does with no conversion of our own.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return nil
        }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
        isValid = true
    }

    private var frameHandler: (() -> Void)?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latestBuffer = buffer
        lock.unlock()
        frameHandler?()
    }

    func newFrameTexture() -> MTLTexture? {
        lock.lock()
        let buffer = latestBuffer
        latestBuffer = nil
        lock.unlock()

        guard let buffer, let textureCache else { return nil }

        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture)
        guard status == kCVReturnSuccess, let texture else { return nil }

        // Replaced only on the next call, by which time the pipeline has finished with the
        // previous frame — it copies synchronously before asking for another.
        handedOut = texture
        return CVMetalTextureGetTexture(texture)
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        frameHandler = nil
        isValid = false
        lock.lock()
        latestBuffer = nil
        handedOut = nil
        lock.unlock()
    }

    deinit { stop() }
}
