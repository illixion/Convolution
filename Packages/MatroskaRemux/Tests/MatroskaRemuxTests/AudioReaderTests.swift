/*
 `MatroskaAudioReader`: windows of a track decoded to PCM, for a player that
 mixes the sound itself. The fixtures carry a tone per 5.1 channel (FL 500,
 FR 700, FC 300, LFE 60, surrounds 900 and 1100 Hz; `make-fixtures.sh`).
 */
#if canImport(AVFoundation) && os(macOS)
import FFmpegDecoders
import Foundation
import Testing
@testable import MatroskaRemux

@Suite("Audio windows as PCM", .serialized)
struct AudioReaderTests {
    static func expectedTone(_ speaker: RemuxSpeaker) -> Double? {
        switch speaker {
        case .frontLeft: 500
        case .frontRight: 700
        case .frontCenter: 300
        case .lowFrequency: 60
        case .sideLeft, .backLeft: 900
        case .sideRight, .backRight: 1100
        default: nil
        }
    }

    static func tone(_ plane: [Float]) -> Double {
        let samples = plane.map(Double.init)
        return [300.0, 500, 700, 60, 900, 1100].max { TranscodeTests.power(samples, $0) < TranscodeTests.power(samples, $1) }!
    }

    static func checkTones(_ window: MatroskaAudioReader.Window) {
        #expect(window.sampleRate == 48000)
        #expect(window.planes.count == 6)
        for (speaker, plane) in zip(window.speakers, window.planes) {
            #expect(tone(plane) == expectedTone(speaker), "\(speaker)")
            #expect(plane.contains { abs($0) > 0.002 }, "\(speaker) has sound")
        }
    }

    /// Two windows read one after the other are the window read whole.
    static func checkJoin(_ reader: MatroskaAudioReader, track: UInt64) async throws {
        let whole = try await reader.read(track: track, from: 2.0, frames: 48000)
        let a = try await reader.read(track: track, from: 2.0, frames: 24000)
        let b = try await reader.read(track: track, from: 2.5, frames: 24000)
        for c in 0 ..< whole.planes.count {
            let joined = a.planes[c] + b.planes[c]
            let worst = zip(joined, whole.planes[c]).map { abs($0 - $1) }.max() ?? 1
            let peak = whole.planes[c].map(abs).max() ?? 1
            // Within a fiftieth of the tone's level (lossy codecs restart
            // their filterbank at each window's priming, not exactly).
            #expect(worst < peak / 50, "channel \(c): \(worst) of \(peak)")
        }
        // The same samples every time.
        let again = try await reader.read(track: track, from: 2.5, frames: 24000)
        #expect(again.planes == b.planes)
    }

    @Test(arguments: ["ac3-51-tones.mkv", "eac3-51-tones.mkv", "aac-51-tones.mkv"])
    func systemCodecsDecodeEachChannelInPlace(_ name: String) async throws {
        let reader = try await MatroskaAudioReader.open(source: try Fixtures.source(name), decoding: SystemAudioDecoding.decoding)
        let track = try #require(reader.tracks.first)
        #expect(reader.tracks.count == 1)
        #expect(track.channels == 6)
        #expect(track.sampleRate == 48000)
        #expect(track.language == "en")
        Self.checkTones(try await reader.read(track: track.number, from: 3.0, frames: 24000))
        try await Self.checkJoin(reader, track: track.number)
    }

    @Test func beforeTheStartAndPastTheEndIsSilence() async throws {
        let reader = try await MatroskaAudioReader.open(source: try Fixtures.source("ac3-51-tones.mkv"),
                                                        decoding: SystemAudioDecoding.decoding)
        let track = try #require(reader.tracks.first)
        let past = try await reader.read(track: track.number, from: 60, frames: 4800)
        #expect(past.planes.allSatisfy { $0.allSatisfy { $0 == 0 } })
        // The last window before the end: sound, then silence.
        let end = try await reader.read(track: track.number, from: 8.5, frames: 48000)
        #expect(end.planes[0].prefix(4800).contains { abs($0) > 0.002 })
        #expect(end.planes[0].suffix(4800).allSatisfy { $0 == 0 })
    }

    @Test func tracksWithoutADecoderAreLeftOut() async throws {
        let reader = try await MatroskaAudioReader.open(source: try Fixtures.source("dts-51.mkv"), decoding: SystemAudioDecoding.decoding)
        #expect(reader.tracks.isEmpty)
    }

    @Test(.enabled(if: FFmpegRemuxDecoder.loaded), arguments: TranscodeTests.fixtures)
    func dtsAndTrueHDThroughFFmpeg(_ name: String) async throws {
        let reader = try await MatroskaAudioReader.open(source: try Fixtures.source(name), decoding: FFmpegRemuxDecoder.decoding)
        let track = try #require(reader.tracks.first)
        Self.checkTones(try await reader.read(track: track.number, from: 1.0, frames: 24000))
        try await Self.checkJoin(reader, track: track.number)
    }
}
#endif

import Testing
@testable import MatroskaRemux

@Suite("Audio reader fetch size")
struct AudioReaderChunkTests {
    @Test func highBitrateFilesAreReadInSmallPieces() {
        // A 42 Mbit/s Blu-ray remux skips its picture blocks instead of fetching them.
        #expect(MatroskaAudioReader.chunkSize(bytesPerSecond: 5_200_000) == 48 << 10)
        #expect(MatroskaAudioReader.chunkSize(bytesPerSecond: 400_000) == 1 << 20)
        #expect(MatroskaAudioReader.chunkSize(bytesPerSecond: nil) == 1 << 20)
    }
}
