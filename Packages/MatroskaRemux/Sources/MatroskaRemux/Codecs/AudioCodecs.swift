/*
 MatroskaRemux - the audio codecs, and how long each of their frames is

 MP4 timestamps audio in samples: the track's timescale is its sample rate
 and each sample's duration is how many PCM samples the frame decodes to.
 Matroska's block timestamps are rounded to its tick (a millisecond, usually),
 so durations taken from timestamp differences jitter by a sample or two and
 leave gaps and overlaps the player hears as clicks. Every codec here says
 its own frame length instead: AAC 1024 (or 960), AC-3 1536, E-AC-3 256 per
 audio block, Opus from each packet's TOC, FLAC from each frame header, MP3
 1152 or 576, ALAC its configured frame length.

 Each codec also supplies what its MP4 sample entry needs that Matroska
 doesn't store: the AudioSpecificConfig for legacy `A_AAC/MPEG4/...` ids, the
 dac3/dec3 fields from the first syncframe, dOps from OpusHead, dfLa from
 FLAC's STREAMINFO.
 */

import Foundation

enum AudioCodec: Sendable {
    case aac(AACConfig)
    case ac3(AC3Syncframe)
    case eac3(EAC3Info)
    case opus(OpusHead)
    case flac(FLACStreamInfo)
    case alac(ALACConfig)
    case mp3(MPEGAudioHeader)

    /// PCM samples in one stored frame, at the track's timescale; nil when
    /// the frame doesn't say (the caller then uses the codec's usual size).
    func samples(in frame: [UInt8]) -> Int? {
        switch self {
        case .aac(let config): config.frameLength
        case .ac3: AC3Syncframe.samples(in: frame)
        case .eac3: EAC3Info.samples(in: frame)
        case .opus: OpusHead.samples(inPacket: frame)
        case .flac(let info): FLACStreamInfo.blockSize(ofFrame: frame) ?? info.fixedBlockSize
        case .alac(let config): Int(config.frameLength)
        case .mp3: MPEGAudioHeader.samples(in: frame)
        }
    }

    /// The frame size when every frame has it (the grid audio timestamps
    /// are snapped to); nil for codecs whose frames vary.
    var constantFrameSamples: Int? {
        switch self {
        case .aac(let config): config.frameLength
        case .ac3: 1536
        case .eac3(let info): info.samplesPerFrame
        case .opus(let head): head.firstPacketSamples
        case .flac(let info): info.fixedBlockSize
        case .alac(let config): Int(config.frameLength)
        case .mp3(let header): header.samplesPerFrame
        }
    }
}

// MARK: - AAC

struct AACConfig: Sendable {
    /// The AudioSpecificConfig.
    var asc: [UInt8]
    /// The audio object type as signalled (2 LC, 5 SBR, 29 PS).
    var objectType: Int
    /// Core sampling rate: the track's timescale.
    var sampleRate: Int
    var channels: Int
    var frameLength: Int

    static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// From an AudioSpecificConfig (A_AAC's CodecPrivate).
    init?(asc: [UInt8], channelsHint: Int) {
        guard asc.count >= 2 else { return nil }
        var r = BitReader(asc)
        func readObjectType() -> Int {
            let type = Int(r.bits(5))
            return type == 31 ? 32 + Int(r.bits(6)) : type
        }
        func rate() -> Int? {
            let index = Int(r.bits(4))
            return index == 15 ? Int(r.bits(24)) : Self.rates[safe: index]
        }
        var type = readObjectType()
        guard let coreRate = rate() else { return nil }
        let channelConfig = Int(r.bits(4))
        let signalled = type
        if type == 5 || type == 29 {
            _ = rate() // extension sampling frequency
            type = readObjectType()
        }
        // GASpecificConfig's frameLengthFlag: 960-sample frames.
        var frameLength = 1024
        if [1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23].contains(type), r.flag() { frameLength = 960 }
        guard !r.overrun else { return nil }
        self.asc = asc
        objectType = signalled
        sampleRate = coreRate
        let configured = [0, 1, 2, 3, 4, 5, 6, 8][safe: channelConfig] ?? 0
        channels = configured > 0 ? configured : max(1, channelsHint)
        self.frameLength = frameLength
    }

