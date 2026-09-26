#!/usr/bin/env bash
# A disposable Jellyfin server with a synthetic library, for testing the
# Atmos Objects plugin (JellyfinPlugin/) without touching a real Jellyfin.
# Never point tests, simulators or agents at a real Jellyfin instance; use
# this, modelled on dev-stash.sh.
#
#   scripts/dev-jellyfin.sh up      create (first run) or start it, seeded + scanned + plugin installed
#   scripts/dev-jellyfin.sh reset   wipe its state and re-seed/reinstall from scratch
#   scripts/dev-jellyfin.sh down    stop it
#   scripts/dev-jellyfin.sh rm      stop it and delete everything it stored
#
# Serves http://127.0.0.1:8097 (loopback only). Needs docker (colima), the
# .NET SDK (to build the plugin) and ffmpeg. Seeds a Movies library with three
# items:
#   - the Dolby Atmos demo file at $HYPNOS_DEV_JELLYFIN_DEMO (default
#     ~/Downloads/DolbyElement4K_VisionAtmos.mkv), bind-mounted read-only —
#     carries both a TrueHD Atmos track and an EAC3 JOC track, so the plugin
#     picks TrueHD (see AtmosSceneService.GetState)
#   - the same demo remuxed to drop the TrueHD track (video + EAC3 only), so
#     its EAC3 track is the only Atmos-capable audio and the plugin is forced
#     onto that path — this is how the EAC3 decoder gets end-to-end tested
#   - NoAtmosTest.mkv: a small synthetic H.264 + plain (non-Atmos) EAC3 5.1
#     item, ffmpeg-generated, for the "unsupported" path
#
# truehdd (JellyfinPlugin/truehdd/) only ships a macOS binary, which can't run
# inside the (Linux) Jellyfin container. Two ways to fix that: run Jellyfin
# natively on the Mac instead of in a container, or build a second, Linux
# truehdd. This script does the latter, from the same already-patched
# checkout truehdd/build.sh produces, inside a throwaway rust container —
# colima's VM here is arm64, matching the macOS host, so no cross-compile
# flags are needed and the same checkout builds unmodified. That keeps the
# whole dev instance disposable via `rm` the same way dev-stash.sh is,
# rather than leaving a native Jellyfin install and a native truehdd build
# behind on the Mac itself.
set -euo pipefail

name=hypnos-dev-jellyfin
port=8097
root="${HYPNOS_DEV_JELLYFIN_DIR:-$HOME/.local/share/hypnos-dev-jellyfin}"
base="http://127.0.0.1:$port"
apikey_file="$root/config/dev-api-key.txt"
demo="${HYPNOS_DEV_JELLYFIN_DEMO:-$HOME/Downloads/DolbyElement4K_VisionAtmos.mkv}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="jellyfin/jellyfin:10.11.11"
devuser=dev
devpass=dev12345
auth_hdr='X-Emby-Authorization: MediaBrowser Client="hypnos-dev-jellyfin", Device="script", DeviceId="hypnos-dev-jellyfin", Version="10.11.11"'

# A bold system font for the generated poster/fanart/logo art (see gen_art
# below) — this Homebrew ffmpeg has no drawtext/libfreetype, so art is
# rendered with ImageMagick instead, which does.
font="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
[[ -f "$font" ]] || font="/System/Library/Fonts/Helvetica.ttc"

api() { curl -s "$@"; }

wait_for_server() {
    for _ in $(seq 1 60); do
        [[ "$(api -o /dev/null -w '%{http_code}' "$base/health")" == "200" ]] && break
        sleep 2
    done
    # /health can turn 200 a moment before the Startup controller's own routes
    # are live — an immediate POST to /Startup/User then 404s (seen directly,
    # not theoretical: on an otherwise-identical fresh container, /health was
    # already 200 but /Startup/User still 404'd for a few seconds). Poll the
    # actual endpoint the wizard needs first. Once the wizard has run, the
    # same route answers 401 instead, which also means it is live.
    local code
    for _ in $(seq 1 30); do
        code="$(api -o /dev/null -w '%{http_code}' "$base/Startup/Configuration")"
        [[ "$code" == "200" || "$code" == "401" ]] && return
        sleep 1
    done
    echo "dev-jellyfin: server did not come up" >&2
    exit 1
}

