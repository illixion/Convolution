import Foundation
import Testing
@testable import FFmpegDecoders

/// The framework's macOS slice, loaded from the package folder (nothing
/// links it; `scripts/build-ffmpeg-decoders.sh` builds it).
enum TestFramework {
    static let loaded: Bool = FFmpegAudioDecoder.load(path: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("HypnosFFmpeg.xcframework/macos-arm64_x86_64/HypnosFFmpeg.framework/HypnosFFmpeg").path)
}

/// Decodes a DTS or TrueHD elementary stream named by FFMPEG_DECODER_FIXTURE
/// (e.g. `ffmpeg -i film.mkv -map 0:a:0 -c copy -t 20 a.dts`). Skipped
/// without the framework or a fixture: the fixtures are films, not
/// something to commit.
@Suite struct DecodeTests {
    @Test func unloadedDecodesNothing() {
        // In a process that never loaded the framework, nothing opens.
        if !TestFramework.loaded {
            #expect(FFmpegAudioDecoder(codec: .dts) == nil)
        }
    }

    @Test(.enabled(if: TestFramework.loaded
                   && ProcessInfo.processInfo.environment["FFMPEG_DECODER_FIXTURE"] != nil))
    func decodesFixtureWholeAndInPieces() throws {
        let path = ProcessInfo.processInfo.environment["FFMPEG_DECODER_FIXTURE"]!
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let codec: FFmpegAudioCodec = path.hasSuffix(".thd") ? .trueHD : .dts

        let whole = try #require(FFmpegAudioDecoder(codec: codec))
        whole.feed(bytes)
        whole.finish()
        #expect(whole.frameCount > 0)
        #expect(whole.errorCount == 0)
        print("decoded \(whole.frameCount) frames, \(whole.channelCount) ch at \(whole.sampleRate) Hz:",
              whole.channels.map { $0.map { "\($0)" } ?? "?" })

        // Fed in uneven pieces, the result is the same.
        let pieces = try #require(FFmpegAudioDecoder(codec: codec))
        var i = 0, step = 1000
        while i < bytes.count {
            pieces.feed(Array(bytes[i ..< min(bytes.count, i + step)]))
            i += step
            step = step == 1000 ? 7777 : 1000
        }
        pieces.finish()
        #expect(pieces.frameCount == whole.frameCount)
        let same = whole.withSamples { a in pieces.withSamples { b in a.elementsEqual(b) } }
        #expect(same)
    }
}
