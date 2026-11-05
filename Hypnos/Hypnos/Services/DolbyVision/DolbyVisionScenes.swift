/*
 Hypnos - a Dolby Vision 8.x picture's per-scene metadata through Metal,
 sideload edition only (HYPNOS_DOVI)

 The flat Metal player draws a profile 8.x picture as its HDR10 base layer
 into an EDR layer, which the system tone-maps with the layer's
 `edrMetadata`. With HDR10's static metadata that is one curve for the whole
 film (its mastering display, MaxCLL). Each frame AVFoundation decodes still
 carries its RPU (`DolbyVisionRPUData`, the bare payload, escaped), and the
 RPU's L1 block says what this scene really spans (min, average and max, as
 12-bit PQ). `DolbyVisionScenes.read` parses it with FFmpeg's reader
 (`FFmpegDolbyVision.parse`, in HypnosFFmpeg.framework) and the player hands
 each scene's range to the layer as its metadata, so a scene that peaks at
 260 nits is mapped as one that peaks at 260, not as part of a 1000-nit
 master: what Dolby Vision's dynamic metadata is for.

 What this does not apply yet, and says so (`Scene`, the `videoDolbyVision`
 debug query):
 - L2/L8 trims, the colourist's per-display adjustments: they are defined on
   Dolby's own display mapping, not on top of the system's curve.
 - Reshaping curves that aren't identity: the frames come out of AVFoundation
   as RGB, after the base layer's matrix, and reshaping works on the base
   layer's YCbCr. `identityReshaping` false means the picture shown is the
   base layer's, not the RPU's mapped signal.
 - Profile 5, whose frames are IPT and still go to the system's layer.

 An App Store build never compiles the reader (CLAUDE.md): `isAvailable` is
 false there and the player keeps HDR10's static metadata.
 */

import CoreVideo
import Foundation

#if HYPNOS_DOVI
import FFmpegDecoders
#endif

enum DolbyVisionScenes {
    /// What one frame's RPU says that the player uses or reports.
    struct Scene: Equatable, Sendable, Encodable {
        var profile: Int
        /// The RPU's L1 block, in cd/m²; nil without one.
        var minNits: Double?
        var averageNits: Double?
        var maxNits: Double?
        /// The source (mastering) range the RPU states, in cd/m².
        var sourceMinNits: Double
        var sourceMaxNits: Double
        /// Display trims carried (L2: CM v2.9, L8: CM v4.0), not applied.
        var l2Trims: Int
        var l8Trims: Int
        /// "4.0" with L254 or L8, else "2.9".
        var contentMappingVersion: String
        /// Every reshaping curve is one linear piece mapping the base layer
        /// to itself, so the base layer is the RPU's signal.
        var identityReshaping: Bool

        /// The same scene as far as the layer's metadata goes (L1 equal).
        func sameRange(as other: Scene?) -> Bool {
            guard let other else { return false }
            return minNits == other.minNits && maxNits == other.maxNits
        }
    }

    /// The reader is compiled in and its framework is here.
    static var isAvailable: Bool {
        #if HYPNOS_DOVI
        FFmpegDolbyVision.isAvailable
        #else
        false
        #endif
    }

    /// The frame's RPU, read; nil without one (an interpolated frame) or in a
    /// build without the reader.
    static func read(_ pixelBuffer: CVPixelBuffer) -> Scene? {
        #if HYPNOS_DOVI
        guard let data = CVBufferCopyAttachment(pixelBuffer, "DolbyVisionRPUData" as CFString, nil) as? Data,
              let rpu = FFmpegDolbyVision.parse([UInt8](data)) else { return nil }
        return scene(from: rpu)
        #else
        return nil
        #endif
    }

    /// A 12-bit PQ code (0...4095) as cd/m² (SMPTE ST 2084).
    static func nits(pq12 code: Int32) -> Double {
        let e = min(max(Double(code) / 4095, 0), 1)
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let p = pow(e, 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    #if HYPNOS_DOVI
    private static func scene(from rpu: hyp_ff_dovi_rpu) -> Scene {
        var rpu = rpu
        let hasL1 = rpu.has_l1 != 0
        return Scene(
            profile: Int(rpu.profile),
            minNits: hasL1 ? nits(pq12: rpu.l1_min_pq) : nil,
            averageNits: hasL1 ? nits(pq12: rpu.l1_avg_pq) : nil,
            maxNits: hasL1 ? nits(pq12: rpu.l1_max_pq) : nil,
            sourceMinNits: nits(pq12: rpu.source_min_pq),
            sourceMaxNits: nits(pq12: rpu.source_max_pq),
            l2Trims: Int(rpu.num_l2),
            l8Trims: Int(rpu.num_l8),
            contentMappingVersion: rpu.has_l254 != 0 || rpu.num_l8 > 0 ? "4.0" : "2.9",
            identityReshaping: isIdentity(&rpu)
        )
    }

    /// Each component one first-order polynomial piece over the whole code
    /// range, c0 = 0 and c1 = 1 (dovi_tool's identity curves).
    private static func isIdentity(_ rpu: inout hyp_ff_dovi_rpu) -> Bool {
        let denominator = Double(Int64(1) << Int64(max(0, min(62, rpu.coef_log2_denom))))
        let top = Int32((1 << Int(max(1, min(16, rpu.bl_bit_depth)))) - 1)
        return withUnsafeBytes(of: &rpu.curves) { raw in
            let curves = raw.bindMemory(to: hyp_ff_dovi_curve.self)
            return curves.allSatisfy { curve in
                guard curve.num_pivots == 2, curve.mapping_idc.0 == 0, curve.poly_order.0 == 1 else { return false }
                guard curve.pivots.0 == 0, curve.pivots.1 == top else { return false }
                let (c0, c1, _) = curve.poly_coef.0
                return abs(Double(c0) / denominator) < 1e-4 && abs(Double(c1) / denominator - 1) < 1e-4
            }
        }
    }
    #endif
}

/// The last scenes the native players applied, for the `videoDolbyVision`
/// debug query.
@MainActor
enum DolbyVisionSceneLog {
    struct Entry: Encodable {
        var seconds: Double
        var scene: DolbyVisionScenes.Scene
        var applied: Bool
    }

    private(set) static var entries: [Entry] = []
    /// The scene showing now, and whether its range went to the layer.
    private(set) static var current: Entry?

    static func note(_ scene: DolbyVisionScenes.Scene, at seconds: Double, applied: Bool) {
        let entry = Entry(seconds: seconds, scene: scene, applied: applied)
        current = entry
        entries.append(entry)
        if entries.count > 40 { entries.removeFirst(entries.count - 40) }
    }

    static func reset() {
        entries = []
        current = nil
    }
}
