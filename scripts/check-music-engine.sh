#!/usr/bin/env bash
# The music engine (Services/Library/MusicEngine) on files ffmpeg makes: both decoders on every container,
# sample-exact gapless joins, crossfade length/level/gain, seeks, seam detection, the crossfade rules, and a
# short run through the real renderer (silent). Needs ffmpeg; no server.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d "${TMPDIR:-/tmp}/hypnos-music-engine.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# One continuous recording (a gliding chord, so a gap or a click at a cut shows), cut at odd samples.
chord="0.25*sin(2*PI*(220*t+40*sin(2*PI*t/5)))+0.18*sin(2*PI*(330*t+60*sin(2*PI*t/5)))"
ff -f lavfi -i "aevalsrc=${chord}|${chord}*0.9:s=44100:d=9" "$dir/whole.wav"
ff -i "$dir/whole.wav" "$dir/whole.flac"
cuts=(0 132317 269601 396900)
for i in 1 2 3; do
    trim="atrim=start_sample=${cuts[i-1]}:end_sample=${cuts[i]},asetpts=PTS-STARTPTS"
    ff -i "$dir/whole.wav" -af "$trim" "$dir/t$i.flac"
    ff -i "$dir/whole.wav" -af "$trim" -c:a libmp3lame -b:a 192k "$dir/t$i.mp3"
    ff -i "$dir/whole.wav" -af "$trim" -c:a aac -b:a 160k -movflags +faststart "$dir/t$i-fast.m4a"
done
ff -i "$dir/t1.flac" "$dir/t1.wav"
ff -i "$dir/t1.flac" -c:a pcm_s24le "$dir/t1-24.wav"
ff -i "$dir/t1.flac" -c:a aac -b:a 160k "$dir/t1-slow.m4a"          # index after the audio
ff -f lavfi -i "sine=frequency=500:sample_rate=22050:duration=3" "$dir/mono22.wav"
ff -f lavfi -i "sine=frequency=500:sample_rate=96000:duration=3" -ac 2 -sample_fmt s32 "$dir/hires.flac"
ff -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=6" -ac 2 "$dir/a.flac"
ff -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=6" -ac 2 "$dir/b.flac"
ff -f lavfi -i "sine=frequency=550:sample_rate=44100:duration=2" -ac 2 "$dir/short.flac"
for i in 1 2; do  # ordinary songs: a fade in, a fade out, a second of silence
    ff -f lavfi -i "sine=frequency=$((300 + 100 * i)):sample_rate=44100:duration=4" -ac 2 \
        -af "afade=t=in:d=0.05,afade=t=out:st=2:d=2,apad=pad_dur=1" -c:a aac -b:a 128k "$dir/faded$i.m4a"
done

engine="$repo_root/Hypnos/Hypnos/Services/Library/MusicEngine"
swiftc -swift-version 6 -O -parse-as-library \
    "$engine/MusicSongFile.swift" "$engine/MusicDecoders.swift" "$engine/MusicTimeline.swift" "$engine/MusicPlaybackEngine.swift" \
    "$repo_root/Hypnos/Hypnos/Services/Library/MusicCrossfade.swift" \
    "$repo_root/scripts/checks/MusicEngineChecks.swift" \
    -o "$dir/music-engine-checks" 2>&1 | grep -E "error" || true
"$dir/music-engine-checks" "$dir"
