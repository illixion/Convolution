// The C surface of HypnosFFmpeg.framework (see CFFmpegShim.h), compiled and
// linked with FFmpeg's static libraries by scripts/build-ffmpeg-decoders.sh.
// Only the hyp_ff_* functions are exported. The Dolby Vision part calls
// FFmpeg's internal RPU reader and writer, linked in from the same static
// libraries (their headers come from the FFmpeg source tree).

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

// MARK: - Dolby Vision RPUs (see CFFmpegShim.h)

#include <libavutil/dovi_meta.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include "libavcodec/dovi_rpu.h"

/// Bytes with emulation-prevention bytes (00 00 03) removed; av_malloc'd.
static uint8_t *dovi_unescape(const uint8_t *in, int size, int *out_size) {
    uint8_t *out = av_malloc((size_t)size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!out) return NULL;
    int n = 0, zeros = 0;
    for (int i = 0; i < size; i++) {
        if (zeros >= 2 && in[i] == 3) { zeros = 0; continue; }
        out[n++] = in[i];
        zeros = in[i] == 0 ? zeros + 1 : 0;
    }
    memset(out + n, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    *out_size = n;
    return out;
}

static int dovi_has_escape(const uint8_t *in, int size) {
    for (int i = 2; i < size; i++)
        if (in[i] == 3 && in[i - 1] == 0 && in[i - 2] == 0) return 1;
    return 0;
}

enum { DOVI_FORM_NAL, DOVI_FORM_BARE_ESCAPED, DOVI_FORM_BARE_RAW };

/// Reads one RPU into a fresh context `s`. `form` says which it was.
static int dovi_read(DOVIContext *s, const uint8_t *in, int size, int *form) {
    av_log_set_level(AV_LOG_QUIET);
    if (!in || size < 6) return AVERROR_INVALIDDATA;
    // Candidates, in order: what the first bytes say, then the other reading
    // of a bare payload. A CRC that checks picks one; if none does, the
    // first that parses at all.
    const uint8_t *payloads[2] = {NULL, NULL};
    int sizes[2] = {0, 0}, forms[2] = {0, 0}, count = 0;
    uint8_t *unescaped = NULL;
    int unescaped_size = 0;
    if (in[0] == 0x7C && in[1] == 0x01) {
        unescaped = dovi_unescape(in + 2, size - 2, &unescaped_size);
        if (!unescaped) return AVERROR(ENOMEM);
        payloads[0] = unescaped; sizes[0] = unescaped_size; forms[0] = DOVI_FORM_NAL;
        count = 1;
    } else if (in[0] == 0x19) {
        payloads[0] = in; sizes[0] = size; forms[0] = DOVI_FORM_BARE_RAW;
        count = 1;
        if (dovi_has_escape(in, size)) {
            unescaped = dovi_unescape(in, size, &unescaped_size);
            if (!unescaped) return AVERROR(ENOMEM);
            payloads[1] = unescaped; sizes[1] = unescaped_size; forms[1] = DOVI_FORM_BARE_ESCAPED;
            count = 2;
        }
    } else {
        return AVERROR_INVALIDDATA;
    }
    int status = AVERROR_INVALIDDATA;
    for (int pass = 0; pass < 2; pass++) {
        int recognition = pass == 0 ? (AV_EF_CRCCHECK | AV_EF_EXPLODE) : 0;
        for (int i = 0; i < count; i++) {
            ff_dovi_ctx_unref(s);
            // The parser reads past the end in whole words: a padded copy.
            uint8_t *padded = av_mallocz((size_t)sizes[i] + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!padded) { av_free(unescaped); return AVERROR(ENOMEM); }
            memcpy(padded, payloads[i], (size_t)sizes[i]);
            status = ff_dovi_rpu_parse(s, padded, (size_t)sizes[i], recognition);
            av_free(padded);
            if (status >= 0 && s->mapping && s->color) {
                *form = forms[i];
                av_free(unescaped);
                return 0;
            }
            if (status >= 0) status = AVERROR_INVALIDDATA; // not a type 2 RPU
        }
    }
    ff_dovi_ctx_unref(s);
    av_free(unescaped);
    return status;
}

static int dovi_el_type(const AVDOVIRpuDataHeader *hdr, const AVDOVIDataMapping *mapping) {
    if (hdr->disable_residual_flag || mapping->nlq_method_idc == AV_DOVI_NLQ_NONE) return HYP_FF_DOVI_EL_NONE;
    // dovi_tool's is_mel: offset 0, vdr_in_max 1.0, no dead zone.
    uint64_t one = 1ull << hdr->coef_log2_denom;
    for (int c = 0; c < 3; c++) {
        const AVDOVINLQParams *nlq = &mapping->nlq[c];
        if (nlq->nlq_offset != 0 || nlq->vdr_in_max != one || nlq->linear_deadzone_slope != 0
            || nlq->linear_deadzone_threshold != 0)
            return HYP_FF_DOVI_EL_FULL;
    }
    return HYP_FF_DOVI_EL_MINIMAL;
}

static int dovi_known_level(int level) {
    switch (level) {
    case 1: case 2: case 3: case 4: case 5: case 6: case 8: case 9: case 10: case 11: case 254: case 255:
        return 1;
    default:
        return 0;
    }
}

int hyp_ff_dovi_convert_to_81(const uint8_t *in, int in_size, uint8_t *out, int out_cap, int flags,
                              int *el_type) {
    DOVIContext dec = {0}, enc = {0};
    AVDOVIMetadata *metadata = NULL;
    uint8_t *rpu = NULL;
    int rpu_size = 0, form = 0;
    int status = dovi_read(&dec, in, in_size, &form);
    if (status < 0) goto done;
    int had_color = dec.color != &ff_dovi_color_default;
    status = ff_dovi_get_metadata(&dec, &metadata);
    if (status <= 0) { status = status < 0 ? status : AVERROR_INVALIDDATA; goto done; }

    AVDOVIRpuDataHeader *hdr = av_dovi_get_header(metadata);
    AVDOVIDataMapping *mapping = av_dovi_get_mapping(metadata);
    AVDOVIColorMetadata *color = av_dovi_get_color(metadata);
    int source_el = dovi_el_type(hdr, mapping);
    if (el_type) *el_type = source_el;

    // dovi_tool's convert_to_p81.
    hdr->el_spatial_resampling_filter_flag = 0;
    hdr->disable_residual_flag = 1;
    mapping->nlq_method_idc = AV_DOVI_NLQ_NONE;
    memset(mapping->nlq, 0, sizeof(mapping->nlq));
    memset(mapping->nlq_pivots, 0, sizeof(mapping->nlq_pivots));
    mapping->num_x_partitions = 1;
    mapping->num_y_partitions = 1;
    if (had_color) {
        static const int ycc[9] = {9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0};
        static const int offset[3] = {16777216, 134217728, 134217728};
        static const int lms[9] = {7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962};
        for (int i = 0; i < 9; i++) color->ycc_to_rgb_matrix[i] = av_make_q(ycc[i], 1 << 13);
        for (int i = 0; i < 3; i++) color->ycc_to_rgb_offset[i] = av_make_q(offset[i], 1 << 28);
        for (int i = 0; i < 9; i++) color->rgb_to_lms_matrix[i] = av_make_q(lms[i], 1 << 14);
        color->signal_color_space = 0;
    }
    // A FEL's curves predict a picture the residual corrects; without the
    // residual dovi_tool shows the base layer as it is (set_empty_p81_mapping).
    if (source_el == HYP_FF_DOVI_EL_FULL && !(flags & HYP_FF_DOVI_KEEP_FEL_MAPPING)) {
        for (int c = 0; c < 3; c++) {
            AVDOVIReshapingCurve *curve = &mapping->curves[c];
            memset(curve, 0, sizeof(*curve));
            curve->num_pivots = 2;
            curve->pivots[0] = 0;
            curve->pivots[1] = (uint16_t)((1 << hdr->bl_bit_depth) - 1);
            curve->mapping_idc[0] = AV_DOVI_MAPPING_POLYNOMIAL;
            curve->poly_order[0] = 1;
            curve->poly_coef[0][1] = (int64_t)1 << hdr->coef_log2_denom;
        }
    }
    // The writer refuses levels it doesn't know.
    int kept = 0;
    for (int i = 0; i < metadata->num_ext_blocks; i++) {
        AVDOVIDmData *block = av_dovi_get_ext(metadata, i);
        if (!dovi_known_level(block->level)) continue;
        if (kept != i) memcpy(av_dovi_get_ext(metadata, kept), block, metadata->ext_block_size);
        kept++;
    }
    metadata->num_ext_blocks = kept;

    enc.cfg.dv_profile = 8;
    enc.cfg.dv_level = 0;
    enc.cfg.rpu_present_flag = 1;
    enc.cfg.bl_present_flag = 1;
    enc.cfg.dv_bl_signal_compatibility_id = 1;
    enc.cfg.dv_md_compression = AV_DOVI_COMPRESSION_NONE;
    enc.enable = 1;
    status = ff_dovi_rpu_generate(&enc, metadata, form == DOVI_FORM_BARE_RAW ? 0 : FF_DOVI_WRAP_NAL, &rpu, &rpu_size);
    if (status < 0) goto done;

    // WRAP_NAL gives 0x19 + the escaped payload; unwrapped, the payload alone.
    int header = form == DOVI_FORM_NAL ? 2 : form == DOVI_FORM_BARE_RAW ? 1 : 0;
    int total = header + rpu_size;
    if (total <= out_cap && out) {
        if (form == DOVI_FORM_NAL) { out[0] = in[0]; out[1] = in[1]; }
        else if (form == DOVI_FORM_BARE_RAW) out[0] = 0x19;
        memcpy(out + header, rpu, (size_t)rpu_size);
    }
    status = total;
done:
    av_free(rpu);
    av_free(metadata);
    ff_dovi_ctx_unref(&dec);
    ff_dovi_ctx_unref(&enc);
    return status;
}

int hyp_ff_dovi_parse(const uint8_t *in, int size, hyp_ff_dovi_rpu *out) {
    if (!out || out->struct_size != sizeof(*out)) return AVERROR(EINVAL);
    memset(out, 0, sizeof(*out));
    out->struct_size = sizeof(*out);
    DOVIContext dec = {0};
    int form = 0;
    int status = dovi_read(&dec, in, size, &form);
    if (status < 0) return status;

    const AVDOVIRpuDataHeader *hdr = &dec.header;
    const AVDOVIDataMapping *mapping = dec.mapping;
    const AVDOVIColorMetadata *color = dec.color;
    out->profile = ff_dovi_guess_profile_hevc(hdr);
    out->el_type = dovi_el_type(hdr, mapping);
    out->rpu_type = hdr->rpu_type;
    out->rpu_format = hdr->rpu_format;
    out->vdr_rpu_profile = hdr->vdr_rpu_profile;
    out->vdr_rpu_level = hdr->vdr_rpu_level;
    out->chroma_resampling_explicit_filter_flag = hdr->chroma_resampling_explicit_filter_flag;
    out->coef_data_type = hdr->coef_data_type;
    out->coef_log2_denom = hdr->coef_log2_denom;
    out->vdr_rpu_normalized_idc = hdr->vdr_rpu_normalized_idc;
    out->bl_video_full_range_flag = hdr->bl_video_full_range_flag;
    out->bl_bit_depth = hdr->bl_bit_depth;
    out->el_bit_depth = hdr->el_bit_depth;
    out->vdr_bit_depth = hdr->vdr_bit_depth;
    out->spatial_resampling_filter_flag = hdr->spatial_resampling_filter_flag;
    out->el_spatial_resampling_filter_flag = hdr->el_spatial_resampling_filter_flag;
    out->disable_residual_flag = hdr->disable_residual_flag;
    out->ext_mapping_idc_0_4 = hdr->ext_mapping_idc_0_4;
    out->ext_mapping_idc_5_7 = hdr->ext_mapping_idc_5_7;

    out->vdr_rpu_id = mapping->vdr_rpu_id;
    out->mapping_color_space = mapping->mapping_color_space;
    out->mapping_chroma_format_idc = mapping->mapping_chroma_format_idc;
    for (int c = 0; c < 3; c++) {
        const AVDOVIReshapingCurve *from = &mapping->curves[c];
        hyp_ff_dovi_curve *to = &out->curves[c];
        to->num_pivots = from->num_pivots;
        for (int i = 0; i < from->num_pivots && i <= HYP_FF_DOVI_PIECES; i++) to->pivots[i] = from->pivots[i];
        for (int i = 0; i < HYP_FF_DOVI_PIECES; i++) {
            to->mapping_idc[i] = from->mapping_idc[i];
            to->poly_order[i] = from->poly_order[i];
            for (int k = 0; k < 3; k++) to->poly_coef[i][k] = from->poly_coef[i][k];
            to->mmr_order[i] = from->mmr_order[i];
            to->mmr_constant[i] = from->mmr_constant[i];
            for (int j = 0; j < 3; j++)
                for (int k = 0; k < 7; k++) to->mmr_coef[i][j][k] = from->mmr_coef[i][j][k];
        }
    }
    out->nlq_method_idc = mapping->nlq_method_idc;
    out->nlq_pivots[0] = mapping->nlq_pivots[0];
    out->nlq_pivots[1] = mapping->nlq_pivots[1];
    out->num_x_partitions = (int32_t)mapping->num_x_partitions;
    out->num_y_partitions = (int32_t)mapping->num_y_partitions;
    for (int c = 0; c < 3; c++) {
        out->nlq[c].nlq_offset = mapping->nlq[c].nlq_offset;
        out->nlq[c].vdr_in_max = (int64_t)mapping->nlq[c].vdr_in_max;
        out->nlq[c].linear_deadzone_slope = (int64_t)mapping->nlq[c].linear_deadzone_slope;
        out->nlq[c].linear_deadzone_threshold = (int64_t)mapping->nlq[c].linear_deadzone_threshold;
    }

    out->has_color_metadata = color != &ff_dovi_color_default;
    out->dm_metadata_id = color->dm_metadata_id;
    out->scene_refresh_flag = color->scene_refresh_flag;
    for (int i = 0; i < 9; i++) out->ycc_to_rgb_matrix[i] = av_q2d(color->ycc_to_rgb_matrix[i]);
    for (int i = 0; i < 3; i++) out->ycc_to_rgb_offset[i] = av_q2d(color->ycc_to_rgb_offset[i]);
    for (int i = 0; i < 9; i++) out->rgb_to_lms_matrix[i] = av_q2d(color->rgb_to_lms_matrix[i]);
    out->signal_eotf = color->signal_eotf;
    out->signal_eotf_param0 = color->signal_eotf_param0;
    out->signal_eotf_param1 = color->signal_eotf_param1;
    out->signal_eotf_param2 = color->signal_eotf_param2;
    out->signal_bit_depth = color->signal_bit_depth;
    out->signal_color_space = color->signal_color_space;
    out->signal_chroma_format = color->signal_chroma_format;
    out->signal_full_range_flag = color->signal_full_range_flag;
    out->source_min_pq = color->source_min_pq;
    out->source_max_pq = color->source_max_pq;
    out->source_diagonal = color->source_diagonal;

    const DOVIExt *ext = dec.ext_blocks;
    int blocks = ext ? ext->num_static + ext->num_dynamic : 0;
    for (int i = 0; i < blocks; i++) {
        const AVDOVIDmData *dm = i < ext->num_static ? &ext->dm_static[i] : &ext->dm_dynamic[i - ext->num_static];
        switch (dm->level) {
        case 1:
            out->has_l1 = 1;
            out->l1_min_pq = dm->l1.min_pq; out->l1_max_pq = dm->l1.max_pq; out->l1_avg_pq = dm->l1.avg_pq;
            break;
        case 2:
            if (out->num_l2 < HYP_FF_DOVI_TRIMS) {
                hyp_ff_dovi_l2 *t = &out->l2[out->num_l2++];
                t->target_max_pq = dm->l2.target_max_pq; t->trim_slope = dm->l2.trim_slope;
                t->trim_offset = dm->l2.trim_offset; t->trim_power = dm->l2.trim_power;
                t->trim_chroma_weight = dm->l2.trim_chroma_weight;
                t->trim_saturation_gain = dm->l2.trim_saturation_gain; t->ms_weight = dm->l2.ms_weight;
            }
            break;
        case 3:
            out->has_l3 = 1;
            out->l3_min_pq_offset = dm->l3.min_pq_offset; out->l3_max_pq_offset = dm->l3.max_pq_offset;
            out->l3_avg_pq_offset = dm->l3.avg_pq_offset;
            break;
        case 5:
            out->has_l5 = 1;
            out->l5_left_offset = dm->l5.left_offset; out->l5_right_offset = dm->l5.right_offset;
            out->l5_top_offset = dm->l5.top_offset; out->l5_bottom_offset = dm->l5.bottom_offset;
            break;
        case 6:
            out->has_l6 = 1;
            out->l6_max_luminance = dm->l6.max_luminance; out->l6_min_luminance = dm->l6.min_luminance;
            out->l6_max_cll = dm->l6.max_cll; out->l6_max_fall = dm->l6.max_fall;
            break;
        case 8:
            if (out->num_l8 < HYP_FF_DOVI_TRIMS) {
                hyp_ff_dovi_l8 *t = &out->l8[out->num_l8++];
                t->target_display_index = dm->l8.target_display_index; t->trim_slope = dm->l8.trim_slope;
                t->trim_offset = dm->l8.trim_offset; t->trim_power = dm->l8.trim_power;
                t->trim_chroma_weight = dm->l8.trim_chroma_weight;
                t->trim_saturation_gain = dm->l8.trim_saturation_gain; t->ms_weight = dm->l8.ms_weight;
                t->target_mid_contrast = dm->l8.target_mid_contrast; t->clip_trim = dm->l8.clip_trim;
            }
            break;
        case 9:
            out->has_l9 = 1;
            out->l9_source_primary_index = dm->l9.source_primary_index;
            break;
        case 11:
            out->has_l11 = 1;
            out->l11_content_type = dm->l11.content_type; out->l11_whitepoint = dm->l11.whitepoint;
            out->l11_reference_mode_flag = dm->l11.reference_mode_flag;
            break;
        case 254:
            out->has_l254 = 1;
            out->l254_dm_mode = dm->l254.dm_mode; out->l254_dm_version_index = dm->l254.dm_version_index;
            break;
        default:
            break;
        }
    }
    ff_dovi_ctx_unref(&dec);
    return 0;
}
