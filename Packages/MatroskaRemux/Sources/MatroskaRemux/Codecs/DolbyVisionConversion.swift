/*
 MatroskaRemux - Dolby Vision profile 7 played as profile 8.1

 A UHD Blu-ray rip's Dolby Vision is profile 7: one HEVC track carrying the
 HDR10 base layer, the enhancement layer (each of its NAL units wrapped in a
 NAL unit of type 63) and an RPU per frame (type 62). Apple's players have no
 profile 7 decoder. Without help the remux plays the base layer as HDR10
 (the EL and RPU units stay in the samples, where an HEVC decoder skips
 them, and the sample entry is plain `hvc1`).

 With a converter from the caller (`RemuxOptions.dolbyVisionConversion`;
 the app's sideload edition passes FFmpeg's, HYPNOS_DOVI), the track is
 played as profile 8.1 instead, the way dovi_tool's mode 2 makes one: every
 type 63 unit is dropped, every RPU is rewritten as a single-layer one
 (`convertToProfile81`), and the sample entry is `hvc1` with a dvvC box for
 profile 8, base-layer compatibility 1 (HDR10), the source's level. The
 system renderer then applies the RPU's reshaping and display mapping.

 What that loses: a minimal enhancement layer (MEL) adds nothing, so
 nothing. A full one (FEL) carries a real residual, which is gone; the RPU's
 curves are made identity for it (dovi_tool's choice), so the picture is the
 base layer with the RPU's display mapping. `RemuxSummary` says which.

 Deterministic like everything else here: a segment asked for twice gives
 the same bytes, as long as the converter does (FFmpeg's reads each RPU with
 a fresh context).
 */

import Foundation

/// What an RPU says the enhancement layer it rode with was.
public enum DolbyVisionEnhancementLayer: String, Sendable, Equatable {
    /// No residual (profiles 5 and 8).
    case none
    /// MEL: a residual of zero, so dropping it loses nothing.
    case minimal
    /// FEL: a real residual, which a single-layer conversion loses.
    case full
}

/// Rewrites Dolby Vision RPUs (see the file comment).
public struct RemuxDolbyVisionConversion: Sendable {
    public struct Converted: Sendable {
        /// The profile 8.1 RPU, a NAL unit in the input's form.
        public var rpu: [UInt8]
        /// The source RPU's enhancement layer, when the converter can tell.
        public var sourceEnhancementLayer: DolbyVisionEnhancementLayer?

        public init(rpu: [UInt8], sourceEnhancementLayer: DolbyVisionEnhancementLayer?) {
            self.rpu = rpu
            self.sourceEnhancementLayer = sourceEnhancementLayer
        }
    }

    /// One RPU NAL unit as stored in a sample (NAL header 0x7C 0x01, then
    /// the payload with its emulation-prevention bytes) rewritten as a
    /// profile 8.1 one in the same form, or nil when it can't be read. The
    /// same input must always give the same output.
    public var convertToProfile81: @Sendable (_ rpu: [UInt8]) -> Converted?

    public init(convertToProfile81: @escaping @Sendable ([UInt8]) -> Converted?) {
        self.convertToProfile81 = convertToProfile81
    }
}

/// A video track's samples rewritten for a profile 7 to 8.1 conversion.
struct DolbyVisionRewrite: Sendable {
    let conversion: RemuxDolbyVisionConversion
    let lengthSize: Int

    static let rpuType: UInt8 = 62
    static let enhancementLayerType: UInt8 = 63

    static func nalType(_ firstByte: UInt8) -> UInt8 { (firstByte >> 1) & 0x3F }

    /// The first RPU NAL unit of a length-prefixed sample.
    static func firstRPU(in sample: [UInt8], lengthSize: Int) -> [UInt8]? {
        NALUnits.lengthPrefixed(sample, lengthSize: lengthSize)
            .first { !$0.isEmpty && nalType($0[$0.startIndex]) == rpuType }
            .map(Array.init)
    }

