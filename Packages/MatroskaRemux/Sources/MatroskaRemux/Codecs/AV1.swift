/*
 MatroskaRemux - AV1 (V_AV1)

 Matroska's CodecPrivate for AV1 is the AV1CodecConfigurationRecord (`av1C`)
 itself: four bytes of profile, level, tier and colour format, then the
 sequence header OBU. It becomes the `av1C` box; blocks are temporal units
 without temporal delimiters, as MP4 wants them. When CodecPrivate is
 missing, the record is built from the sequence header in the first
 keyframe.

 The sequence header is parsed for its colour description (for the HLS
 VIDEO-RANGE and the CODECS string's colour fields) when the track has no
 Colour element. Whether a device decodes AV1 at all is left to the decode
 probe: Apple silicon before M3 / A17 Pro has no AV1 decoder.
 */

import Foundation

struct AV1Configuration {
    var record: [UInt8]
    var profile: Int
    var level: Int
    var tier: Int
    var bitDepth: Int
    var monochrome: Bool
    var subsamplingX: Bool
    var subsamplingY: Bool
    var chromaSamplePosition: Int
    var colour: ColourDescription?

    struct SequenceHeader {
        var profile = 0
        var level = 0
        var tier = 0
        var bitDepth = 8
        var monochrome = false
        var subsamplingX = true
        var subsamplingY = true
        var chromaSamplePosition = 0
        var colour: ColourDescription?
        /// The whole OBU, for an `av1C` built from scratch.
        var obu: [UInt8] = []
    }

    init?(track: MatroskaTrack, firstKeyframe: [UInt8]?) {
        let cp = track.codecPrivate
        var sequence: SequenceHeader?
        if cp.count >= 4, cp[0] & 0x80 != 0 {
            sequence = Self.findSequenceHeader(Array(cp.dropFirst(4)))
            record = cp
            profile = Int(cp[1] >> 5)
            level = Int(cp[1] & 0x1F)
            tier = Int(cp[2] >> 7)
            let high = cp[2] & 0x40 != 0, twelve = cp[2] & 0x20 != 0
            bitDepth = high ? (twelve ? 12 : 10) : 8
            monochrome = cp[2] & 0x10 != 0
            subsamplingX = cp[2] & 0x08 != 0
            subsamplingY = cp[2] & 0x04 != 0
            chromaSamplePosition = Int(cp[2] & 3)
        } else if let frame = firstKeyframe, let header = Self.findSequenceHeader(frame) {
            sequence = header
            profile = header.profile
            level = header.level
            tier = header.tier
            bitDepth = header.bitDepth
            monochrome = header.monochrome
            subsamplingX = header.subsamplingX
            subsamplingY = header.subsamplingY
            chromaSamplePosition = header.chromaSamplePosition
            var w = BoxWriter()
            w.u8(0x81)
            w.u8(UInt8(profile << 5 | level))
            w.u8(UInt8(tier << 7 | (bitDepth > 8 ? 0x40 : 0) | (bitDepth == 12 ? 0x20 : 0) | (monochrome ? 0x10 : 0)
                    | (subsamplingX ? 0x08 : 0) | (subsamplingY ? 0x04 : 0) | chromaSamplePosition))
            w.u8(0)
            w.bytes += header.obu
            record = w.bytes
        } else {
            return nil
        }
        if let colourElement = track.video?.colour,
           let primaries = colourElement.primaries, let transfer = colourElement.transferCharacteristics {
            colour = ColourDescription(primaries: primaries, transfer: transfer,
                                       matrix: colourElement.matrixCoefficients ?? sequence?.colour?.matrix ?? 2,
                                       fullRange: colourElement.range == 2)
        } else {
            colour = sequence?.colour
        }
    }

    /// RFC: av01.P.LLT.DD.M.CCC.cp.tc.mc.F.
    var codecString: String {
        var parts = ["av01", "\(profile)", String(format: "%02d%@", level, tier == 1 ? "H" : "M"), String(format: "%02d", bitDepth)]
        if let colour {
            let chroma = "\(subsamplingX ? 1 : 0)\(subsamplingY ? 1 : 0)\(subsamplingX && subsamplingY ? chromaSamplePosition : 0)"
            parts += ["\(monochrome ? 1 : 0)", chroma, String(format: "%02d", colour.primaries),
                      String(format: "%02d", colour.transfer), String(format: "%02d", colour.matrix),
                      colour.fullRange ? "1" : "0"]
        }
        return parts.joined(separator: ".")
    }

