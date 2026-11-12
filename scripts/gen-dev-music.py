#!/usr/bin/env python3
"""Synthetic music for the disposable dev Jellyfin (scripts/dev-jellyfin.sh).

The dev instance holds one real album, which is too little to see sorting, Random, Cover Flow or an artist with
several albums. This writes ~40 short tone albums with tags and generated cover art under
`$root/data/music/Synthetic/` (the folder the Music library already watches), with spread-out years, genres,
lengths and file dates so every sort order has something to sort. Includes a two-disc album and a compilation
whose track artists differ from its album artist.

Ordinary tracks fade out and end in silence, as mastered songs do, so a crossfade has something to blend and the
seam detector (`MusicSeams`) finds them not seamless. Two albums are one continuous piece cut into tracks at exact
samples, the way a live album or a DJ mix is: "Unbroken Line" (FLAC) and "Night Drive Mix" (AAC with its priming
in an edit list). Played gaplessly their tracks join without a click; the seam detector finds them seamless.

    scripts/gen-dev-music.py              write the files (skips ones already there)
    scripts/gen-dev-music.py --refresh    also ask the dev Jellyfin to rescan its libraries
    scripts/gen-dev-music.py --clean      delete the synthetic folder

Only ever for the disposable instance; it signs in with the dev user from dev-jellyfin.sh.
"""
import argparse, colorsys, hashlib, json, os, random, shutil, subprocess, sys, urllib.request
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(os.environ.get("HYPNOS_DEV_JELLYFIN_DIR", Path.home() / ".local/share/hypnos-dev-jellyfin")) / "data/music/Synthetic"
BASE = "http://127.0.0.1:8097"

ARTISTS = ["Aurora Vale", "Brass Monkeys Club", "Cobalt Hour", "Dust & Daylight", "Echo Harbor", "Fable Street",
           "Glass Orchard", "Hollow Tide", "Iron Lantern", "Juniper Sky", "Kite Season", "Lunar Mile",
           "Marble Arcade", "Neon Almanac", "The Quiet Engines", "A Thousand Paper Cranes"]
GENRES = ["Indie Rock", "Electronic", "Jazz", "Folk", "Ambient", "Hip-Hop", "Classical", "Synthpop"]
WORDS = ["Midnight", "Orchard", "Static", "Harbor", "Velvet", "Signal", "Paper", "Winter", "Lantern", "Satellite",
         "Garden", "Mirror", "Cascade", "Ember", "Tundra", "Carousel", "Monsoon", "Halcyon", "Parade", "Meridian"]
TRACK_WORDS = ["Intro", "Slow Burn", "Afterglow", "Northern Lights", "Hold Still", "Weather", "Small Hours", "Undertow",
               "Glasshouse", "Paper Boats", "Second Wind", "Low Tide", "Kerosene", "Wildflower", "Overpass", "Lullaby"]


def cover(path: Path, title: str, artist: str):
    seed = int(hashlib.md5((title + artist).encode()).hexdigest()[:8], 16)
    rng = random.Random(seed)
    hue = rng.random()
    size = 640
    img = Image.new("RGB", (size, size))
    px = img.load()
    c1 = colorsys.hsv_to_rgb(hue, 0.75, 0.95)
    c2 = colorsys.hsv_to_rgb((hue + 0.18 + rng.random() * 0.2) % 1, 0.85, 0.45)
    for y in range(size):
        for x in range(size):
            t = (x * 0.4 + y * 0.6) / size
            px[x, y] = tuple(int(255 * (a * (1 - t) + b * t)) for a, b in zip(c1, c2))
    d = ImageDraw.Draw(img)
    for _ in range(3):  # a few translucent shapes so covers are visibly different at a glance
        x, y, r = rng.randint(0, size), rng.randint(0, size), rng.randint(90, 260)
        d.ellipse([x - r, y - r, x + r, y + r], outline=(255, 255, 255), width=rng.randint(3, 9))
    big = ImageFont.load_default(size=300)
    small = ImageFont.load_default(size=40)
    d.text((40, 20), title[0], font=big, fill=(255, 255, 255))
    d.text((40, size - 120), title, font=small, fill=(255, 255, 255))
    d.text((40, size - 70), artist, font=small, fill=(255, 235, 220))
    img.save(path, quality=90)


def metadata(tags: dict):
    meta = []
    for k, v in tags.items():
        meta += ["-metadata", f"{k}={v}"]
    return meta


def synth(path: Path, cover_path: Path, tags: dict, freq: int, seconds: int):
    # A short fade in, a two-second fade out and a second of silence: an ordinary mastered song's edges.
    tone = seconds - 1
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                    f"sine=frequency={freq}:duration={tone}:sample_rate=44100", "-i", str(cover_path),
                    "-af", f"afade=t=in:d=0.05,afade=t=out:st={tone - 2}:d=2,apad=pad_dur=1",
                    "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-b:a", "48k", "-c:v", "mjpeg",
                    "-disposition:v", "attached_pic", *metadata(tags), str(path)], check=True)


# One continuous piece: a chord whose pitch glides and whose level swells, so every cut lands mid-sound and a
# gap or a click at a seam is audible (and measurable). Phase is continuous across the whole piece.
CONTINUOUS = ("0.25*sin(2*PI*(220*t+40*sin(2*PI*t/23)))+0.18*sin(2*PI*(330*t+60*sin(2*PI*t/23)))"
              "+0.12*sin(2*PI*(440*t+80*sin(2*PI*t/31)))*(0.6+0.4*sin(2*PI*t/7))")


