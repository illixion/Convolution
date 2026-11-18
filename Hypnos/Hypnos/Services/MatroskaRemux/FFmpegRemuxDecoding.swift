/*
 Hypnos - DTS, TrueHD, Vorbis and VP8 for the on-device remux, sideload
 edition only

 Hands FFmpeg's decoders (the FFmpegDecoders package) to `MatroskaRemux`, so
 an MKV whose sound is DTS or TrueHD, or a WebM whose sound is Vorbis, plays
 natively, its track decoded on the device and served as lossless ALAC
 (`AudioTranscode.swift` in the package), where the remux used to decline
 the file and Jellyfin or Stash transcoded it to AAC (or WebKit played it).
 VP8 video is decoded the same way and re-encoded segment by segment with
 the hardware HEVC encoder (`VideoTranscode.swift`), and a VP8 file's
 thumbnail is its decoded keyframe (`MatroskaThumbnails`), where WebKit used
 to be the only way (and never produced a frame on visionOS).

 Compiled only with HYPNOS_FFMPEG (`FFMPEG_CONDITION` in
 Configuration/Hypnos.xcconfig): an App Store build never decodes Dolby or
 DTS audio itself (CLAUDE.md). Without the flag nothing here exists and
 nothing references the library, so the linker leaves it out; without the
 xcframework (`scripts/build-ffmpeg-decoders.sh`) the package is a stub and
 `decoding` is nil.
 */

import Foundation
import MatroskaRemux

#if HYPNOS_FFMPEG

import FFmpegDecoders

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

final class FFmpegRemuxVideoDecoder: RemuxVideoDecoder {
    /// The VP8 decoder, or nil when this build was made without the library
    /// or its framework predates the video decoder.
    static let decoding: RemuxVideoDecoding? = FFmpegVideoDecoder.isAvailable
        ? RemuxVideoDecoding(
            decodes: { FFmpegVideoCodec(matroskaCodecID: $0) != nil },
            make: { id, codecPrivate in
                // A few threads: frame threading keeps one picture in flight
                // per thread, and the encoder is the slower half anyway.
                guard let codec = FFmpegVideoCodec(matroskaCodecID: id),
                      let decoder = FFmpegVideoDecoder(codec: codec, extradata: codecPrivate,
                                                       threads: min(4, ProcessInfo.processInfo.activeProcessorCount))
                else { return nil }
                return FFmpegRemuxVideoDecoder(decoder)
            })
        : nil

    private let decoder: FFmpegVideoDecoder
    private init(_ decoder: FFmpegVideoDecoder) { self.decoder = decoder }

    func decode(_ frame: [UInt8], tag: Int64, output: (RemuxPicture) -> Void) -> Bool {
        decoder.decode(frame, tag: tag) { output(Self.picture($0)) }
    }

    func finish(output: (RemuxPicture) -> Void) {
        decoder.finish { output(Self.picture($0)) }
    }

    private static func picture(_ p: FFmpegVideoDecoder.Picture) -> RemuxPicture {
        RemuxPicture(width: p.width, height: p.height, tag: p.tag, isFullRange: p.isFullRange) {
            p.copyNV12(luma: $0, lumaStride: $1, chroma: $2, chromaStride: $3)
        }
    }
}

#endif

extension MatroskaRemuxService {
    /// The video decoder the remux and the thumbnails may use: FFmpeg's VP8
    /// in the sideload edition, none otherwise (a VP8 file is declined and
    /// keeps WebKit).
    static var videoDecoding: RemuxVideoDecoding? {
        #if HYPNOS_FFMPEG
        FFmpegRemuxVideoDecoder.decoding
        #else
        nil
        #endif
    }
}
