/*
 MatroskaRemux - a frame of silence, per codec

 Where an audio rendition has nothing to play (a track that starts late, a
 stretch with no frames), `RemuxSession.audioFragments` puts one sample
 that covers the stretch, as AVPlayer's HLS clock stalls on audio that runs
 out. That sample used to be the track's first frame, audible as a blip
 (the start of the soundtrack, or a tone); it is now a frame built here
 from the track's own configuration that decodes to digital silence:

 - AAC (Main, LC, SSR, LTP, and HE-AAC's LC core): a raw_data_block with
   one element per channel of the AudioSpecificConfig's channel
   configuration, each long-window ICS with max_sfb 0, so no spectrum.
 - AC-3 and E-AC-3: a syncframe with the stream's sample rate, channel
   mode, LFE and frame size, every block's exponents flat, the coarse and
   fine SNR offsets 0 (which A/52 defines as "no bits allocated") and
   dither off, so every mantissa is zero; both CRCs computed. E-AC-3 only
   for a single independent substream without object audio: a frame
   without the dependent substream (7.1) or the object metadata would
   change what the decoder is decoding.
 - Opus: what libopus itself writes for digital silence, a 20 ms CELT
   frame of two bytes (FF FE), once per stream of a multistream packet.
 - FLAC: the stream's first frame header (its block size, sample rate and
   sample size codes; Apple's decoder refuses a frame that leaves them to
   STREAMINFO) over a CONSTANT 0 subframe per channel.
 - ALAC: an uncompressed ("escape") frame of zero samples, mono or stereo.
 - MP3: a frame whose granules have no Huffman data (part2_3_length 0).

 Everything else (an AAC channel configuration of 0, which needs the
 program config element; ER AAC; E-AC-3 with dependent substreams or
 object audio; ALAC beyond stereo; free-format MP3) keeps the first frame.
 Each builder is checked by decoding it with AVFoundation (CodecTests'
 `silentFramesDecodeToSilence`).
 */

import Foundation

enum SilentFrame {
    /// A frame that decodes to silence with this track's configuration, or
    /// nil where none can be made safely.
    static func make(codec: AudioCodec, firstFrame: [UInt8]) -> [UInt8]? {
        switch codec {
        case .aac(let config): aac(config)
        case .ac3(let syncframe): ac3(syncframe)
        case .eac3(let info): eac3(info, firstFrame: firstFrame)
        case .opus(let head): opus(head)
        case .flac(let info): flac(info, firstFrame: firstFrame)
        case .alac(let config): alac(config)
        case .mp3: mp3(firstFrame)
        }
    }

    // MARK: - AAC

    static func aac(_ config: AACConfig) -> [UInt8]? {
        var r = BitReader(config.asc)
        func objectType() -> Int {
            let type = Int(r.bits(5))
            return type == 31 ? 32 + Int(r.bits(6)) : type
        }
        var type = objectType()
        if r.bits(4) == 15 { r.skip(24) }
        let channelConfiguration = Int(r.bits(4))
        if type == 5 || type == 29 {
            if r.bits(4) == 15 { r.skip(24) }
            type = objectType()
        }
        // The GA syntax with ics_info's predictor flag (Main, LC, SSR, LTP).
        guard !r.overrun, [1, 2, 3, 4].contains(type) else { return nil }
        // Elements by channel configuration (ISO 14496-3 table 1.19).
        let sce = 0, cpe = 1, lfe = 3
        let elements: [Int]
        switch channelConfiguration {
        case 1: elements = [sce]
        case 2: elements = [cpe]
        case 3: elements = [sce, cpe]
        case 4: elements = [sce, cpe, sce]
        case 5: elements = [sce, cpe, cpe]
        case 6: elements = [sce, cpe, cpe, lfe]
        case 7: elements = [sce, cpe, cpe, cpe, lfe]
        default: return nil
        }
        var w = BitWriter()
        func ics() {
            w.write(100, bits: 8) // global_gain
            w.write(0, bits: 1) // ics_reserved_bit
            w.write(0, bits: 2) // window_sequence: ONLY_LONG
            w.write(0, bits: 1) // window_shape
            w.write(0, bits: 6) // max_sfb: no bands, so no sections, scale factors or spectrum
            w.write(0, bits: 1) // predictor_data_present
            w.write(0, bits: 3) // pulse, tns, gain control data present
        }
        var tags: [Int: Int] = [:]
        for element in elements {
            w.write(element, bits: 3)
            w.write(tags[element, default: 0], bits: 4)
            tags[element, default: 0] += 1
            if element == cpe {
                w.write(0, bits: 1) // common_window
                ics()
                ics()
            } else {
                ics()
            }
        }
        w.write(7, bits: 3) // ID_END
        return w.bytes
    }

