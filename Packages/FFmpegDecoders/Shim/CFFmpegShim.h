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

// MARK: - Dolby Vision RPUs (HYPNOS_DOVI, sideload edition only)
//
// FFmpeg's RPU reader and writer (libavcodec/dovi_rpudec.c, dovi_rpuenc.c).
// Each call reads one RPU on its own, with a fresh context, so the same
// bytes always give the same result; an RPU that refers to an earlier one
// (profile 8's optional metadata compression, `use_prev_vdr_rpu`) can't be
// read that way and is refused.
//
// An RPU is accepted in either of two forms, told apart by the first byte:
//  - a NAL unit as stored in an HEVC sample: the two-byte NAL header (type
//    62: 0x7C 0x01), then the payload with emulation-prevention bytes;
//  - a bare payload starting at the 0x19 prefix byte, with or without
//    emulation-prevention bytes (tried as given first, then unescaped; the
//    one whose CRC-32 checks is used).

/// What an RPU says its enhancement layer is.
typedef enum {
    HYP_FF_DOVI_EL_NONE = 0,    // no residual (disable_residual_flag): profiles 5 and 8
    HYP_FF_DOVI_EL_MINIMAL = 1, // MEL: NLQ that adds nothing; dropping the layer loses nothing
    HYP_FF_DOVI_EL_FULL = 2,    // FEL: a real residual, which a single-layer conversion loses
} hyp_ff_dovi_el;

/// Options for hyp_ff_dovi_convert_to_81.
enum {
    /// Keep a FEL's reshaping curves (dovi_tool's "8.1, mapping preserved")
    /// instead of making them identity (dovi_tool's mode 2). A MEL's curves
    /// are always kept: with a zero residual they are the whole picture.
    HYP_FF_DOVI_KEEP_FEL_MAPPING = 1 << 0,
};

/// Rewrites one profile 7 RPU (also 8, a no-op apart from the coefficients)
/// as a single-layer profile 8.1 RPU, the way dovi_tool's mode 2 does:
/// disable_residual_flag 1, el_spatial_resampling_filter_flag 0, NLQ and
/// its pivots removed, one partition, the profile 8.1 YCbCr-to-RGB and
/// RGB-to-LMS coefficients (dovi_tool's set_p81_coeffs) when the RPU has
/// colour metadata, and for a FEL identity reshaping curves (one linear
/// piece over 0..2^bl_bit_depth-1) unless HYP_FF_DOVI_KEEP_FEL_MAPPING. Every
/// extension block FFmpeg knows (L1-L6, L8-L11, L254, L255) is kept; an
/// unknown level is dropped. Written uncompressed.
///
/// The output is in the input's form (a NAL unit keeps the input's two
/// header bytes). Returns the output's length; when that is more than
/// `out_cap`, nothing is written (call again with a larger buffer). A
/// negative AVERROR when the RPU can't be read or written. `el_type`, when
/// not NULL, receives the source's hyp_ff_dovi_el.
int hyp_ff_dovi_convert_to_81(const uint8_t *in, int in_size, uint8_t *out, int out_cap, int flags,
                              int *el_type);

#define HYP_FF_DOVI_PIECES 8 // reshaping pieces per component (AV_DOVI_MAX_PIECES)
#define HYP_FF_DOVI_TRIMS 8  // L2 and L8 trims kept, in RPU order

/// One component's reshaping curve: the base layer's code values (0 to
/// 2^bl_bit_depth - 1) mapped piece by piece to the VDR signal.
typedef struct {
    int32_t num_pivots;                               // [2, 9]; pieces = num_pivots - 1
    int32_t pivots[HYP_FF_DOVI_PIECES + 1];           // base-layer code values, ascending
    int32_t mapping_idc[HYP_FF_DOVI_PIECES];          // per piece: 0 polynomial, 1 MMR
    int32_t poly_order[HYP_FF_DOVI_PIECES];           // polynomial: 1 or 2
    int64_t poly_coef[HYP_FF_DOVI_PIECES][3];         // polynomial: x^0, x^1, x^2
    int32_t mmr_order[HYP_FF_DOVI_PIECES];            // MMR: 1 to 3
    int64_t mmr_constant[HYP_FF_DOVI_PIECES];         // MMR
    int64_t mmr_coef[HYP_FF_DOVI_PIECES][3][7];       // MMR: [order - 1][term]
} hyp_ff_dovi_curve;

/// One component's non-linear inverse quantisation of the residual.
typedef struct {
    int32_t nlq_offset;                // el_bit_depth code value
    int64_t vdr_in_max;                // fixed point, see coef_log2_denom
    int64_t linear_deadzone_slope;     // fixed point
    int64_t linear_deadzone_threshold; // fixed point
} hyp_ff_dovi_nlq;

/// An L2 (CM v2.9) trim for one target display. 12-bit values, 2048
/// neutral for slope/offset/power/chroma weight/saturation gain.
typedef struct {
    int32_t target_max_pq, trim_slope, trim_offset, trim_power, trim_chroma_weight, trim_saturation_gain;
    int32_t ms_weight; // signed, -1 to 4095
} hyp_ff_dovi_l2;

