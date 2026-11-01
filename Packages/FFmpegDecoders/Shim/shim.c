// The C surface of HypnosFFmpeg.framework (see CFFmpegShim.h), compiled and
// linked with FFmpeg's static libraries by scripts/build-ffmpeg-decoders.sh.
// Only the hyp_ff_* functions are exported.

#include "CFFmpegShim.h"

#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/log.h>

struct hyp_ff_decoder {
    AVCodecContext *context;
    AVCodecParserContext *parser;
    AVPacket *packet;
    AVFrame *frame;
    int channels;
    int sample_rate;
    int ids[64];
    int32_t *samples;
    int64_t frames;
    int64_t capacity; // in frames
    int errors;
};

int hyp_ff_available(void) { return 1; }

hyp_ff_decoder *hyp_ff_open(hyp_ff_codec codec, const uint8_t *extradata, int extradata_size) {
    enum AVCodecID id;
    switch (codec) {
    case HYP_FF_DTS: id = AV_CODEC_ID_DTS; break;
    case HYP_FF_TRUEHD: id = AV_CODEC_ID_TRUEHD; break;
    case HYP_FF_MLP: id = AV_CODEC_ID_MLP; break;
    default: return NULL;
    }
    av_log_set_level(AV_LOG_QUIET);
    const AVCodec *decoder = avcodec_find_decoder(id);
    if (!decoder) return NULL;

    hyp_ff_decoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->context = avcodec_alloc_context3(decoder);
    d->parser = av_parser_init(id);
    d->packet = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->context || !d->parser || !d->packet || !d->frame) goto fail;
    if (extradata && extradata_size > 0) {
        d->context->extradata = av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!d->context->extradata) goto fail;
        memcpy(d->context->extradata, extradata, extradata_size);
        d->context->extradata_size = extradata_size;
    }
    if (avcodec_open2(d->context, decoder, NULL) < 0) goto fail;
    return d;
fail:
    hyp_ff_close(d);
    return NULL;
}

static int reserve(hyp_ff_decoder *d, int64_t more) {
    if (d->frames + more <= d->capacity) return 1;
    int64_t capacity = d->capacity ? d->capacity : 48000;
    while (capacity < d->frames + more) capacity *= 2;
    int32_t *grown = realloc(d->samples, (size_t)capacity * (size_t)d->channels * sizeof(int32_t));
    if (!grown) return 0;
    d->samples = grown;
    d->capacity = capacity;
    return 1;
}

static int32_t clamp24(double value) {
    double scaled = value * 8388608.0;
    if (scaled >= 8388607.0) return 8388607;
    if (scaled <= -8388608.0) return -8388608;
    return (int32_t)(scaled < 0 ? scaled - 0.5 : scaled + 0.5);
}

static void append(hyp_ff_decoder *d, const AVFrame *f) {
    int channels = f->ch_layout.nb_channels;
    if (d->channels == 0) {
        if (channels <= 0 || channels > 64) { d->errors++; return; }
        d->channels = channels;
        d->sample_rate = f->sample_rate;
        for (int i = 0; i < channels; i++) {
            enum AVChannel ch = av_channel_layout_channel_from_index(&f->ch_layout, (unsigned)i);
            d->ids[i] = ch == AV_CHAN_NONE ? -1 : (int)ch;
        }
    } else if (channels != d->channels || f->sample_rate != d->sample_rate) {
        d->errors++;
        return;
    }
    int n = f->nb_samples;
    if (n <= 0 || !reserve(d, n)) return;
    int32_t *out = d->samples + d->frames * channels;
    enum AVSampleFormat format = f->format;
    for (int c = 0; c < channels; c++) {
        for (int i = 0; i < n; i++) {
            int32_t v;
            switch (format) {
            case AV_SAMPLE_FMT_FLTP: v = clamp24(((const float *)f->extended_data[c])[i]); break;
            case AV_SAMPLE_FMT_FLT: v = clamp24(((const float *)f->extended_data[0])[i * channels + c]); break;
            case AV_SAMPLE_FMT_S32P: v = ((const int32_t *)f->extended_data[c])[i] >> 8; break;
            case AV_SAMPLE_FMT_S32: v = ((const int32_t *)f->extended_data[0])[i * channels + c] >> 8; break;
            case AV_SAMPLE_FMT_S16P: v = (int32_t)((const int16_t *)f->extended_data[c])[i] * 256; break;
            case AV_SAMPLE_FMT_S16: v = (int32_t)((const int16_t *)f->extended_data[0])[i * channels + c] * 256; break;
            default: d->errors++; return;
            }
            out[(int64_t)i * channels + c] = v;
        }
    }
    d->frames += n;
}

static void decode(hyp_ff_decoder *d, AVPacket *packet) {
    int status = avcodec_send_packet(d->context, packet);
    if (status < 0 && status != AVERROR_EOF) {
        d->errors++;
        return;
    }
    for (;;) {
        status = avcodec_receive_frame(d->context, d->frame);
        if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) return;
        if (status < 0) { d->errors++; return; }
        append(d, d->frame);
        av_frame_unref(d->frame);
    }
}

int hyp_ff_feed(hyp_ff_decoder *d, const uint8_t *data, int size) {
    if (!d) return AVERROR(EINVAL);
    int draining = data == NULL || size == 0;
    // The parser reads a padded buffer.
    uint8_t *padded = NULL;
    if (!draining) {
        padded = av_malloc((size_t)size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!padded) return AVERROR(ENOMEM);
        memcpy(padded, data, (size_t)size);
        memset(padded + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    }
    const uint8_t *cursor = padded;
    int left = size;
    do {
        uint8_t *out = NULL;
        int outSize = 0;
        int used = av_parser_parse2(d->parser, d->context, &out, &outSize, draining ? NULL : cursor,
                                    draining ? 0 : left, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
        if (used < 0) { av_free(padded); return used; }
        if (!draining) { cursor += used; left -= used; }
        if (outSize > 0) {
            d->packet->data = out;
            d->packet->size = outSize;
            decode(d, d->packet);
        } else if (draining) {
            break;
        }
    } while (draining || left > 0);
    if (draining) decode(d, NULL);
    av_free(padded);
    return 0;
}

int hyp_ff_channels(const hyp_ff_decoder *d) { return d ? d->channels : 0; }
int hyp_ff_sample_rate(const hyp_ff_decoder *d) { return d ? d->sample_rate : 0; }
int hyp_ff_channel(const hyp_ff_decoder *d, int index) {
    return d && index >= 0 && index < d->channels ? d->ids[index] : -1;
}
int64_t hyp_ff_frames(const hyp_ff_decoder *d) { return d ? d->frames : 0; }
const int32_t *hyp_ff_samples(const hyp_ff_decoder *d) { return d ? d->samples : NULL; }
int hyp_ff_errors(const hyp_ff_decoder *d) { return d ? d->errors : 0; }

void hyp_ff_close(hyp_ff_decoder *d) {
    if (!d) return;
    if (d->parser) av_parser_close(d->parser);
    avcodec_free_context(&d->context);
    av_packet_free(&d->packet);
    av_frame_free(&d->frame);
    free(d->samples);
    free(d);
}
