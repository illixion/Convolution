/*
 MatroskaRemux - H.264 (V_MPEG4/ISO/AVC)

 Matroska's CodecPrivate is the AVCDecoderConfigurationRecord itself, and
 its blocks are length-prefixed NAL units, which is exactly MP4's form: the
 record becomes the `avcC` box and samples pass through. The SPS is read for
 the colour description (HLG/PQ H.264 exists) when the track's Colour
 element is absent.
 */

import Foundation

struct AVCConfiguration {
    let record: [UInt8]
    let profile: UInt8
    let compatibility: UInt8
    let level: UInt8
    let lengthSize: Int
    let sps: [[UInt8]]
    let pps: [[UInt8]]

    init?(record: [UInt8]) {
        guard record.count >= 7, record[0] == 1 else { return nil }
        self.record = record
        profile = record[1]
        compatibility = record[2]
        level = record[3]
        lengthSize = Int(record[4] & 3) + 1
        var p = 5
        var sps: [[UInt8]] = []
        let spsCount = Int(record[p] & 0x1F)
        p += 1
        for _ in 0 ..< spsCount {
            guard p + 2 <= record.count else { return nil }
            let length = Int(record[p]) << 8 | Int(record[p + 1])
            p += 2
            guard p + length <= record.count else { return nil }
            sps.append(Array(record[p ..< p + length]))
            p += length
        }
        var pps: [[UInt8]] = []
        if p < record.count {
            let ppsCount = Int(record[p])
            p += 1
            for _ in 0 ..< ppsCount {
                guard p + 2 <= record.count else { break }
                let length = Int(record[p]) << 8 | Int(record[p + 1])
                p += 2
                guard p + length <= record.count else { break }
                pps.append(Array(record[p ..< p + length]))
                p += length
            }
        }
        guard !sps.isEmpty else { return nil }
        self.sps = sps
        self.pps = pps
    }

    /// RFC 6381: avc1.PPCCLL.
    var codecString: String {
        String(format: "avc1.%02X%02X%02X", profile, compatibility, level)
    }

    var colour: ColourDescription? {
        sps.first.flatMap(AVCConfiguration.spsColour)
    }

    /// The SPS's VUI colour description.
    static func spsColour(_ nal: [UInt8]) -> ColourDescription? {
        guard nal.count > 4 else { return nil }
        var r = BitReader(NALUnits.rbsp(nal.dropFirst()))
        let profileIDC = r.bits(8)
        r.skip(16) // constraint flags, level_idc
        _ = r.ue() // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profileIDC) {
            let chromaFormat = r.ue()
            if chromaFormat == 3 { r.skip(1) }
            _ = r.ue() // bit_depth_luma_minus8
            _ = r.ue() // bit_depth_chroma_minus8
            r.skip(1) // qpprime_y_zero_transform_bypass_flag
            if r.flag() { // seq_scaling_matrix_present_flag
                for i in 0 ..< (chromaFormat == 3 ? 12 : 8) where r.flag() {
                    skipScalingList(&r, size: i < 6 ? 16 : 64)
                }
            }
        }
        _ = r.ue() // log2_max_frame_num_minus4
        let pocType = r.ue()
        if pocType == 0 {
            _ = r.ue()
        } else if pocType == 1 {
            r.skip(1)
            _ = r.se()
            _ = r.se()
            let cycle = r.ue()
            for _ in 0 ..< min(cycle, 256) { _ = r.se() }
        }
        _ = r.ue() // max_num_ref_frames
        r.skip(1) // gaps_in_frame_num_value_allowed_flag
        _ = r.ue() // pic_width_in_mbs_minus1
        _ = r.ue() // pic_height_in_map_units_minus1
        if !r.flag() { r.skip(1) } // frame_mbs_only_flag → mb_adaptive_frame_field_flag
        r.skip(1) // direct_8x8_inference_flag
        if r.flag() { // frame_cropping_flag
            for _ in 0 ..< 4 { _ = r.ue() }
        }
        guard !r.overrun, r.flag() else { return nil } // vui_parameters_present_flag
        return VUI.colour(&r)
    }

    private static func skipScalingList(_ r: inout BitReader, size: Int) {
        var last: Int32 = 8, next: Int32 = 8
        for _ in 0 ..< size {
            if next != 0 {
                next = (last + r.se() + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }
}
