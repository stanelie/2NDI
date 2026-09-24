import Foundation

/// Captures whatever the NDI library writes to stdout/stderr and hands it to the app.
///
/// This exists for one specific failure: the Advanced SDK's development licence stops
/// delivering a stream after 30 minutes, and the *only* signal is a line the library
/// prints. `NDIlib_send_send_video_v2` keeps returning normally and the connection count
/// stays up, so from the app's point of view nothing has gone wrong — meanwhile every
/// receiver goes black. Without surfacing this the app looks broken for no visible reason.
///
/// The library is loaded with dlopen into this process, so its output goes to our own file
/// descriptors; the pipe below is spliced in front of them and everything read is written
/// straight back out, so nothing that used to appear in a terminal is lost.
final class LibraryLog {

    static let shared = LibraryLog()

    /// Matched verbatim against the notice in libndi_advanced. Deliberately a fragment of
    /// the sentence rather than the whole thing, so a reworded build still trips it.
    static let trialExpiryMarker = "will run on a stream for 30 minutes"

    private let lock = NSLock()
    private var handlers: [(String) -> Void] = []
    private var captures: [Capture] = []

    private init() {}

    /// Text arrives in whatever chunks the library writes, not necessarily whole lines —
    /// the notice has no trailing newline in some builds — so handlers should match on a
    /// substring and de-duplicate rather than expect one call per line.
    func observe(_ handler: @escaping (String) -> Void) {
        lock.lock()
        handlers.append(handler)
        let needsStart = captures.isEmpty
        lock.unlock()

        if needsStart {
            let deliver: (String) -> Void = { [weak self] text in
                guard let self else { return }
                self.lock.lock()
                let current = self.handlers
                self.lock.unlock()
                for handler in current { handler(text) }
            }
            lock.lock()
            captures = [Capture(fd: STDERR_FILENO, onText: deliver),
                        Capture(fd: STDOUT_FILENO, onText: deliver)].compactMap { $0 }
            lock.unlock()
        }
    }

    private final class Capture {
        private let originalFD: Int32

        init?(fd: Int32, onText: @escaping (String) -> Void) {
            var ends: [Int32] = [0, 0]
            guard pipe(&ends) == 0 else { return nil }

            let duplicate = dup(fd)
            guard duplicate >= 0 else {
                close(ends[0]); close(ends[1])
                return nil
            }
            originalFD = duplicate

            dup2(ends[1], fd)
            close(ends[1])

            let readEnd = ends[0]
            let passthrough = duplicate
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(readEnd, &buffer, buffer.count)
                    if count <= 0 { break }
                    _ = buffer.withUnsafeBytes { write(passthrough, $0.baseAddress, count) }
                    let text = String(decoding: buffer[0..<count], as: UTF8.self)
                    if !text.isEmpty { onText(text) }
                }
            }
        }
    }
}
