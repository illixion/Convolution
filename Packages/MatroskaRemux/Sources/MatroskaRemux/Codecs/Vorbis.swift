/*
 MatroskaRemux - how long a Vorbis packet is

 MP4 can't carry Vorbis (AVFoundation has no decoder for it), so a Vorbis
 track is only ever decoded and offered as ALAC (`AudioTranscode.swift`),
 and that needs each packet's length to time the frames: Vorbis packets are
 either short or long blocks, chosen per packet by its mode.

 A packet's mode is the few bits after its type bit; whether that mode is a
 long block is in the setup header's mode list, the last thing in it. The
 setup header is read backwards from its framing bit, the way FFmpeg's
 Vorbis parser does it, which skips the codebooks, floors and residues
 entirely.

 A packet decodes to a quarter of the previous block plus a quarter of its
 own; with no previous packet at hand, a packet is counted as half its own
 block. Summed over a run that is off by a quarter of the first and last
 block at most (a few milliseconds), never accumulating, and every block
 time resets it.
 */

import Foundation

struct VorbisSetup: Sendable, Equatable {
    let sampleRate: Int
    let channels: Int
    /// Short and long block sizes, in samples.
    let blockSizes: (Int, Int)
    /// For each mode, whether it uses the long block.
    let modeIsLong: [Bool]

    static func == (a: VorbisSetup, b: VorbisSetup) -> Bool {
        a.sampleRate == b.sampleRate && a.channels == b.channels && a.blockSizes == b.blockSizes
            && a.modeIsLong == b.modeIsLong
    }

    init(sampleRate: Int, channels: Int, blockSizes: (Int, Int), modeIsLong: [Bool]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.blockSizes = blockSizes
        self.modeIsLong = modeIsLong
    }

    /// From Matroska's CodecPrivate: the identification, comment and setup
    /// headers, Xiph-laced.
    init?(codecPrivate: [UInt8]) {
        guard let headers = Self.xiphHeaders(codecPrivate), headers.count == 3 else { return nil }
        let ident = headers[0], setup = headers[2]
        guard ident.count >= 30, ident[0] == 1, Array(ident[1 ..< 7]) == Array("vorbis".utf8),
              setup.count > 7, setup[0] == 5 else { return nil }
        channels = Int(ident[11])
        sampleRate = Int(ident[12]) | Int(ident[13]) << 8 | Int(ident[14]) << 16 | Int(ident[15]) << 24
        let small = Int(ident[28] & 0x0F), large = Int(ident[28] >> 4)
        guard channels > 0, sampleRate > 0, (6 ... 13).contains(small), (6 ... 13).contains(large), small <= large else {
            return nil
        }
        blockSizes = (1 << small, 1 << large)
        guard let modes = Self.modes(setup: Array(setup[7...])), !modes.isEmpty else { return nil }
        modeIsLong = modes
    }

    /// The samples a packet adds, counted as half its block.
    func samples(in packet: [UInt8]) -> Int {
        guard let first = packet.first, first & 1 == 0 else { return 0 } // a header packet
        let bits = modeIsLong.count <= 1 ? 0 : Int.bitWidth - (modeIsLong.count - 1).leadingZeroBitCount
        let mode = Int(first >> 1) & ((1 << bits) - 1)
        let long = mode < modeIsLong.count ? modeIsLong[mode] : false
        return (long ? blockSizes.1 : blockSizes.0) / 2
    }

    /// The packets of Xiph lacing: a count less one, the sizes of all but
    /// the last (each a run of 255s and a final byte), then the packets.
    static func xiphHeaders(_ bytes: [UInt8]) -> [[UInt8]]? {
        guard let first = bytes.first else { return nil }
        let count = Int(first) + 1
        var i = 1
        var sizes: [Int] = []
        for _ in 0 ..< count - 1 {
            var size = 0
            while true {
                guard i < bytes.count else { return nil }
                let b = Int(bytes[i])
                i += 1
                size += b
                if b < 255 { break }
            }
            sizes.append(size)
        }
        let lacedTotal = sizes.reduce(0, +)
        guard i + lacedTotal <= bytes.count else { return nil }
        sizes.append(bytes.count - i - lacedTotal)
        var packets: [[UInt8]] = []
        for size in sizes {
            packets.append(Array(bytes[i ..< i + size]))
            i += size
        }
        return packets
    }

    /// The setup header's mode list (each mode's block flag), read from the
    /// end of the header's body (after its 7-byte packet header).
    ///
    /// Read backwards, the header ends: framing bit (1), then for each mode
    /// from the last: mapping (8 bits), transform type (16, zero), window
    /// type (16, zero), block flag (1); then the mode count less one (6).
    /// Where the count read back matches the modes counted is where the list
    /// starts: the furthest such count that the fields allow is taken, as
    /// FFmpeg does.
    static func modes(setup: [UInt8]) -> [Bool]? {
        var reader = ReverseBits(setup)
        // Padding zeros, then the framing bit.
        while true {
            guard reader.left > 0 else { return nil }
            if reader.bits(1) == 1 { break }
        }
        let start = reader.position
        var count = 0, found = 0
        while reader.left >= 97 {
            if reader.bits(8) > 63 || reader.bits(16) != 0 || reader.bits(16) != 0 { break }
            reader.skip(1)
            count += 1
            if count > 64 { break }
            let here = reader.position
            if reader.bits(6) + 1 == count { found = count }
            reader.position = here
        }
        guard found > 0 else { return nil }
        reader.position = start
        var flags = [Bool](repeating: false, count: found)
        for i in stride(from: found - 1, through: 0, by: -1) {
            reader.skip(40)
            flags[i] = reader.bits(1) == 1
        }
        return flags
    }

    /// Bits from the end of a buffer backwards: Vorbis packs fields from the
    /// least significant bit, so reading the bytes last to first, each from
    /// its most significant bit, gives every field most significant bit
    /// first.
    private struct ReverseBits {
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var left: Int { bytes.count * 8 - position }

        mutating func bits(_ n: Int) -> Int {
            var value = 0
            for _ in 0 ..< n {
                guard position < bytes.count * 8 else { return value << 1 }
                let byte = bytes[bytes.count - 1 - position / 8]
                value = value << 1 | Int(byte >> (7 - UInt8(position % 8)) & 1)
                position += 1
            }
            return value
        }

        mutating func skip(_ n: Int) { position += n }
    }
}