    // MARK: - AC-3

    static func ac3(_ s: AC3Syncframe) -> [UInt8]? {
        guard let frameBytes = AC3Syncframe.frameBytes(fscod: s.fscod, frmsizecod: s.frmsizecod) else { return nil }
        let channels = [2, 1, 2, 3, 3, 4, 4, 5][s.acmod]
        var w = BitWriter()
        w.write(0x0B77, bits: 16)
        w.write(0, bits: 16) // crc1, below
        w.write(s.fscod, bits: 2)
        w.write(s.frmsizecod, bits: 6)
        // bsi. bsid 6's alternate syntax reads the same with its flags off.
        w.write(s.bsid, bits: 5)
        w.write(s.bsmod, bits: 3)
        w.write(s.acmod, bits: 3)
        if s.acmod & 1 != 0, s.acmod != 1 { w.write(0, bits: 2) } // cmixlev
        if s.acmod & 4 != 0 { w.write(0, bits: 2) } // surmixlev
        if s.acmod == 2 { w.write(0, bits: 2) } // dsurmod
        w.write(s.lfeon ? 1 : 0, bits: 1)
        for _ in 0 ..< (s.acmod == 0 ? 2 : 1) {
            w.write(31, bits: 5) // dialnorm
            w.write(0, bits: 3) // compre, langcode, audprodie
        }
        w.write(0, bits: 2) // copyrightb, origbs
        w.write(0, bits: 3) // timecod1e, timecod2e (xbsi1e, xbsi2e), addbsie

        for block in 0 ..< 6 {
            let first = block == 0
            w.write(0, bits: channels) // blksw
            w.write(0, bits: channels) // dithflag: off, so unallocated mantissas are 0
            w.write(0, bits: 1) // dynrnge
            if s.acmod == 0 { w.write(0, bits: 1) } // dynrng2e
            w.write(first ? 1 : 0, bits: 1) // cplstre
            if first { w.write(0, bits: 1) } // cplinu
            if s.acmod == 2 {
                w.write(first ? 1 : 0, bits: 1) // rematstr
                if first { w.write(0, bits: 4) } // rematflg, four bands
            }
            for _ in 0 ..< channels { w.write(first ? 3 : 0, bits: 2) } // chexpstr: D45, then reuse
            if s.lfeon { w.write(first ? 1 : 0, bits: 1) } // lfeexpstr
            if first {
                for _ in 0 ..< channels { w.write(0, bits: 6) } // chbwcod: 73 coefficients
                for _ in 0 ..< channels {
                    // A flat exponent (no change across six D45 groups).
                    w.write(15, bits: 4)
                    for _ in 0 ..< 6 { w.write(62, bits: 7) }
                    w.write(0, bits: 2) // gainrng
                }
                if s.lfeon {
                    w.write(15, bits: 4)
                    w.write(62, bits: 7)
                    w.write(62, bits: 7)
                }
                w.write(1, bits: 1) // baie
                w.write(2, bits: 2) // sdcycod
                w.write(1, bits: 2) // fdcycod
                w.write(1, bits: 2) // sgaincod
                w.write(2, bits: 2) // dbpbcod
                w.write(7, bits: 3) // floorcod
                w.write(1, bits: 1) // snroffste
                w.write(0, bits: 6) // csnroffst
                for _ in 0 ..< channels + (s.lfeon ? 1 : 0) {
                    w.write(0, bits: 4) // fsnroffst: with csnroffst 0, no bits anywhere
                    w.write(0, bits: 3) // fgaincod
                }
            } else {
                w.write(0, bits: 2) // baie, snroffste
            }
            w.write(0, bits: 2) // deltbaie, skiple
        }
        // auxdatae, crcrsv and the rest are zeros, then crc2.
        guard w.bytes.count <= frameBytes - 3 else { return nil }
        var frame = w.bytes + [UInt8](repeating: 0, count: frameBytes - w.bytes.count)
        let fiveEighths = ((frameBytes >> 2) + (frameBytes >> 4)) << 1
        // crc1 makes the CRC of everything from it to five eighths 0.
        let crc1 = solveLeadingCRC(frame, field: 2, end: fiveEighths)
        frame[2] = UInt8(crc1 >> 8)
        frame[3] = UInt8(crc1 & 0xFF)
        writeTrailingCRC(&frame, from: fiveEighths)
        return frame
    }

