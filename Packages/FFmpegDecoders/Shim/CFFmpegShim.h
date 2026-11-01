// The C surface of HypnosFFmpeg.framework: FFmpeg's DTS and TrueHD/MLP
// decoders, and nothing else of FFmpeg exported.
//
// Bytes go in as stored (a Matroska block's frame, one or several access
// units: a parser splits them), PCM comes out as one interleaved run of
// 32-bit integers holding 24-bit samples, in the decoder's channel order
// (`hyp_ff_channel` names each).
//
// Nothing links against this: the FFmpegDecoders Swift package looks each
// function up with dlsym once the framework is loaded, so a build that
// doesn't embed the framework (every App Store build) carries no FFmpeg code
// at all. Keep these declarations and FFmpegAudioDecoder.swift's `Symbols`
// in step.

#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    HYP_FF_DTS = 1,
    HYP_FF_TRUEHD = 2,
    HYP_FF_MLP = 3,
} hyp_ff_codec;

typedef struct hyp_ff_decoder hyp_ff_decoder;

/// 1 when this build carries the decoders.
int hyp_ff_available(void);

/// A decoder, or NULL (unavailable, or the codec failed to open).
hyp_ff_decoder *hyp_ff_open(hyp_ff_codec codec, const uint8_t *extradata, int extradata_size);

/// Feeds stored bytes; NULL/0 drains what the parser and decoder still hold.
/// Returns 0, or a negative AVERROR for a failure that ends the stream
/// (a frame that fails to decode is skipped and counted instead).
int hyp_ff_feed(hyp_ff_decoder *decoder, const uint8_t *data, int size);

/// What has been decoded so far. The format is the first decoded frame's;
/// frames in another layout are dropped and counted.
int hyp_ff_channels(const hyp_ff_decoder *decoder);
int hyp_ff_sample_rate(const hyp_ff_decoder *decoder);
/// FFmpeg's AVChannel id of channel `index` (0 front left, 1 front right,
/// 2 front centre, 3 LFE, 4/5 back left/right, 8 back centre, 9/10 side
/// left/right), or -1 when unknown.
int hyp_ff_channel(const hyp_ff_decoder *decoder, int index);
/// Interleaved samples decoded so far (frames × channels values).
int64_t hyp_ff_frames(const hyp_ff_decoder *decoder);
const int32_t *hyp_ff_samples(const hyp_ff_decoder *decoder);
/// Frames that failed to decode or changed layout.
int hyp_ff_errors(const hyp_ff_decoder *decoder);

void hyp_ff_close(hyp_ff_decoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