    /// For the legacy codec ids (`A_AAC/MPEG4/LC`, `/MAIN`, `/LC/SBR`,
    /// `/MPEG2/LC`…) that carry no CodecPrivate: an AudioSpecificConfig from
    /// the id, the track's rates and its channel count, as ffmpeg's Matroska
    /// demuxer builds it.
    init?(legacyCodecID: String, sampleRate: Double, outputSampleRate: Double?, channels: Int) {
        let profile: Int
        if legacyCodecID.contains("/MAIN") { profile = 1 }
        else if legacyCodecID.contains("/SSR") { profile = 3 }
        else if legacyCodecID.contains("/LTP") { profile = 4 }
        else { profile = 2 }
        let rate = Int(sampleRate.rounded())
        guard let rateIndex = Self.rates.firstIndex(of: rate) else { return nil }
        var asc: [UInt8] = [UInt8(profile << 3 | rateIndex >> 1), UInt8((rateIndex & 1) << 7 | (channels & 0xF) << 3)]
        if legacyCodecID.contains("SBR") {
            let output = Int((outputSampleRate ?? sampleRate * 2).rounded())
            let outputIndex = Self.rates.firstIndex(of: output) ?? max(0, rateIndex - 3)
            // Backward-compatible explicit SBR signalling (sync extension 0x2B7).
            asc += [0x56, 0xE5, UInt8(0x80 | outputIndex << 3)]
        }
        self.init(asc: asc, channelsHint: channels)
        // Backward-compatible signalling still reads as LC; the stream is
        // HE-AAC, which is what a player should be told.
        if legacyCodecID.contains("SBR") { objectType = 5 }
    }

    var codecString: String { "mp4a.40.\(objectType)" }
}

// MARK: - AC-3

struct AC3Syncframe: Sendable {
    var fscod: Int
    var frmsizecod: Int
    var bsid: Int
    var bsmod: Int
    var acmod: Int
    var lfeon: Bool

    var sampleRate: Int { [48000, 44100, 32000][safe: fscod] ?? 48000 }
    var channels: Int { [2, 1, 2, 3, 3, 4, 4, 5][acmod] + (lfeon ? 1 : 0) }

    init?(_ frame: [UInt8]) {
        guard frame.count >= 7, frame[0] == 0x0B, frame[1] == 0x77 else { return nil }
        var r = BitReader(frame.dropFirst(4))
        fscod = Int(r.bits(2))
        frmsizecod = Int(r.bits(6))
        bsid = Int(r.bits(5))
        guard fscod < 3, bsid <= 8 else { return nil }
        bsmod = Int(r.bits(3))
        acmod = Int(r.bits(3))
        if acmod & 1 != 0, acmod != 1 { r.skip(2) } // cmixlev
        if acmod & 4 != 0 { r.skip(2) } // surmixlev
        if acmod == 2 { r.skip(2) } // dsurmod
        lfeon = r.flag()
    }

    /// Bytes in a syncframe.
    static func frameBytes(fscod: Int, frmsizecod: Int) -> Int? {
        let kbps = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
        guard let rate = kbps[safe: frmsizecod >> 1] else { return nil }
        switch fscod {
        case 0: return rate * 4
        case 1: return (320 * rate / 147 + (frmsizecod & 1)) * 2
        case 2: return rate * 6
        default: return nil
        }
    }

