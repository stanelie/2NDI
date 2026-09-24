// Runs the real Pipeline headlessly against a live Syphon source and prints its stats once
// a second. The app shows the same numbers, but only in a window — this makes them
// scriptable, so an optimisation can be A/B'd against an actual 60 fps source instead of
// being argued about.
//
//   profile <source substring> [seconds] [h264|hevc|speedhq]
import Foundation
import Cocoa
import Metal

let arguments = CommandLine.arguments
let wanted = arguments.count > 1 ? arguments[1] : "Canvas"
let seconds = arguments.count > 2 ? Int(arguments[2])! : 15
let codecName = arguments.count > 3 ? arguments[3] : "h264"
let orientationName = arguments.count > 4 ? arguments[4] : "flipv"
let capArgument = arguments.count > 6 ? (Double(arguments[6]) ?? 0) : 0
// 8th argument: switch codec mid-stream after N seconds, to reproduce a live format change.
let switchAfter = arguments.count > 7 ? (Double(arguments[7]) ?? 0) : 0

// Unbuffered: a crash must not swallow the last thing printed.
setvbuf(stdout, nil, _IONBF, 0)

guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(1) }
print("metal ok")

var loadError: NSString?
guard NDISender.load(.advanced, error: &loadError) else {
    print("could not load NDI: \(loadError ?? "unknown")"); exit(1)
}

print("ndi loaded")
var config = PipelineConfig()
config.ndiName = "Profile"
config.codec = codecName == "hevc" ? .hevc : (codecName == "speedhq" ? .speedHQ : .h264)
config.orientation = orientationName == "none" ? .none : .flipVertical
// 5th argument turns the delivery monitor on, to measure what it costs.
config.fpsCap = capArgument

guard let pipeline = Pipeline(device: device, config: config) else {
    print("could not create the pipeline"); exit(1)
}
pipeline.onError = { print("pipeline error: \($0)") }

print("pipeline created")
// The Syphon directory needs a run loop before it knows about anything.
let deadline = Date().addingTimeInterval(3)
while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }

guard let source = InputSource.available().first(where: {
    $0.displayName.localizedCaseInsensitiveContains(wanted)
}) else {
    print("no input matching \"\(wanted)\"; available: \(InputSource.available().map(\.displayName))")
    exit(1)
}
print("profiling \(source.displayName), codec \(codecName), orientation \(orientationName), \(seconds) s")
try! pipeline.start(source: source)

// Plain concatenation: String(format:) with %s and a Swift String is undefined and
// segfaults, which cost a debugging round when this tool was first written.
print("   t     src    out   drop   rlim   decl   conn     gpu   total")
var tick = 0
if switchAfter > 0 {
    Timer.scheduledTimer(withTimeInterval: switchAfter, repeats: false) { _ in
        var next = pipeline.config
        next.codec = (next.codec == .speedHQ) ? .h264 : .speedHQ
        print("--- switching codec to \(next.codec == .h264 ? "h264" : "speedhq") ---")
        fflush(stdout)
        pipeline.update(config: next)
    }
}
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
    tick += 1
    pipeline.pollConnections()
    let s = pipeline.stats.sample()
    print(String(format: "%4ds  %6.1f %6.1f %6.1f %6.1f %6.2f %6.0f  %6.2f %6.2f",
                 tick, s.sourceFPS, s.sentFPS, s.droppedPerSecond, s.rateLimitedPerSecond,
                 pipeline.nominalFPS, Double(s.connections), s.gpuMillisecondsAvg, s.totalMillisecondsAvg))
    fflush(stdout)
    if tick >= seconds {
        pipeline.stop()
        timer.invalidate()
        exit(0)
    }
}
RunLoop.main.run()
