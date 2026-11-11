import AVFoundation
import Foundation
import Testing
@testable import GeneratedCaptions

/// The audio equalizer plays what `HLSCaptionAudio` reads in place of the
/// player's own sound, so it has to be on the player's timeline to the
/// millisecond and continuous across segments. The fixtures
/// (`Fixtures/hls-clicks`, made by ffmpeg) are a 440 Hz tone with a click on
/// every whole second, as fragmented MP4 HLS, MPEG-TS with video, audio-only
/// MPEG-TS (Jellyfin's music) and packed ADTS (YouTube's audio renditions);
/// each click must come out where the container puts it.
///
/// With video, that is on its second, the frame the click was made with
/// (AVPlayer shows frame k at k/24 s on these streams, measured with
/// `AVPlayerItemVideoOutput`). Audio alone is placed by its own timestamps,
/// which keep ffmpeg's 1024 samples of AAC priming: the click is 21.3 ms
/// after its second there, where no picture says otherwise.
///
/// Measured on macOS 27.2 for comparison: `AVPlayerItemSampleBufferOutput`
/// (AVPlayer's own decoded audio) reports the clicks 2112 samples earlier on
/// every AAC stream except audio-only fMP4 (it assumes Apple's priming, and
/// ignores ffmpeg's edit lists on muxed fMP4: 106 ms early). Whether that is
/// what it plays, or only how that output labels its buffers, isn't known;
/// these are the container's times.
struct HLSAudioTimingTests {
    /// Where each form's click is relative to its second.
    private static let priming = 1024.0 / 48_000
    private static let expectedOffset: [String: Double] = [
        "fmp4": priming, "fmp4-video": 0, "ts": 0, "ts-audio": priming, "packed": priming,
    ]
    private static let root = Bundle.module.url(forResource: "Fixtures/hls-clicks", withExtension: nil)!

    private func read(_ form: String, from start: Double) async throws -> (clicks: [Double], first: Double, end: Double, worstStep: Float, gaps: Double) {
        let directory = Self.root.appendingPathComponent(form)
        let source = try await HLSCaptionAudio.source(
            playlist: directory.appendingPathComponent("index.m3u8"), selection: .init(), start: start
        ) { url, range in
            let data = try Data(contentsOf: url)
            guard let range else { return data }
            return data.subdata(in: range)
        }
        var clicks: [Double] = []
        var first: Double?
        var end = 0.0
        var worstStep: Float = 0
        var gaps = 0.0
        var previous: Float?
        var lastClick = -1.0
        while let chunk = try await source.next() {
            let rate = chunk.buffer.format.sampleRate
            if first == nil { first = chunk.time } else { gaps = max(gaps, abs(chunk.time - end)) }
            let samples = chunk.buffer.floatChannelData![0]
            for index in 0 ..< Int(chunk.buffer.frameLength) {
                let time = chunk.time + Double(index) / rate
                let value = samples[index]
                if abs(value) > 0.45, time - lastClick > 0.5 {
                    clicks.append(time)
                    lastClick = time
                }
                // The tone's own steps are < 0.006; a seam between segments is far larger.
                if let previous, time - (first ?? 0) > 0.05, abs(time - time.rounded()) > 0.04 {
                    worstStep = max(worstStep, abs(value - previous))
                }
                previous = value
            }
            end = chunk.time + Double(chunk.buffer.frameLength) / rate
        }
        return (clicks, first ?? -1, end, worstStep, gaps)
    }

    @Test(arguments: ["fmp4", "fmp4-video", "ts", "ts-audio", "packed"])
    func clicksLandOnTheirSecond(form: String) async throws {
        for start in [0.0, 4.5] {
            let result = try await read(form, from: start)
            print("\(form) from \(start): first \(result.first), end \(result.end), clicks \(result.clicks.map { String(format: "%.4f", $0) }), worst step \(result.worstStep), gap \(result.gaps)")
            let expected = (Int(start.rounded(.up)) ... 8).map(Double.init)
            let found = result.clicks.filter { $0 >= start.rounded(.up) - 0.01 }
            #expect(found.count == expected.count, "\(form) from \(start)")
            for (click, second) in zip(found, expected) {
                // Within a quarter of an AAC frame of where the player plays it.
                let expected = second + Self.expectedOffset[form]!
                #expect(abs(click - expected) < 0.002, "\(form) from \(start): click at \(click), expected \(expected)")
            }
            #expect(result.worstStep < 0.05, "\(form) from \(start): a seam stepped the tone by \(result.worstStep)")
            #expect(result.gaps < 0.002, "\(form) from \(start): chunks \(result.gaps) s apart")
            #expect(result.end > 8.9)
        }
    }

    @Test func transportStreamAudioIsPlacedAgainstTheVideo() throws {
        let segment = try Data(contentsOf: Self.root.appendingPathComponent("ts/s1.ts"))
        let audio = try #require(MPEGTSAudio.extract(segment))
        #expect(audio.fileExtension == "aac")
        #expect(audio.elementaryStream.first == 0xFF) // ADTS sync
        #expect(abs(audio.leadIn) < 0.1)
        let audioOnly = try #require(MPEGTSAudio.extract(try Data(contentsOf: Self.root.appendingPathComponent("ts-audio/s1.ts"))))
        #expect(audioOnly.leadIn == 0)
    }
}