    /// 1536 for each syncframe the block holds (one, almost always).
    static func samples(in frame: [UInt8]) -> Int? {
        var p = 0, count = 0
        while p + 5 <= frame.count, frame[p] == 0x0B, frame[p + 1] == 0x77 {
            guard let bytes = frameBytes(fscod: Int(frame[p + 4] >> 6), frmsizecod: Int(frame[p + 4] & 0x3F)) else { break }
            count += 1
            p += bytes
        }
        return count > 0 ? count * 1536 : nil
    }

    /// The dac3 box payload.
    var dac3: [UInt8] {
        let bitRateCode = frmsizecod >> 1
        let value = UInt32(fscod) << 22 | UInt32(bsid) << 17 | UInt32(bsmod) << 14 | UInt32(acmod) << 11
            | UInt32(lfeon ? 1 : 0) << 10 | UInt32(bitRateCode) << 5
        return [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

// MARK: - E-AC-3

struct EAC3Info: Sendable {
    struct Substream: Sendable {
        var fscod: Int
        var bsid: Int
        var bsmod: Int
        var acmod: Int
        var lfeon: Bool
        var dependentCount = 0
        var channelLocations = 0
    }

    var independent: [Substream]
    var sampleRate: Int
    var samplesPerFrame: Int
    var dataRateKbps: Int
    var channels: Int
    /// The stream carries object audio (JOC), with this complexity index.
    var objectComplexity: Int?

    /// One E-AC-3 syncframe's bit stream info.
    struct Syncframe {
        var strmtyp: Int
        var substreamID: Int
        var bytes: Int
        var fscod: Int
        var numblks: Int
        var acmod: Int
        var lfeon: Bool
        var bsid: Int
        var channelMap: Int?
        var sampleRate: Int
        /// complexity_index_type_a when the frame says it carries object
        /// (JOC) extension data; nil otherwise.
        var objectComplexity: Int?

        init?(_ data: ArraySlice<UInt8>) {
            guard data.count >= 6, data[data.startIndex] == 0x0B, data[data.startIndex + 1] == 0x77 else { return nil }
            var r = BitReader(data.dropFirst(2))
            strmtyp = Int(r.bits(2))
            substreamID = Int(r.bits(3))
            bytes = (Int(r.bits(11)) + 1) * 2
            fscod = Int(r.bits(2))
            var numblkscod = 3
            if fscod == 3 {
                let fscod2 = Int(r.bits(2))
                sampleRate = [24000, 22050, 16000][safe: fscod2] ?? 24000
            } else {
                numblkscod = Int(r.bits(2))
                sampleRate = [48000, 44100, 32000][fscod]
            }
            numblks = [1, 2, 3, 6][numblkscod]
            acmod = Int(r.bits(3))
            lfeon = r.flag()
            bsid = Int(r.bits(5))
            guard bsid > 10, bsid <= 16 else { return nil }
            r.skip(5) // dialnorm
            if r.flag() { r.skip(8) } // compre → compr
            if acmod == 0 { // 1+1: the second channel's dialnorm and compr
                r.skip(5)
                if r.flag() { r.skip(8) }
            }
            if strmtyp == 1, r.flag() { // chanmape
                channelMap = Int(r.bits(16))
            }
            objectComplexity = Self.objectComplexity(&r, strmtyp: strmtyp, acmod: acmod, lfeon: lfeon,
                                                     numblks: numblks, reducedRate: fscod == 3)
        }

        /// Reads on through the rest of the bit stream info (mixing and
        /// informational metadata, as ETSI TS 102 366 E.1.2.2 lays it out)
        /// to the additional info, whose first byte's low bit is
        /// flag_ec3_extension_type_a: object audio, with its complexity
        /// index in the next byte. ffmpeg reads it the same way.
        private static func objectComplexity(_ r: inout BitReader, strmtyp: Int, acmod: Int, lfeon: Bool,
                                             numblks: Int, reducedRate: Bool) -> Int? {
            if r.flag() { // mixmdate
                if acmod > 2 {
                    r.skip(2) // dmixmod
                    if acmod & 1 != 0 { r.skip(6) } // ltrtcmixlev, lorocmixlev
                    if acmod & 4 != 0 { r.skip(6) } // ltrtsurmixlev, lorosurmixlev
                }
                if lfeon, r.flag() { r.skip(5) } // lfemixlevcode
                if strmtyp == 0 {
                    for _ in 0 ..< (acmod == 0 ? 2 : 1) where r.flag() { r.skip(6) } // pgmscl
                    if r.flag() { r.skip(6) } // extpgmscl
                    switch r.bits(2) { // mixdef
                    case 1: r.skip(5)
                    case 2: r.skip(12)
                    case 3: r.skip((Int(r.bits(5)) + 2) * 8)
                    default: break
                    }
                    if acmod < 2 {
                        for _ in 0 ..< (acmod == 0 ? 2 : 1) where r.flag() { r.skip(14) } // paninfo
                    }
                    if r.flag() { // frmmixcfginfoe
                        for _ in 0 ..< numblks where numblks == 1 || r.flag() { r.skip(5) }
                    }
                }
            }
            if r.flag() { // infomdate
                r.skip(5) // bsmod, copyrightb, origbs
                if acmod == 2 { r.skip(4) } // dsurmod, dheadphonmod
                if acmod >= 6 { r.skip(2) } // dsurexmod
                for _ in 0 ..< (acmod == 0 ? 2 : 1) where r.flag() { r.skip(8) } // audprodi
                if !reducedRate { r.skip(1) } // sourcefscod
            }
            if strmtyp == 0, numblks != 6 { r.skip(1) } // convsync
            if strmtyp == 2, numblks == 6 || r.flag() { r.skip(6) } // frmsizecod
            guard r.flag() else { return nil } // addbsie
            let length = Int(r.bits(6)) + 1
            r.skip(7)
            guard length >= 2, r.flag() else { return nil } // flag_ec3_extension_type_a
            let complexity = Int(r.bits(8))
            return r.overrun ? nil : complexity
        }
    }

    init?(_ frame: [UInt8]) {
        let syncframes = Self.syncframes(frame)
        guard let first = syncframes.first, first.strmtyp != 1 else { return nil }
        var independent: [Substream] = []
        for frame in syncframes {
            if frame.strmtyp == 1 {
                guard !independent.isEmpty else { continue }
                independent[independent.count - 1].dependentCount += 1
                // Dependent substream channel locations (dec3's chan_loc):
                // the channel map's bits above the independent stream's
                // 5.1, folded to dec3's nine-bit layout.
                if let map = frame.channelMap {
                    independent[independent.count - 1].channelLocations |= Self.channelLocations(fromChannelMap: map)
                }
            } else if frame.substreamID == independent.count {
                independent.append(Substream(fscod: frame.fscod, bsid: frame.bsid, bsmod: 0, acmod: frame.acmod,
                                             lfeon: frame.lfeon))
            }
        }
        guard !independent.isEmpty else { return nil }
        self.independent = independent
        sampleRate = first.sampleRate
        samplesPerFrame = first.numblks * 256
        let totalBytes = syncframes.reduce(0) { $0 + $1.bytes }
        dataRateKbps = totalBytes * 8 * sampleRate / samplesPerFrame / 1000
        let base = [2, 1, 2, 3, 3, 4, 4, 5][first.acmod] + (first.lfeon ? 1 : 0)
        let extra = Self.channelCount(ofLocations: independent[0].channelLocations)
        channels = base + extra
        objectComplexity = first.objectComplexity
    }

    static func syncframes(_ frame: [UInt8]) -> [Syncframe] {
        var result: [Syncframe] = []
        var p = 0
        while p < frame.count, let syncframe = Syncframe(frame[p...]) {
            result.append(syncframe)
            p += syncframe.bytes
        }
        return result
    }

    /// 256 per audio block of the first independent substream's
    /// syncframes (a block holds one access unit of 1536 samples, normally).
    static func samples(in frame: [UInt8]) -> Int? {
        let frames = syncframes(frame).filter { $0.strmtyp != 1 && $0.substreamID == 0 }
        return frames.isEmpty ? nil : frames.reduce(0) { $0 + $1.numblks * 256 }
    }

    /// chanmap (16 bits, MSB first: L C R Ls Rs Lc/Rc Lrs/Rrs Cs Ts
    /// Lsd/Rsd Lw/Rw Vhl/Vhr Vhc Lts/Rts LFE2 LFE) to dec3's chan_loc (9
    /// bits, MSB first: Lc/Rc, Lrs/Rrs, Cs, Ts, Lsd/Rsd, Lw/Rw, Lvh/Rvh,
    /// Cvh, LFE2). Lts/Rts has no chan_loc bit.
    static func channelLocations(fromChannelMap map: Int) -> Int {
        var locations = 0
        for (bit, mapBit) in [5, 6, 7, 8, 9, 10, 11, 12, 14].enumerated() where map & (1 << (15 - mapBit)) != 0 {
            locations |= 1 << (8 - bit)
        }
        return locations
    }

    /// Channels a chan_loc adds (the pairs count twice).
    static func channelCount(ofLocations locations: Int) -> Int {
        let weights = [2, 2, 1, 1, 2, 2, 2, 1, 1]
        return weights.enumerated().reduce(0) { $0 + (locations & (1 << (8 - $1.offset)) != 0 ? $1.element : 0) }
    }

    /// The dec3 box payload.
    var dec3: [UInt8] {
        var w = BitWriter()
        w.write(dataRateKbps, bits: 13)
        w.write(independent.count - 1, bits: 3)
        for sub in independent {
            w.write(sub.fscod, bits: 2)
            w.write(sub.bsid, bits: 5)
            w.write(0, bits: 1) // reserved
            w.write(0, bits: 1) // asvc
            w.write(sub.bsmod, bits: 3)
            w.write(sub.acmod, bits: 3)
            w.write(sub.lfeon ? 1 : 0, bits: 1)
            w.write(0, bits: 3) // reserved
            w.write(sub.dependentCount, bits: 4)
            if sub.dependentCount > 0 {
                w.write(sub.channelLocations, bits: 9)
            } else {
                w.write(0, bits: 1)
            }
        }
        // ETSI TS 103 420: flag_ec3_extension_type_a and the complexity
        // index, which tell a decoder the stream has object audio.
        if let complexity = objectComplexity {
            w.write(0, bits: 7)
            w.write(1, bits: 1)
            w.write(complexity, bits: 8)
        }
        return w.bytes
    }
}

// MARK: - Opus

struct OpusHead: Sendable {
    var channels: Int
    var preSkip: Int
    var inputSampleRate: Int
    var outputGain: Int16
    var mappingFamily: Int
    var streamCount: Int
    var coupledCount: Int
    var channelMapping: [UInt8]
    /// The first packet's length in samples (the snapping grid when every
    /// packet has it, which encoders do).
    var firstPacketSamples: Int?

    init?(_ data: [UInt8]) {
        guard data.count >= 19, data.starts(with: Array("OpusHead".utf8)) else { return nil }
        channels = Int(data[9])
        preSkip = Int(data[10]) | Int(data[11]) << 8
        inputSampleRate = Int(data[12]) | Int(data[13]) << 8 | Int(data[14]) << 16 | Int(data[15]) << 24
        outputGain = Int16(bitPattern: UInt16(data[16]) | UInt16(data[17]) << 8)
        mappingFamily = Int(data[18])
        if mappingFamily != 0 {
            guard data.count >= 21 + channels else { return nil }
            streamCount = Int(data[19])
            coupledCount = Int(data[20])
            channelMapping = Array(data[21 ..< 21 + channels])
        } else {
            streamCount = 1
            coupledCount = channels > 1 ? 1 : 0
            channelMapping = []
        }
        guard channels > 0 else { return nil }
    }

    /// The dOps box payload (big-endian, unlike OpusHead).
    var dOps: [UInt8] {
        var w = BoxWriter()
        w.u8(0) // Version
        w.u8(UInt8(channels))
        w.u16(UInt16(preSkip))
        w.u32(UInt32(inputSampleRate))
        w.u16(UInt16(bitPattern: outputGain))
        w.u8(UInt8(mappingFamily))
        if mappingFamily != 0 {
            w.u8(UInt8(streamCount))
            w.u8(UInt8(coupledCount))
            w.bytes += channelMapping
        }
        return w.bytes
    }

    /// A packet's duration at 48 kHz from its TOC byte (RFC 6716 §3.1).
    static func samples(inPacket packet: [UInt8]) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frameSamples: Int
        switch config {
        case 0 ..< 12: frameSamples = [480, 960, 1920, 2880][config & 3]
        case 12 ..< 16: frameSamples = [480, 960][config & 1]
        default: frameSamples = [120, 240, 480, 960][config & 3]
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[1] & 0x3F)
        }
        return frames * frameSamples
    }
}

// MARK: - FLAC

struct FLACStreamInfo: Sendable {
    /// STREAMINFO's 34 bytes.
    var streamInfo: [UInt8]
    var minimumBlockSize: Int
    var maximumBlockSize: Int
    var sampleRate: Int
    var channels: Int
    var bitsPerSample: Int

