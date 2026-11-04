/*
 Hypnos - Dolby Vision profile 7 as 8.1 for the on-device remux, sideload
 edition only

 Hands FFmpeg's RPU rewriter (the FFmpegDecoders package's
 `FFmpegDolbyVision`) to `MatroskaRemux`, so a UHD Blu-ray rip's profile 7
 (base layer, enhancement layer and RPU in one HEVC track) plays as real
 Dolby Vision, profile 8.1, where it used to play its HDR10 base layer: the
 enhancement layer is dropped and every RPU rewritten as a single-layer one
 (`DolbyVisionConversion.swift` in the package says what that loses).

 Compiled only with HYPNOS_DOVI (`DOVI_CONDITION` in
 Configuration/Hypnos.xcconfig), which needs HYPNOS_FFMPEG: the rewriter is
 in the same HypnosFFmpeg.framework, which only HYPNOS_FFMPEG embeds. An App
 Store build never touches an RPU (CLAUDE.md). Without the flag
 `dolbyVisionConversion` is nil and nothing here references the library.
 */

import MatroskaRemux

#if HYPNOS_DOVI && !HYPNOS_FFMPEG
#error("HYPNOS_DOVI needs HYPNOS_FFMPEG: the RPU rewriter is in HypnosFFmpeg.framework, which only HYPNOS_FFMPEG embeds. Set FFMPEG_CONDITION=HYPNOS_FFMPEG too.")
#endif

#if HYPNOS_DOVI
import FFmpegDecoders
#endif

extension MatroskaRemuxService {
    /// The RPU converter, or nil: a build without HYPNOS_DOVI, or one whose
    /// framework predates the RPU functions (`scripts/build-ffmpeg-decoders.sh`).
    static var dolbyVisionConversion: RemuxDolbyVisionConversion? {
        #if HYPNOS_DOVI
        guard FFmpegAudioDecoder.isAvailable, FFmpegDolbyVision.isAvailable else { return nil }
        return RemuxDolbyVisionConversion { rpu in
            guard let converted = FFmpegDolbyVision.convertToProfile81(rpu) else { return nil }
            let layer: DolbyVisionEnhancementLayer = switch converted.sourceLayer {
            case .none: .none
            case .minimal: .minimal
            case .full: .full
            }
            return .init(rpu: converted.rpu, sourceEnhancementLayer: layer)
        }
        #else
        nil
        #endif
    }
}
