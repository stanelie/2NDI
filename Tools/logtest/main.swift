// Checks that LibraryLog really sees what the NDI library prints, using the notice string
// taken verbatim out of libndi_advanced.dylib. Covers the two things that can silently
// break: the stdout/stderr capture, and the marker no longer matching.
import Foundation

let notice = "This version of the NDI Advanced SDK is designed for development use and "
    + "will run on a stream for 30 minutes. For a commercial use license, please email "
    + "licensing@ndi.video."

let matched = DispatchSemaphore(value: 0)

LibraryLog.shared.observe { text in
    if text.contains(LibraryLog.trialExpiryMarker) { matched.signal() }
}

// Written the way a C library would: no Swift buffering, no trailing newline.
notice.withCString { _ = fputs($0, stderr) }
fflush(stderr)
"unrelated chatter on stdout\n".withCString { _ = fputs($0, stdout) }
fflush(stdout)

let result = matched.wait(timeout: .now() + 3)

// The notice and the stdout chatter appearing above is the passthrough working: both were
// written into the capture pipe and echoed back to the real descriptors.
print("")
print("marker            \"\(LibraryLog.trialExpiryMarker)\"")
print("notice detected   \(result == .success ? "YES" : "NO — capture or marker is broken")")
print("passthrough       see the notice and the stdout chatter echoed above")
fflush(stdout)

// The capture forwards on a background thread, so give it a moment to drain before exit
// or this summary is lost with it.
Thread.sleep(forTimeInterval: 0.3)
exit(result == .success ? 0 : 1)
