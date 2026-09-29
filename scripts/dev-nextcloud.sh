#!/usr/bin/env bash
# A disposable Nextcloud with synthetic photos, for testing Hypnos's Nextcloud
# source without touching a real server. Never point tests, simulators or
# agents at a personal Nextcloud; use this.
#
#   scripts/dev-nextcloud.sh up        create (first run) or start it, seeded
#   scripts/dev-nextcloud.sh backfill  run the server's metadata job (and its per-file jobs) over the scanned photos
#   scripts/dev-nextcloud.sh down      stop it
#   scripts/dev-nextcloud.sh rm        stop it and delete everything it stored
#
# Serves http://127.0.0.1:9997 (loopback only), user admin / password
# dev-nextcloud-1. Two folders, because they differ in what the server knows
# about each photo — the difference the app's original-aspect grid has to cope
# with:
#   uploaded/  put over WebDAV, so Nextcloud's Photos app recorded pixel
#              dimensions (nc:metadata-photos-size) immediately
#   scanned/   copied into the data directory and `occ files:scan`ned, the way
#              a bulk-imported library arrives: no dimensions until `backfill`
# The images are drawn by PHP's gd inside the container, so this only needs
# docker (colima). Verified against Nextcloud 35 with Photos 8.
set -euo pipefail

name=hypnos-dev-nextcloud
port=9997
user=admin
pass=dev-nextcloud-1
base="http://127.0.0.1:$port"
occ() { docker exec -u www-data "$name" php occ "$@"; }

wait_ready() {
    for _ in $(seq 1 90); do
        [[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/status.php")" == 200 ]] && return
        sleep 3
    done
    echo "dev-nextcloud: server not ready after 4.5 minutes" >&2
    return 1
}

seed() {
    # width x height for each generated image; a mix of shapes on purpose.
    docker exec "$name" php -r '
        $shapes = [[1200,800],[800,1200],[1600,900],[1000,1000],[2000,700],[700,1100],[1400,1050],[900,1600]];
        foreach (["up", "scan"] as $set) {
            foreach ($shapes as $i => [$w, $h]) {
                $im = imagecreatetruecolor($w, $h);
                imagefill($im, 0, 0, imagecolorallocate($im, ($i * 37 + ($set == "up" ? 20 : 120)) % 255, 60 + $i * 18, 150));
                imagestring($im, 5, 20, 20, "$set $i {$w}x{$h}", imagecolorallocate($im, 255, 255, 255));
                imagejpeg($im, "/tmp/$set-$i.jpg", 85);
            }
        }'
    for i in $(seq 0 7); do
        docker exec "$name" curl -s -o /dev/null -u "$user:$pass" -X MKCOL "$base/remote.php/dav/files/$user/uploaded" 2>/dev/null || true
        docker exec "$name" curl -s -o /dev/null -u "$user:$pass" -T "/tmp/up-$i.jpg" "http://localhost/remote.php/dav/files/$user/uploaded/upload-$i.jpg"
    done
    docker exec "$name" bash -c "mkdir -p /var/www/html/data/$user/files/scanned && cp /tmp/scan-*.jpg /var/www/html/data/$user/files/scanned/ && chown -R www-data:www-data /var/www/html/data/$user/files/scanned"
    occ files:scan "$user" >/dev/null
}

case "${1:-}" in
    up)
        if docker inspect "$name" >/dev/null 2>&1; then
            docker start "$name" >/dev/null
            wait_ready
        else
            docker run -d --name "$name" -p "127.0.0.1:$port:80" \
                -e NEXTCLOUD_ADMIN_USER="$user" -e NEXTCLOUD_ADMIN_PASSWORD="$pass" \
                -e SQLITE_DATABASE=nc nextcloud:apache >/dev/null
            wait_ready
            docker exec "$name" curl -s -o /dev/null -u "$user:$pass" -X MKCOL "http://localhost/remote.php/dav/files/$user/uploaded" || true
            seed
        fi
        echo "dev-nextcloud: $base  ($user / $pass)"
        ;;
    backfill)
        # Captured first: `awk ... exit` on a live pipe would SIGPIPE occ, and
        # pipefail would then end the script silently.
        jobs=$(occ background-job:list)
        id=$(awk -F'|' '/GenerateMetadataJob/ { gsub(/ /, "", $2); print $2; exit }' <<<"$jobs")
        [[ -n "$id" ]] || { echo "dev-nextcloud: GenerateMetadataJob not found" >&2; exit 1; }
        # The job only queues one UpdateSingleMetadata job per file; a worker
        # (cron, in a real install) is what actually reads the dimensions.
        occ background-job:execute --force-execute "$id" >/dev/null
        occ background-job:worker 'OC\FilesMetadata\Job\UpdateSingleMetadata' \
            --stop_after=20s --interval=0 --silent >/dev/null || true
        echo "dev-nextcloud: metadata job ran"
        ;;
    down) docker stop "$name" >/dev/null ;;
    rm) docker rm -f "$name" >/dev/null 2>&1 || true ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
