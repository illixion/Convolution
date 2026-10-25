/*
 MatroskaRemux - reading bitstream headers

 MSB-first bits with the Exp-Golomb codes H.264 and HEVC parameter sets use.
 Reads past the end return zeros and set `overrun`, so a truncated header
 parses to "unknown" rather than trapping; callers check `overrun` where a
 value matters.
 */

import Foundation

struct BitReader {
    private let bytes: [UInt8]
    private(set) var bitPosition = 0
    private(set) var overrun = false

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init<C: Collection>(_ bytes: C) where C.Element == UInt8 { self.bytes = Array(bytes) }

    var bitsLeft: Int { bytes.count * 8 - bitPosition }

    mutating func bit() -> UInt32 {
        guard bitPosition < bytes.count * 8 else {
            overrun = true
            bitPosition += 1
            return 0
        }
        let value = UInt32(bytes[bitPosition >> 3] >> (7 - UInt8(bitPosition & 7))) & 1
        bitPosition += 1
        return value
    }

    mutating func flag() -> Bool { bit() == 1 }

    mutating func bits(_ count: Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0 ..< count { value = value << 1 | bit() }
        return value
    }

    mutating func bits64(_ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0 ..< count { value = value << 1 | UInt64(bit()) }
        return value
    }

    mutating func skip(_ count: Int) {
        bitPosition += count
        if bitPosition > bytes.count * 8 { overrun = true }
    }

    /// Unsigned Exp-Golomb, ue(v).
    mutating func ue() -> UInt32 {
        var zeros = 0
        while bit() == 0 {
            zeros += 1
            if zeros > 31 || overrun { overrun = true; return 0 }
        }
        guard zeros > 0 else { return 0 }
        return (UInt32(1) << UInt32(zeros)) - 1 + bits(zeros)
    }

    /// Signed Exp-Golomb, se(v).
    mutating func se() -> Int32 {
        let code = ue()
        return code & 1 == 1 ? Int32((code + 1) / 2) : -Int32(code / 2)
    }

    /// AV1's leb128.
    mutating func leb128() -> UInt64 {
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            let byte = UInt64(bits(8))
            value |= (byte & 0x7F) << UInt64(i * 7)
            if byte & 0x80 == 0 { break }
        }
        return value
    }

    /// AV1's uvlc().
    mutating func uvlc() -> UInt32 {
        var zeros = 0
        while bit() == 0 {
            zeros += 1
            if zeros >= 32 || overrun { return UInt32.max }
        }
        return zeros >= 32 ? UInt32.max : bits(zeros) + (UInt32(1) << UInt32(zeros)) - 1
    }

    mutating func byteAlign() {
        if bitPosition & 7 != 0 { bitPosition += 8 - bitPosition & 7 }
    }
}

enum NALUnits {
    /// A NAL unit's payload with emulation-prevention bytes (00 00 03)
    /// removed, so the bit reader sees the RBSP.
    static func rbsp<C: Collection>(_ nal: C) -> [UInt8] where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(nal.count)
        var zeros = 0
        for byte in nal {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// The NAL units of a length-prefixed access unit (the MP4/Matroska form).
    static func lengthPrefixed(_ data: [UInt8], lengthSize: Int) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var p = 0
        while p + lengthSize <= data.count {
            var length = 0
            for i in 0 ..< lengthSize { length = length << 8 | Int(data[p + i]) }
            p += lengthSize
            guard length > 0, p + length <= data.count else { break }
            units.append(data[p ..< p + length])
            p += length
        }
        return units
    }
}

/// Colour as ITU-T H.273 code points, from wherever the stream says it.
public struct ColourDescription: Sendable, Equatable {
    public var primaries: Int
    public var transfer: Int
    public var matrix: Int
    public var fullRange: Bool

    public init(primaries: Int, transfer: Int, matrix: Int, fullRange: Bool) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
    }

    /// Nothing but "unspecified" (2) in all three.
    var isUnspecified: Bool { primaries == 2 && transfer == 2 && matrix == 2 }
}

/// H.264/HEVC VUI's video signal type, which both codecs write the same way.
enum VUI {
    /// Reads aspect_ratio_info, overscan_info and video_signal_type from the
    /// start of a VUI; nil without a colour description.
    static func colour(_ reader: inout BitReader) -> ColourDescription? {
        if reader.flag() { // aspect_ratio_info_present_flag
            if reader.bits(8) == 255 { reader.skip(32) } // Extended_SAR
        }
        if reader.flag() { reader.skip(1) } // overscan_info_present → overscan_appropriate
        guard reader.flag() else { return nil } // video_signal_type_present_flag
        reader.skip(3) // video_format
        let fullRange = reader.flag()
        guard reader.flag() else { // colour_description_present_flag
            return ColourDescription(primaries: 2, transfer: 2, matrix: 2, fullRange: fullRange)
        }
        let primaries = Int(reader.bits(8)), transfer = Int(reader.bits(8)), matrix = Int(reader.bits(8))
        return reader.overrun ? nil : ColourDescription(primaries: primaries, transfer: transfer, matrix: matrix, fullRange: fullRange)
    }
}
