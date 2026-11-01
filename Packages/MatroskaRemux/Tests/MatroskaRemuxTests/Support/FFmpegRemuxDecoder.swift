import FFmpegDecoders
import Foundation
@testable import MatroskaRemux

/// FFmpeg's decoders as the remux's (the app has its own copy of this
/// adapter, compiled only into the sideload edition).
final class FFmpegRemuxDecoder: RemuxAudioDecoder {
    /// The framework's macOS slice, from the FFmpegDecoders package folder
    /// (built by `scripts/build-ffmpeg-decoders.sh`; nothing links it).
    static let loaded: Bool = FFmpegAudioDecoder.load(path: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FFmpegDecoders/HypnosFFmpeg.xcframework/macos-arm64_x86_64/HypnosFFmpeg.framework/HypnosFFmpeg").path)

    static let decoding = RemuxAudioDecoding(
        decodes: { loaded && FFmpegAudioCodec(matroskaCodecID: $0) != nil },
        make: { id, codecPrivate in
            guard let codec = FFmpegAudioCodec(matroskaCodecID: id),
                  let decoder = FFmpegAudioDecoder(codec: codec, extradata: codecPrivate) else { return nil }
            return FFmpegRemuxDecoder(decoder)
        })

    private let decoder: FFmpegAudioDecoder
    init(_ decoder: FFmpegAudioDecoder) { self.decoder = decoder }

    func feed(_ frame: [UInt8]) { decoder.feed(frame) }
    func finish() { decoder.finish() }
    var sampleRate: Int { decoder.sampleRate }
    var frameCount: Int { decoder.frameCount }
    var speakers: [RemuxSpeaker] {
        decoder.channels.map { channel in
            switch channel {
            case .frontLeft: .frontLeft
            case .frontRight: .frontRight
            case .frontCenter: .frontCenter
            case .lowFrequency: .lowFrequency
            case .backLeft: .backLeft
            case .backRight: .backRight
            case .backCenter: .backCenter
            case .sideLeft: .sideLeft
            case .sideRight: .sideRight
            default: .other
            }
        }
    }
    func withSamples<R>(_ body: (UnsafeBufferPointer<Int32>) throws -> R) rethrows -> R {
        try decoder.withSamples(body)
    }
}
