/*
 MatroskaRemux - HEVC (V_MPEGH/ISO/HEVC)

 Like H.264, Matroska keeps the MP4 forms: CodecPrivate is the
 HEVCDecoderConfigurationRecord and blocks are length-prefixed NAL units.
 The record becomes `hvcC` under `hvc1` when it carries the parameter sets
 (VPS, SPS and PPS), else under `hev1`, which tells the decoder to look for
 them in the samples.

 The SPS is parsed down to its VUI for the colour description: a UHD remux
 often has no Colour element at all (the Dolby demo doesn't) and only the
 bitstream says it is PQ, which the HLS master must say too or the player
 treats the picture as SDR.

 Dolby Vision rides on the track as a BlockAdditionMapping holding the
 dvcC/dvvC payload. Profile 8 keeps `hvc1` (its base layer is plain HEVC)
 plus the configuration box; profile 5 has no compatible base layer and is
 `dvh1`. The RPU NAL units stay in the samples untouched: the app never
 does Dolby processing itself.
 */

import Foundation

struct HEVCConfiguration {
    let record: [UInt8]
    let profileSpace: UInt8
    let tier: UInt8
    let profileIDC: UInt8
    let compatibilityFlags: UInt32
    let constraintFlags: [UInt8]
    let levelIDC: UInt8
    let lengthSize: Int
    /// NAL units by type (32 VPS, 33 SPS, 34 PPS, 39/40 SEI).
    let arrays: [UInt8: [[UInt8]]]

    init?(record: [UInt8]) {
        guard record.count >= 23, record[0] == 1 else { return nil }
        self.record = record
        profileSpace = record[1] >> 6
        tier = (record[1] >> 5) & 1
        profileIDC = record[1] & 0x1F
        compatibilityFlags = UInt32(record[2]) << 24 | UInt32(record[3]) << 16 | UInt32(record[4]) << 8 | UInt32(record[5])
        constraintFlags = Array(record[6 ..< 12])
        levelIDC = record[12]
        lengthSize = Int(record[21] & 3) + 1
        var arrays: [UInt8: [[UInt8]]] = [:]
        var p = 23
        for _ in 0 ..< Int(record[22]) {
            guard p + 3 <= record.count else { break }
            let type = record[p] & 0x3F
            let count = Int(record[p + 1]) << 8 | Int(record[p + 2])
            p += 3
            for _ in 0 ..< count {
                guard p + 2 <= record.count else { break }
                let length = Int(record[p]) << 8 | Int(record[p + 1])
                p += 2
                guard p + length <= record.count else { break }
                arrays[type, default: []].append(Array(record[p ..< p + length]))
                p += length
            }
        }
        self.arrays = arrays
    }

    /// The record carries a VPS, an SPS and a PPS.
    var hasParameterSets: Bool {
        [32, 33, 34].allSatisfy { !(arrays[$0]?.isEmpty ?? true) }
    }

    /// ISO/IEC 14496-15 Annex E: hvc1.2.4.L153.B0.
    func codecString(sampleEntry: String) -> String {
        let space = ["", "A", "B", "C"][Int(profileSpace)]
        var reversed: UInt32 = 0
        for i in 0 ..< 32 where compatibilityFlags & (1 << UInt32(i)) != 0 { reversed |= 1 << UInt32(31 - i) }
        var constraints = constraintFlags
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var parts = [sampleEntry, "\(space)\(profileIDC)", String(reversed, radix: 16, uppercase: true),
                     "\(tier == 1 ? "H" : "L")\(levelIDC)"]
        parts += constraints.map { String($0, radix: 16, uppercase: true) }
        return parts.joined(separator: ".")
    }

    var colour: ColourDescription? {
        arrays[33]?.first.flatMap(HEVCConfiguration.spsColour)
    }

    /// The SPS's VUI colour description.
    static func spsColour(_ nal: [UInt8]) -> ColourDescription? {
        guard nal.count > 4 else { return nil }
        var r = BitReader(NALUnits.rbsp(nal.dropFirst(2)))
        r.skip(4) // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(r.bits(3))
        r.skip(1) // sps_temporal_id_nesting_flag
        skipProfileTierLevel(&r, maxSubLayersMinus1: maxSubLayersMinus1)
        _ = r.ue() // sps_seq_parameter_set_id
        if r.ue() == 3 { r.skip(1) } // chroma_format_idc → separate_colour_plane_flag
        _ = r.ue() // pic_width_in_luma_samples
        _ = r.ue() // pic_height_in_luma_samples
        if r.flag() { for _ in 0 ..< 4 { _ = r.ue() } } // conformance_window
        _ = r.ue() // bit_depth_luma_minus8
        _ = r.ue() // bit_depth_chroma_minus8
        let log2MaxPocLsb = Int(r.ue()) + 4
        let orderingInfo = r.flag()
        for _ in (orderingInfo ? 0 : maxSubLayersMinus1) ... maxSubLayersMinus1 {
            _ = r.ue(); _ = r.ue(); _ = r.ue()
        }
        for _ in 0 ..< 6 { _ = r.ue() } // block sizes, transform hierarchy depths
        if r.flag(), r.flag() { skipScalingListData(&r) } // scaling_list_enabled → sps_scaling_list_data_present
        r.skip(2) // amp_enabled_flag, sample_adaptive_offset_enabled_flag
        if r.flag() { // pcm_enabled_flag
            r.skip(8)
            _ = r.ue(); _ = r.ue()
            r.skip(1)
        }
        let shortTermSets = Int(r.ue())
        guard shortTermSets <= 64 else { return nil }
        var deltaPocs: [Int] = []
        for index in 0 ..< shortTermSets {
            deltaPocs.append(skipShortTermRefPicSet(&r, index: index, previous: deltaPocs))
        }
        if r.flag() { // long_term_ref_pics_present_flag
            let count = Int(r.ue())
            for _ in 0 ..< min(count, 33) { r.skip(log2MaxPocLsb + 1) }
        }
        r.skip(2) // sps_temporal_mvp_enabled_flag, strong_intra_smoothing_enabled_flag
        guard !r.overrun, r.flag() else { return nil } // vui_parameters_present_flag
        return VUI.colour(&r)
    }

