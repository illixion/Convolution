import Foundation
#if HAS_ANYTHINGUSDZ
import AnythingUSDZKit
#endif

/// Turns a GLB from the Generated 3D gateway into a USDZ. The converter itself
/// (AnythingUSDZKit) is only linked when its sibling checkout exists; see Package.swift.
public enum Gen3DConverter {
    public struct Unavailable: LocalizedError {
        public var errorDescription: String? { "This build has no GLB to USDZ converter." }
    }

    public static var isAvailable: Bool {
        #if HAS_ANYTHINGUSDZ
        true
        #else
        false
        #endif
    }

    public static func convert(glb: URL, to usdz: URL) throws {
        #if HAS_ANYTHINGUSDZ
        _ = try Converter().convert(fileAt: glb, to: usdz)
        #else
        throw Unavailable()
        #endif
    }
}
