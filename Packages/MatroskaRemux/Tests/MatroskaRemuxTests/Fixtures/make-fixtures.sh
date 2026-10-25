#!/usr/bin/env bash
# Regenerates the test fixtures: small synthetic Matroska/WebM files, one per
# path the remuxer branches on. Each stays under ~200 KB so they can be
# committed. Needs ffmpeg (with libx264, libx265, libvpx, libsvtav1, libopus,
# libmp3lame) and mkvtoolnix (mkvmerge).
#
# What mkvmerge no longer offers (header-removal compression went in v61) the
# tests build themselves, rewriting one of these files with
# `MatroskaTestWriter`: header stripping, legacy AAC codec ids, fixed-size
# lacing, BlockGroups and Dolby Vision configuration records.
#
#   make-fixtures.sh                  regenerate every fixture and expected.json
#   make-fixtures.sh --expected-only  rewrite expected.json from the files here
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ff() { ffmpeg -nostdin -loglevel error -y "$@"; }

# expected.json: each fixture's streams as ffprobe counts them (packets are
# frames; ffmpeg splits laces), which the tests check the remux against.
write_expected() {
    for f in ./*.mkv ./*.webm; do
        printf '%s\t' "${f#./}"
        ffprobe -v error -count_packets -show_entries stream=codec_type,codec_name,nb_read_packets -of json "$f" | tr -d '\n'
        echo
    done | python3 -c '
import json, sys
out = {}
for line in sys.stdin:
    name, probe = line.rstrip("\n").split("\t", 1)
    out[name] = [{"type": s["codec_type"], "codec": s["codec_name"], "packets": int(s["nb_read_packets"])}
                 for s in json.loads(probe)["streams"]]
json.dump(out, open("expected.json", "w"), indent=1, sort_keys=True)
'
}
if [[ "${1:-}" == "--expected-only" ]]; then write_expected; exit 0; fi
src() { echo "testsrc2=size=$1:rate=$2:duration=$3"; }

# VP9 + Opus WebM, a keyframe every second: the case the app hits most.
ff -f lavfi -i "$(src 320x180 25 8)" -f lavfi -i "sine=frequency=440:duration=8" \
   -c:v libvpx-vp9 -b:v 80k -g 25 -deadline realtime -cpu-used 8 -c:a libopus -b:a 24k vp9-opus.webm

# H.264 with B-frames (decode order differs from presentation) + AAC.
ff -f lavfi -i "$(src 320x180 24 9)" -f lavfi -i "sine=frequency=330:duration=9" \
   -c:v libx264 -preset veryfast -crf 38 -bf 3 -g 24 -keyint_min 24 -sc_threshold 0 -pix_fmt yuv420p \
   -c:a aac -b:a 48k h264-bframes-aac.mkv

# HEVC Main10 HDR10 with mastering metadata and content light levels in the
# track's Colour element (written by mkvmerge), + AAC.
ff -f lavfi -i "$(src 320x180 24 7)" -f lavfi -i "sine=frequency=550:duration=7" \
   -c:v libx265 -preset ultrafast -crf 36 -pix_fmt yuv420p10le -tag:v hvc1 \
   -x265-params "log-level=error:keyint=24:min-keyint=24:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
   -c:a aac -b:a 32k "$tmp/hevc.mkv"
mkvmerge -q -o hevc-hdr10.mkv \
   --colour-matrix-coefficients 0:9 --colour-transfer-characteristics 0:16 --colour-primaries 0:9 \
   --max-content-light 0:1000 --max-frame-light 0:400 \
   --chromaticity-coordinates 0:0.708,0.292,0.170,0.797,0.131,0.046 \
   --white-colour-coordinates 0:0.3127,0.3290 --max-luminance 0:1000 --min-luminance 0:0.0001 "$tmp/hevc.mkv"

# Surround: AC-3 and E-AC-3 5.1.
ff -f lavfi -i "$(src 160x90 25 5)" -f lavfi -i "sine=frequency=440:duration=5" \
   -c:v libx264 -preset veryfast -crf 40 -g 25 -ac 6 -c:a ac3 -b:a 192k ac3-51.mkv
ff -f lavfi -i "$(src 160x90 25 5)" -f lavfi -i "sine=frequency=440:duration=5" \
   -c:v libx264 -preset veryfast -crf 40 -g 25 -ac 6 -c:a eac3 -b:a 96k eac3-51.mkv

# FLAC (variable block sizes are allowed; this encoder's are fixed).
ff -f lavfi -i "$(src 160x90 25 4)" -f lavfi -i "sine=frequency=440:duration=4:sample_rate=22050" \
   -c:v libx264 -preset veryfast -crf 40 -g 25 -c:a flac -sample_fmt s16 flac.mkv

# Two audio tracks with languages, names and one default.
ff -f lavfi -i "$(src 160x90 25 8)" -c:v libx264 -preset veryfast -crf 40 -g 25 "$tmp/v.mkv"
ff -f lavfi -i "sine=frequency=440:duration=8" -c:a aac -b:a 32k "$tmp/a1.mka"
ff -f lavfi -i "sine=frequency=660:duration=8" -ac 2 -c:a ac3 -b:a 96k "$tmp/a2.mka"
mkvmerge -q -o two-audio.mkv "$tmp/v.mkv" \
   --language 0:en --track-name "0:Main Stereo" --default-track-flag 0:yes "$tmp/a1.mka" \
   --language 0:fr --track-name "0:Commentaire" --default-track-flag 0:no "$tmp/a2.mka"

# Laced audio: mkvmerge's Xiph lacing over MP3, EBML lacing over AAC.
ff -f lavfi -i "sine=frequency=440:duration=6" -c:a libmp3lame -b:a 32k "$tmp/a.mp3"
mkvmerge -q --engage lacing_xiph -o laced-xiph-mp3.mkv "$tmp/v.mkv" "$tmp/a.mp3"
mkvmerge -q --engage lacing_ebml -o laced-ebml-aac.mkv "$tmp/v.mkv" "$tmp/a1.mka"

# A live WebM: written to a pipe, so unknown-size Segment and Clusters, no
# Cues and no Duration (MediaRecorder's shape).
ffmpeg -nostdin -loglevel error -f lavfi -i "$(src 320x180 25 7)" -f lavfi -i "sine=frequency=440:duration=7" \
   -c:v libvpx-vp9 -b:v 80k -g 25 -deadline realtime -cpu-used 8 -c:a libopus -b:a 24k -f webm - > live.webm

# Declines: VP8 video; VP9 whose only audio is Vorbis.
ff -f lavfi -i "$(src 160x90 25 2)" -f lavfi -i "sine=frequency=440:duration=2" \
   -c:v libvpx -b:v 50k -c:a libopus -b:a 24k vp8-opus.webm
ff -f lavfi -i "$(src 160x90 25 2)" -f lavfi -i "sine=frequency=440:duration=2" \
   -c:v libvpx-vp9 -b:v 50k -deadline realtime -cpu-used 8 -c:a vorbis -strict -2 -ac 2 vp9-vorbis.webm

# AV1 + Opus.
ff -f lavfi -i "$(src 320x176 24 4)" -f lavfi -i "sine=frequency=440:duration=4" \
   -c:v libsvtav1 -preset 12 -crf 50 -g 24 -svtav1-params log-level=1 -c:a libopus -b:a 24k av1-opus.mkv

# MP3 and ALAC, each with a little H.264.
ff -f lavfi -i "$(src 160x90 25 4)" -f lavfi -i "sine=frequency=440:duration=4" \
   -c:v libx264 -preset veryfast -crf 40 -g 25 -c:a libmp3lame -b:a 32k mp3.mkv
ff -f lavfi -i "$(src 160x90 25 3)" -f lavfi -i "sine=frequency=440:duration=3:sample_rate=22050" \
   -c:v libx264 -preset veryfast -crf 40 -g 25 -c:a alac -ac 1 alac.mkv

# Subtitles beside a little H.264 + AAC: SubRip, ASS and PGS (a .sup built
# here, segment by segment, as ffmpeg can't encode PGS). mkvmerge indexes
# every subtitle block in the Cues; the second file has no cue points for
# its subtitles and zlib on its SubRip, so its blocks come from parsing.
python3 - "$tmp" <<'PY'
import sys
tmp = sys.argv[1]
open(f"{tmp}/subs.srt", "w").write(
    "1\n00:00:01,000 --> 00:00:02,000\nOne <i>italic</i>\n\n"
    "2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n"
    "3\n00:00:05,000 --> 00:00:06,500\nThree\nlines\n")
open(f"{tmp}/subs.ass", "w").write("""[Script Info]
ScriptType: v4.00+
PlayResX: 160
PlayResY: 90

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.50,0:00:02.50,Default,,0,0,0,,{\\i1}Un{\\i0}\\Ndeux, trois
Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,{\\an8\\b1}En haut
""")
def seg(t, body): return bytes([t, len(body) >> 8, len(body) & 255]) + bytes(body)
def u16(v): return [v >> 8, v & 255]
def show(n):
    rle = [1, 1, 0, 0x02, 0, 0, 0, 0xC0, 4, 2, 0, 0]  # 4x2: white, white, clear; a run of colour 2
    return [seg(0x16, u16(160) + u16(90) + [0x10] + u16(n) + [0x80, 0, 0, 1] + u16(0) + [0, 0] + u16(70) + u16(80)),
            seg(0x17, [1, 0] + u16(70) + u16(80) + u16(4) + u16(2)),
            seg(0x14, [0, 0, 1, 235, 128, 128, 255, 2, 16, 128, 128, 128]),
            seg(0x15, u16(0) + [0, 0xC0, 0, 0, len(rle) + 4] + u16(4) + u16(2) + rle),
            seg(0x80, [])]
def clear(n):
    return [seg(0x16, u16(160) + u16(90) + [0x10] + u16(n) + [0, 0, 0, 0]),
            seg(0x17, [1, 0] + u16(70) + u16(80) + u16(4) + u16(2)),
            seg(0x80, [])]
sup = b""
for n, (t, segments) in enumerate([(2.0, show), (3.0, clear), (6.0, show), (7.0, clear)]):
    pts = int(t * 90000)
    for s in segments(n):
        sup += b"PG" + pts.to_bytes(4, "big") + pts.to_bytes(4, "big") + s
open(f"{tmp}/subs.sup", "wb").write(sup)
PY
ff -f lavfi -i "$(src 160x90 25 8)" -f lavfi -i "sine=frequency=440:duration=8" \
   -c:v libx264 -preset veryfast -crf 40 -g 25 -c:a aac -b:a 32k "$tmp/av.mkv"
mkvmerge -q -o subtitles.mkv "$tmp/av.mkv" \
   --language 0:en --track-name "0:English" "$tmp/subs.srt" \
   --language 0:fr --forced-display-flag 0:yes "$tmp/subs.ass" \
   --language 0:de --hearing-impaired-flag 0:yes "$tmp/subs.sup"
mkvmerge -q -o subtitles-unindexed.mkv "$tmp/av.mkv" \
   --language 0:en --cues 0:none --compression 0:zlib "$tmp/subs.srt" --cues 0:none "$tmp/subs.ass"

write_expected

ls -l ./*.mkv ./*.webm