    private static func skipProfileTierLevel(_ r: inout BitReader, maxSubLayersMinus1: Int) {
        r.skip(96) // general profile, compatibility, constraint flags, level
        var profilePresent: [Bool] = [], levelPresent: [Bool] = []
        for _ in 0 ..< maxSubLayersMinus1 {
            profilePresent.append(r.flag())
            levelPresent.append(r.flag())
        }
        if maxSubLayersMinus1 > 0 { r.skip(2 * (8 - maxSubLayersMinus1)) }
        for i in 0 ..< maxSubLayersMinus1 {
            if profilePresent[i] { r.skip(88) }
            if levelPresent[i] { r.skip(8) }
        }
    }

    private static func skipScalingListData(_ r: inout BitReader) {
        for sizeID in 0 ..< 4 {
            for _ in stride(from: 0, to: 6, by: sizeID == 3 ? 3 : 1) {
                if !r.flag() {
                    _ = r.ue() // scaling_list_pred_matrix_id_delta
                } else {
                    let coefficients = min(64, 1 << (4 + (sizeID << 1)))
                    if sizeID > 1 { _ = r.se() }
                    for _ in 0 ..< coefficients { _ = r.se() }
                }
            }
        }
    }

    /// Skips st_ref_pic_set(index) and returns its NumDeltaPocs.
    private static func skipShortTermRefPicSet(_ r: inout BitReader, index: Int, previous: [Int]) -> Int {
        if index != 0, r.flag() { // inter_ref_pic_set_prediction_flag
            r.skip(1) // delta_rps_sign
            _ = r.ue() // abs_delta_rps_minus1
            let reference = previous[safe: index - 1] ?? 0
            var count = 0
            for _ in 0 ... reference {
                let used = r.flag()
                let useDelta = used ? true : r.flag()
                if used || useDelta { count += 1 }
            }
            return count
        }
        let negative = Int(r.ue()), positive = Int(r.ue())
        guard negative + positive <= 32 else { return 0 }
        for _ in 0 ..< negative + positive {
            _ = r.ue()
            r.skip(1)
        }
        return negative + positive
    }
}

/// A Dolby Vision decoder configuration record (the dvcC/dvvC payload).
struct DolbyVisionConfiguration {
    let boxType: String
    let payload: [UInt8]
    let profile: Int
    let level: Int
    let hasRPU: Bool
    let hasEnhancementLayer: Bool
    let hasBaseLayer: Bool
    /// What the base layer is when decoded alone: 0 none, 1 HDR10, 2 SDR,
    /// 4 HLG, 6 Ultra HD Blu-ray HDR10.
    let compatibilityID: Int

    init?(mapping: MatroskaTrack.BlockAdditionMapping) {
        guard let type = mapping.idType, mapping.extraData.count >= 5 else { return nil }
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((type >> $0) & 0xFF) }, encoding: .ascii) ?? ""
        guard ["dvcC", "dvvC", "dvwC"].contains(fourCC) else { return nil }
        boxType = fourCC
        payload = mapping.extraData
        let bits = UInt16(payload[2]) << 8 | UInt16(payload[3])
        profile = Int(bits >> 9)
        level = Int((bits >> 3) & 0x3F)
        hasRPU = bits & 0x4 != 0
        hasEnhancementLayer = bits & 0x2 != 0
        hasBaseLayer = bits & 0x1 != 0
        compatibilityID = Int(payload[4] >> 4)
    }

    /// "dvh1.05.06", the HLS CODECS (profile 5) or SUPPLEMENTAL-CODECS
    /// (profile 8, with its compatibility brand) value.
    var codecString: String {
        String(format: "dvh1.%02d.%02d", profile, level)
    }

    /// The brand after the slash in SUPPLEMENTAL-CODECS: what a player that
    /// can't do Dolby Vision may still play the base layer as.
    var compatibilityBrand: String? {
        switch compatibilityID {
        case 1, 6: "db1p"
        case 2: "db2g"
        case 4: "db4h"
        default: nil
        }
    }
}