/// An L8 (CM v4.0) trim for one target display (an L10 or preset index).
typedef struct {
    int32_t target_display_index, trim_slope, trim_offset, trim_power, trim_chroma_weight, trim_saturation_gain;
    int32_t ms_weight, target_mid_contrast, clip_trim;
} hyp_ff_dovi_l8;

/// Everything an RPU says, flat, for applying it without FFmpeg.
///
/// Numbers:
///  - Integers are the bitstream's values as FFmpeg reads them (PQ values
///    are 12-bit codes, 0..4095; luminances in L6 are cd/m², min in 0.0001).
///  - Reshaping and NLQ coefficients are fixed point: the real value is
///    coef / 2^coef_log2_denom, the integer part signed (an RPU with float
///    coefficients, coef_data_type 1, is converted by FFmpeg with
///    coef_log2_denom 32). Evaluated as libplacebo does: base-layer samples
///    and pivots normalised by 2^bl_bit_depth - 1; a polynomial piece is
///    c0 + c1·x + c2·x² of the component's own sample; an MMR piece is
///    mmr_constant + Σ over orders o = 1..mmr_order of the 7 terms
///    (y, cb, cr, y·cb, y·cr, cb·cr, y·cb·cr)^o weighted by mmr_coef[o-1];
///    the result is the normalised VDR signal (0..1, vdr_bit_depth).
///  - The colour matrices are doubles holding FFmpeg's rationals exactly:
///    ycc_to_rgb_matrix n/8192, rgb_to_lms_matrix n/16384, both row-major
///    3x3; ycc_to_rgb_offset n/2^28 (n/2^30 for profile 4), i.e. the
///    neutral input value on a 0..1 scale (0.0625, 0.5, 0.5 for 10-bit
///    limited range).
///  - has_* and num_* say which extension blocks the RPU carries; fields of
///    a block it lacks are 0.
typedef struct {
    uint32_t struct_size; // sizeof(hyp_ff_dovi_rpu), checked by hyp_ff_dovi_parse

    // Header (rpu_data_header).
    int32_t profile; // the Dolby Vision profile this header reads as: 4, 5, 7 or 8; 0 unknown
    int32_t el_type; // hyp_ff_dovi_el
    int32_t rpu_type, rpu_format, vdr_rpu_profile, vdr_rpu_level;
    int32_t chroma_resampling_explicit_filter_flag, coef_data_type, coef_log2_denom;
    int32_t vdr_rpu_normalized_idc, bl_video_full_range_flag;
    int32_t bl_bit_depth, el_bit_depth, vdr_bit_depth;
    int32_t spatial_resampling_filter_flag, el_spatial_resampling_filter_flag, disable_residual_flag;
    int32_t ext_mapping_idc_0_4, ext_mapping_idc_5_7;

    // Data mapping (base layer to VDR), per component Y, Cb, Cr.
    int32_t vdr_rpu_id, mapping_color_space, mapping_chroma_format_idc;
    hyp_ff_dovi_curve curves[3];
    int32_t nlq_method_idc; // -1 none (no residual), 0 linear dead zone
    int32_t nlq_pivots[2];
    int32_t num_x_partitions, num_y_partitions;
    hyp_ff_dovi_nlq nlq[3];

    // Colour metadata (vdr_dm_data). Without it in the RPU, has_color_metadata
    // is 0 and these hold FFmpeg's defaults (ff_dovi_color_default).
    int32_t has_color_metadata;
    int32_t dm_metadata_id, scene_refresh_flag;
    double ycc_to_rgb_matrix[9];
    double ycc_to_rgb_offset[3];
    double rgb_to_lms_matrix[9];
    int32_t signal_eotf, signal_eotf_param0, signal_eotf_param1;
    int64_t signal_eotf_param2;
    int32_t signal_bit_depth, signal_color_space, signal_chroma_format, signal_full_range_flag;
    int32_t source_min_pq, source_max_pq, source_diagonal;

    // Extension blocks.
    int32_t has_l1, l1_min_pq, l1_max_pq, l1_avg_pq;
    int32_t num_l2;
    hyp_ff_dovi_l2 l2[HYP_FF_DOVI_TRIMS];
    int32_t has_l3, l3_min_pq_offset, l3_max_pq_offset, l3_avg_pq_offset;
    int32_t has_l5, l5_left_offset, l5_right_offset, l5_top_offset, l5_bottom_offset;
    int32_t has_l6, l6_max_luminance, l6_min_luminance, l6_max_cll, l6_max_fall;
    int32_t num_l8;
    hyp_ff_dovi_l8 l8[HYP_FF_DOVI_TRIMS];
    int32_t has_l9, l9_source_primary_index;
    int32_t has_l11, l11_content_type, l11_whitepoint, l11_reference_mode_flag;
    int32_t has_l254, l254_dm_mode, l254_dm_version_index;
} hyp_ff_dovi_rpu;

/// Reads one RPU into `out`, whose struct_size must be sizeof(hyp_ff_dovi_rpu)
/// (it is zeroed first). Returns 0, or a negative AVERROR.
int hyp_ff_dovi_parse(const uint8_t *rpu, int size, hyp_ff_dovi_rpu *out);

#ifdef __cplusplus
}
#endif

#endif
