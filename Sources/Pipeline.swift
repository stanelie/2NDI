import Foundation
import Metal
import CoreVideo

struct PipelineConfig: Equatable {
    /// Output size. Only ever equal to or smaller than the source.
    ///
    /// There is no way to ask for a fixed size, deliberately. Upscaling spends GPU time and
    /// bandwidth inventing detail that is not there, and a fixed size whose aspect differs
    /// from the source burns letterbox bars into the stream. A cap on height keeps the
    /// source's aspect ratio, so the picture never grows bars and never grows pixels.
    enum Resolution: Equatable {
        case native
        case maxHeight(Int)
    }

    var ndiName = "Syphon"
    var codec = NDICodec.speedHQ
    var resolution = Resolution.native
    /// 0 means "send every frame the source publishes".
    var fpsCap = 0.0
    /// 0 means "use the bit rate the SDK suggests for this format".
    var bitrateMbps = 0.0
    var ignoreAlpha = true
    /// Force VideoToolbox's software encoder. Only useful for diagnosis: measured at 4K,
    /// software H.264 managed 3.9 fps against the hardware block's 26.6.
    var allowHardwareEncoder = true
    /// H.264 only. Baseline is the cheapest for a receiver to decode.
    var h264Profile = Encoder.Profile.high
    /// Corrects sources that publish with the opposite vertical origin — Millumin 2 and
    /// other OpenGL Syphon servers arrive upside down. Applied to the NDI output, not
    /// just the preview.
    var orientation = FrameOrientation.none
}

// Owns the Syphon client, the frame pool, the encoder and the NDI sender, and moves one
// frame between them. Everything after the Syphon callback runs on `queue`, a single
// serial queue, so the ordering of the timings the stats collect is well defined.
final class Pipeline {

    private(set) var config: PipelineConfig
    let stats = Stats()

    /// Latest frame, for the preview. Called on the capture queue.
    var onPreviewFrame: ((MTLTexture) -> Void)?
    /// Fatal problems worth putting in front of the user. Called on the main queue.
    var onError: ((String) -> Void)?
    /// Result of a requested snapshot: the file written, or nil on failure. Main queue.
    var onSnapshot: ((URL?) -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let queue = DispatchQueue(label: "ca.exmachina.syphonndi.capture", qos: .userInteractive)

    private var input: VideoInput?
    private var sender: NDISender?
    private var monitor: NDIDeliveryMonitor?
    private var encoder: Encoder?
    private var pool: FramePool?

    // The Advanced SDK makes a compressed sender responsible for its own low-bandwidth
    // proxy: it synthesises one only for the formats it encodes itself. Without this, a
    // receiver that asks for NDIlib_recv_bandwidth_lowest — as some hardware decoders do —
    // gets no video at all, while NDI Monitor and the like (which ask for highest) work.
    // Measured with Tools/ndi_probe: HX delivered 0 frames at lowest, SpeedHQ delivered a
    // 640x360 proxy the library had made on its own.
    private var previewEncoder: Encoder?
    private var previewPool: FramePool?
    private var previewFrameCounter = 0
    private var previewEncodesInFlight = 0
    private var previewEligible = 0
    private var previewBlocked = 0
    private var previewNoFrame = 0
    private var previewSent = 0
    private var previewEncoderFailures = 0
    private var previewLastKeyframe: CFAbsoluteTime = 0
    private let previewDebug = ProcessInfo.processInfo.environment["SYPHONNDI_PREVIEW_DEBUG"] != nil
    /// SDK ceiling for the proxy stream.
    static let previewMaxFPS = 45.0
    static let previewMaxEncodesInFlight = 4

    // Guards against the pipeline falling behind the source: rather than queueing frames
    // (which would inflate exactly the latency we are trying to measure) a frame that
    // arrives while another is in flight is dropped and counted.
    private let flightLock = NSLock()
    private var capturesPending = 0
    private var encodesInFlight = 0

    private var lastSentTime: CFAbsoluteTime = 0
    /// Next moment a frame is due, when a frame rate cap is active.
    private var nextSendDeadline: CFAbsoluteTime = 0
    private var startTime = CFAbsoluteTimeGetCurrent()
    // Per-frame context the encoder callback needs to finish the timing, keyed by pts.
    private var pendingEncodes = [Int64: (captureStart: CFAbsoluteTime, gpuMs: Double)]()
    private var pendingSnapshot: URL?

    init?(device: MTLDevice, config: PipelineConfig) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.config = config
    }