    /// The first sequence header OBU in a run of OBUs.
    static func findSequenceHeader(_ data: [UInt8]) -> SequenceHeader? {
        var p = 0
        while p < data.count {
            let header = data[p]
            let type = Int(header >> 3) & 0xF
            let hasExtension = header & 0x04 != 0
            let hasSize = header & 0x02 != 0
            var q = p + 1 + (hasExtension ? 1 : 0)
            var size = data.count - q
            if hasSize {
                var value = 0
                for i in 0 ..< 8 {
                    guard q < data.count else { return nil }
                    let byte = Int(data[q])
                    q += 1
                    value |= (byte & 0x7F) << (7 * i)
                    if byte & 0x80 == 0 { break }
                }
                size = value
            }
            guard q + size <= data.count else { return nil }
            if type == 1 {
                var parsed = parseSequenceHeader(Array(data[q ..< q + size]))
                parsed?.obu = Array(data[p ..< q + size])
                return parsed
            }
            guard hasSize else { return nil }
            p = q + size
        }
        return nil
    }

    static func parseSequenceHeader(_ payload: [UInt8]) -> SequenceHeader? {
        var r = BitReader(payload)
        var s = SequenceHeader()
        s.profile = Int(r.bits(3))
        r.skip(1) // still_picture
        let reduced = r.flag()
        if reduced {
            s.level = Int(r.bits(5))
        } else {
            var decoderModelInfo = false
            var bufferDelayLength = 0
            if r.flag() { // timing_info_present_flag
                r.skip(64) // num_units_in_display_tick, time_scale
                if r.flag() { _ = r.uvlc() } // equal_picture_interval
                decoderModelInfo = r.flag()
                if decoderModelInfo {
                    bufferDelayLength = Int(r.bits(5)) + 1
                    r.skip(32 + 5 + 5)
                }
            }
            let initialDisplayDelay = r.flag()
            let operatingPoints = Int(r.bits(5)) + 1
            for i in 0 ..< operatingPoints {
                r.skip(12) // operating_point_idc
                let level = Int(r.bits(5))
                let tier = level > 7 ? Int(r.bit()) : 0
                if i == 0 { s.level = level; s.tier = tier }
                if decoderModelInfo, r.flag() { r.skip(2 * bufferDelayLength + 1) }
                if initialDisplayDelay, r.flag() { r.skip(4) }
            }
        }
        let widthBits = Int(r.bits(4)) + 1, heightBits = Int(r.bits(4)) + 1
        r.skip(widthBits + heightBits)
        if !reduced, r.flag() { r.skip(4 + 3) } // frame_id_numbers_present_flag
        r.skip(3) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
        if !reduced {
            r.skip(4) // interintra, masked, warped, dual_filter
            let orderHint = r.flag()
            if orderHint { r.skip(2) } // jnt_comp, ref_frame_mvs
            var forceScreenContent = 2
            if !r.flag() { forceScreenContent = Int(r.bit()) } // seq_choose_screen_content_tools
            if forceScreenContent > 0, !r.flag() { r.skip(1) } // seq_choose_integer_mv → seq_force_integer_mv
            if orderHint { r.skip(3) }
        }
        r.skip(3) // superres, cdef, restoration
        // color_config()
        let highBitDepth = r.flag()
        s.bitDepth = highBitDepth ? 10 : 8
        if s.profile == 2, highBitDepth { s.bitDepth = r.flag() ? 12 : 10 }
        s.monochrome = s.profile == 1 ? false : r.flag()
        var primaries = 2, transfer = 2, matrix = 2
        if r.flag() {
            primaries = Int(r.bits(8))
            transfer = Int(r.bits(8))
            matrix = Int(r.bits(8))
        }
        var fullRange = false
        if s.monochrome {
            fullRange = r.flag()
        } else if primaries == 1, transfer == 13, matrix == 0 {
            fullRange = true
            s.subsamplingX = false
            s.subsamplingY = false
        } else {
            fullRange = r.flag()
            switch s.profile {
            case 0: s.subsamplingX = true; s.subsamplingY = true
            case 1: s.subsamplingX = false; s.subsamplingY = false
            default:
                if s.bitDepth == 12 {
                    s.subsamplingX = r.flag()
                    s.subsamplingY = s.subsamplingX ? r.flag() : false
                } else {
                    s.subsamplingX = true
                    s.subsamplingY = false
                }
            }
            if s.subsamplingX, s.subsamplingY { s.chromaSamplePosition = Int(r.bits(2)) }
        }
        guard !r.overrun else { return nil }
        s.colour = ColourDescription(primaries: primaries, transfer: transfer, matrix: matrix, fullRange: fullRange)
        return s
    }
}