    /// The sample without its enhancement-layer units and with each RPU
    /// converted (one that doesn't convert is left out). A sample with
    /// neither is returned as it is.
    func rewrite(_ sample: [UInt8]) -> [UInt8] {
        // Most of a frame's bytes are slice data; look before copying.
        var p = 0
        var touched = false
        while p + lengthSize <= sample.count {
            var length = 0
            for i in 0 ..< lengthSize { length = length << 8 | Int(sample[p + i]) }
            p += lengthSize
            guard length > 0, p + length <= sample.count else { break }
            let type = Self.nalType(sample[p])
            if type == Self.rpuType || type == Self.enhancementLayerType { touched = true; break }
            p += length
        }
        guard touched else { return sample }

        var out: [UInt8] = []
        out.reserveCapacity(sample.count)
        let maxLength = lengthSize >= 4 ? Int(UInt32.max) : (1 << (8 * lengthSize)) - 1
        func append(_ unit: ArraySlice<UInt8>) {
            guard unit.count <= maxLength else { return }
            for i in (0 ..< lengthSize).reversed() { out.append(UInt8((unit.count >> (8 * i)) & 0xFF)) }
            out += unit
        }
        p = 0
        while p + lengthSize <= sample.count {
            var length = 0
            for i in 0 ..< lengthSize { length = length << 8 | Int(sample[p + i]) }
            guard length > 0, p + lengthSize + length <= sample.count else { break }
            let unit = sample[p + lengthSize ..< p + lengthSize + length]
            p += lengthSize + length
            switch Self.nalType(unit[unit.startIndex]) {
            case Self.enhancementLayerType:
                continue
            case Self.rpuType:
                if let converted = conversion.convertToProfile81(Array(unit)) { append(converted.rpu[...]) }
            default:
                append(unit)
            }
        }
        // Whatever doesn't parse as NAL units goes on as it was.
        if p < sample.count { out += sample[p...] }
        return out
    }
}

extension DolbyVisionConfiguration {
    /// The configuration record of the profile 8.1 stream a profile 7 one
    /// becomes: same version and level, RPU and base layer, no enhancement
    /// layer, base-layer compatibility 1 (HDR10), as a dvvC box (profiles 8
    /// to 10).
    func asProfile81() -> DolbyVisionConfiguration? {
        var payload = [UInt8](repeating: 0, count: 24)
        payload[0] = self.payload[0]
        payload[1] = self.payload[1]
        let bits = UInt16(8) << 9 | UInt16(level & 0x3F) << 3 | 0b101
        payload[2] = UInt8(bits >> 8)
        payload[3] = UInt8(bits & 0xFF)
        payload[4] = 1 << 4 // compatibility 1, no metadata compression
        return DolbyVisionConfiguration(boxType: "dvvC", payload: payload)
    }
}

extension HEVCConfiguration {
    /// This record without the arrays of the given NAL unit types (a
    /// profile 7 record may list the enhancement layer's units).
    func removingArrays(ofTypes types: Set<UInt8>) -> HEVCConfiguration {
        guard arrays.keys.contains(where: types.contains) else { return self }
        var kept: [[UInt8]] = []
        var p = 23
        for _ in 0 ..< Int(record[22]) {
            guard p + 3 <= record.count else { break }
            let start = p
            let type = record[p] & 0x3F
            let count = Int(record[p + 1]) << 8 | Int(record[p + 2])
            p += 3
            for _ in 0 ..< count {
                guard p + 2 <= record.count else { break }
                p += 2 + (Int(record[p]) << 8 | Int(record[p + 1]))
            }
            p = min(p, record.count)
            if !types.contains(type) { kept.append(Array(record[start ..< p])) }
        }
        var rebuilt = Array(record.prefix(22))
        rebuilt.append(UInt8(kept.count))
        for array in kept { rebuilt += array }
        return HEVCConfiguration(record: rebuilt) ?? self
    }
}
