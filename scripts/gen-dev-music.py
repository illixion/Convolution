#!/usr/bin/env python3
"""Synthetic music for the disposable dev Jellyfin (scripts/dev-jellyfin.sh).

The dev instance holds one real album, which is too little to see sorting, Random, Cover Flow or an artist with
several albums. This writes ~40 short tone albums with tags and generated cover art under
`$root/data/music/Synthetic/` (the folder the Music library already watches), with spread-out years, genres,
lengths and file dates so every sort order has something to sort. Includes a two-disc album and a compilation
whose track artists differ from its album artist.

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


def synth(path: Path, cover_path: Path, tags: dict, freq: int, seconds: int):
    meta = []
    for k, v in tags.items():
        meta += ["-metadata", f"{k}={v}"]
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                    f"sine=frequency={freq}:duration={seconds}:sample_rate=44100", "-i", str(cover_path),
                    "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-b:a", "48k", "-c:v", "mjpeg",
                    "-disposition:v", "attached_pic", *meta, str(path)], check=True)


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
        # Spread file dates over ~a year so Date Added has Today / This Week / months to group by.
        stamp = subprocess.run(["date", "-v", f"-{(index * 9) % 380}d", "+%Y%m%d%H%M"], capture_output=True, text=True).stdout.strip()
        for f in folder.iterdir():
            subprocess.run(["touch", "-t", stamp, str(f)], check=True)
        subprocess.run(["touch", "-t", stamp, str(folder)], check=True)
    print(f"wrote {files} files under {ROOT}")


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
