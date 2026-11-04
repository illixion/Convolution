#!/usr/bin/env python3
"""Writes a synthetic PGS subtitle track as a .sup file, for the dev Jellyfin.

ffmpeg has a sup muxer but no PGS encoder, so the dev seed's PGS title
(`Caption Window (2026)`, scripts/dev-jellyfin.sh) gets its track from here:
a caption every `--every` seconds for `--duration` seconds, each shown for
three seconds and then cleared, as a disc does. Each caption is its own epoch
(a composition that carries its window, palette and object), so a player that
joins after a seek can show the next one on its own. The bitmap is a white
bar whose width steps with the caption's number, so captions differ.

    gen-pgs-sup.py OUT.sup [--duration 600] [--every 5]
"""

import argparse
import struct


def segment(kind, body, pts):
    """One segment as a .sup file stores it: "PG", PTS, DTS (0), type, size."""
    return b"PG" + struct.pack(">IIBH", pts, 0, kind, len(body)) + body


def composition(number, state, objects):
    """PCS: a 1920x1080 frame at 23.976 fps; `objects` are (id, x, y)."""
    body = struct.pack(">HHBHBBBB", 1920, 1080, 0x10, number, state, 0, 0, len(objects))
    for object_id, x, y in objects:
        body += struct.pack(">HBBHH", object_id, 0, 0, x, y)
    return body


def window(x, y, width, height):
    """WDS: one window, id 0."""
    return struct.pack(">BBHHHH", 1, 0, x, y, width, height)


def palette():
    """PDS, palette 0: index 1 opaque white, index 2 half-transparent black."""
    return bytes([0, 0, 1, 235, 128, 128, 255, 2, 16, 128, 128, 128])


def bar_rle(width, height):
    """Rows of `width` white pixels (index 1), long-run coded."""
    row = bytes([0, 0xC0 | (width >> 8), width & 0xFF, 1, 0, 0])
    return row * height


def object_definition(object_id, width, height):
    """ODS: the whole object in one segment."""
    rle = bar_rle(width, height)
    length = len(rle) + 4
    return struct.pack(">HBB", object_id, 0, 0xC0) + length.to_bytes(3, "big") + struct.pack(">HH", width, height) + rle


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--duration", type=float, default=600)
    parser.add_argument("--every", type=float, default=5)
    args = parser.parse_args()

    out = bytearray()
    number = 0
    count = int(args.duration // args.every)
    for index in range(count):
        start = int((index * args.every + 0.5) * 90_000)
        clear = start + 3 * 90_000
        width, height = 200 + (index % 20) * 40, 60
        x, y = (1920 - width) // 2, 900
        # Shown: an epoch start carrying everything it needs.
        out += segment(0x16, composition(number, 0x80, [(0, x, y)]), start)
        out += segment(0x17, window(x, y, width, height), start)
        out += segment(0x14, palette(), start)
        out += segment(0x15, object_definition(0, width, height), start)
        out += segment(0x80, b"", start)
        number += 1
        # Cleared: a composition with no objects.
        out += segment(0x16, composition(number, 0, []), clear)
        out += segment(0x17, window(x, y, width, height), clear)
        out += segment(0x80, b"", clear)
        number += 1
    with open(args.out, "wb") as f:
        f.write(out)
    print(f"{count} captions, {len(out)} bytes")


if __name__ == "__main__":
    main()