def continuous_album(folder: Path, art: Path, artist: str, album: str, year: int, genre: str, lengths: list,
                     titles: list, codec: list, ext: str):
    total = sum(lengths)
    whole = folder / "whole.wav"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                    f"aevalsrc={CONTINUOUS}:s=44100:d={total}", "-ac", "2", str(whole)], check=True)
    start = 0
    for track, (seconds, title) in enumerate(zip(lengths, titles), start=1):
        end = start + seconds * 44100
        tags = {"title": title, "artist": artist, "album_artist": artist, "album": album, "date": str(year),
                "genre": genre, "track": f"{track}/{len(lengths)}", "disc": "1/1"}
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(whole), "-i", str(art),
                        "-af", f"atrim=start_sample={start}:end_sample={end},asetpts=PTS-STARTPTS",
                        "-map", "0:a", "-map", "1:v", *codec, "-c:v", "mjpeg", "-disposition:v", "attached_pic",
                        *metadata(tags), str(folder / f"{track:02d} {title}.{ext}")], check=True)
        start = end
    whole.unlink()
    return len(lengths)


def build():
    rng = random.Random(7)
    plan = []  # (artist, album, year, genre, discs, tracks_per_disc, compilation)
    for i, artist in enumerate(ARTISTS):
        for j in range(2 + (i % 2)):
            album = f"{rng.choice(WORDS)} {rng.choice(WORDS)}"
            plan.append((artist, album, rng.randint(1968, 2024), rng.choice(GENRES), 1, rng.randint(3, 5), False))
    plan.append(("Aurora Vale", "Live At The Meridian", 2019, "Indie Rock", 2, 3, False))  # two discs
    plan.append(("Various Artists", "Now That's What I Synthesised", 2011, "Synthpop", 1, 6, True))
    files = 0
    ROOT.mkdir(parents=True, exist_ok=True)
    for index, (artist, album, year, genre, discs, per_disc, compilation) in enumerate(plan):
        folder = ROOT / artist.replace("/", "-") / album
        if folder.exists():
            continue
        folder.mkdir(parents=True)
        art = folder / "cover.jpg"
        cover(art, album, artist)
        for disc in range(1, discs + 1):
            for track in range(1, per_disc + 1):
                title = rng.choice(TRACK_WORDS) + (f" {track}" if rng.random() < 0.3 else "")
                track_artist = rng.choice(ARTISTS) if compilation else artist
                name = f"{disc}-{track:02d} {title}.m4a" if discs > 1 else f"{track:02d} {title}.m4a"
                tags = {"title": title, "artist": track_artist, "album_artist": artist, "album": album, "date": str(year),
                        "genre": genre, "track": f"{track}/{per_disc}", "disc": f"{disc}/{discs}"}
                synth(folder / name, art, tags, 220 + index * 17 + track * 40, rng.randint(14, 50))
                files += 1
        stamp_folder(folder, index)
    continuous = [
        ("Echo Harbor", "Unbroken Line", 2016, "Electronic", [24, 31, 19, 27],
         ["Departure", "Long Exposure", "Crossing", "Arrival"], ["-c:a", "flac"], "flac"),
        ("Neon Almanac", "Night Drive Mix", 2022, "Synthpop", [22, 18, 26],
         ["On Ramp", "Sodium Lights", "Exit 9"], ["-c:a", "aac", "-b:a", "128k"], "m4a"),
    ]
    for offset, (artist, album, year, genre, lengths, titles, codec, ext) in enumerate(continuous):
        folder = ROOT / artist / album
        if folder.exists():
            continue
        folder.mkdir(parents=True)
        art = folder / "cover.jpg"
        cover(art, album, artist)
        files += continuous_album(folder, art, artist, album, year, genre, lengths, titles, codec, ext)
        stamp_folder(folder, len(plan) + offset)
    print(f"wrote {files} files under {ROOT}")


def stamp_folder(folder: Path, index: int):
    # Spread file dates over ~a year so Date Added has Today / This Week / months to group by.
    stamp = subprocess.run(["date", "-v", f"-{(index * 9) % 380}d", "+%Y%m%d%H%M"], capture_output=True, text=True).stdout.strip()
    for f in folder.iterdir():
        subprocess.run(["touch", "-t", stamp, str(f)], check=True)
    subprocess.run(["touch", "-t", stamp, str(folder)], check=True)


def refresh():
    hdr = 'MediaBrowser Client="gen", Device="Mac", DeviceId="gen-1", Version="1"'
    req = urllib.request.Request(f"{BASE}/Users/AuthenticateByName", method="POST", headers={
        "Authorization": hdr, "Content-Type": "application/json"}, data=json.dumps({"Username": "dev", "Pw": "dev12345"}).encode())
    token = json.load(urllib.request.urlopen(req))["AccessToken"]
    req = urllib.request.Request(f"{BASE}/Library/Refresh", method="POST", headers={"Authorization": f'{hdr}, Token="{token}"'})
    urllib.request.urlopen(req)
    print("asked the dev Jellyfin to rescan")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--clean", action="store_true")
    args = ap.parse_args()
    if args.clean:
        shutil.rmtree(ROOT, ignore_errors=True)
        print("removed", ROOT)
        sys.exit(0)
    build()
    if args.refresh:
        refresh()