# Builds the plugin on the host (portable IL — the same build runs fine under
# the container's bundled .NET runtime) and drops it straight into the
# instance's plugin folder. Named/versioned per JellyfinPlugin/README.md.
build_plugin() {
    dotnet build "$repo_root/JellyfinPlugin/Jellyfin.Plugin.AtmosObjects" -c Release >/dev/null
    local out="$repo_root/JellyfinPlugin/Jellyfin.Plugin.AtmosObjects/bin/Release/net9.0"
    local dest="$root/config/plugins/AtmosObjects_0.1.0.0"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp "$out/Jellyfin.Plugin.AtmosObjects.dll" "$out/Cavern.dll" "$out/Cavern.Format.dll" "$dest/"
}

build_truehdd_linux() {
    local checkout="$repo_root/JellyfinPlugin/truehdd/checkout"
    if [[ ! -d "$checkout" ]]; then
        echo "dev-jellyfin: $checkout doesn't exist — run JellyfinPlugin/truehdd/build.sh first" >&2
        exit 1
    fi

    [[ -x "$root/truehdd/truehdd" ]] && return
    mkdir -p "$root/truehdd" "$root/cargo-cache"
    echo "dev-jellyfin: building a Linux truehdd (first run only)..."
    # `cargo build --release` (any -C opt-level above 0, tested 1/2/3, with or
    # without the evo-protection feature/hmac+sha2) reliably gets rustc 1.98.1
    # SIGKILLed compiling the `truehd` lib crate for aarch64-unknown-linux-gnu
    # — and even a plain debug build needs more than colima's default 2 GiB
    # VM (confirmed: OOM-killed there too, succeeds the moment the VM has
    # more headroom). The same source and rustc version builds the release
    # macOS binary at truehdd/checkout/target/release/truehdd
    # (aarch64-apple-darwin) without incident, so --release specifically
    # looks like an LLVM/rustc backend bug on the linux-gnu target at this
    # toolchain version, not anything about our patch or this content — but
    # either way, this one build needs real memory. Rather than resize the
    # default colima profile (shared with other projects' containers — see
    # ~/CLAUDE.md's server rules on not disturbing other running work), spin
    # up a throwaway colima profile just for this, sized generously, and
    # target it with `docker --context` for this one command only — the
    # default context (and everything already running under it) is never
    # touched. A plain debug build (opt-level 0) is what runs inside it:
    # slower than release, but only used here to verify the TrueHD path
    # still works end-to-end through the dev instance — not to measure
    # TrueHD decode speed (see the README for that; EAC3 speed is what this
    # task actually needed measured).
    local build_profile=hypnos-jellyfin-truehdd-build
    local sock="$HOME/.colima/$build_profile/docker.sock"
    local build_status=0
    colima start --profile "$build_profile" --memory 8 --cpu 4 --disk 20 >/dev/null 2>&1
    # `colima start`'s own docker-context switch is flaky right after it
    # returns (seen directly: `docker --context colima-$build_profile run`
    # failed against /var/run/docker.sock — the default socket, not this
    # profile's — even after confirming the context existed via `docker
    # context inspect`). Talking to the profile's own socket directly via
    # DOCKER_HOST sidesteps context bookkeeping entirely; still wait for the
    # socket file to actually exist first, since colima forwards it a moment
    # after printing "READY".
    for _ in $(seq 1 30); do
        [[ -S "$sock" ]] && break
        sleep 1
    done
    DOCKER_HOST="unix://$sock" docker run --rm \
        -v "$checkout:/src:ro" \
        -v "$root/truehdd:/out" \
        -v "$root/cargo-cache:/usr/local/cargo/registry" \
        rust:1-bookworm bash -c "cp -r /src /build && cd /build && cargo build --quiet && cp target/debug/truehdd /out/truehdd" \
        || build_status=$?
    colima stop --profile "$build_profile" >/dev/null 2>&1 || true
    colima delete --profile "$build_profile" --force >/dev/null 2>&1 || true
    # `colima delete` of the (current) build profile leaves docker's context
    # pointed at the built-in "default" (unix:///var/run/docker.sock, which
    # doesn't exist on this Mac — colima never uses it) instead of restoring
    # "colima", the default profile's own context — every later `docker`
    # call in this script would otherwise fail with exactly that error.
    docker context use colima >/dev/null 2>&1 || true
    if [[ $build_status -ne 0 || ! -f "$root/truehdd/truehdd" ]]; then
        echo "dev-jellyfin: building the Linux truehdd failed" >&2
        exit 1
    fi
    chmod +x "$root/truehdd/truehdd"
}

