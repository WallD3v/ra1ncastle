#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tree_dir="$root_dir/android/lineage-24.0"
log_file="$root_dir/logs/android-repo-sync.log"
lock_file="$root_dir/logs/android-repo-sync.lock"

mkdir -p "$root_dir/logs"
cd "$tree_dir"

exec 9>"$lock_file"
if ! flock -n 9; then
    echo "Another managed Android sync is already running." >&2
    exit 1
fi

printf '\n[%s] Resuming Lineage sync: direct network, HTTP/1.1, network=6, checkout=4\n' \
    "$(date --iso-8601=seconds)" >>"$log_file"

set +e
env \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
    GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=http.version \
    GIT_CONFIG_VALUE_0=HTTP/1.1 \
    GIT_CONFIG_KEY_1=http.lowSpeedLimit \
    GIT_CONFIG_VALUE_1=1024 \
    GIT_CONFIG_KEY_2=http.lowSpeedTime \
    GIT_CONFIG_VALUE_2=120 \
    repo sync \
        -c \
        --force-sync \
        --no-clone-bundle \
        --no-tags \
        --optimized-fetch \
        --retry-fetches=8 \
        --jobs-network=6 \
        --jobs-checkout=4 \
        "$@" >>"$log_file" 2>&1

status=$?
set -e
printf '[%s] Lineage sync exited with status %d\n' \
    "$(date --iso-8601=seconds)" "$status" >>"$log_file"
exit "$status"