    var fixedBlockSize: Int? { minimumBlockSize == maximumBlockSize ? minimumBlockSize : nil }

    /// From A_FLAC's CodecPrivate: "fLaC" then metadata blocks.
    init?(codecPrivate: [UInt8]) {
        var p = codecPrivate.starts(with: Array("fLaC".utf8)) ? 4 : 0
        var found: [UInt8]?
        while p + 4 <= codecPrivate.count {
            let type = codecPrivate[p] & 0x7F
            let last = codecPrivate[p] & 0x80 != 0
            let length = Int(codecPrivate[p + 1]) << 16 | Int(codecPrivate[p + 2]) << 8 | Int(codecPrivate[p + 3])
            p += 4
            guard p + length <= codecPrivate.count else { break }
            if type == 0, length >= 34 { found = Array(codecPrivate[p ..< p + 34]) }
            p += length
            if last { break }
        }
        guard let info = found else { return nil }
        streamInfo = info
        minimumBlockSize = Int(info[0]) << 8 | Int(info[1])
        maximumBlockSize = Int(info[2]) << 8 | Int(info[3])
        sampleRate = Int(info[10]) << 12 | Int(info[11]) << 4 | Int(info[12]) >> 4
        channels = Int((info[12] >> 1) & 7) + 1
        bitsPerSample = (Int(info[12] & 1) << 4 | Int(info[13] >> 4)) + 1
        guard sampleRate > 0 else { return nil }
    }

