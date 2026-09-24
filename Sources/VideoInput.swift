import Foundation
import Metal

/// Anything that can hand the pipeline a frame as a Metal texture.
///
/// Everything downstream — orientation, letterboxing, scaling, encoding, NDI — already
/// works on an MTLTexture, so a new kind of input only has to produce one.
protocol VideoInput: AnyObject {
    /// The current frame, or nil when nothing new has arrived. The texture belongs to the
    /// input and may be recycled, so the caller must copy out of it before returning.
    func newFrameTexture() -> MTLTexture?
    var isValid: Bool { get }
    func stop()
}

// SyphonInput already has exactly this shape.
extension SyphonInput: VideoInput {}

/// One selectable input, whichever kind it is.
struct InputSource: Equatable {
    enum Kind: Int {
        case syphon = 0
        case camera = 1
        /// Generated internally; always available, needs nothing else running.
        case testPattern = 2
    }

    let kind: Kind
    /// Syphon server UUID, or the capture device's unique ID.
    let id: String
    let displayName: String
    /// Only set for Syphon sources; the camera equivalent is looked up from `id`.
    let syphonSource: SyphonSource?

    static func == (a: InputSource, b: InputSource) -> Bool { a.kind == b.kind && a.id == b.id }

    /// Key under which this source's orientation is remembered.
    ///
    /// Syphon carries no orientation information — a server description from an OpenGL
    /// publisher and one from a Metal publisher are structurally identical — so which way
    /// up a source arrives cannot be detected, only remembered. Keyed on the *app* name
    /// rather than the server UUID, because Syphon UUIDs are regenerated every run while
    /// the publishing application's behaviour is what actually stays constant.
    var orientationKey: String {
        switch kind {
        case .syphon:      return "syphon:\(syphonSource?.appName ?? displayName)"
        case .camera:      return "camera:\(id)"
        case .testPattern: return "test-pattern"
        }
    }

    /// Everything currently available, Syphon servers first.
    static func available() -> [InputSource] {
        let syphon = SyphonInput.availableSources().map {
            InputSource(kind: .syphon, id: $0.uuid, displayName: $0.displayName, syphonSource: $0)
        }
        let cameras = CameraInput.availableCameras().map {
            InputSource(kind: .camera, id: $0.id, displayName: "Camera — \($0.name)", syphonSource: nil)
        }
        // Last, so it never displaces a real source as the default selection.
        let generated = InputSource(kind: .testPattern, id: "test-pattern",
                                    displayName: TestPatternInput.displayName, syphonSource: nil)
        return syphon + cameras + [generated]
    }
}