# Poster (portrait), fanart (backdrop) and a transparent logo for one item,
# written into $1. Deliberately not photoreal — a flat color card with the
# title is enough to prove artwork round-trips (image URLs return real image
# data, tags differ between items) without needing real assets.
gen_art() {
    local dir="$1" title="$2" color="$3"
    mkdir -p "$dir"
    [[ -f "$dir/poster.jpg" ]] || magick -size 1000x1500 xc:"$color" -gravity center \
        -pointsize 80 -fill white -font "$font" -annotate 0 "$title" "$dir/poster.jpg"
    [[ -f "$dir/fanart.jpg" ]] || magick -size 1920x1080 xc:"$color" -gravity center \
        -pointsize 60 -fill '#ffffffaa' -font "$font" -annotate 0 "$title" "$dir/fanart.jpg"
    [[ -f "$dir/logo.png" ]] || magick -size 1600x400 xc:none -gravity center \
        -pointsize 100 -fill white -font "$font" -annotate 0 "$title" "$dir/logo.png"
}

# A short silent-pattern H.264/AAC clip at $1, $2 seconds long. $3 (optional)
# overrides the lavfi source pattern; used once below to render a WebM/VP9
# clip instead, which AVFoundation can't parse at all (wrong container, not
# just an exotic codec) — the one item that's guaranteed to force Hypnos's
# transcode fallback rather than direct play.
gen_clip() {
    local path="$1" duration="$2" webm="${3:-}"
    [[ -f "$path" ]] && return
    if [[ "$webm" == "webm" ]]; then
        ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=960x540:rate=24:duration=$duration" \
            -f lavfi -i "sine=frequency=300:duration=$duration" \
            -c:v libvpx-vp9 -pix_fmt yuv420p -c:a libopus "$path"
    else
        ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=$duration" \
            -f lavfi -i "sine=frequency=300:duration=$duration" \
            -c:v libx264 -pix_fmt yuv420p -c:a aac "$path"
    fi
}

# Kodi/Jellyfin-style local NFOs — enough fields for genres, rating, plot and
# runtime to show up without any internet metadata provider ever running
# (each library is created below with EnableInternetProviders:false, so NFO
# is the only metadata source in this whole instance).
write_movie_nfo() {
    local path="$1" title="$2" year="$3" genre="$4" plot="$5" rating="$6"
    cat > "$path" <<XML
<?xml version="1.0" encoding="utf-8"?>
<movie>
  <title>$title</title>
  <year>$year</year>
  <genre>$genre</genre>
  <plot>$plot</plot>
  <rating>$rating</rating>
  <mpaa>PG-13</mpaa>
</movie>
XML
}

write_tvshow_nfo() {
    local path="$1" title="$2" year="$3" genre="$4" plot="$5"
    cat > "$path" <<XML
<?xml version="1.0" encoding="utf-8"?>
<tvshow>
  <title>$title</title>
  <year>$year</year>
  <genre>$genre</genre>
  <plot>$plot</plot>
</tvshow>
XML
}

