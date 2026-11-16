#!/usr/bin/env python3
"""
MP4 fixtures for MP4ReindexTests: one short H.264 (B-frames) + AAC file made
by ffmpeg, laid out four ways.

  mp4-interleaved.mp4        ffmpeg's own layout: ~1 s chunks, moov first.
                             Nothing to fix.
  mp4-onechunk-free.mp4      every track's samples in one chunk (video, then
                             audio), moov first with a 4 KB free box after it,
                             as MainConcept writes (the file that stalled on a
                             Vision Pro, 2026-11-16, had 341 frames in one
                             30 MB chunk and a 10 KB skip box).
  mp4-onechunk.mp4           the same without the free box: the rewritten moov
                             must shift every chunk offset.
  mp4-onechunk-moov-end.mp4  the same with moov after mdat: offsets don't move.
  mp4-fragmented.mp4         fragmented MP4 (moof): declined.

Run from this folder: python3 make-mp4-fixtures.py (needs ffmpeg).
"""
import struct
import subprocess

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}


def boxes(data, start, end):
    at = start
    while at + 8 <= end:
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[at + 8:at + 16])[0]
            header = 16
        elif size == 0:
            size = end - at
        yield kind, at, header, size
        at += size


def find(data, start, end, path):
    for kind, at, header, size in boxes(data, start, end):
        if kind == path[0]:
            if len(path) == 1:
                yield at, header, size
            else:
                yield from find(data, at + header, at + size, path[1:])


def u32(data, at):
    return struct.unpack(">I", data[at:at + 4])[0]


def track_samples(data, trak_at, trak_header, trak_size):
    """[(offset, size)] for every sample of a track, in decode order."""
    (stbl_at, stbl_h, stbl_size), = find(data, trak_at + trak_header, trak_at + trak_size, [b"mdia", b"minf", b"stbl"])
    body = (stbl_at + stbl_h, stbl_at + stbl_size)
    (stsz_at, h, _), = find(data, *body, [b"stsz"])
    uniform, count = u32(data, stsz_at + h + 4), u32(data, stsz_at + h + 8)
    sizes = [uniform] * count if uniform else [u32(data, stsz_at + h + 12 + 4 * i) for i in range(count)]
    (stsc_at, h, _), = find(data, *body, [b"stsc"])
    runs = [(u32(data, stsc_at + h + 8 + 12 * i), u32(data, stsc_at + h + 12 + 12 * i))
            for i in range(u32(data, stsc_at + h + 4))]
    (stco_at, h, _), = find(data, *body, [b"stco"])
    chunks = [u32(data, stco_at + h + 8 + 4 * i) for i in range(u32(data, stco_at + h + 4))]
    out, sample = [], 0
    for index, offset in enumerate(chunks):
        per = [r[1] for r in runs if r[0] <= index + 1][-1]
        for _ in range(per):
            out.append((offset, sizes[sample]))
            offset += sizes[sample]
            sample += 1
    assert sample == count
    return out, (stsc_at, stco_at)


def resize(moov, path_offsets, delta):
    """Grows every box on the path (absolute offsets into moov) by delta."""
    for at in path_offsets:
        moov[at:at + 4] = struct.pack(">I", u32(moov, at) + delta)


def one_chunk(src, layout):
    data = open(src, "rb").read()
    (moov_at, moov_h, moov_size), = find(data, 0, len(data), [b"moov"])
    moov = bytearray(data[moov_at:moov_at + moov_size])
    traks = list(find(moov, moov_h, len(moov), [b"trak"]))
    payload = bytearray()
    plans = []
    for trak_at, trak_h, trak_size in traks:
        samples, _ = track_samples(moov, trak_at, trak_h, trak_size)
        plans.append(len(payload))
        for offset, size in samples:
            payload += data[offset:offset + size]
    # Rewrite each track's stsc to one entry and stco to one chunk. Both shrink;
    # the boxes above them shrink with them. Work from the last track back so
    # earlier offsets stay valid.
    for (trak_at, trak_h, trak_size), start in reversed(list(zip(traks, plans))):
        (mdia_at, mdia_h, _), = find(moov, trak_at + trak_h, trak_at + trak_size, [b"mdia"])
        (minf_at, minf_h, _), = find(moov, mdia_at + mdia_h, mdia_at + u32(moov, mdia_at), [b"minf"])
        (stbl_at, stbl_h, _), = find(moov, minf_at + minf_h, minf_at + u32(moov, minf_at), [b"stbl"])
        body = (stbl_at + stbl_h, stbl_at + u32(moov, stbl_at))
        (stsz_at, h, _), = find(moov, *body, [b"stsz"])
        count = u32(moov, stsz_at + h + 8)
        # stco last (it sits after stsc in ffmpeg's order); placeholder offset.
        (stco_at, h, stco_size), = find(moov, *body, [b"stco"])
        new_stco = struct.pack(">I4sIII", 20, b"stco", 0, 1, 0xDEADBEEF)
        moov[stco_at:stco_at + stco_size] = new_stco
        resize(moov, [stbl_at, minf_at, mdia_at, trak_at, 0], len(new_stco) - stco_size)
        body = (stbl_at + stbl_h, stbl_at + u32(moov, stbl_at))
        (stsc_at, h, stsc_size), = find(moov, *body, [b"stsc"])
        new_stsc = struct.pack(">I4sIIIII", 28, b"stsc", 0, 1, 1, count, 1)
        moov[stsc_at:stsc_at + stsc_size] = new_stsc
        resize(moov, [stbl_at, minf_at, mdia_at, trak_at, 0], len(new_stsc) - stsc_size)
    ftyp = data[0:u32(data, 0)]
    free = struct.pack(">I4s", 4096, b"free") + bytes(4088) if layout == "free" else b""
    mdat = struct.pack(">I4s", 8 + len(payload), b"mdat") + payload
    if layout == "end":
        head = ftyp + mdat
        media_start = len(ftyp) + 8
        out = bytearray(head + moov)
    else:
        media_start = len(ftyp) + len(moov) + len(free) + 8
        out = bytearray(ftyp + moov + free + mdat)
    moov_base = len(ftyp) + len(mdat) if layout == "end" else len(ftyp)
    for start in plans:
        at = out.find(struct.pack(">I", 0xDEADBEEF), moov_base)
        out[at:at + 4] = struct.pack(">I", media_start + start)
    return bytes(out)


subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-t", "3", "-c:v", "libx264", "-preset", "veryfast", "-g", "25", "-bf", "2",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
                "-movflags", "+faststart", "mp4-interleaved.mp4"], check=True)
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", "mp4-interleaved.mp4",
                "-c", "copy", "-movflags", "+frag_keyframe+empty_moov", "mp4-fragmented.mp4"], check=True)
for name, layout in [("mp4-onechunk-free.mp4", "free"), ("mp4-onechunk.mp4", "plain"),
                     ("mp4-onechunk-moov-end.mp4", "end")]:
    open(name, "wb").write(one_chunk("mp4-interleaved.mp4", layout))
