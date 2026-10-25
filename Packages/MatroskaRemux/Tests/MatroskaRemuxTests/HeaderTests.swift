import Foundation
import Testing
@testable import MatroskaRemux

@Suite("Matroska head")
struct HeaderTests {
    @Test func webmHeadAndCues() async throws {
        let header = try await MatroskaHeaderReader.read(Fixtures.source("vp9-opus.webm"))
        #expect(header.docType == "webm")
        #expect(header.timestampScale == 1_000_000)
        #expect(header.tracks.map(\.codecID) == ["V_VP9", "A_OPUS"])
        #expect(header.tracks[0].video?.pixelWidth == 320)
        #expect(header.tracks[1].audio?.samplingFrequency == 48000)
        #expect(header.tracks[1].codecDelay == 6_500_000)
        #expect(header.tracks[1].seekPreRoll == 80_000_000)
        // A keyframe a second, each cued.
        let videoCues = header.cues.filter { $0.track == 1 }
        #expect(videoCues.count == 8)
        #expect(videoCues.map(\.time) == (0 ..< 8).map { Int64($0) * 1000 })
        #expect(header.firstClusterPosition != nil)
        #expect(header.durationNanoseconds.map { abs($0 - 8_000_000_000) < 50_000_000 } == true)
    }

    @Test func colourAndMastering() async throws {
        let header = try await MatroskaHeaderReader.read(Fixtures.source("hevc-hdr10.mkv"))
        let colour = try #require(header.tracks[0].video?.colour)
        #expect(colour.transferCharacteristics == 16)
        #expect(colour.primaries == 9)
        #expect(colour.matrixCoefficients == 9)
        #expect(colour.maxCLL == 1000)
        #expect(colour.maxFALL == 400)
        let mastering = try #require(colour.mastering)
        #expect(mastering.isComplete)
        #expect(abs((mastering.red?.x ?? 0) - 0.708) < 1e-6)
        #expect(mastering.luminanceMax == 1000)
    }

    @Test func languagesNamesAndDefaults() async throws {
        let header = try await MatroskaHeaderReader.read(Fixtures.source("two-audio.mkv"))
        let audio = header.tracks.filter { $0.kind == .audio }
        #expect(audio.map(\.name) == ["Main Stereo", "Commentaire"])
        #expect(audio.map(\.bcp47Language) == ["en", "fr"])
        #expect(audio.map(\.isDefault) == [true, false])
    }

    @Test func liveStreamHasNoCuesAndUnknownSizes() async throws {
        let header = try await MatroskaHeaderReader.read(Fixtures.source("live.webm"))
        #expect(header.segmentEnd == nil)
        #expect(header.cues.isEmpty)
        #expect(header.duration == nil)
        #expect(header.firstClusterPosition != nil)
    }

    @Test func notMatroska() async throws {
        let mp4 = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70] + [UInt8](repeating: 0, count: 64))
        await #expect(throws: RemuxError.notMatroska) {
            _ = try await MatroskaHeaderReader.read(DataByteSource(mp4))
        }
    }

    @Test func languageCodes() {
        #expect(LanguageCodes.bcp47(fromISO6392: "eng") == "en")
        #expect(LanguageCodes.bcp47(fromISO6392: "fre") == "fr")
        #expect(LanguageCodes.bcp47(fromISO6392: "ger") == "de")
        #expect(LanguageCodes.iso6392T(fromBCP47: "en") == "eng")
        #expect(LanguageCodes.iso6392T(fromBCP47: "pt-BR") == "por")
        #expect(LanguageCodes.iso6392T(fromBCP47: nil) == "und")
    }

    @Test func ebmlLacingSizesAreSigned() {
        // 0xBF is a one-byte signed vint for 0x3F - 63 = 0; 0x80 is -63.
        #expect(EBML.signedVint([0xBF], at: 0, end: 1)?.value == 0)
        #expect(EBML.signedVint([0x80], at: 0, end: 1)?.value == -63)
        #expect(EBML.signedVint([0x60, 0x00], at: 0, end: 2)?.value == 1) // 0x2000 - 8191
    }
}