    /// The dfLa box payload: STREAMINFO alone, flagged as the last block.
    var dfLa: [UInt8] {
        [0x80, 0x00, 0x00, 34] + streamInfo
    }

    /// A frame's block size from its header.
    static func blockSize(ofFrame frame: [UInt8]) -> Int? {
        guard frame.count >= 6, frame[0] == 0xFF, frame[1] & 0xFE == 0xF8 else { return nil }
        let code = Int(frame[2] >> 4)
        switch code {
        case 1: return 192
        case 2 ... 5: return 576 << (code - 2)
        case 8 ... 15: return 256 << (code - 8)
        case 6, 7:
            // The coded frame/sample number (UTF-8-like) precedes the size.
            var p = 4
            let lead = frame[p]
            let extra = lead < 0x80 ? 0 : (lead.leadingZeroBitCount == 0 ? (~lead).leadingZeroBitCount - 1 : 0)
            p += 1 + extra
            if code == 6 {
                guard p < frame.count else { return nil }
                return Int(frame[p]) + 1
            }
            guard p + 1 < frame.count else { return nil }
            return (Int(frame[p]) << 8 | Int(frame[p + 1])) + 1
        default: return nil
        }
    }
}

// MARK: - ALAC

struct ALACConfig: Sendable {
    /// The 24-byte ALACSpecificConfig.
    var config: [UInt8]
    var frameLength: UInt32
    var bitDepth: Int
    var channels: Int
    var sampleRate: Int

