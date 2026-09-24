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
        if isKeyframe, bitstreamSummary == nil, codec == .h264 {
            bitstreamSummary = Self.describeH264(parameterSets: parameterSets)
        }

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


    /// Profile, level and chroma format, read back out of the SPS the encoder actually
    /// produced.
    ///
    /// Worth showing rather than inferring, because VideoToolbox picks the *level* itself
    /// from the resolution and frame rate, and the level is what a limited hardware decoder
    /// refuses. Measured from this encoder: 1080p60 asks for level 4.2, 1080p30 for 4.0,
    /// 720p60 for 3.2. Plenty of decoders stop at 4.1, which makes 1080p60 the single
    /// setting that fails while every other one works — a pattern that looks arbitrary
    /// until the level is visible.
    private(set) var bitstreamSummary: String?

    private static func describeH264(parameterSets: Data) -> String? {
        // Find the SPS (NAL type 7) between Annex B start codes.
        let bytes = [UInt8](parameterSets)
        var sps: [UInt8] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 {
                let body = i + 3
                if body < bytes.count, bytes[body] & 0x1f == 7 {
                    var end = body + 1
                    while end + 3 < bytes.count,
                          !(bytes[end] == 0 && bytes[end+1] == 0 && bytes[end+2] == 1) { end += 1 }
                    sps = Array(bytes[(body + 1)..<min(end + 3, bytes.count)])
                    break
                }
                i = body
            } else { i += 1 }
        }
        guard sps.count >= 3 else { return nil }

        // Strip emulation-prevention bytes before reading any Exp-Golomb fields.
        var rbsp: [UInt8] = []
        for (k, b) in sps.enumerated() {
            if k >= 2, b == 3, sps[k-1] == 0, sps[k-2] == 0 { continue }
            rbsp.append(b)
        }

        let profileIDC = Int(rbsp[0])
        let levelIDC = Int(rbsp[2])
        let profile: String
        switch profileIDC {
        case 66:  profile = "Baseline"
        case 77:  profile = "Main"
        case 100: profile = "High"
        case 110: profile = "High 10"
        case 122: profile = "High 4:2:2"
        case 244: profile = "High 4:4:4"
        default:  profile = "profile \(profileIDC)"
        }

        var chroma = "4:2:0"
        if profileIDC == 100 || profileIDC == 110 || profileIDC == 122 || profileIDC == 244 {
            var reader = BitReader(rbsp)
            _ = reader.bits(24)
            _ = reader.ue()
            switch reader.ue() {
            case 0: chroma = "4:0:0"
            case 1: chroma = "4:2:0"
            case 2: chroma = "4:2:2"
            case 3: chroma = "4:4:4"
            default: chroma = "?"
            }
        }

        return String(format: "%@ profile, level %.1f, %@", profile, Double(levelIDC) / 10.0, chroma)
    }

    private struct BitReader {
        let d: [UInt8]
        var pos = 0
        init(_ d: [UInt8]) { self.d = d }
        mutating func bit() -> UInt32 {
            guard pos < d.count * 8 else { return 0 }
            let v = UInt32((d[pos >> 3] >> (7 - (pos & 7))) & 1)
            pos += 1
            return v
        }
        mutating func bits(_ c: Int) -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<c { v = (v << 1) | bit() }
            return v
        }
        mutating func ue() -> UInt32 {
            var z = 0
            while bit() == 0 && z < 32 { z += 1 }
            return z == 0 ? 0 : ((1 << UInt32(z)) - 1) + bits(z)
        }
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