    var isRunning: Bool { sender != nil }
    var isHardwareEncoding: Bool { encoder?.isHardware ?? false }
    /// Profile, level and chroma read back out of the SPS actually being sent.
    var bitstreamSummary: String? { encoder?.bitstreamSummary }

    // MARK: - Lifecycle

    /// The input currently being read, whichever kind it is.
    private(set) var currentSource: InputSource?
    /// The source's own pixel dimensions, once a frame has arrived. The resolution list is
    /// built from this so it can never offer more pixels than the source has.
    private(set) var sourceSize: (width: Int, height: Int)?

    func start(source: InputSource) throws {
        stop()
        stats.reset()
        startTime = CFAbsoluteTimeGetCurrent()
        publishTimes.removeAll()
        candidateStreak = 0
        nextSendDeadline = 0
        measuredSourceFPS = nil
        // Until the source has been measured the setting stands on its own; the clamp
        // applies as soon as there is something to clamp against.
        recomputeNominalRate()

        guard let sender = NDISender(name: config.ndiName) else {
            throw PipelineError.message("Could not create the NDI sender. Is another sender using this name?")
        }
        self.sender = sender

        let built: VideoInput?
        switch source.kind {
        case .syphon:
            built = source.syphonSource.flatMap {
                SyphonInput(source: $0, device: device) { [weak self] in self?.handleFrame() }
            }
        case .camera:
            built = CameraInput(deviceID: source.id, device: device) { [weak self] in self?.handleFrame() }
        case .testPattern:
            built = TestPatternInput(device: device,
                                     preset: TestPatternInput.preset(id: source.id)) { [weak self] in
                self?.handleFrame()
            }
        }
        guard let built else {
            self.sender = nil
            self.currentSource = nil
            switch source.kind {
            case .camera:
                throw PipelineError.message("Could not open “\(source.displayName)”. Another app may be using it.")
            case .testPattern:
                throw PipelineError.message("Could not build the test pattern; this Mac may be out of video memory.")
            case .syphon:
                throw PipelineError.message("Could not connect to “\(source.displayName)”. Is it still publishing?")
            }
        }
        self.input = built
        self.currentSource = source

        // Always on. It is the only thing that can tell whether frames are actually being
        // delivered, and measured with it on and off the throughput was the same.
        monitor = NDIDeliveryMonitor(sourceName: config.ndiName)
    }

    /// YES once the local receiver has found and attached to our own source.
    var isDeliveryMonitored: Bool { monitor?.isConnected ?? false }

    /// Frames the local receiver has actually been given since the last call.
    func takeDeliveredFrameCount() -> Int { monitor?.takeFrameCount() ?? 0 }

    func stop() {
        queue.sync {
            encoder?.stop()
            encoder = nil
            pool = nil
            previewEncoder?.stop()
            previewEncoder = nil
            previewPool = nil
            pendingEncodes.removeAll()
        }
        input?.stop()
        input = nil
        currentSource = nil
        sourceSize = nil
        monitor?.stop()
        monitor = nil
        sender?.stop()
        sender = nil

        flightLock.lock()
        capturesPending = 0
        encodesInFlight = 0
        flightLock.unlock()
    }

