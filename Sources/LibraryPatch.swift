import Foundation

/// Whether the bundled NDI Advanced library is stock or has had its development-licence
/// time limit patched out.
///
/// The Advanced SDK's development licence stops delivering video after 30 minutes while
/// the sender keeps reporting success, which is why this app has a delivery monitor at
/// all. A patched library does not, and a measurement taken with one is not comparable
/// with a measurement taken without — so which library is in the bundle has to be visible
/// rather than remembered.
///
/// Detection is by signature, not by behaviour: the patch rewrites the timeout constant in
/// place at five sites per architecture slice, so the replacement bytes appear in a patched
/// library and in no other. Measured against both: the stock library has zero of them and
/// five of the originals per slice, a patched one exactly the reverse.
enum LibraryPatch {

    enum State {
        /// Patched sites found and no original ones left.
        case patched
        /// The library as it ships.
        case stock
        /// Not found, unreadable, or some mixture of the two — which would mean a patch
        /// that only partly applied, and is worth not calling either thing.
        case unknown
    }

    // The instruction sequences that load the limit. The arm64 form is a three-instruction
    // immediate build (mov/movk/movk), the x86_64 form a single movabs.
    private static let stockARM64: [[UInt8]] = [
        [0x08, 0x00, 0x8a, 0xd2, 0x88, 0x0b, 0xa3, 0xf2, 0x68, 0x34, 0xc0, 0xf2],
        [0x28, 0x00, 0x8a, 0xd2, 0x88, 0x0b, 0xa3, 0xf2, 0x68, 0x34, 0xc0, 0xf2],
    ]
    private static let patchedARM64: [UInt8] =
        [0x48, 0xd6, 0xa3, 0xd2, 0x28, 0xad, 0xc6, 0xf2, 0x28, 0x01, 0xe0, 0xf2]
    private static let stockX86: [[UInt8]] = [
        [0x48, 0xb8, 0x00, 0x50, 0x5c, 0x18, 0xa3, 0x01, 0x00, 0x00],
        [0x48, 0xb8, 0x01, 0x50, 0x5c, 0x18, 0xa3, 0x01, 0x00, 0x00],
    ]
    private static let patchedX86: [UInt8] =
        [0x48, 0xb8, 0x00, 0x00, 0xb2, 0x1e, 0x69, 0x35, 0x09, 0x00]

    /// Computed once. The library is ~30 MB and cannot change under a running process.
    static let state: State = detect()

    private static func detect() -> State {
        guard let url = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("libndi_advanced.dylib"),
              // Mapped rather than read: no reason to copy 30 MB to count byte patterns.
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return .unknown }

        let patched = count(patchedARM64, in: data) + count(patchedX86, in: data)
        let stock = stockARM64.reduce(0) { $0 + count($1, in: data) }
            + stockX86.reduce(0) { $0 + count($1, in: data) }

        switch (patched, stock) {
        case (0, 0):          return .unknown
        case (0, _):          return .stock
        case (_, 0):          return .patched
        default:              return .unknown
        }
    }

    private static func count(_ pattern: [UInt8], in data: Data) -> Int {
        let needle = Data(pattern)
        var found = 0
        var from = data.startIndex
        while from < data.endIndex,
              let r = data.range(of: needle, in: from..<data.endIndex) {
            found += 1
            from = r.lowerBound + 1
        }
        return found
    }
}
