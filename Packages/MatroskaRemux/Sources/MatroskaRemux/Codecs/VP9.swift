/*
 MatroskaRemux - VP9 (V_VP9)

 MP4's `vp09` sample entry needs a `vpcC` (VP Codec Configuration, version 1)
 that Matroska doesn't store whole. Its fields come from three places, most
 trusted first:

 1. CodecPrivate, when present: a list of (id, length, value) features —
    1 profile, 2 level, 3 bit depth, 4 chroma subsampling.
 2. The first keyframe's uncompressed header: profile, bit depth, colour
    space (the matrix), colour range and subsampling.
 3. The track's Colour element: primaries, transfer and matrix, which the
    VP9 bitstream doesn't carry at all (VP9 profile 2 PQ says it's PQ only
    here), plus mastering metadata and content light levels.

 A level the file doesn't state is computed from the picture size and frame
 rate against the VP9 level table, as ffmpeg's vpcc.c does.

 Samples pass through unchanged: a Matroska VP9 block is a whole temporal
 unit (a superframe when it holds a hidden alt-ref), which is also what an
 MP4 `vp09` sample is.
 */

import Foundation

struct VP9Configuration {
    var profile: Int
    var level: Int
    var bitDepth: Int
    /// vpcC chromaSubsampling: 0 4:2:0 vertical, 1 4:2:0 colocated, 2 4:2:2, 3 4:4:4.
    var chromaSubsampling: Int
    var fullRange: Bool
    var colour: ColourDescription

    /// The first frame's uncompressed header, if it is a keyframe.
    struct KeyframeHeader {
        var profile: Int
        var bitDepth: Int
        /// VP9 color_space: 0 unknown, 1 BT.601, 2 BT.709, 3 SMPTE-170,
        /// 4 SMPTE-240, 5 BT.2020, 6 reserved, 7 sRGB.
        var colorSpace: Int
        var fullRange: Bool
        var subsamplingX: Bool
        var subsamplingY: Bool
    }

    static func keyframeHeader(_ frame: [UInt8]) -> KeyframeHeader? {
        // A superframe's index (at its end) lists its frames' sizes; the
        // keyframe is the first.
        var data = frame[...]
        if let last = frame.last, last & 0xE0 == 0xC0 {
            let sizeBytes = Int((last >> 3) & 3) + 1
            let frames = Int(last & 7) + 1
            let indexSize = 2 + sizeBytes * frames
            if frame.count >= indexSize, frame[frame.count - indexSize] == last {
                var size = 0
                for i in 0 ..< sizeBytes { size |= Int(frame[frame.count - indexSize + 1 + i]) << (8 * i) }
                if size > 0, size <= frame.count { data = frame[0 ..< size] }
            }
        }
        var r = BitReader(data)
        guard r.bits(2) == 2 else { return nil } // frame_marker
        let low = Int(r.bit()), high = Int(r.bit())
        let profile = high << 1 | low
        if profile == 3 { r.skip(1) }
        if r.flag() { return nil } // show_existing_frame
        guard r.bit() == 0 else { return nil } // frame_type: KEY_FRAME is 0
        r.skip(2) // show_frame, error_resilient_mode
        guard r.bits(24) == 0x498342 else { return nil } // frame_sync_code
        var bitDepth = 8
        if profile >= 2 { bitDepth = r.flag() ? 12 : 10 }
        let colorSpace = Int(r.bits(3))
        var fullRange = false, subX = true, subY = true
        if colorSpace != 7 {
            fullRange = r.flag()
            if profile == 1 || profile == 3 {
                subX = r.flag()
                subY = r.flag()
                r.skip(1)
            }
        } else {
            fullRange = true
            subX = false
            subY = false
            if profile == 1 || profile == 3 { r.skip(1) }
        }
        guard !r.overrun else { return nil }
        return KeyframeHeader(profile: profile, bitDepth: bitDepth, colorSpace: colorSpace, fullRange: fullRange,
                              subsamplingX: subX, subsamplingY: subY)
    }