    /// Applies a new configuration to a running pipeline. The encoder and pool are torn
    /// down lazily on the next frame, so a codec or resolution change takes effect
    /// immediately without dropping the NDI sender — receivers stay connected.
    func update(config newConfig: PipelineConfig) {
        let nameChanged = newConfig.ndiName != config.ndiName

        let rateChanged = newConfig.fpsCap != config.fpsCap
        queue.sync {
            let needsRebuild = newConfig.codec != config.codec
                || newConfig.resolution != config.resolution

                || newConfig.allowHardwareEncoder != config.allowHardwareEncoder
                || newConfig.h264Profile != config.h264Profile
            config = newConfig
            if needsRebuild {
                encoder?.stop()
                encoder = nil
                pool = nil
                previewEncoder?.stop()
                previewEncoder = nil
                previewPool = nil
                pendingEncodes.removeAll()
            } else if let encoder, newConfig.bitrateMbps > 0 {
                encoder.updateBitrate(Int(newConfig.bitrateMbps * 1_000_000))
            }
            if rateChanged { recomputeNominalRate() }
        }

        // The NDI source name is fixed at sender creation, so it is the one change that
        // has to bounce the sender.
        //
        // A codec change deliberately does *not*. Bouncing was tried, on the theory that
        // changing the FourCC underneath connected receivers caused corruption: measured,
        // it cost about 3 s of reconnect downtime and fixed nothing, because the first
        // frame of the new codec is already an IDR carrying its parameter sets. Switching
        // codecs is this app's main job; it should stay instant.
        if nameChanged, let source = currentSource {
            try? start(source: source)
        }
    }

    /// Writes the next outgoing frame to `url`. Encoding it stalls one frame, which is
    /// fine for a one-shot check and is why it is not on by default.
    func requestSnapshot(to url: URL) {
        queue.async { [weak self] in self?.pendingSnapshot = url }
    }

    func pollConnections() {
        guard let sender else { return }
        stats.noteConnections(sender.connectionCount)
    }

    // MARK: - Capture

    /// Standard rates a source is likely to actually be running at. A measured rate is
    /// snapped to the nearest of these so the declaration is a clean fraction rather than
    /// whatever the last second happened to average.
    /// Only rates that can actually be told apart by measuring. The broadcast fractional
    /// rates (23.976, 29.97, 59.94) are deliberately absent: they sit 0.1% from their
    /// integer neighbours, so snapping to them would be reading noise. Set those
    /// explicitly with the frame rate control if a receiver needs them.
    private static let standardRates: [Double] = [24, 25, 30, 48, 50, 60, 120]

    /// The rate declared to receivers, and the rate the encoder budgets for.
    ///
    /// Derived, never configured. It is the send rate limit when one is set, otherwise the
    /// source's own measured rate. Declaring a rate the stream does not deliver misleads
    /// receivers about playback timing and skews two encoder settings that are computed
    /// from it — the per-frame bit budget, and the keyframe interval in frames.
    /// The rate declared to receivers, and the rate the encoder budgets for.
    ///
    /// Derived, never configured directly. It is the frame rate setting, clamped by the
    /// source: asking for more frames than the source produces cannot conjure them, so
    /// requesting 60 from a 30 fps source sends *and declares* 30. Without the clamp the
    /// setting would reintroduce exactly the mismatch removing the old "declared frame
    /// rate" field was meant to end.
    private(set) var nominalFPS: Double = 60
    /// The source's own rate, once measured and settled.
    private(set) var measuredSourceFPS: Double?
    /// True when the frame rate setting asked for more than the source can supply.
    private(set) var frameRateLimitedBySource = false
    /// True when the rate came from measuring rather than from the setting.
    var nominalFPSIsMeasured: Bool { config.fpsCap == 0 || frameRateLimitedBySource }

    private var publishTimes: [CFAbsoluteTime] = []
    private var candidateRate: Double = 0
    private var candidateStreak = 0

    /// Called for every frame the source publishes.
    private func recordPublishTime() {
        let now = CFAbsoluteTimeGetCurrent()
        publishTimes.append(now)
        if publishTimes.count > 120 { publishTimes.removeFirst(publishTimes.count - 120) }

        // 30 samples is about half a second at 60 fps — enough to be meaningful without
        // taking so long that the first frames go out under a stale declaration.
        guard publishTimes.count >= 30, let first = publishTimes.first else { return }
        let span = now - first
        guard span > 0.2 else { return }
        adoptMeasuredRate(Double(publishTimes.count - 1) / span)
    }

    /// The source is measured whether or not a cap is set, because the cap needs something
    /// to be clamped against.
    private func adoptMeasuredRate(_ measured: Double) {
        let snapped = Self.standardRates.min(by: { abs($0 - measured) < abs($1 - measured) }) ?? measured
        // Only adopt once the same answer has come back repeatedly, so a momentary stall
        // does not re-declare the stream.
        if snapped == candidateRate {
            candidateStreak += 1
        } else {
            candidateRate = snapped
            candidateStreak = 1
        }
        guard candidateStreak >= 20, snapped != measuredSourceFPS else { return }
        measuredSourceFPS = snapped
        recomputeNominalRate()
    }

