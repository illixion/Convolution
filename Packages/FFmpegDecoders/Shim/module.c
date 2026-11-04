// Empty on purpose. The CFFmpegShim target exists only so Swift can read
// CFFmpegShim.h's types (hyp_ff_dovi_rpu), and SwiftPM needs a source file to
// make a target of. Nothing of FFmpeg is compiled here: shim.c is excluded
// and goes into HypnosFFmpeg.framework (scripts/build-ffmpeg-decoders.sh).