    init?(track: MatroskaTrack, firstKeyframe: [UInt8]?, framesPerSecond: Double?) {
        let header = firstKeyframe.flatMap(Self.keyframeHeader)
        var features: [Int: Int] = [:]
        var p = 0
        let cp = track.codecPrivate
        while p + 2 <= cp.count {
            let id = Int(cp[p]), length = Int(cp[p + 1])
            guard p + 2 + length <= cp.count else { break }
            var value = 0
            for i in 0 ..< length { value = value << 8 | Int(cp[p + 2 + i]) }
            features[id] = value
            p += 2 + length
        }
        guard header != nil || features[1] != nil else { return nil }
        let colourElement = track.video?.colour

        profile = features[1] ?? header?.profile ?? 0
        bitDepth = features[3] ?? header?.bitDepth ?? colourElement?.bitsPerChannel ?? (profile >= 2 ? 10 : 8)
        let subX = header?.subsamplingX ?? (colourElement?.chromaSubsamplingHorz.map { $0 > 0 } ?? true)
        let subY = header?.subsamplingY ?? (colourElement?.chromaSubsamplingVert.map { $0 > 0 } ?? true)
        if let feature = features[4] {
            chromaSubsampling = feature
        } else if subX && subY {
            // Matroska's ChromaSitingHorz 1 is "left collocated".
            chromaSubsampling = colourElement?.chromaSitingHorz == 1 ? 1 : 0
        } else {
            chromaSubsampling = subX ? 2 : 3
        }
        fullRange = colourElement?.range.map { $0 == 2 } ?? header?.fullRange ?? false

        let matrixFromBitstream: Int? = switch header?.colorSpace {
        case 1: 6
        case 2: 1
        case 3: 6
        case 4: 7
        case 5: 9
        case 7: 0
        default: nil
        }
        let matrix = colourElement?.matrixCoefficients ?? matrixFromBitstream ?? 2
        var primaries = colourElement?.primaries ?? 2
        var transfer = colourElement?.transferCharacteristics ?? 2
        // Neither stated: the matrix implies the usual pairing.
        if primaries == 2, transfer == 2 {
            switch matrix {
            case 1: primaries = 1; transfer = 1
            case 5, 6: primaries = 6; transfer = 6
            case 9, 10: primaries = 9
            default: break
            }
        }
        colour = ColourDescription(primaries: primaries, transfer: transfer, matrix: matrix, fullRange: fullRange)

        if let feature = features[2], feature > 0 {
            level = feature
        } else {
            let width = track.video?.pixelWidth ?? 0, height = track.video?.pixelHeight ?? 0
            level = Self.level(width: width, height: height, framesPerSecond: framesPerSecond ?? 30)
        }
    }

    /// The lowest VP9 level whose picture size and luma sample rate fit.
    static func level(width: Int, height: Int, framesPerSecond: Double) -> Int {
        let picture = Double(width * height)
        let rate = picture * framesPerSecond
        let levels: [(level: Int, rate: Double, picture: Double)] = [
            (10, 829_440, 36_864), (11, 2_764_800, 73_728), (20, 4_608_000, 122_880),
            (21, 9_216_000, 245_760), (30, 20_736_000, 552_960), (31, 36_864_000, 983_040),
            (40, 83_558_400, 2_228_224), (41, 160_432_128, 2_228_224), (50, 311_951_360, 8_912_896),
            (51, 588_251_136, 8_912_896), (52, 1_176_502_272, 8_912_896), (60, 1_176_502_272, 35_651_584),
            (61, 2_353_004_544, 35_651_584), (62, 4_706_009_088, 35_651_584),
        ]
        return levels.first { rate <= $0.rate && picture <= $0.picture }?.level ?? 62
    }

    /// The vpcC box payload (version 1).
    var vpcC: [UInt8] {
        var w = BoxWriter()
        w.u8(UInt8(profile))
        w.u8(UInt8(level))
        w.u8(UInt8(bitDepth << 4 | chromaSubsampling << 1 | (fullRange ? 1 : 0)))
        w.u8(UInt8(colour.primaries))
        w.u8(UInt8(colour.transfer))
        w.u8(UInt8(colour.matrix))
        w.u16(0) // codecIntializationDataSize
        return w.bytes
    }

    /// The full form vp09.PP.LL.DD.CC.cp.tc.mc.FF, which is what tells a
    /// player the stream is HDR.
    var codecString: String {
        String(format: "vp09.%02d.%02d.%02d.%02d.%02d.%02d.%02d.%02d", profile, level, bitDepth, chromaSubsampling,
               colour.primaries, colour.transfer, colour.matrix, fullRange ? 1 : 0)
    }
}