write_episode_nfo() {
    local path="$1" title="$2" season="$3" episode="$4" plot="$5"
    cat > "$path" <<XML
<?xml version="1.0" encoding="utf-8"?>
<episodedetails>
  <title>$title</title>
  <season>$season</season>
  <episode>$episode</episode>
  <plot>$plot</plot>
</episodedetails>
XML
}

# The 3 existing Atmos-plugin test items, plus a small synthetic movie and TV
# library spanning several genres and both watch-state paths (see
# seed_watch_state), so every Library home shelf has something in it:
# Continue Watching/Next Up need real progress, Recently Added needs several
# items, genres need Genre tags, and Collections needs a BoxSet.
seed_synthetic_library() {
    # Movies, Kodi-style folder-per-item so each gets its own NFO + art.
    local m
    m="$root/data/movies/Crimson Tide Station (2021)"
    mkdir -p "$m"
    gen_clip "$m/Crimson Tide Station (2021).mp4" 20
    write_movie_nfo "$m/Crimson Tide Station (2021).nfo" "Crimson Tide Station" 2021 "Action" \
        "A derelict orbital station drifts back into a crowded shipping lane." 7.2
    gen_art "$m" "CRIMSON TIDE STATION" "#7a1f2b"

    m="$root/data/movies/Paper Moon Diner (2019)"
    mkdir -p "$m"
    gen_clip "$m/Paper Moon Diner (2019).mp4" 18
    write_movie_nfo "$m/Paper Moon Diner (2019).nfo" "Paper Moon Diner" 2019 "Comedy" \
        "A roadside diner's night shift gets stranger with every customer." 6.8
    gen_art "$m" "PAPER MOON DINER" "#c07a1e"

    m="$root/data/movies/The Quiet Ledger (2022)"
    mkdir -p "$m"
    gen_clip "$m/The Quiet Ledger (2022).mp4" 22
    write_movie_nfo "$m/The Quiet Ledger (2022).nfo" "The Quiet Ledger" 2022 "Drama" \
        "An auditor uncovers a decades-old debt no one wants repaid." 7.6
    gen_art "$m" "THE QUIET LEDGER" "#2b3a55"

    # Deliberately WebM/VP9: AVFoundation cannot parse the container at all,
    # so this is the one library item guaranteed to route to the HLS
    # transcode fallback rather than direct play.
    m="$root/data/movies/Wide Static Field (2020)"
    mkdir -p "$m"
    gen_clip "$m/Wide Static Field (2020).webm" 16 webm
    write_movie_nfo "$m/Wide Static Field (2020).nfo" "Wide Static Field" 2020 "Sci-Fi" \
        "A signal from an abandoned relay repeats a message no one can place." 6.5
    gen_art "$m" "WIDE STATIC FIELD" "#264026"

    # One series, 2 seasons x 3 episodes, Kodi TV layout.
    local show="$root/data/tvshows/Nebula Drift"
    mkdir -p "$show"
    write_tvshow_nfo "$show/tvshow.nfo" "Nebula Drift" 2021 "Sci-Fi" \
        "A salvage crew chases a signal deeper into the drift than anyone has come back from."
    gen_art "$show" "NEBULA DRIFT" "#1f2b3a"
    local season ep title
    for season in 1 2; do
        local sdir="$show/Season 0$season"
        mkdir -p "$sdir"
        for ep in 1 2 3; do
            title="Nebula Drift S0${season}E0${ep}"
            gen_clip "$sdir/$title.mp4" 12
            write_episode_nfo "$sdir/$title.nfo" "Episode $ep" "$season" "$ep" \
                "The crew pushes further into the drift, season $season, part $ep."
        done
    done
}