    init?(codecPrivate: [UInt8]) {
        var data = codecPrivate
        // ffmpeg's extradata form: a 12-byte 'alac' atom header first.
        if data.count >= 36, Array(data[4 ..< 8]) == Array("alac".utf8) { data = Array(data[12...]) }
        guard data.count >= 24 else { return nil }
        config = Array(data[0 ..< 24])
        frameLength = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        bitDepth = Int(data[5])
        channels = Int(data[9])
        sampleRate = Int(data[20]) << 24 | Int(data[21]) << 16 | Int(data[22]) << 8 | Int(data[23])
        guard frameLength > 0, sampleRate > 0 else { return nil }
    }
}

// MARK: - MP3

struct MPEGAudioHeader: Sendable {
    /// 1 MPEG-1, 2 MPEG-2, 25 MPEG-2.5.
    var version: Int
    var layer: Int
    var sampleRate: Int
    var channels: Int

    init?(_ frame: [UInt8]) {
        guard frame.count >= 4, frame[0] == 0xFF, frame[1] & 0xE0 == 0xE0 else { return nil }
        switch (frame[1] >> 3) & 3 {
        case 0: version = 25
        case 2: version = 2
        case 3: version = 1
        default: return nil
        }
        switch (frame[1] >> 1) & 3 {
        case 1: layer = 3
        case 2: layer = 2
        case 3: layer = 1
        default: return nil
        }
        let rateIndex = Int((frame[2] >> 2) & 3)
        guard rateIndex < 3 else { return nil }
        let base = [44100, 48000, 32000][rateIndex]
        sampleRate = version == 1 ? base : version == 2 ? base / 2 : base / 4
        channels = (frame[3] >> 6) == 3 ? 1 : 2
    }