    // MARK: - E-AC-3

    static func eac3(_ info: EAC3Info, firstFrame: [UInt8]) -> [UInt8]? {
        guard info.independent.count == 1, info.independent[0].dependentCount == 0, info.objectComplexity == nil,
              let source = EAC3Info.syncframes(firstFrame).first, source.strmtyp == 0 else { return nil }
        let channels = [2, 1, 2, 3, 3, 4, 4, 5][source.acmod]
        let blocks = source.numblks
        guard let blockCode = [1: 0, 2: 1, 3: 2, 6: 3][blocks] else { return nil }
        var w = BitWriter()
        w.write(0x0B77, bits: 16)
        w.write(0, bits: 2) // strmtyp: independent
        w.write(0, bits: 3) // substreamid
        w.write(source.bytes / 2 - 1, bits: 11) // frmsiz
        w.write(source.fscod, bits: 2)
        if source.fscod == 3 {
            guard let fscod2 = [24000: 0, 22050: 1, 16000: 2][source.sampleRate] else { return nil }
            w.write(fscod2, bits: 2)
        } else {
            w.write(blockCode, bits: 2)
        }
        w.write(source.acmod, bits: 3)
        w.write(source.lfeon ? 1 : 0, bits: 1)
        w.write(source.bsid, bits: 5)
        for _ in 0 ..< (source.acmod == 0 ? 2 : 1) {
            w.write(31, bits: 5) // dialnorm
            w.write(0, bits: 1) // compre
        }
        w.write(0, bits: 2) // mixmdate, infomdate
        if blocks != 6 { w.write(0, bits: 1) } // convsync
        w.write(0, bits: 1) // addbsie

        // audfrm
        if blocks == 6 { w.write(0b10, bits: 2) } // expstre (AC-3-style strategies), ahte
        w.write(0, bits: 2) // snroffststr: one offset for the frame
        w.write(0, bits: 1) // transproce
        w.write(0, bits: 1) // blkswe
        w.write(1, bits: 1) // dithflage: the flags follow (off: without them dither is on)
        w.write(0, bits: 1) // bamode: default bit allocation parameters
        w.write(0, bits: 4) // frmfgaincode, dbaflde, skipflde, spxattene
        if source.acmod > 1 {
            w.write(0, bits: 1) // cplinu[0]
            w.write(0, bits: blocks - 1) // cplstre[1...]: as before
        }
        for block in 0 ..< blocks {
            for _ in 0 ..< channels { w.write(block == 0 ? 1 : 0, bits: 2) } // chexpstr: D15, then reuse
        }
        if source.lfeon {
            for block in 0 ..< blocks { w.write(block == 0 ? 1 : 0, bits: 1) } // lfeexpstr
        }
        if blocks == 6 {
            // convexpstr: the frame strategy table's first entry, D15 then reuse.
            for _ in 0 ..< channels { w.write(0, bits: 5) }
        } else {
            w.write(0, bits: 1) // convexpstre
        }
        w.write(0, bits: 6) // frmcsnroffst
        w.write(0, bits: 4) // frmfsnroffst: no bits anywhere
        if blocks > 1 { w.write(0, bits: 1) } // blkstrtinfoe

        for block in 0 ..< blocks {
            let first = block == 0
            w.write(0, bits: channels) // dithflag
            w.write(0, bits: 1) // dynrnge
            if source.acmod == 0 { w.write(0, bits: 1) } // dynrng2e
            if first {
                w.write(0, bits: 1) // spxinu
            } else {
                w.write(0, bits: 1) // spxstre
            }
            if source.acmod == 2 {
                if first { w.write(0, bits: 4) } else { w.write(0, bits: 1) } // rematflg / rematstr
            }
            if first {
                for _ in 0 ..< channels { w.write(0, bits: 6) } // chbwcod
                for _ in 0 ..< channels {
                    w.write(15, bits: 4)
                    for _ in 0 ..< 24 { w.write(62, bits: 7) } // D15: 24 groups for 73 coefficients
                    w.write(0, bits: 2) // gainrng
                }
                if source.lfeon {
                    w.write(15, bits: 4)
                    w.write(62, bits: 7)
                    w.write(62, bits: 7)
                }
            }
            w.write(0, bits: 1) // convsnroffste
        }
        guard w.bytes.count <= source.bytes - 3 else { return nil }
        var frame = w.bytes + [UInt8](repeating: 0, count: source.bytes - w.bytes.count)
        writeTrailingCRC(&frame, from: 2)
        return frame
    }