seed_media() {
    mkdir -p "$root/data/movies"
    if [[ ! -f "$demo" ]]; then
        echo "dev-jellyfin: demo file not found at $demo (set HYPNOS_DEV_JELLYFIN_DEMO)" >&2
        exit 1
    fi

    # The demo is bind-mounted straight into the container by start_container
    # (as /media/DolbyElement4K_VisionAtmos.mkv) rather than symlinked from
    # here: a symlink under $root/data would point at a host path ($demo)
    # that's otherwise invisible inside the container's filesystem namespace,
    # since only $root/data itself is mounted. That per-file bind mount needs
    # an existing file at the target path to mount onto — /media itself is
    # :ro, and docker can't create a new mountpoint inside a read-only bind
    # mount (confirmed: "read-only file system" from runc) — so touch an
    # empty placeholder here first.
    touch "$root/data/movies/DolbyElement4K_VisionAtmos.mkv"

    # Video + EAC3 only (streams 0 and 2 of the demo): forces the plugin onto
    # the EAC3/Cavern path, since GetState prefers TrueHD when both are present.
    [[ -f "$root/data/movies/DolbyElement-EAC3Only.mkv" ]] || ffmpeg -loglevel error -y \
        -i "$demo" -map 0:0 -map 0:2 -c copy "$root/data/movies/DolbyElement-EAC3Only.mkv"

    # A plain non-Atmos item, for the "unsupported" path. Deliberately not
    # named anything ending in a Jellyfin/Kodi "extra" suffix (-clip, -sample,
    # -trailer, ...) — such a file is filed as an extra of some other item
    # instead of a standalone Movie and never shows up in a normal listing
    # (confirmed directly: "PlainClip-clip.mkv" scanned with zero errors and
    # simply never appeared anywhere in /Items).
    [[ -f "$root/data/movies/NoAtmosTest.mkv" ]] || ffmpeg -loglevel error -y \
        -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=20" \
        -f lavfi -i "sine=frequency=400:duration=20" \
        -c:v libx264 -pix_fmt yuv420p -c:a eac3 -ac 6 "$root/data/movies/NoAtmosTest.mkv"

    mkdir -p "$root/data/tvshows"
    seed_synthetic_library
}

install_plugin_config() {
    mkdir -p "$root/config/plugins/configurations"
    cat > "$root/config/plugins/configurations/Jellyfin.Plugin.AtmosObjects.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration>
  <TruehddPath>/truehdd/truehdd</TruehddPath>
  <CacheDirectory />
  <SegmentSeconds>10</SegmentSeconds>
  <EncoderParallelism>4</EncoderParallelism>
  <VideoCacheMegabytes>4096</VideoCacheMegabytes>
</PluginConfiguration>
XML
}

start_container() {
    mkdir -p "$root"/{config,cache}
    if docker container inspect "$name" >/dev/null 2>&1; then
        docker start "$name" >/dev/null
    else
        docker run -d --name "$name" --restart unless-stopped -p "127.0.0.1:$port:8096" \
            -v "$root/config:/config" -v "$root/cache:/cache" \
            -v "$root/data:/media:ro" \
            -v "$demo:/media/movies/DolbyElement4K_VisionAtmos.mkv:ro" \
            -v "$root/truehdd:/truehdd:ro" \
            "$image" >/dev/null
    fi
    wait_for_server
}

