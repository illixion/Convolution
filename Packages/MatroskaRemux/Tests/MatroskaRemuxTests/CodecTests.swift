import Foundation
import Testing
@testable import MatroskaRemux

@Suite("Codec details")
struct CodecTests {
    /// An E-AC-3 syncframe header, 5.1 at 48 kHz in six blocks, with the
    /// given metadata flags and additional bit stream info.
    private func eac3Frame(mixingMetadata: Bool, addbsi: [UInt8]?) -> [UInt8] {
        var w = BitWriter()
        w.write(0x0B77, bits: 16)
        w.write(0, bits: 2) // strmtyp: independent
        w.write(0, bits: 3) // substreamid
        w.write(767, bits: 11) // frmsiz: 1536 bytes
        w.write(0, bits: 2) // fscod 48 kHz
        w.write(3, bits: 2) // numblkscod: six blocks
        w.write(7, bits: 3) // acmod 3/2
        w.write(1, bits: 1) // lfeon
        w.write(16, bits: 5) // bsid
        w.write(27, bits: 5) // dialnorm
        w.write(0, bits: 1) // compre
        w.write(mixingMetadata ? 1 : 0, bits: 1) // mixmdate
        if mixingMetadata {
            w.write(1, bits: 2) // dmixmod
            w.write(0, bits: 6) // ltrt/loro center
            w.write(0, bits: 6) // ltrt/loro surround
            w.write(1, bits: 1) // lfemixlevcode
            w.write(10, bits: 5)
            w.write(0, bits: 1) // pgmscle
            w.write(0, bits: 1) // extpgmscle
            w.write(3, bits: 2) // mixdef 3: a length then that many + 2 bytes
            w.write(1, bits: 5)
            w.write(0, bits: 24)
            w.write(0, bits: 1) // frmmixcfginfoe
        }
        w.write(0, bits: 1) // infomdate
        if let addbsi {
            w.write(1, bits: 1) // addbsie
            w.write(addbsi.count - 1, bits: 6)
            for byte in addbsi { w.write(Int(byte), bits: 8) }
        } else {
            w.write(0, bits: 1)
        }
        var bytes = w.bytes
        bytes += [UInt8](repeating: 0, count: 1536 - bytes.count)
        return bytes
    }

    @Test func eac3ObjectAudioIsDetected() throws {
        for mixing in [false, true] {
            let info = try #require(EAC3Info(eac3Frame(mixingMetadata: mixing, addbsi: [0x01, 0x10])))
            #expect(info.objectComplexity == 16)
            #expect(info.channels == 6)
            #expect(info.samplesPerFrame == 1536)
            #expect(info.dataRateKbps == 384)
            // As ffmpeg writes it for the Dolby demo's 768 kbps track
            // (1800 200f 00 0110), at this frame's 384 kbps.
            #expect(info.dec3 == [0x0C, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10])
        }
        let plain = try #require(EAC3Info(eac3Frame(mixingMetadata: true, addbsi: nil)))
        #expect(plain.objectComplexity == nil)
        #expect(plain.dec3 == [0x0C, 0x00, 0x20, 0x0F, 0x00])
        // Additional info without the extension flag isn't object audio.
        #expect(EAC3Info(eac3Frame(mixingMetadata: false, addbsi: [0x00, 0x10]))?.objectComplexity == nil)
    }

    @Test func opusPacketDurations() {
        // config 31 (CELT 20 ms), one frame; code 1, two frames; code 3, n.
        #expect(OpusHead.samples(inPacket: [31 << 3]) == 960)
        #expect(OpusHead.samples(inPacket: [31 << 3 | 1]) == 1920)
        #expect(OpusHead.samples(inPacket: [16 << 3 | 3, 4]) == 480)
        #expect(OpusHead.samples(inPacket: [3 << 3]) == 2880) // SILK 60 ms
    }

    @Test func flacBlockSizes() {
        #expect(FLACStreamInfo.blockSize(ofFrame: [0xFF, 0xF8, 0xC9, 0x08, 0x00, 0x00]) == 4096) // code 12
        #expect(FLACStreamInfo.blockSize(ofFrame: [0xFF, 0xF8, 0x19, 0x08, 0x00, 0x00]) == 192) // code 1
        // Code 7: a 16-bit size after a two-byte coded frame number.
        #expect(FLACStreamInfo.blockSize(ofFrame: [0xFF, 0xF9, 0x79, 0x08, 0xC2, 0x80, 0x03, 0xFF, 0x00]) == 1024)
    }

