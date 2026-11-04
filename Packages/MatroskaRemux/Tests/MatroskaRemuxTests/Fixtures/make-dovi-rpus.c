// Writes dovi-p7-rpus.bin: synthetic Dolby Vision profile 7 RPUs, made with
// FFmpeg's own RPU writer, for the profile 7 to 8.1 conversion tests
// (DolbyVisionTests.swift). Built and run by make-fixtures.sh against the
// static FFmpeg that scripts/build-ffmpeg-decoders.sh leaves in
// build/ffmpeg-decoders.
//
// The file is RPU NAL units as an HEVC sample stores them (NAL header 7C 01,
// emulation prevention), each preceded by its length as 4 bytes big-endian:
// FRAMES full-enhancement-layer RPUs, then FRAMES minimal-layer ones. Each
// has a two-piece polynomial luma curve and MMR chroma curves, linear
// dead-zone NLQ (a real residual for FEL, the identity for MEL), custom
// colour metadata, and L1 (changing every frame), two L2 trims, L5, L6,
// L11 and L254 blocks.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavutil/dovi_meta.h>
#include <libavutil/mem.h>
#include "libavcodec/dovi_rpu.h"

#define FRAMES 48

static void fill(AVDOVIMetadata *md, int frame, int full) {
    AVDOVIRpuDataHeader *hdr = av_dovi_get_header(md);
    AVDOVIDataMapping *map = av_dovi_get_mapping(md);
    AVDOVIColorMetadata *color = av_dovi_get_color(md);
    *hdr = (AVDOVIRpuDataHeader){
        .rpu_type = 2, .rpu_format = 0, .vdr_rpu_profile = 1, .vdr_rpu_level = 0,
        .coef_data_type = 0, .coef_log2_denom = 23, .vdr_rpu_normalized_idc = 1,
        .bl_video_full_range_flag = 0, .bl_bit_depth = 10, .el_bit_depth = 10, .vdr_bit_depth = 12,
        .spatial_resampling_filter_flag = 0, .el_spatial_resampling_filter_flag = 1,
        .disable_residual_flag = 0,
    };
    const int64_t one = (int64_t)1 << 23;
    memset(map, 0, sizeof(*map));
    map->vdr_rpu_id = 0;
    // Luma: two second-order pieces.
    AVDOVIReshapingCurve *y = &map->curves[0];
    y->num_pivots = 3;
    y->pivots[0] = 63; y->pivots[1] = 500; y->pivots[2] = 940;
    for (int i = 0; i < 2; i++) {
        y->mapping_idc[i] = AV_DOVI_MAPPING_POLYNOMIAL;
        y->poly_order[i] = 2;
        y->poly_coef[i][0] = -one / 16 + i * 1000;
        y->poly_coef[i][1] = one + one / 8 - i * 2000;
        y->poly_coef[i][2] = -one / 32 + frame * 10;
    }
    // Chroma: one second-order MMR piece each.
    for (int c = 1; c < 3; c++) {
        AVDOVIReshapingCurve *ch = &map->curves[c];
        ch->num_pivots = 2;
        ch->pivots[0] = 64; ch->pivots[1] = 960;
        ch->mapping_idc[0] = AV_DOVI_MAPPING_MMR;
        ch->mmr_order[0] = 2;
        ch->mmr_constant[0] = one / 50 * c;
        for (int o = 0; o < 2; o++)
            for (int k = 0; k < 7; k++) ch->mmr_coef[0][o][k] = (k == c ? one : one / (40 + 7 * k + o)) - o * 300;
    }
    map->nlq_method_idc = AV_DOVI_NLQ_LINEAR_DZ;
    map->nlq_pivots[0] = 0; map->nlq_pivots[1] = 1023;
    map->num_x_partitions = 1; map->num_y_partitions = 1;
    for (int c = 0; c < 3; c++) {
        if (full) {
            map->nlq[c] = (AVDOVINLQParams){
                .nlq_offset = 512, .vdr_in_max = (uint64_t)one * 3 / 4 + c,
                .linear_deadzone_slope = (uint64_t)one / 512, .linear_deadzone_threshold = (uint64_t)one / 1024,
            };
        } else {
            map->nlq[c] = (AVDOVINLQParams){ .vdr_in_max = (uint64_t)one };
        }
    }
    *color = ff_dovi_color_default;
    color->scene_refresh_flag = frame % 24 == 0;
    // An IPT-ish 12-bit matrix, unlike the 8.1 coefficients the conversion writes.
    static const int ycc[9] = {8192, 799, 1681, 8192, -933, 1091, 8192, 267, -5545};
    for (int i = 0; i < 9; i++) color->ycc_to_rgb_matrix[i] = av_make_q(ycc[i], 1 << 13);
    color->ycc_to_rgb_offset[0] = av_make_q(0, 1 << 28);
    color->ycc_to_rgb_offset[1] = av_make_q(134217728, 1 << 28);
    color->ycc_to_rgb_offset[2] = av_make_q(134217728, 1 << 28);
    color->signal_bit_depth = 12;
    color->signal_color_space = 1;
    color->signal_full_range_flag = 1;
    color->source_min_pq = 62; color->source_max_pq = 3079;

    md->num_ext_blocks = 0;
    AVDOVIDmData *dm;
    dm = av_dovi_get_ext(md, md->num_ext_blocks++); memset(dm, 0, md->ext_block_size);
    dm->level = 1; dm->l1 = (AVDOVIDmLevel1){ .min_pq = 7, .max_pq = 2900 + frame, .avg_pq = 1200 + 3 * frame };
    dm = av_dovi_get_ext(md, md->num_ext_blocks++); memset(dm, 0, md->ext_block_size);
    dm->level = 2; dm->l2 = (AVDOVIDmLevel2){ 2081, 2048, 2048, 2048, 2048, 2048, -1 };
    dm = av_dovi_get_ext(md, md->num_ext_blocks++); memset(dm, 0, md->ext_block_size);
    dm->level = 2; dm->l2 = (AVDOVIDmLevel2){ 2851, 2100, 1990, 2040, 2048, 2200, 2048 };
    dm = av_dovi_get_ext(md, md->num_ext_blocks++); memset(dm, 0, md->ext_block_size);
    dm->level = 5; dm->l5 = (AVDOVIDmLevel5){ 0, 0, 276, 276 };
    dm = av_dovi_get_ext(md, md->num_ext_blocks++); memset(dm, 0, md->ext_block_size);
    dm->level = 6; dm->l6 = (AVDOVIDmLevel6){ 1000, 1, 1000, 400 };
    dm = av_dovi_get_ext(md, md->num_ext_blocks++); memset(dm, 0, md->ext_block_size);
    dm->level = 11; dm->l11.content_type = 1; dm->l11.whitepoint = 0; dm->l11.reference_mode_flag = 1;
    dm = av_dovi_get_ext(md, md->num_ext_blocks++); memset(dm, 0, md->ext_block_size);
    dm->level = 254; dm->l254 = (AVDOVIDmLevel254){ 0, 2 };
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "dovi-p7-rpus.bin";
    FILE *file = fopen(path, "wb");
    if (!file) { perror(path); return 1; }
    for (int full = 1; full >= 0; full--) {
        for (int frame = 0; frame < FRAMES; frame++) {
            size_t size = 0;
            AVDOVIMetadata *md = av_dovi_metadata_alloc(&size);
            fill(md, frame, full);
            DOVIContext enc = {0};
            enc.enable = 1;
            enc.cfg = (AVDOVIDecoderConfigurationRecord){
                .dv_version_major = 1, .dv_profile = 7, .dv_level = 6, .rpu_present_flag = 1,
                .el_present_flag = 1, .bl_present_flag = 1, .dv_bl_signal_compatibility_id = 6,
            };
            uint8_t *rpu = NULL;
            int rpu_size = 0;
            int status = ff_dovi_rpu_generate(&enc, md, FF_DOVI_WRAP_NAL, &rpu, &rpu_size);
            if (status < 0) { fprintf(stderr, "generate failed: %d\n", status); return 1; }
            uint32_t length = (uint32_t)rpu_size + 2;
            uint8_t prefix[6] = { length >> 24, length >> 16, length >> 8, length, 0x7C, 0x01 };
            fwrite(prefix, 1, sizeof(prefix), file);
            fwrite(rpu, 1, (size_t)rpu_size, file);
            av_free(rpu);
            av_free(md);
            ff_dovi_ctx_unref(&enc);
        }
    }
    fclose(file);
    return 0;
}
