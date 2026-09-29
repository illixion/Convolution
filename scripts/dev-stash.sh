#!/usr/bin/env bash
# A disposable Stash server with synthetic media, for testing Hypnos's Stash
# source without touching a real library. Never point tests, simulators or
# agents at a personal Stash; use this.
#
#   scripts/dev-stash.sh up               create (first run) or start it, seeded and scanned
#   scripts/dev-stash.sh reset            wipe its database and re-seed from scratch
#   scripts/dev-stash.sh auth [user pass] set a login + generate an API key (default dev/dev)
#   scripts/dev-stash.sh down             stop it
#   scripts/dev-stash.sh rm               stop it and delete everything it stored
#
# Serves http://127.0.0.1:9998 (loopback only, no API key by default — see
# `auth` above for testing the app's API-key path). The iOS, tvOS and
# visionOS simulators share the Mac's loopback, so the app can use that URL
# directly. The media is generated with ffmpeg: 12 distinct photos and 5 clips
# covering the codec paths the players branch on (H.264, 10-bit HEVC 4K,
# VP9/Opus WebM). Needs docker (colima) and ffmpeg.
set -euo pipefail

name=hypnos-dev-stash
port=9998
root="${HYPNOS_DEV_STASH_DIR:-$HOME/.local/share/hypnos-dev-stash}"
graphql="http://127.0.0.1:$port/graphql"
apikey_file="$root/config/dev-api-key.txt"

gql() { curl -s "$graphql" -H 'Content-Type: application/json' -d "$1"; }

wait_for_jobs() {
    for _ in $(seq 1 60); do
        [[ "$(gql '{"query":"{ jobQueue { description } }"}')" == *'"jobQueue":null'* ]] && return
        sleep 5
    done
    echo "dev-stash: jobs still running after 5 minutes" >&2
}

seed_media() {
    mkdir -p "$root/data/videos" "$root/data/images"
    cd "$root/data"
    for i in 1 2 3; do
        [[ -f videos/h264-test-$i.mp4 ]] || ffmpeg -loglevel error -y \
            -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=20" \
            -f lavfi -i "sine=frequency=$((300 * i)):duration=20" \
            -c:v libx264 -pix_fmt yuv420p -c:a aac "videos/h264-test-$i.mp4"
    done
    [[ -f videos/vp9-test.webm ]] || ffmpeg -loglevel error -y \
        -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=20" -f lavfi -i "sine=frequency=500:duration=20" \
        -c:v libvpx-vp9 -b:v 2M -c:a libopus videos/vp9-test.webm
    [[ -f videos/hevc-4k-test.mp4 ]] || ffmpeg -loglevel error -y \
        -f lavfi -i "testsrc2=size=3840x2160:rate=24:duration=15" \
        -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p10le -x265-params log-level=error videos/hevc-4k-test.mp4
    # Each photo must differ: Stash merges files with the same fingerprint
    # into one image, so identical frames would show up as a single photo.
    # The sizes vary on purpose: the Pictures grid's original-aspect mode needs
    # landscape, portrait, square, panoramic and tall sources to show anything.
    # (Only missing files are generated — `rm` first to re-shape an old seed.)
    local sizes=(2400x1600 1600x2400 2400x1350 1200x1200 3000x1000 1000x1500
                 2000x1500 1350x2400 2400x1600 1500x1500 1800x1200 1200x1800)
    for i in $(seq 1 12); do
        f=$(printf 'images/photo-%02d.jpg' "$i")
        [[ -f $f ]] || ffmpeg -loglevel error -y \
            -f lavfi -i "testsrc2=size=${sizes[$((i - 1))]}:rate=1,hue=h=$((i * 30))" -ss "$i" -frames:v 1 "$f"
    done
}