    // MARK: - Opus

    static func opus(_ head: OpusHead) -> [UInt8]? {
        let streams = max(1, head.streamCount)
        var packet: [UInt8] = []
        for stream in 0 ..< streams {
            let toc: UInt8 = stream < head.coupledCount ? 0xFC : 0xF8 // CELT, fullband, 20 ms
            packet.append(toc)
            if stream < streams - 1 { packet.append(2) } // self-delimited: the frame's length
            packet += [0xFF, 0xFE]
        }
        return packet
    }

    // MARK: - FLAC

    /// The stream's first frame header (frame 0, block size, sample rate and
    /// size codes as the stream states them: Apple's decoder takes no frame
    /// that leaves them to STREAMINFO) with independent channels, then a
    /// CONSTANT 0 subframe per channel.
    static func flac(_ info: FLACStreamInfo, firstFrame: [UInt8]) -> [UInt8]? {
        guard firstFrame.count >= 6, firstFrame[0] == 0xFF, firstFrame[1] & 0xFE == 0xF8 else { return nil }
        let blockCode = Int(firstFrame[2] >> 4), rateCode = Int(firstFrame[2] & 0x0F)
        let sizeCode = Int((firstFrame[3] >> 1) & 0x07)
        // The coded frame or sample number, UTF-8 style.
        let lead = firstFrame[4]
        let numberLength = lead < 0x80 ? 1 : (lead.leadingZeroBitCount == 0 ? (~lead).leadingZeroBitCount : 0)
        guard (1 ... 7).contains(numberLength) else { return nil }
        var length = 4 + numberLength
        length += blockCode == 6 ? 1 : blockCode == 7 ? 2 : 0
        length += rateCode == 12 ? 1 : (rateCode == 13 || rateCode == 14) ? 2 : 0
        guard firstFrame.count > length, blockCode != 0, rateCode != 15 else { return nil }
        let bits = [0: info.bitsPerSample, 1: 8, 2: 12, 4: 16, 5: 20, 6: 24, 7: 32][sizeCode] ?? 0
        guard bits > 0, (1 ... 8).contains(info.channels) else { return nil }
        var header = Array(firstFrame[0 ..< length])
        header[3] = UInt8(info.channels - 1) << 4 | (firstFrame[3] & 0x0F) // independent channels
        header.append(crc8(header))
        var w = BitWriter()
        for byte in header { w.write(Int(byte), bits: 8) }
        for _ in 0 ..< info.channels {
            w.write(0, bits: 8) // padding, CONSTANT, no wasted bits
            w.write(0, bits: bits)
        }
        var frame = w.bytes
        let crc = crc16(frame, 0 ..< frame.count)
        frame += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return frame
    }

    // MARK: - ALAC

    static func alac(_ config: ALACConfig) -> [UInt8]? {
        guard config.channels == 1 || config.channels == 2, [16, 20, 24, 32].contains(config.bitDepth) else { return nil }
        var w = BitWriter()
        w.write(config.channels == 1 ? 0 : 1, bits: 3) // ID_SCE or ID_CPE
        w.write(0, bits: 4) // element instance tag
        w.write(0, bits: 12) // unused
        w.write(0b0001, bits: 4) // whole frame, no shift, escape: uncompressed
        var frame = w.bytes
        // The samples: frameLength × channels × bitDepth zero bits, then
        // ID_END. The header was 23 bits, so the zeros start mid-byte.
        let sampleBits = Int(config.frameLength) * config.channels * config.bitDepth
        let totalBits = 23 + sampleBits + 3
        frame += [UInt8](repeating: 0, count: (totalBits + 7) / 8 - frame.count)
        // ID_END (111) right after the samples.
        let endBit = 23 + sampleBits
        for i in 0 ..< 3 {
            let bit = endBit + i
            frame[bit >> 3] |= 0x80 >> UInt8(bit & 7)
        }
        return frame
    }