    private func recomputeNominalRate() {
        let previous = nominalFPS
        let requested = config.fpsCap

        if requested > 0 {
            if let source = measuredSourceFPS, requested > source {
                nominalFPS = source
                frameRateLimitedBySource = true
            } else {
                nominalFPS = requested
                frameRateLimitedBySource = false
            }
        } else {
            nominalFPS = measuredSourceFPS ?? previous
            frameRateLimitedBySource = false
        }

        // The NDI declaration is per-frame metadata and costs nothing to change, but the
        // encoder took the old rate as its bit budget and keyframe spacing. Rebuild only
        // for a real change; a step between neighbouring standard rates is not worth a
        // visible glitch.
        if previous > 0, abs(nominalFPS - previous) / previous > 0.25 {
            encoder?.stop()
            encoder = nil
            previewEncoder?.stop()
            previewEncoder = nil
        }
    }

    private func handleFrame() {
        // Counted here, not after the busy check, so "source" is what the input actually
        // produced rather than what we managed to keep up with.
        stats.noteSourcePublished()
        recordPublishTime()

        flightLock.lock()
        // One at a time. Allowing two was measured against a live 1080p60 source:
        // throughput did not improve (43.6 -> 41.2 fps) while end-to-end latency got much
        // worse (36 -> 56 ms), because the second frame simply waits its turn. Dropping
        // rather than queueing is the whole point.
        if capturesPending >= 1 {
            flightLock.unlock()
            stats.noteDrop()
            return
        }
        capturesPending += 1
        flightLock.unlock()

        queue.async { [weak self] in self?.captureAndSend() }
    }

    private func releaseCaptureSlot() {
        flightLock.lock()
        capturesPending = max(0, capturesPending - 1)
        flightLock.unlock()
    }

    private func captureAndSend() {
        let captureStart = CFAbsoluteTimeGetCurrent()
        guard let input, sender != nil else { releaseCaptureSlot(); return }
        guard let sourceTexture = input.newFrameTexture() else { releaseCaptureSlot(); return }

        stats.noteSourceSize(width: sourceTexture.width, height: sourceTexture.height)
        sourceSize = (sourceTexture.width, sourceTexture.height)

        if config.fpsCap > 0, !frameRateLimitedBySource {
            let interval = 1.0 / nominalFPS
            // Pace against a running deadline, not against the gap since the last frame
            // sent. Measuring the gap means any scheduling jitter that puts a frame a
            // fraction under the interval costs a whole source frame, and the error
            // compounds: a 60 fps source capped to 30 delivered 24.
            //
            // The tolerance is half a source interval, so the frame *nearest* each
            // deadline is taken rather than the first one past it.
            let sourceInterval = measuredSourceFPS.map { 1.0 / $0 } ?? interval
            if nextSendDeadline == 0 { nextSendDeadline = captureStart }
            if captureStart < nextSendDeadline - sourceInterval / 2 {
                // Not a drop: this frame was skipped on purpose to honour the frame rate
                // setting. Counting it as a drop made lowering the rate *raise* the
                // dropped figure, which reads as the opposite of what is happening.
                stats.noteRateLimited()
                releaseCaptureSlot()
                return
            }
            nextSendDeadline += interval
            // If the pipeline has fallen behind, resynchronise rather than trying to catch
            // up with a burst.
            if nextSendDeadline < captureStart { nextSendDeadline = captureStart + interval }
        }

        let (outWidth, outHeight) = outputSize(sourceWidth: sourceTexture.width, sourceHeight: sourceTexture.height)
        guard outWidth > 0, outHeight > 0 else { releaseCaptureSlot(); return }

        if pool == nil || pool?.width != outWidth || pool?.height != outHeight {
            pool = FramePool(device: device, commandQueue: commandQueue, width: outWidth, height: outHeight)
            encoder?.stop()
            encoder = nil
            previewEncoder?.stop()
            previewEncoder = nil
            previewPool = nil
        }
        guard let pool else { releaseCaptureSlot(); return }

        // The generated pattern prints the resolution on itself, and only the pipeline
        // knows what that will be after scaling.
        (input as? TestPatternInput)?.describeOutput(width: outWidth, height: outHeight)

        lastSentTime = captureStart
        let rate = frameRateFraction()

        let submitted = pool.copy(from: sourceTexture, orientation: config.orientation) { [weak self] frame, gpuMs in
            guard let self else { return }
            // Command buffers on one queue complete in order, so hopping back here keeps
            // frames in order too.
            self.queue.async {
                self.send(frame: frame, gpuMs: gpuMs, captureStart: captureStart,
                          width: outWidth, height: outHeight, rate: rate)
                self.releaseCaptureSlot()
            }
        }
        if !submitted { releaseCaptureSlot() }

        // The proxy stream rides alongside, from the same source texture so it picks up
        // the orientation but not the output resolution cap.
        if config.codec != .speedHQ { sendPreview(from: sourceTexture, rate: rate) }
    }

