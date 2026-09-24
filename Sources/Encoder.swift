import Foundation
import VideoToolbox
import CoreMedia

// One encoded frame, already converted to the Annex B layout NDI HX expects.
struct EncodedFrame {
    let data: Data              // Annex B bitstream, start-code separated
    let parameterSets: Data     // SPS/PPS (or VPS/SPS/PPS), also Annex B; only sent on keyframes
    let isKeyframe: Bool
    let pts: Int64              // 100 ns units, NDI's timebase
    let dts: Int64
    let encodeMilliseconds: Double
}

// Wraps a VTCompressionSession configured for live streaming: hardware where available,
// no frame reordering, and no lookahead — anything that buffers frames would show up as
// latency in the comparison this app exists to make.
final class Encoder {

    enum Codec {
        case h264, hevc
        var cmType: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
    }

    /// H.264 profile. Baseline forbids CABAC and B-frames, so it is the cheapest to decode
    /// — which matters when the receiver is a small board rather than a desktop. High
    /// compresses best. HEVC ignores this and always uses Main.
    enum Profile: Int, CaseIterable {
        case baseline = 0, main = 1, high = 2

        var label: String {
            switch self {
            case .baseline: return "Baseline (cheapest to decode)"
            case .main:     return "Main"
            case .high:     return "High (best compression)"
            }
        }
    }

    let width: Int
    let height: Int
    let codec: Codec

    /// Called on VideoToolbox's own callback thread, in encode order.
    var onFrame: ((EncodedFrame) -> Void)?
    /// Set when the session reports a hardware encoder was refused; surfaced in the stats panel.
    private(set) var isHardware = false

    private var session: VTCompressionSession?
    private var submitTimes = [Int64: CFAbsoluteTime]()
    private let submitLock = NSLock()

    /// - Parameter allowHardware: pass false to force VideoToolbox's software encoder.
    ///   Only useful for comparing the two; the hardware block is otherwise always wanted.
    init?(width: Int, height: Int, codec: Codec, bitrate: Int, fps: Double,
          keyframeIntervalSeconds: Double, allowHardware: Bool = true,
          profile: Profile = .high) {
        let profileLevel: CFString
        switch (codec, profile) {
        case (.hevc, _):        profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel
        case (.h264, .baseline): profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel
        case (.h264, .main):     profileLevel = kVTProfileLevel_H264_Main_AutoLevel
        case (.h264, .high):     profileLevel = kVTProfileLevel_H264_High_AutoLevel
        }
        self.width = width
        self.height = height
        self.codec = codec

        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: allowHardware
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.cmType,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created)

        guard status == noErr, let session = created else { return nil }
        self.session = session

        var usingHardware: CFBoolean?
        if VTSessionCopyProperty(session,
                                 key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: kCFAllocatorDefault,
                                 valueOut: &usingHardware) == noErr,
           let flag = usingHardware {
            isHardware = CFBooleanGetValue(flag)
        }

        set(kVTCompressionPropertyKey_RealTime, true)
        // B-frames would reorder output and add at least one frame of latency for no
        // benefit here; the SDK docs recommend against them for the same reason.
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_ProfileLevel, profileLevel)
        // Emit each frame as soon as it is encoded instead of holding a lookahead window.
        // Measured at 1080p: mean encode latency 21.5 ms without, 14.6 ms with.
        //
        // Do NOT also set MaximizePowerEfficiency to false here "for latency" — measured
        // on the same machine it tripled it, to 45 ms.
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeIntervalSeconds)
        // A hard cap alongside the duration keeps GOPs bounded if the source stalls.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, max(1, Int(fps * keyframeIntervalSeconds)))

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// A property VideoToolbox does not support is otherwise accepted silently and simply
    /// never takes effect, which has bitten this project more than once.
    private func set(_ key: CFString, _ value: Any) {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        if status != noErr {
            FileHandle.standardError.write(Data("Encoder: \(key) rejected, status \(status)\n".utf8))
        }
    }

    /// Adjust the bitrate without rebuilding the session, so a sweep does not restart the stream.
    func updateBitrate(_ bitrate: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
    }

    /// - Parameter pts: presentation time in 100 ns units.
    func encode(pixelBuffer: CVPixelBuffer, pts: Int64, forceKeyframe: Bool) {
        guard let session else { return }

        submitLock.lock()
        submitTimes[pts] = CFAbsoluteTimeGetCurrent()
        submitLock.unlock()

        let time = CMTime(value: pts, timescale: 10_000_000)
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer else { return }
                self?.handle(sampleBuffer)
            }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        onFrame = nil
    }

    deinit { stop() }

    // MARK: - AVCC to Annex B

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsTicks = pts.isValid ? pts.convertScale(10_000_000, method: .default).value : 0
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let dtsTicks = dts.isValid ? dts.convertScale(10_000_000, method: .default).value : ptsTicks

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            if CFDictionaryContainsKey(dict, key) { isKeyframe = false }
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block,
                                          atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == noErr,
              let base = pointer else { return }

        let nalHeaderLength = Self.nalUnitHeaderLength(format: format, codec: codec)
        let annexB = Self.annexB(from: UnsafeRawPointer(base), length: totalLength, nalHeaderLength: nalHeaderLength)

        // The parameter set has to accompany every keyframe: an NDI receiver can join at
        // any IDR and has no earlier bitstream to have learned it from.
        let parameterSets = isKeyframe ? Self.parameterSets(format: format, codec: codec) : Data()

        submitLock.lock()
        let submitted = submitTimes.removeValue(forKey: ptsTicks)
        // Guard against unbounded growth if a frame is ever dropped without a callback.
        if submitTimes.count > 64 { submitTimes.removeAll() }
        submitLock.unlock()

        let elapsed = submitted.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000.0 } ?? 0

        onFrame?(EncodedFrame(data: annexB,
                              parameterSets: parameterSets,
                              isKeyframe: isKeyframe,
                              pts: ptsTicks,
                              dts: dtsTicks,
                              encodeMilliseconds: elapsed))
    }

    /// VideoToolbox emits length-prefixed NALs; the prefix width comes from the format description.
    private static func nalUnitHeaderLength(format: CMFormatDescription, codec: Codec) -> Int {
        var length: Int32 = 4
        if codec == .h264 {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: &length)
        } else {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: &length)
        }
        return Int(length)
    }

    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    private static func annexB(from base: UnsafeRawPointer, length: Int, nalHeaderLength: Int) -> Data {
        var out = Data()
        out.reserveCapacity(length + 16)

        var offset = 0
        while offset + nalHeaderLength <= length {
            var nalLength = 0
            for i in 0..<nalHeaderLength {
                nalLength = (nalLength << 8) | Int(base.load(fromByteOffset: offset + i, as: UInt8.self))
            }
            offset += nalHeaderLength
            guard nalLength > 0, offset + nalLength <= length else { break }

            out.append(startCode)
            out.append(UnsafeBufferPointer(start: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                                           count: nalLength))
            offset += nalLength
        }
        return out
    }

    private static func parameterSets(format: CMFormatDescription, codec: Codec) -> Data {
        var count = 0
        let countStatus: OSStatus
        if codec == .h264 {
            countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        guard countStatus == noErr else { return Data() }

        var out = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if codec == .h264 {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer, size > 0 else { continue }
            out.append(startCode)
            out.append(UnsafeBufferPointer(start: pointer, count: size))
        }
        return out
    }
}