    @Test func legacyAACConfigurations() throws {
        let lc = try #require(AACConfig(legacyCodecID: "A_AAC/MPEG4/LC", sampleRate: 48000, outputSampleRate: nil, channels: 2))
        #expect(lc.asc == [0x11, 0x90])
        #expect(lc.codecString == "mp4a.40.2")
        let sbr = try #require(AACConfig(legacyCodecID: "A_AAC/MPEG4/LC/SBR", sampleRate: 24000, outputSampleRate: 48000, channels: 2))
        #expect(sbr.asc == [0x13, 0x10, 0x56, 0xE5, 0x98])
        #expect(sbr.codecString == "mp4a.40.5")
        #expect(sbr.sampleRate == 24000)
    }

    @Test func mp3Frames() throws {
        // MPEG-1 Layer III, 128 kbps, 44.1 kHz, stereo: 417 bytes, 1152 samples.
        let header: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
        let parsed = try #require(MPEGAudioHeader(header))
        #expect(parsed.sampleRate == 44100)
        #expect(parsed.samplesPerFrame == 1152)
        let frame = header + [UInt8](repeating: 0, count: 413)
        #expect(MPEGAudioHeader.samples(in: frame + frame) == 2304)
    }

    @Test func ac3SyncframeFields() throws {
        // 48 kHz, 384 kbps (frmsizecod 28), bsid 8, bsmod 0, 3/2 + LFE.
        var w = BitWriter()
        w.write(0x0B77, bits: 16)
        w.write(0, bits: 16) // crc1
        w.write(0, bits: 2)
        w.write(28, bits: 6)
        w.write(8, bits: 5)
        w.write(0, bits: 3)
        w.write(7, bits: 3)
        w.write(0, bits: 2) // cmixlev
        w.write(0, bits: 2) // surmixlev
        w.write(1, bits: 1) // lfeon
        let frame = w.bytes + [UInt8](repeating: 0, count: 1536 - w.bytes.count)
        let sync = try #require(AC3Syncframe(frame))
        #expect(sync.channels == 6)
        #expect(AC3Syncframe.frameBytes(fscod: 0, frmsizecod: 28) == 1536)
        #expect(AC3Syncframe.samples(in: frame) == 1536)
        // fscod 0, bsid 8, bsmod 0, acmod 7, lfeon 1, bit_rate_code 14.
        #expect(sync.dac3 == [0x10, 0x3D, 0xC0])
    }

    @Test func vp9Levels() {
        #expect(VP9Configuration.level(width: 1920, height: 1080, framesPerSecond: 30) == 40)
        #expect(VP9Configuration.level(width: 3840, height: 2160, framesPerSecond: 60) == 51)
        #expect(VP9Configuration.level(width: 320, height: 180, framesPerSecond: 25) == 11)
    }

    @Test func hevcCodecString() throws {
        // Main 10, level 5.1, main tier, progressive-source constraint.
        var record: [UInt8] = [1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 153, 0xF0, 0, 0xFC, 0xFD, 0xFA, 0xFA, 0, 0, 0x0F, 0]
        #expect(HEVCConfiguration(record: record)?.codecString(sampleEntry: "hvc1") == "hvc1.2.4.L153.90")
        record[1] = 0x22 // high tier
        #expect(HEVCConfiguration(record: record)?.codecString(sampleEntry: "hev1") == "hev1.2.4.H153.90")
        #expect(HEVCConfiguration(record: record)?.hasParameterSets == false)
    }

    @Test func segmentByteSpans() {
        // A segment's bytes are its clusters', the last one's to the end
        // (what BANDWIDTH is estimated from).
        let index = SegmentIndex.build(keyframes: [.init(time: 0, clusterPosition: 100), .init(time: 6000, clusterPosition: 900)],
                                       endTime: 9000, endPosition: 1500, timestampScale: 1_000_000)
        #expect(index.count == 2)
        #expect(index.byteLength(0) == 800)
        #expect(index.byteLength(1) == 600)
    }
}
