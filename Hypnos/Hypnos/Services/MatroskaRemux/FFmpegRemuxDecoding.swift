/*
 Hypnos - DTS and TrueHD for the on-device remux, sideload edition only

 Hands FFmpeg's decoders (the FFmpegDecoders package) to `MatroskaRemux`, so
 an MKV whose sound is DTS or TrueHD plays natively, its track decoded on
 the device and served as lossless ALAC (`AudioTranscode.swift` in the
 package), where the remux used to decline the file and Jellyfin or Stash
 transcoded it to AAC.

 Compiled only with HYPNOS_FFMPEG (`FFMPEG_CONDITION` in
 Configuration/Hypnos.xcconfig): an App Store build never decodes Dolby or
 DTS audio itself (CLAUDE.md). Without the flag nothing here exists and
 nothing references the library, so the linker leaves it out; without the
 xcframework (`scripts/build-ffmpeg-decoders.sh`) the package is a stub and
 `decoding` is nil.
 */

#if HYPNOS_FFMPEG

import FFmpegDecoders
import MatroskaRemux

final class FFmpegRemuxDecoder: RemuxAudioDecoder {
    /// The decoders, or nil when this build was made without the library.
    static let decoding: RemuxAudioDecoding? = FFmpegAudioDecoder.isAvailable
        ? RemuxAudioDecoding(
            decodes: { FFmpegAudioCodec(matroskaCodecID: $0) != nil },
            make: { id, codecPrivate in
                guard let codec = FFmpegAudioCodec(matroskaCodecID: id),
                      let decoder = FFmpegAudioDecoder(codec: codec, extradata: codecPrivate) else { return nil }
                return FFmpegRemuxDecoder(decoder)
            })
        : nil

    private let decoder: FFmpegAudioDecoder
    private init(_ decoder: FFmpegAudioDecoder) { self.decoder = decoder }

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

#endif