# Completes the first-run wizard, creates the dev user + a Movies library
# pointed at /media, and mints an API key — mirrors dev-stash.sh's `auth`,
# done unconditionally here since there's nothing to test un-authenticated.
setup_and_scan() {
    if [[ ! -f "$apikey_file" ]]; then
        api -X POST "$base/Startup/Configuration" -H 'Content-Type: application/json' \
            -d '{"ServerName":"hypnos-dev","UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null

        # Startup/User's own write has been seen not to have taken effect yet
        # by the time the very next call reads it back (Jellyfin is still
        # running its "Core startup complete"/background startup tasks right
        # when its HTTP routes start answering) — confirmed directly: the
        # POST returned 204 but a login with that exact password was denied
        # moments later. Re-post until a GET reads the name back, since
        # Startup/Complete makes the wizard endpoints stop being authoritative.
        local got_name=""
        for _ in $(seq 1 15); do
            api -X POST "$base/Startup/User" -H 'Content-Type: application/json' \
                -d "$(printf '{"Name":"%s","Password":"%s"}' "$devuser" "$devpass")" >/dev/null
            got_name=$(api "$base/Startup/User" | python3 -c 'import json,sys; print(json.loads(sys.stdin.buffer.read().decode("utf-8-sig")).get("Name",""))' 2>/dev/null || true)
            [[ "$got_name" == "$devuser" ]] && break
            sleep 1
        done

        api -X POST "$base/Startup/RemoteAccess" -H 'Content-Type: application/json' \
            -d '{"EnableRemoteAccess":false,"EnableAutomaticPortMapping":false}' >/dev/null
        api -X POST "$base/Startup/Complete" >/dev/null

        # Same story for authentication itself right after Complete — retry
        # rather than assume the first attempt lands.
        local resp token
        for _ in $(seq 1 15); do
            resp=$(api -X POST "$base/Users/AuthenticateByName" -H "$auth_hdr" -H 'Content-Type: application/json' \
                -d "$(printf '{"Username":"%s","Pw":"%s"}' "$devuser" "$devpass")")
            token=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.buffer.read().decode("utf-8-sig")).get("AccessToken",""))' <<<"$resp" 2>/dev/null || true)
            [[ -n "$token" ]] && break
            sleep 1
        done
        if [[ -z "$token" ]]; then
            echo "dev-jellyfin: could not authenticate as $devuser after the startup wizard" >&2
            exit 1
        fi

        # Scoped to /media/movies (not the whole /media tree), now that
        # /media/tvshows exists too — a Movies library rooted at /media would
        # otherwise try to interpret every episode as its own movie.
        # EnableInternetProviders:false on both libraries is what keeps this
        # instance fully offline and deterministic: with it off, local NFO is
        # the only metadata source Jellyfin ever consults for these items.
        api -X POST "$base/Library/VirtualFolders?name=Movies&collectionType=movies&refreshLibrary=true" \
            -H "X-Emby-Token: $token" -H 'Content-Type: application/json' \
            -d '{"LibraryOptions":{"PathInfos":[{"Path":"/media/movies"}],"EnablePhotos":false,"EnableRealtimeMonitor":false,"EnableInternetProviders":false}}' >/dev/null
        api -X POST "$base/Library/VirtualFolders?name=TV%20Shows&collectionType=tvshows&refreshLibrary=true" \
            -H "X-Emby-Token: $token" -H 'Content-Type: application/json' \
            -d '{"LibraryOptions":{"PathInfos":[{"Path":"/media/tvshows"}],"EnablePhotos":false,"EnableRealtimeMonitor":false,"EnableInternetProviders":false}}' >/dev/null

        api -X POST "$base/Auth/Keys?App=hypnos-dev" -H "X-Emby-Token: $token" >/dev/null
        local key
        key=$(api "$base/Auth/Keys" -H "X-Emby-Token: $token" | python3 -c 'import json,sys; print(json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))["Items"][0]["AccessToken"])')
        mkdir -p "$root/config"
        printf '%s' "$key" > "$apikey_file"
        chmod 600 "$apikey_file"
        echo "dev-jellyfin: username=$devuser password=$devpass"
        echo "dev-jellyfin: API key written to $apikey_file (not printed)"
    else
        local key
        key=$(cat "$apikey_file")
        api -X POST "$base/Library/Refresh" -H "X-Emby-Token: $key" >/dev/null
    fi

    local key
    key=$(cat "$apikey_file")
    for _ in $(seq 1 60); do
        local running
        running=$(api "$base/ScheduledTasks" -H "X-Emby-Token: $key" \
            | python3 -c 'import json,sys; print(any(t["State"]=="Running" for t in json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))))')
        [[ "$running" == "False" ]] && break
        sleep 3
    done

    # MinResumeDurationSeconds defaults to 300 (5 min) — Jellyfin won't create
    # a resume point or a partial PlayedPercentage for anything shorter, it
    # just marks a stopped item fully played instead. Every synthetic clip
    # here is far under that, so watch-state seeding (and Continue Watching/
    # Next Up generally) would silently do nothing without this. Confirmed
    # directly: with the default 300 in force, reporting a 35%-through stop
    # left PlaybackPositionTicks at 0 and Played=true; after lowering this to
    # 3s, the same call left a real PlayedPercentage/resume point.
    api "$base/System/Configuration" -H "X-Emby-Token: $key" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); d["MinResumeDurationSeconds"]=3; print(json.dumps(d))' \
        | api -X POST "$base/System/Configuration" -H "X-Emby-Token: $key" -H 'Content-Type: application/json' --data-binary @- >/dev/null

    seed_collection_and_watch_state "$key"
    echo "dev-jellyfin: http://127.0.0.1:$port"
}