    /// The low-bandwidth stream the Advanced SDK requires a compressed sender to provide
    /// itself: progressive, longest dimension 640, and no faster than 45 Hz.
    private func sendPreview(from sourceTexture: MTLTexture, rate: (n: Int, d: Int)) {
        guard let sender else { return }

        let fps = Double(rate.n) / Double(max(rate.d, 1))
        // The SDK explicitly allows just dropping frames to reach the preview rate.
        let stride = max(1, Int((fps / Self.previewMaxFPS).rounded(.up)))
        previewFrameCounter += 1
        guard previewFrameCounter % stride == 0 else { return }

        let (width, height) = Self.previewSize(sourceWidth: sourceTexture.width,
                                               sourceHeight: sourceTexture.height)
        guard width > 0, height > 0 else { return }

        if previewPool == nil || previewPool?.width != width || previewPool?.height != height {
            previewPool = FramePool(device: device, commandQueue: commandQueue,
                                    width: width, height: height)
            previewEncoder?.stop()
            previewEncoder = nil
        }
        guard let previewPool else { return }

        let previewRate = (n: rate.n, d: rate.d * stride)

        if previewEncoder == nil {
            let target = sender.targetBitRate(for: config.codec, xres: width, yres: height,
                                              frameRateN: previewRate.n, frameRateD: previewRate.d)
            previewEncoder = Encoder(width: width,
                                     height: height,
                                     codec: config.codec == .hevc ? .hevc : .h264,
                                     bitrate: target > 0 ? target : 2_000_000,
                                     fps: fps / Double(stride),
                                     keyframeIntervalSeconds: Self.keyframeIntervalSeconds,
                                     allowHardware: config.allowHardwareEncoder,
                                     profile: config.h264Profile)
            previewEncoder?.onFrame = { [weak self] encoded in
                self?.deliverPreview(encoded, width: width, height: height, rate: previewRate)
            }
        }
        guard let previewEncoder else {
            if previewDebug, previewEncoderFailures == 0 {
                previewEncoderFailures += 1
                FileHandle.standardError.write("preview: encoder refused at \(width)x\(height)\n".data(using: .utf8)!)
            }
            return
        }

        flightLock.lock()
        previewEligible += 1
        // Not 1: HEVC rejects MaxFrameDelayCount = 0 on this hardware and buffers its
        // first frame, so a depth-1 gate deadlocked the proxy outright — one frame in,
        // none ever out, every later frame refused. Measured: sent 0 over 300 eligible.
        let blocked = previewEncodesInFlight >= Self.previewMaxEncodesInFlight
        if blocked { previewBlocked += 1 }
        let snapshot = (previewEligible, previewBlocked, previewNoFrame, previewSent, previewEncodesInFlight)
        if !blocked { previewEncodesInFlight += 1 }
        flightLock.unlock()
        if previewDebug, snapshot.0 % 60 == 0 {
            FileHandle.standardError.write("preview: eligible \(snapshot.0) blocked \(snapshot.1) nopoolframe \(snapshot.2) sent \(snapshot.3) inflight \(snapshot.4) hw \(previewEncoder.isHardware)\n".data(using: .utf8)!)
        }
        if blocked { return }
        // The proxy has its own receivers and its own IDR requests; without asking for
        // them separately a receiver that joined only the proxy waited out the whole GOP
        // (measured: 0.83 s of black before the first keyframe).
        //
        // The encoder's own GOP is counted in frames, which only matches the wall clock
        // while the proxy keeps up. When it cannot — HEVC at 640x360 measures 105 ms per
        // frame on Intel graphics — a 30-frame GOP stretches to many seconds and a joining
        // receiver sees nothing at all, so the interval is enforced here in time instead.
        let now = CFAbsoluteTimeGetCurrent()
        // A safety net at twice the interval, not a second scheduler: the encoder's own
        // GOP already does this correctly while the proxy keeps up, and forcing on top of
        // it doubled the proxy's keyframe rate (measured 2.16/s against a wanted 1/s).
        let keyframeOverdue = now - previewLastKeyframe >= Self.keyframeIntervalSeconds * 2
        let forceKeyframe = keyframeOverdue
            || sender.keyframeRequired(for: config.codec, xres: width, yres: height, preview: true)
        if forceKeyframe { previewLastKeyframe = now }
        let pts = Int64((CFAbsoluteTimeGetCurrent() - startTime) * 10_000_000)
        let submitted = previewPool.copy(from: sourceTexture, orientation: config.orientation) { [weak self] frame, _ in
            guard let self else { return }
            self.queue.async {
                previewEncoder.encode(pixelBuffer: frame.pixelBuffer, pts: pts, forceKeyframe: forceKeyframe)
            }
        }
        if !submitted {
            flightLock.lock()
            previewNoFrame += 1
            previewEncodesInFlight = max(0, previewEncodesInFlight - 1)
            flightLock.unlock()
        }
    }

