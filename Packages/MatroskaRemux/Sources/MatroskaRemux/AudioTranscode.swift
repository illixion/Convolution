/*
 MatroskaRemux - audio MP4 can't carry, decoded and offered as ALAC

 DTS and TrueHD have no MP4 sample entry AVFoundation plays and no decoder
 on Apple platforms. When the caller supplies a decoder for a codec
 (`RemuxOptions.audioDecoding`; the app's sideload edition passes FFmpeg's),
 such a track becomes a rendition like any other, as lossless 24-bit ALAC.
 Nothing else changes: the track keeps its own timeline, segment boundaries
 and gap handling (`RemuxSession.audioFragments`).

 Each segment is decoded on its own, with a new decoder, from its own frames
 plus the previous segment's last quarter second (`primingSeconds`), so a
 segment asked for twice is the same bytes. The priming matters for both
 codecs: TrueHD only starts at a major sync, and a fresh DTS decoder's
 filterbank has no history, which left the first ~80 ms of every segment
 off by up to a tenth of full scale (measured against ffmpeg decoding the
 whole track). The PCM is laid over the span its frames cover, measured from the
 end: a decoder primed or delayed by a frame lines up with the last sample
 either way.

 The ALAC is written uncompressed (escape frames), which is exact for any
 packet length and costs no encoder: 24-bit 5.1 at 48 kHz is 6.9 Mbps, and
 it only ever crosses the loopback interface to the player.
 */

import Foundation

/// Where a decoded channel plays.
public enum RemuxSpeaker: Sendable, Equatable {
    case frontLeft, frontRight, frontCenter, lowFrequency
    case backLeft, backRight, backCenter, sideLeft, sideRight
    case other
}

/// Decodes one stretch of a stream (see `RemuxAudioDecoding`).
public protocol RemuxAudioDecoder: AnyObject {
    /// One stored frame, in order.
    func feed(_ frame: [UInt8])
    /// Decodes whatever is still held back.
    func finish()
    /// Known once something has decoded.
    var sampleRate: Int { get }
    var speakers: [RemuxSpeaker] { get }
    /// Decoded frames so far (a sample per channel each).
    var frameCount: Int { get }
    /// The PCM, interleaved, 24-bit values in 32-bit integers.
    func withSamples<R>(_ body: (UnsafeBufferPointer<Int32>) throws -> R) rethrows -> R
}

/// The decoders a session may use for audio MP4 can't carry.
public struct RemuxAudioDecoding: Sendable {
    /// Whether a Matroska CodecID can be decoded.
    public var decodes: @Sendable (_ codecID: String) -> Bool
    /// A new decoder for one stretch of a track.
    public var make: @Sendable (_ codecID: String, _ codecPrivate: [UInt8]) -> (any RemuxAudioDecoder)?

    public init(decodes: @escaping @Sendable (String) -> Bool,
                make: @escaping @Sendable (String, [UInt8]) -> (any RemuxAudioDecoder)?) {
        self.decodes = decodes
        self.make = make
    }
}

/// How a decoded track is planned: the source's frame timing and the
/// channel order ALAC wants.
struct AudioTranscode: Sendable {
    enum Source: Sendable {
        /// Constant frames (DTS: a frame's samples at the decoded rate).
        case constant(Int)
        /// TrueHD/MLP: access units of `samplesPerUnit` each, one or several
        /// to a block. An access unit is 1/1200 s, under Matroska's usual
        /// millisecond tick, so block times alone collide; each unit's
        /// `input_timing` (a 16-bit sample counter) places it exactly,
        /// counted from the first one's (`timingOrigin`).
        case accessUnits(samplesPerUnit: Int, timingOrigin: UInt16?)
    }

    let decoding: RemuxAudioDecoding
    let codecID: String
    let codecPrivate: [UInt8]
    let source: Source
    /// For each ALAC channel, the decoded channel it takes.
    let order: [Int]
    let config: ALACConfig
    /// How much of the previous segment is decoded first (and thrown
    /// away), so the decoder's state at the segment's start is the state a
    /// decoder playing straight through would have.
    let primingSeconds: Double

    var constantFrameSamples: Int? {
        if case .constant(let n) = source { return n }
        return nil
    }

    func samples(in frame: [UInt8]) -> Int {
        switch source {
        case .constant(let n): return n
        case .accessUnits(let perUnit, _): return max(1, Self.accessUnits(in: frame)) * perUnit
        }
    }

    /// How far (in samples) a counter-given time may be from the block
    /// time: 50 ms at 192 kHz, far beyond a tick's rounding.
    private var sampleRateBound: Int { 9600 }

    /// A TrueHD/MLP block's first access unit's `input_timing`.
    static func inputTiming(_ frame: [UInt8]) -> UInt16? {
        guard frame.count >= 4 else { return nil }
        return UInt16(frame[2]) << 8 | UInt16(frame[3])
    }

    /// A frame's time in samples, from its block time (`raw`, unsnapped)
    /// and, for TrueHD/MLP, its own sample counter; `origin` is the first
    /// frame's time. Nil: use the block time.
    func time(raw: Int64, origin: Int64, frame: [UInt8]) -> Int64? {
        guard case .accessUnits(_, let timingOrigin?) = source, let timing = Self.inputTiming(frame) else { return nil }
        // Where the counter says, within ±32768 samples of where the block
        // time says: the block time is off by under a millisecond.
        let counted = Int64(timing &- timingOrigin)
        let wrapped = Int64(Int16(truncatingIfNeeded: counted - (raw - origin)))
        // Further out than a block time can be wrong by: the counter isn't
        // in samples here, so the block time it is.
        guard abs(wrapped) <= Int64(sampleRateBound) else { return nil }
        return raw + wrapped
    }