# A BoxSet grouping two of the synthetic movies, and watch state for the dev
# user: one movie marked fully played, one movie and one episode left
# partway through. The partial-watch calls go through the exact same
# /Sessions/Playing* endpoints JellyfinLibrary's progress reporting uses
# (start → progress → stopped), so seeding this way doubles as a first proof
# that those calls work. Idempotent: safe to call on every `up`, not just the
# first-time setup.
find_item_id() {
    # $1: base URL, $2: API key, $3: IncludeItemTypes, $4: exact name to match
    api "$1/Items" -H "X-Emby-Token: $2" \
        --data-urlencode "IncludeItemTypes=$3" --data-urlencode "Recursive=true" \
        --data-urlencode "SearchTerm=$4" -G \
        | python3 -c "
import json,sys
items=json.loads(sys.stdin.buffer.read().decode('utf-8-sig')).get('Items', [])
for i in items:
    if i.get('Name') == sys.argv[1]:
        print(i['Id']); break
" "$4" 2>/dev/null
}

seed_collection_and_watch_state() {
    local key="$1"
    local userId
    userId=$(api "$base/Users" -H "X-Emby-Token: $key" \
        | python3 -c 'import json,sys; u=json.loads(sys.stdin.buffer.read().decode("utf-8-sig")); print(u[0]["Id"] if u else "")')
    [[ -z "$userId" ]] && { echo "dev-jellyfin: no user found, skipping watch-state seed" >&2; return; }

    local crimson quiet
    crimson=$(find_item_id "$base" "$key" Movie "Crimson Tide Station")
    quiet=$(find_item_id "$base" "$key" Movie "The Quiet Ledger")

    if [[ -n "$crimson" && -n "$quiet" ]]; then
        local existing
        existing=$(api "$base/Items" -H "X-Emby-Token: $key" \
            --data-urlencode "IncludeItemTypes=BoxSet" --data-urlencode "Recursive=true" -G \
            | python3 -c 'import json,sys; print(",".join(i["Name"] for i in json.loads(sys.stdin.buffer.read().decode("utf-8-sig")).get("Items", [])))')
        if [[ "$existing" != *"Station Saga"* ]]; then
            api -X POST "$base/Collections" -H "X-Emby-Token: $key" -G \
                --data-urlencode "Name=Station Saga" --data-urlencode "Ids=$crimson,$quiet" >/dev/null
        fi
    fi

    # Fully played: The Quiet Ledger.
    if [[ -n "$quiet" ]]; then
        api -X POST "$base/Users/$userId/PlayedItems/$quiet" -H "X-Emby-Token: $key" >/dev/null
    fi

    # Partially watched (~35%): Crimson Tide Station, via the real playback
    # session endpoints so Continue Watching has real data to show.
    if [[ -n "$crimson" ]]; then
        report_partial_progress "$key" "$userId" "$crimson" 0.35
    fi

    # Partially watched (~50%): season 1 episode 1 of Nebula Drift, so
    # Continue Watching *and* Next Up both have something once this resumes.
    local seriesId seasonId ep
    seriesId=$(find_item_id "$base" "$key" Series "Nebula Drift")
    if [[ -n "$seriesId" ]]; then
        seasonId=$(api "$base/Shows/$seriesId/Seasons" -H "X-Emby-Token: $key" --data-urlencode "userId=$userId" -G \
            | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(next((s["Id"] for s in d["Items"] if s.get("IndexNumber")==1), ""))')
        if [[ -n "$seasonId" ]]; then
            ep=$(api "$base/Shows/$seriesId/Episodes" -H "X-Emby-Token: $key" \
                --data-urlencode "userId=$userId" --data-urlencode "seasonId=$seasonId" -G \
                | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(next((e["Id"] for e in d["Items"] if e.get("IndexNumber")==1), ""))')
            [[ -n "$ep" ]] && report_partial_progress "$key" "$userId" "$ep" 0.5
        fi
    fi
}

# /Sessions/Playing* silently no-ops against a plain admin-issued API key —
# confirmed directly: PlayCount/PlaybackPositionTicks never moved when these
# calls were sent with the `X-Emby-Token: <api key>` header instead of a real
# signed-in session's access token. Jellyfin's session manager looks up an
# actual session object for the caller, and a bare API key doesn't have one
# the way `/Users/AuthenticateByName` does. So this authenticates as the dev
# user for its own session token, same as JellyfinAuth/JellyfinLibrary do —
# which also means an app configured with only an API key (no sign-in) will
# see the same silent no-op for progress reporting; that's a real, documented
# constraint of this feature, not just a seeding-script wrinkle.
session_token() {
    api -X POST "$base/Users/AuthenticateByName" -H "$auth_hdr" -H 'Content-Type: application/json' \
        -d "{\"Username\":\"$devuser\",\"Pw\":\"$devpass\"}" \
        | python3 -c 'import json,sys; print(json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))["AccessToken"])'
}

# Reports a play session at `$4` (0..1) of $3's runtime, exactly the
# start/progress/stopped sequence JellyfinLibrary.reportPlaybackStarted/
# Progress/Stopped issues, so this leaves the item with a real resume point
# and PlayedPercentage instead of one poked in directly.
report_partial_progress() {
    local key="$1" userId="$2" itemId="$3" fraction="$4"
    local runtimeTicks ticks sessionId token
    runtimeTicks=$(api "$base/Users/$userId/Items/$itemId" -H "X-Emby-Token: $key" \
        | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("RunTimeTicks") or 0)')
    [[ "$runtimeTicks" -le 0 ]] && return
    ticks=$(python3 -c "print(int($runtimeTicks * $fraction))")
    sessionId=$(python3 -c 'import uuid; print(uuid.uuid4())')
    token=$(session_token)
    api -X POST "$base/Sessions/Playing" -H "X-Emby-Token: $token" -H 'Content-Type: application/json' \
        -d "{\"ItemId\":\"$itemId\",\"PlaySessionId\":\"$sessionId\",\"PositionTicks\":0,\"IsPaused\":false,\"CanSeek\":true}" >/dev/null
    api -X POST "$base/Sessions/Playing/Progress" -H "X-Emby-Token: $token" -H 'Content-Type: application/json' \
        -d "{\"ItemId\":\"$itemId\",\"PlaySessionId\":\"$sessionId\",\"PositionTicks\":$ticks,\"IsPaused\":false,\"CanSeek\":true}" >/dev/null
    api -X POST "$base/Sessions/Playing/Stopped" -H "X-Emby-Token: $token" -H 'Content-Type: application/json' \
        -d "{\"ItemId\":\"$itemId\",\"PlaySessionId\":\"$sessionId\",\"PositionTicks\":$ticks}" >/dev/null
}

case "${1:-up}" in
    up)
        build_plugin
        build_truehdd_linux
        seed_media
        install_plugin_config
        start_container
        setup_and_scan
        ;;
    reset)
        docker rm -f "$name" >/dev/null 2>&1 || true
        rm -rf "${root:?}"/config "${root:?}"/cache
        build_plugin
        build_truehdd_linux
        seed_media
        install_plugin_config
        start_container
        setup_and_scan
        ;;
    down)
        docker stop "$name" >/dev/null
        ;;
    rm)
        docker rm -f "$name" >/dev/null 2>&1 || true
        rm -rf "${root:?}"
        ;;
    *)
        echo "usage: $0 up|reset|down|rm" >&2
        exit 2
        ;;
esac