start_container() {
    mkdir -p "$root"/{config,generated,metadata,cache,blobs}
    if docker container inspect "$name" >/dev/null 2>&1; then
        docker start "$name" >/dev/null
    else
        docker run -d --name "$name" --restart unless-stopped -p "127.0.0.1:$port:9999" \
            -e STASH_STASH=/data/ -e STASH_GENERATED=/generated/ -e STASH_METADATA=/metadata/ \
            -e STASH_CACHE=/cache/ -e STASH_PORT=9999 \
            -v "$root/config:/root/.stash" -v "$root/data:/data" -v "$root/generated:/generated" \
            -v "$root/metadata:/metadata" -v "$root/cache:/cache" -v "$root/blobs:/blobs" \
            stashapp/stash:latest >/dev/null
    fi
    for _ in $(seq 1 30); do
        curl -s -o /dev/null "http://127.0.0.1:$port/" && return
        sleep 2
    done
    echo "dev-stash: server did not come up" >&2
    exit 1
}

setup_and_scan() {
    if [[ "$(gql '{"query":"{ systemStatus { status } }"}')" == *'"SETUP"'* ]]; then
        gql '{"query":"mutation { setup(input: { configLocation: \"/root/.stash/config.yml\", stashes: [{ path: \"/data\", excludeVideo: false, excludeImage: false }], databaseFile: \"\", generatedLocation: \"/generated\", cacheLocation: \"/cache\", blobsLocation: \"/blobs\", storeBlobsInDatabase: false }) }"}' >/dev/null
        sleep 5
    fi
    gql '{"query":"mutation { metadataScan(input: {}) }"}' >/dev/null
    sleep 3
    wait_for_jobs
    gql '{"query":"mutation { metadataGenerate(input: { covers: true, sprites: true, imageThumbnails: true }) }"}' >/dev/null
    sleep 3
    wait_for_jobs
    gql '{"query":"{ findImages { count } findScenes { count } }"}'
    echo
    echo "dev-stash: http://127.0.0.1:$port"
}

enable_auth() {
    local user="$1" pass="$2"

    if [[ -f "$apikey_file" ]]; then
        echo "dev-stash: auth already enabled (username=$user expected) — key at $apikey_file"
        return
    fi

    # Requires the instance to still be unauthenticated: setting a
    # username/password is what turns auth on in the first place, so this
    # must run before Stash starts demanding a session for every request.
    gql "$(printf '{"query":"mutation { configureGeneral(input: { username: \\"%s\\", password: \\"%s\\" }) { username } }"}' "$user" "$pass")" >/dev/null

    # GraphQL now requires a session cookie; get one the same way a browser
    # would, via the plain form-POST login endpoint, then use it once to mint
    # a long-lived API key.
    local cookiejar
    cookiejar="$(mktemp)"
    curl -s -c "$cookiejar" -X POST "http://127.0.0.1:$port/login" \
        --data-urlencode "username=$user" --data-urlencode "password=$pass" >/dev/null

    local response key
    response="$(curl -s -b "$cookiejar" "$graphql" -H 'Content-Type: application/json' \
        -d '{"query":"mutation { generateAPIKey(input: {}) }"}')"
    rm -f "$cookiejar"
    key="$(python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["data"]["generateAPIKey"])
except Exception:
    pass' <<<"$response")"

    if [[ -z "$key" ]]; then
        echo "dev-stash: failed to generate an API key (is auth already configured with different credentials?)" >&2
        exit 1
    fi

    mkdir -p "$root/config"
    printf '%s' "$key" > "$apikey_file"
    chmod 600 "$apikey_file"
    # The key itself is never echoed — callers read it from the file.
    echo "dev-stash: auth enabled — username=$user password=$pass"
    echo "dev-stash: API key written to $apikey_file (not printed)"
}

case "${1:-up}" in
    up)
        seed_media
        start_container
        setup_and_scan
        ;;
    reset)
        docker stop "$name" >/dev/null 2>&1 || true
        rm -rf "${root:?}"/{config,generated,metadata,cache,blobs}
        seed_media
        start_container
        setup_and_scan
        ;;
    auth)
        enable_auth "${2:-dev}" "${3:-dev}"
        ;;
    down)
        docker stop "$name" >/dev/null
        ;;
    rm)
        docker rm -f "$name" >/dev/null 2>&1 || true
        rm -rf "${root:?}"
        ;;
    *)
        echo "usage: $0 up|reset|auth [user pass]|down|rm" >&2
        exit 2
        ;;
esac
