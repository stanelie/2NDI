// Unattended check that the trial notice is real and that LibraryLog catches it.
//
// The in-app "Simulate Trial Expiry" exercises the banner, the log line and the
// notification, but it cannot prove the one thing only the library knows: that it really
// prints that sentence when the development licence runs out. This holds a stream open
// past the 30-minute mark and reports what actually happened.
//
//   soak [minutes] [h264|speedhq]      default 35 h264
//
// The codec matters. The limit is on the Advanced SDK's compressed passthrough, so an
// uncompressed stream may never trip it — which is itself worth knowing, because if
// Advanced+SpeedHQ runs unlimited then long comparison sessions do not need the base SDK
// at all. Run both and find out.
import Foundation
import CoreVideo

let arguments = CommandLine.arguments
let minutes = arguments.count > 1 ? (Double(arguments[1]) ?? 35) : 35
let useHX = arguments.count > 2 ? (arguments[2].lowercased() != "speedhq") : true
let label = useHX ? "h264" : "speedhq"
let started = Date()

func log(_ text: String) {
    let stamp = String(format: "%6.1f min", Date().timeIntervalSince(started) / 60)
    // Straight to the real stderr: stdout is spliced by LibraryLog.
    FileHandle.standardError.write(Data("[\(stamp)] [\(label)] \(text)\n".utf8))
}

var noticeSeenAt: Date?
LibraryLog.shared.observe { text in
    guard text.contains(LibraryLog.trialExpiryMarker), noticeSeenAt == nil else { return }
    noticeSeenAt = Date()
    log("*** TRIAL NOTICE FROM THE LIBRARY — LibraryLog caught it ***")
}

var loadError: NSString?
guard NDISender.load(.advanced, error: &loadError) else {
    log("could not load the Advanced SDK: \(loadError ?? "unknown")")
    exit(1)
}
guard let sender = NDISender(name: "TrialSoak-\(label)") else {
    log("could not create the sender")
    exit(1)
}

// Wide enough for the hardware encoder; below 640 VideoToolbox drops to software.
let width = 1280, height = 720
var buffer: CVPixelBuffer?
CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
guard let pixelBuffer = buffer,
      let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
    log("could not allocate a frame")
    exit(1)
}

var framesSent = 0
var encoder: Encoder?

if useHX {
    guard let built = Encoder(width: width, height: height, codec: .h264,
                              bitrate: 8_000_000, fps: 30, keyframeIntervalSeconds: 1) else {
        log("VideoToolbox refused an encoder")
        exit(1)
    }
    built.onFrame = { frame in
        frame.data.withUnsafeBytes { data in
            frame.parameterSets.withUnsafeBytes { extra in
                sender.sendCompressed(data.baseAddress!, size: UInt32(frame.data.count),
                                      extra: extra.baseAddress, extraSize: UInt32(frame.parameterSets.count),
                                      keyframe: frame.isKeyframe, pts: frame.pts, dts: frame.dts,
                                      xres: width, yres: height, frameRateN: 30, frameRateD: 1,
                                      codec: .h264)
            }
        }
        framesSent += 1
    }
    encoder = built
    log("sending \"TrialSoak-\(label)\" as H.264 HX (hardware=\(built.isHardware)) for \(Int(minutes)) min")
} else {
    log("sending \"TrialSoak-\(label)\" as uncompressed/SpeedHQ for \(Int(minutes)) min")
}

var lastReport = Date()
var tick = 0
while Date().timeIntervalSince(started) < minutes * 60 {
    if let encoder {
        // Vary the content so the encoder cannot collapse the stream to nothing.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(tick % 255), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let force = sender.keyframeRequired(for: .h264, xres: width, yres: height)
        encoder.encode(pixelBuffer: pixelBuffer, pts: Int64(tick) * 333_333, forceKeyframe: force)
    } else {
        sender.sendUncompressedSurface(surface, ignoreAlpha: true, frameRateN: 30, frameRateD: 1)
        framesSent += 1
    }
    tick += 1

    // Short runs are for probing the expiry boundary, so sample often enough to see it.
    let reportInterval: TimeInterval = minutes <= 5 ? 10 : 300
    if Date().timeIntervalSince(lastReport) >= reportInterval {
        lastReport = Date()
        log("frames \(framesSent), connections \(sender.connectionCount)"
            + (noticeSeenAt == nil ? "" : ", notice seen"))
    }
    usleep(33_000)
}

encoder?.stop()
log("finished after \(framesSent) frames")
if let noticeSeenAt {
    let at = noticeSeenAt.timeIntervalSince(started) / 60
    log("RESULT: the library printed the notice at \(String(format: "%.1f", at)) min and it was detected.")
} else {
    log("RESULT: no notice in \(Int(minutes)) min on the \(label) path.")
    if useHX {
        log("        That is the path the banner exists for, so the marker or the capture")
        log("        needs revisiting before trusting it in a show.")
    } else {
        log("        Suggests Advanced+SpeedHQ is not time limited, so long SpeedHQ")
        log("        sessions would not need the base SDK.")
    }
}
sender.stop()
exit(noticeSeenAt == nil ? 2 : 0)