    // MARK: - MP3

    static func mp3(_ firstFrame: [UInt8]) -> [UInt8]? {
        guard let header = MPEGAudioHeader(firstFrame), header.layer == 3 else { return nil }
        let bitrateIndex = Int(firstFrame[2] >> 4)
        let table = header.version == 1
            ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        guard let kbps = table[safe: bitrateIndex], kbps > 0 else { return nil }
        let bytes = (header.version == 1 ? 144 : 72) * kbps * 1000 / header.sampleRate
        let sideInfo = header.version == 1 ? (header.channels == 1 ? 17 : 32) : (header.channels == 1 ? 9 : 17)
        guard bytes >= 4 + sideInfo else { return nil }
        var frame = [UInt8](repeating: 0, count: bytes)
        frame[0] = 0xFF
        frame[1] = firstFrame[1] | 0x01 // no CRC
        frame[2] = firstFrame[2] & 0xFC // no padding, no private bit
        frame[3] = firstFrame[3] & 0xC0 // the channel mode; no mode extension, flags or emphasis
        // Side information all zeros: no main data, no Huffman data.
        return frame
    }

    // MARK: - CRCs

    /// CRC-16 with x^16 + x^15 + x^2 + 1, MSB first, from 0: AC-3's and
    /// FLAC's.
    static func crc16(_ bytes: [UInt8], _ range: Range<Int>) -> UInt16 {
        var crc: UInt16 = 0
        for i in range {
            crc ^= UInt16(bytes[i]) << 8
            for _ in 0 ..< 8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return crc
    }

    /// FLAC's header CRC-8 (x^8 + x^2 + x + 1).
    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0 ..< 8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    /// The last two bytes: the CRC of everything from `start` before them
    /// (the reserved bit ahead flipped if the CRC would read as a sync word).
    static func writeTrailingCRC(_ frame: inout [UInt8], from start: Int) {
        var crc = crc16(frame, start ..< frame.count - 2)
        if crc == 0x0B77 {
            frame[frame.count - 3] ^= 0x01
            crc = crc16(frame, start ..< frame.count - 2)
        }
        frame[frame.count - 2] = UInt8(crc >> 8)
        frame[frame.count - 1] = UInt8(crc & 0xFF)
    }

    /// The 16-bit value at `field` that makes the CRC of `field ..< end`
    /// zero. The CRC is linear in the field's bits, so the value solves
    /// sixteen equations over GF(2).
    static func solveLeadingCRC(_ frame: [UInt8], field: Int, end: Int) -> UInt16 {
        var bytes = frame
        func crc(_ value: UInt16) -> UInt16 {
            bytes[field] = UInt8(value >> 8)
            bytes[field + 1] = UInt8(value & 0xFF)
            return crc16(bytes, field ..< end)
        }
        let base = crc(0)
        // Columns: what each bit of the field adds to the CRC.
        var rows: [(lhs: UInt16, bit: UInt16)] = (0 ..< 16).map { i in (crc(1 << UInt16(i)) ^ base, 1 << UInt16(i)) }
        // Gaussian elimination: find a combination of columns equal to base.
        var target = base
        var solution: UInt16 = 0
        for pivot in (0 ..< 16).reversed() {
            let mask = UInt16(1) << UInt16(pivot)
            guard let index = rows.firstIndex(where: { $0.lhs & mask != 0 }) else { continue }
            let row = rows.remove(at: index)
            for i in rows.indices where rows[i].lhs & mask != 0 {
                rows[i].lhs ^= row.lhs
                rows[i].bit ^= row.bit
            }
            if target & mask != 0 {
                target ^= row.lhs
                solution ^= row.bit
            }
        }
        return solution
    }
}
