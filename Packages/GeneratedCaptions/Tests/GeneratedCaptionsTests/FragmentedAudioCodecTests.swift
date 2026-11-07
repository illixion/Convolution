import AVFoundation
import Foundation
import Testing
@testable import GeneratedCaptions

/// The caption decoder must read every codec the Matroska remux can put in a
/// fragment. The ALAC fixture is the remux's own rendition of a 16-bit stereo
/// file (what a DTS or TrueHD track becomes on the sideload edition): the
/// packet converter failed it with '!dat' bad data on every fragment, so AI
/// captions died on any MKV whose audio was DTS ("failed (code 560226676)").
@Suite struct FragmentedAudioCodecTests {
    @Test func alacFragmentDecodesToPCM() async throws {
        let directory = try #require(Bundle.module.url(forResource: "alac-fragment", withExtension: nil, subdirectory: "Fixtures"))
        let data = try Data(contentsOf: directory.appendingPathComponent("init.mp4"))
            + Data(contentsOf: directory.appendingPathComponent("audio0.m4s"))
        let feed = OneFragment(data)
        let source = RAVECaptionAudioSource.fragmentedMP4 { await feed.take() }
        var frames = 0
        var energy = 0.0
        var lastEnd = 0.0
        while let chunk = try await source.next() {
            #expect(chunk.time >= lastEnd - 0.001)
            lastEnd = chunk.time + Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            frames += Int(chunk.buffer.frameLength)
            if let values = chunk.buffer.floatChannelData {
                for channel in 0..<Int(chunk.buffer.format.channelCount) {
                    energy += UnsafeBufferPointer(start: values[channel], count: Int(chunk.buffer.frameLength)).reduce(0) { $0 + Double($1 * $1) }
                }
            }
        }
        #expect(frames > 40_000)
        #expect(energy > 0)
    }
}

private actor OneFragment {
    var data: Data?
    init(_ data: Data) { self.data = data }
    func take() -> Data? { defer { data = nil }; return data }
}
