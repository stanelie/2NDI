import Foundation

// What the stats panel shows, sampled once a second.
struct StatsSnapshot {
    var sourceFPS = 0.0          // frames Syphon published
    var sentFPS = 0.0            // frames that reached the wire
    var droppedPerSecond = 0.0   // frames the pipeline could not keep up with
    var droppedTotal = 0
    /// Frames skipped deliberately to honour the frame rate setting. Kept apart from
    /// drops: one means the machine is struggling, the other means it is obeying.
    var rateLimitedPerSecond = 0.0

    var gpuMillisecondsAvg = 0.0     // scale/copy out of the Syphon surface
    var encodeMillisecondsAvg = 0.0  // VideoToolbox submit to callback (HX only)
    var sendMillisecondsAvg = 0.0    // time inside the NDI send call
    var totalMillisecondsAvg = 0.0   // Syphon callback to send returning
    var totalMillisecondsPeak = 0.0

    var measuredMbps = 0.0       // exact, from encoded frame sizes (HX only)
    var targetMbps = 0.0         // what the SDK suggests for this format
    var keyframesPerSecond = 0.0

    var sourceWidth = 0
    var sourceHeight = 0
    var outputWidth = 0
    var outputHeight = 0
    var connections = 0
}

// Accumulates per-frame timings on the capture thread and hands the UI a snapshot once a
// second. The whole point of this app is the comparison, so these numbers are measured
// rather than assumed: every figure below is timed at the moment it happens.
final class Stats {

    private let lock = NSLock()
    private var windowStart = CFAbsoluteTimeGetCurrent()

    private var sourceFrames = 0
    private var sentFrames = 0
    private var droppedInWindow = 0
    private var droppedTotal = 0
    private var rateLimitedInWindow = 0
    private var keyframes = 0
    private var bytesSent = 0

    private var gpuTotal = 0.0
    private var encodeTotal = 0.0
    private var encodeSamples = 0
    private var sendTotal = 0.0
    private var totalTotal = 0.0
    private var totalPeak = 0.0

    private var latest = StatsSnapshot()

    /// Every frame the Syphon server publishes, counted before any decision to process or
    /// drop it. This is the source's real rate; anything counted later would report our own
    /// throughput while calling it the source's.
    func noteSourcePublished() {
        lock.lock()
        sourceFrames += 1
        lock.unlock()
    }

    func noteSourceSize(width: Int, height: Int) {
        lock.lock()
        latest.sourceWidth = width
        latest.sourceHeight = height
        lock.unlock()
    }

    func noteRateLimited() {
        lock.lock()
        rateLimitedInWindow += 1
        lock.unlock()
    }

    func noteDrop() {
        lock.lock()
        droppedInWindow += 1
        droppedTotal += 1
        lock.unlock()
    }

    func noteSentFrame(bytes: Int,
                       keyframe: Bool,
                       gpuMs: Double,
                       encodeMs: Double?,
                       sendMs: Double,
                       totalMs: Double,
                       width: Int,
                       height: Int) {
        lock.lock()
        sentFrames += 1
        bytesSent += bytes
        if keyframe { keyframes += 1 }
        gpuTotal += gpuMs
        if let encodeMs { encodeTotal += encodeMs; encodeSamples += 1 }
        sendTotal += sendMs
        totalTotal += totalMs
        totalPeak = max(totalPeak, totalMs)
        latest.outputWidth = width
        latest.outputHeight = height
        lock.unlock()
    }

    func noteConnections(_ count: Int) {
        lock.lock(); latest.connections = count; lock.unlock()
    }

    func noteTargetBitrate(bitsPerSecond: Int) {
        lock.lock(); latest.targetMbps = Double(bitsPerSecond) / 1_000_000.0; lock.unlock()
    }

    /// Closes the current window and returns the result. Call once per second.
    func sample() -> StatsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = max(now - windowStart, 0.001)

        var snapshot = latest
        snapshot.sourceFPS = Double(sourceFrames) / elapsed
        snapshot.sentFPS = Double(sentFrames) / elapsed
        snapshot.droppedPerSecond = Double(droppedInWindow) / elapsed
        snapshot.rateLimitedPerSecond = Double(rateLimitedInWindow) / elapsed
        snapshot.droppedTotal = droppedTotal
        snapshot.keyframesPerSecond = Double(keyframes) / elapsed
        snapshot.measuredMbps = Double(bytesSent) * 8.0 / elapsed / 1_000_000.0

        let sent = max(sentFrames, 1)
        snapshot.gpuMillisecondsAvg = gpuTotal / Double(sent)
        snapshot.encodeMillisecondsAvg = encodeSamples > 0 ? encodeTotal / Double(encodeSamples) : 0
        snapshot.sendMillisecondsAvg = sendTotal / Double(sent)
        snapshot.totalMillisecondsAvg = totalTotal / Double(sent)
        snapshot.totalMillisecondsPeak = totalPeak

        windowStart = now
        sourceFrames = 0; sentFrames = 0; droppedInWindow = 0; rateLimitedInWindow = 0
        keyframes = 0; bytesSent = 0
        gpuTotal = 0; encodeTotal = 0; encodeSamples = 0; sendTotal = 0; totalTotal = 0; totalPeak = 0
        latest = snapshot

        return snapshot
    }

    func reset() {
        lock.lock()
        windowStart = CFAbsoluteTimeGetCurrent()
        sourceFrames = 0; sentFrames = 0; droppedInWindow = 0; droppedTotal = 0
        rateLimitedInWindow = 0; keyframes = 0; bytesSent = 0
        gpuTotal = 0; encodeTotal = 0; encodeSamples = 0; sendTotal = 0; totalTotal = 0; totalPeak = 0
        latest = StatsSnapshot()
        lock.unlock()
    }
}