    var samplesPerFrame: Int {
        switch layer {
        case 1: 384
        case 2: 1152
        default: version == 1 ? 1152 : 576
        }
    }

    /// The frames in a block (normally one) times their length.
    static func samples(in data: [UInt8]) -> Int? {
        var p = 0, total = 0
        while p + 4 <= data.count, let header = MPEGAudioHeader(Array(data[p ..< p + 4])) {
            let bitrateIndex = Int(data[p + 2] >> 4)
            let padding = Int((data[p + 2] >> 1) & 1)
            let table: [Int] = header.version == 1
                ? (header.layer == 3 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                    : header.layer == 2 ? [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
                    : [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448])
                : (header.layer == 1 ? [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
                    : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
            guard let kbps = table[safe: bitrateIndex], kbps > 0 else { break }
            let bytes: Int
            if header.layer == 1 {
                bytes = (12 * kbps * 1000 / header.sampleRate + padding) * 4
            } else {
                let coefficient = header.layer == 3 && header.version != 1 ? 72 : 144
                bytes = coefficient * kbps * 1000 / header.sampleRate + padding
            }
            total += header.samplesPerFrame
            guard bytes > 0 else { break }
            p += bytes
        }
        return total > 0 ? total : nil
    }

    /// MPEG-4 Systems object type: 0x6B MPEG-1 audio, 0x69 MPEG-2.
    var objectTypeIndication: UInt8 { version == 1 ? 0x6B : 0x69 }
}

/// MSB-first bit packing for the dec3 payload.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: Int, bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if (value >> i) & 1 != 0 { bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount % 8) }
            bitCount += 1
        }
    }
}