    private func deliverPreview(_ encoded: EncodedFrame, width: Int, height: Int, rate: (n: Int, d: Int)) {
        defer {
            flightLock.lock()
            previewEncodesInFlight = max(0, previewEncodesInFlight - 1)
            flightLock.unlock()
        }
        queue.async { [weak self] in
            guard let self, let sender = self.sender, !encoded.data.isEmpty else { return }
            encoded.data.withUnsafeBytes { dataBytes in
                encoded.parameterSets.withUnsafeBytes { extraBytes in
                    sender.sendCompressed(dataBytes.baseAddress!,
                                          size: UInt32(encoded.data.count),
                                          extra: extraBytes.baseAddress,
                                          extraSize: UInt32(encoded.parameterSets.count),
                                          keyframe: encoded.isKeyframe,
                                          pts: encoded.pts,
                                          dts: encoded.dts,
                                          xres: width,
                                          yres: height,
                                          frameRateN: rate.n,
                                          frameRateD: rate.d,
                                          codec: self.config.codec,
                                          preview: true)
                    self.previewSent += 1
                }
            }
        }
    }

    /// Longest dimension 640, aspect preserved, both dimensions even for the encoder.
    static func previewSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (0, 0) }
        let scale = 640.0 / Double(max(sourceWidth, sourceHeight))
        if scale >= 1 { return (sourceWidth & ~1, sourceHeight & ~1) }
        let w = max(2, Int((Double(sourceWidth) * scale).rounded())) & ~1
        let h = max(2, Int((Double(sourceHeight) * scale).rounded())) & ~1
        return (w, h)
    }

    /// Runs once the GPU has produced the frame.
    private func send(frame: PooledFrame, gpuMs: Double, captureStart: CFAbsoluteTime,
                      width: Int, height: Int, rate: (n: Int, d: Int)) {
        guard let sender else { return }

        onPreviewFrame?(frame.texture)

        if let url = pendingSnapshot {
            pendingSnapshot = nil
            let written = Snapshot.write(texture: frame.texture, to: url, commandQueue: commandQueue)
            DispatchQueue.main.async { [weak self] in self?.onSnapshot?(written ? url : nil) }
        }

        if config.codec == .speedHQ {
            let sendStart = CFAbsoluteTimeGetCurrent()
            sender.sendUncompressedSurface(frame.surface,
                                           ignoreAlpha: config.ignoreAlpha,
                                           frameRateN: rate.n,
                                           frameRateD: rate.d)
            let now = CFAbsoluteTimeGetCurrent()
            // SpeedHQ is encoded inside NDI, so the bytes actually put on the wire are not
            // observable from here; the target rate reported below is the SDK's estimate.
            stats.noteSentFrame(bytes: 0,
                                keyframe: true,
                                gpuMs: gpuMs,
                                encodeMs: nil,
                                sendMs: (now - sendStart) * 1000.0,
                                totalMs: (now - captureStart) * 1000.0,
                                width: width,
                                height: height)
            stats.noteTargetBitrate(bitsPerSecond: sender.targetBitRate(for: .speedHQ,
                                                                       xres: width, yres: height,
                                                                       frameRateN: rate.n, frameRateD: rate.d))
            return
        }

        encodeAndSend(frame: frame, gpuMs: gpuMs, captureStart: captureStart,
                      width: width, height: height, rate: rate, sender: sender)
    }

    private func encodeAndSend(frame: PooledFrame,
                               gpuMs: Double,
                               captureStart: CFAbsoluteTime,
                               width: Int,
                               height: Int,
                               rate: (n: Int, d: Int),
                               sender: NDISender) {
        let targetBitrate = sender.targetBitRate(for: config.codec,
                                                 xres: width, yres: height,
                                                 frameRateN: rate.n, frameRateD: rate.d)
        stats.noteTargetBitrate(bitsPerSecond: targetBitrate)

        if encoder == nil {
            let bitrate = config.bitrateMbps > 0
                ? Int(config.bitrateMbps * 1_000_000)
                : (targetBitrate > 0 ? targetBitrate : 25_000_000)

            let built = Encoder(width: width,
                                height: height,
                                codec: config.codec == .hevc ? .hevc : .h264,
                                bitrate: bitrate,
                                fps: nominalFPS,
                                keyframeIntervalSeconds: Self.keyframeIntervalSeconds,
                                allowHardware: config.allowHardwareEncoder,
                                profile: config.h264Profile)
            guard let built else {
                let codecName = config.codec == .hevc ? "HEVC" : "H.264"
                DispatchQueue.main.async { [weak self] in
                    self?.onError?("VideoToolbox refused to create a \(codecName) encoder at \(width)×\(height).")
                }
                return
            }
            built.onFrame = { [weak self] encoded in
                self?.deliver(encoded, width: width, height: height, rate: rate)
            }
            encoder = built
        }
        guard let encoder else { return }

        flightLock.lock()
        // Two in flight lets the encoder overlap with the next capture without letting a
        // slow encoder build a backlog that would show up as latency downstream.
        if encodesInFlight >= 2 {
            flightLock.unlock()
            stats.noteDrop()
            return
        }
        encodesInFlight += 1
        flightLock.unlock()

        // The SDK tells us when a receiver has joined or lost sync and needs an IDR.
        let forceKeyframe = sender.keyframeRequired(for: config.codec, xres: width, yres: height, preview: false)
        let pts = Int64((CFAbsoluteTimeGetCurrent() - startTime) * 10_000_000)

        pendingEncodes[pts] = (captureStart, gpuMs)
        encoder.encode(pixelBuffer: frame.pixelBuffer, pts: pts, forceKeyframe: forceKeyframe)
    }

    private func deliver(_ encoded: EncodedFrame, width: Int, height: Int, rate: (n: Int, d: Int)) {
        defer {
            flightLock.lock()
            encodesInFlight = max(0, encodesInFlight - 1)
            flightLock.unlock()
        }

        // The callback arrives on VideoToolbox's thread; hop back so the context lookup
        // and the sender are only ever touched from the capture queue.
        queue.async { [weak self] in
            guard let self, let sender = self.sender, !encoded.data.isEmpty else { return }

            let context = self.pendingEncodes.removeValue(forKey: encoded.pts)
            if self.pendingEncodes.count > 64 { self.pendingEncodes.removeAll() }

            let sendStart = CFAbsoluteTimeGetCurrent()
            encoded.data.withUnsafeBytes { dataBytes in
                encoded.parameterSets.withUnsafeBytes { extraBytes in
                    sender.sendCompressed(dataBytes.baseAddress!,
                                          size: UInt32(encoded.data.count),
                                          extra: extraBytes.baseAddress,
                                          extraSize: UInt32(encoded.parameterSets.count),
                                          keyframe: encoded.isKeyframe,
                                          pts: encoded.pts,
                                          dts: encoded.dts,
                                          xres: width,
                                          yres: height,
                                          frameRateN: rate.n,
                                          frameRateD: rate.d,
                                          codec: self.config.codec,
                                          preview: false)
                }
            }
            let now = CFAbsoluteTimeGetCurrent()

            self.stats.noteSentFrame(
                bytes: encoded.data.count + (encoded.isKeyframe ? encoded.parameterSets.count : 0),
                keyframe: encoded.isKeyframe,
                gpuMs: context?.gpuMs ?? 0,
                encodeMs: encoded.encodeMilliseconds,
                sendMs: (now - sendStart) * 1000.0,
                totalMs: context.map { (now - $0.captureStart) * 1000.0 } ?? 0,
                width: width,
                height: height)
        }
    }

    // MARK: - Helpers

    /// Fixed, not a setting. NDI's own documentation recommends "an I-Frame interval of
    /// between one and two seconds" for both H.264 and H.265, and one second is the
    /// responsive end of that. It was adjustable and the range made no observable
    /// difference: recovery does not run through this timer at all but through
    /// `NDIlib_send_is_keyframe_required`, which is polled before every encode and gets a
    /// keyframe to a joining receiver within 0.03 s whatever this is set to. All the
    /// setting changed was bandwidth, by about 4% across its whole useful range.
    static let keyframeIntervalSeconds = 1.0

    /// Below this width VideoToolbox refuses the Quick Sync encoder on this class of Mac
    /// and silently substitutes a software one, which buffers for hundreds of milliseconds
    /// — measured at ~400 ms per frame against ~6 ms in hardware. Small sources are scaled
    /// up to keep the hardware path, since a software fallback would make every latency
    /// number below meaningless. Measured by Tools/encoder_test: 640×96 encodes in
    /// hardware, 600×360 does not, so the constraint is width alone.
    private static let minimumHardwareEncodeWidth = 640

    /// True when the last frame was scaled up purely to satisfy the constraint above.
    private(set) var didRaiseResolutionForEncoder = false

    private func outputSize(sourceWidth: Int, sourceHeight: Int) -> (Int, Int) {
        var width: Int
        var height: Int
        switch config.resolution {
        case .native:
            width = sourceWidth
            height = sourceHeight
        case .maxHeight(let cap) where sourceHeight > cap && sourceHeight > 0:
            // Aspect preserved, so this only ever removes pixels.
            width = Int((Double(sourceWidth) * Double(cap) / Double(sourceHeight)).rounded())
            height = cap
        case .maxHeight:
            // Already at or below the cap; leave it alone rather than upscaling.
            width = sourceWidth
            height = sourceHeight
        }

        didRaiseResolutionForEncoder = false
        if config.codec != .speedHQ, width > 0, width < Self.minimumHardwareEncodeWidth {
            height = Int((Double(height) * Double(Self.minimumHardwareEncodeWidth) / Double(width)).rounded())
            width = Self.minimumHardwareEncodeWidth
            didRaiseResolutionForEncoder = true
        }

        // H.264 and HEVC want even dimensions; Syphon sources are not guaranteed to have
        // them (a Millumin composition can be any size at all).
        return (width & ~1, height & ~1)
    }

    private func frameRateFraction() -> (n: Int, d: Int) {
        // nominalFPS already is the setting, clamped by the source. Reading config.fpsCap
        // here instead put the unclamped setting on the wire while every internal readout
        // showed the clamped one — the declaration was wrong in exactly the place it
        // mattered and right everywhere it was easy to check.
        let fps = nominalFPS
        // Keep the broadcast rates exact rather than letting them round to 30 or 60.
        switch fps {
        case 23.976: return (24000, 1001)
        case 29.97:  return (30000, 1001)
        case 59.94:  return (60000, 1001)
        default:     return (Int((fps * 1000).rounded()), 1000)
        }
    }
}

enum PipelineError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