    /// TrueHD/MLP access units in a block: each starts with a 4-bit check
    /// nibble and its own length in 16-bit words.
    static func accessUnits(in frame: [UInt8]) -> Int {
        var i = 0, count = 0
        while i + 2 <= frame.count {
            let words = (Int(frame[i] & 0x0F) << 8) | Int(frame[i + 1])
            guard words >= 2 else { break }
            count += 1
            i += words * 2
        }
        return count
    }

    /// ALAC's channel order for each count it has a default layout for,
    /// ending with the LFE: C, L R, Ls Rs, Cs, LFE.
    static func alacOrder(for speakers: [RemuxSpeaker]) -> [Int]? {
        func index(_ wanted: RemuxSpeaker...) -> Int? {
            for speaker in wanted { if let i = speakers.firstIndex(of: speaker) { return i } }
            return nil
        }
        switch speakers.count {
        case 1: return [0]
        case 2: return [0, 1]
        default: break
        }
        guard let c = index(.frontCenter), let l = index(.frontLeft), let r = index(.frontRight) else { return nil }
        switch speakers.count {
        case 3: return [c, l, r]
        case 4:
            guard let cs = index(.backCenter) else { return nil }
            return [c, l, r, cs]
        case 5, 6:
            guard let ls = index(.sideLeft, .backLeft), let rs = index(.sideRight, .backRight) else { return nil }
            if speakers.count == 5 { return [c, l, r, ls, rs] }
            guard let lfe = index(.lowFrequency) else { return nil }
            return [c, l, r, ls, rs, lfe]
        default:
            return nil
        }
    }

    /// The ALACSpecificConfig for decoded PCM.
    static func alacConfig(channels: Int, sampleRate: Int) -> ALACConfig {
        let frameLength = ALACEscape.frameLength
        var bytes: [UInt8] = []
        func u32(_ v: Int) { bytes += [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        u32(frameLength)
        bytes += [0, 24, 40, 10, 14, UInt8(channels)] // version, bit depth, pb, mb, kb, channels
        bytes += [0, 255] // maxRun
        u32(ALACEscape.maxBytes(channels: channels, frames: frameLength))
        u32(channels * 24 * sampleRate) // average bitrate
        u32(sampleRate)
        return ALACConfig(codecPrivate: bytes)!
    }
}

/// Uncompressed ("escape") ALAC frames, 24-bit.
enum ALACEscape {
    static let frameLength = 4096
    private static let bitDepth = 24

    /// The element sequence for a channel count (ALAC's default layouts):
    /// true for a channel pair, false for one channel.
    static func elements(channels: Int) -> [Bool] {
        switch channels {
        case 1: [false]
        case 2: [true]
        case 3: [false, true]
        case 4: [false, true, false]
        case 5: [false, true, true]
        case 6: [false, true, true, false]
        case 7: [false, true, true, false, false]
        default: [false, true, true, true, false]
        }
    }

    static func maxBytes(channels: Int, frames: Int) -> Int {
        // Per element 23 header bits and a 32-bit sample count, then the end tag.
        (elements(channels: channels).count * 55 + frames * channels * bitDepth + 3 + 7) / 8
    }

    /// One frame of `frames` samples per channel, from interleaved PCM
    /// already in ALAC's channel order.
    static func frame(_ pcm: UnsafeBufferPointer<Int32>, from start: Int, frames: Int, channels: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(maxBytes(channels: channels, frames: frames))
        var accumulator: UInt64 = 0
        var pending = 0
        @inline(__always) func put(_ value: UInt64, _ bits: Int) {
            accumulator = (accumulator << UInt64(bits)) | (value & ((1 << UInt64(bits)) - 1))
            pending += bits
            while pending >= 8 {
                pending -= 8
                out.append(UInt8(truncatingIfNeeded: accumulator >> UInt64(pending)))
            }
        }
        let partial = frames != frameLength
        var channel = 0
        var singles = 0, pairs = 0
        for isPair in elements(channels: channels) {
            put(isPair ? 1 : 0, 3) // ID_CPE or ID_SCE
            put(UInt64(isPair ? pairs : singles), 4) // element instance tag
            if isPair { pairs += 1 } else { singles += 1 }
            put(0, 12)
            put(partial ? 0b1001 : 0b0001, 4) // partial frame, no shift, escape
            if partial { put(UInt64(frames), 32) }
            let width = isPair ? 2 : 1
            for i in 0 ..< frames {
                let base = (start + i) * channels + channel
                for c in 0 ..< width {
                    put(UInt64(UInt32(bitPattern: pcm[base + c])), bitDepth)
                }
            }
            channel += width
        }
        put(7, 3) // ID_END
        if pending > 0 { put(0, 8 - pending) }
        return out
    }

    /// A whole frame of silence (a placeholder).
    static func silence(channels: Int) -> [UInt8] {
        let zeros = [Int32](repeating: 0, count: frameLength * channels)
        return zeros.withUnsafeBufferPointer { frame($0, from: 0, frames: frameLength, channels: channels) }
    }
}
