#!/usr/bin/env bash
# A disposable SponsorBlock server (the reference implementation, ajayyy/SponsorBlockServer),
# so Hypnos's SponsorBlock lookups, votes and submissions are tested without
# ever writing to the real sponsor.ajay.app. Never submit or vote against the
# real server from a test, a simulator or an agent; use this.
#
#   scripts/dev-sponsorblock.sh up      clone (first run), install, start it
#   scripts/dev-sponsorblock.sh reset   wipe its database
#   scripts/dev-sponsorblock.sh down    stop it
#   scripts/dev-sponsorblock.sh rm      stop it and delete everything it stored
#   scripts/dev-sponsorblock.sh logs
#
# Serves http://127.0.0.1:9996 (loopback only; the simulators share it). In the
# app: Settings > YouTube > SponsorBlock > Server, or launch with
# `-UITestDefault youtube.sponsorblock.server=http://127.0.0.1:9996`.
# SQLite, no Redis/Postgres, `mode: test` (skips the server's calls to YouTube
# for video details, which would otherwise reject our made-up video ids).
# Needs docker (colima) and git.
set -euo pipefail

name=hypnos-dev-sponsorblock
port=9996
root="${HYPNOS_DEV_SPONSORBLOCK_DIR:-$HOME/.local/share/hypnos-dev-sponsorblock}"
ref="${HYPNOS_DEV_SPONSORBLOCK_REF:-master}"

write_config() {
    cat > "$root/server/config.json" <<EOF
{
    "port": 8080,
    "globalSalt": "dev-salt",
    "adminUserID": "0000000000000000000000000000000000000000000000000000000000000000",
    "newLeafURLs": ["placeholder"],
    "behindProxy": false,
    "db": "./databases/sponsorTimes.db",
    "privateDB": "./databases/private.db",
    "createDatabaseIfNotExist": true,
    "schemaFolder": "./databases",
    "dbSchema": "./databases/_sponsorTimes.db.sql",
    "privateDBSchema": "./databases/_private.db.sql",
    "categoryList": ["sponsor", "selfpromo", "exclusive_access", "interaction", "intro", "outro", "preview", "music_offtopic", "filler", "poi_highlight", "chapter"],
    "mode": "test",
    "readOnly": false,
    "webhooks": [],
    "rateLimit": {
        "vote": { "windowMs": 900000, "max": 20, "message": "Too many votes, please try again later", "statusCode": 429 },
        "view": { "windowMs": 900000, "max": 20, "statusCode": 200 }
    },
    "minReputationToSubmitFiller": -1,
    "minUserIDLength": 30
}
EOF
}

up() {
    mkdir -p "$root"
    if [[ ! -d "$root/server/.git" ]]; then
        git clone --depth 1 --branch "$ref" https://github.com/ajayyy/SponsorBlockServer "$root/server"
    fi
    write_config
    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        docker start "$name" >/dev/null
    else
        # mode "test" makes the server skip its YouTube lookups; the install
        # lives in the mounted checkout, so only the first run is slow.
        docker run -d --name "$name" -p "127.0.0.1:$port:8080" \
            -v "$root/server:/app" -w /app node:22-alpine \
            sh -c 'apk add --no-cache python3 make g++ git >/dev/null && npm ci --silent && npx ts-node src/index.ts' >/dev/null
    fi
    for _ in $(seq 1 120); do
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/status")" == 200 ]]; then
            echo "SponsorBlock dev server: http://127.0.0.1:$port"
            return
        fi
        sleep 3
    done
    echo "dev-sponsorblock: not up after 6 minutes; see '$0 logs'" >&2
    exit 1
}

case "${1:-}" in
    up) up ;;
    reset) docker rm -f "$name" >/dev/null 2>&1 || true; rm -f -- "$root/server/databases/sponsorTimes.db" "$root/server/databases/private.db"; up ;;
    down) docker stop "$name" >/dev/null ;;
    rm) docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf -- "$root" ;;
    logs) docker logs --tail 80 "$name" ;;
    *) sed -n '2,19p' "$0"; exit 2 ;;
esac
