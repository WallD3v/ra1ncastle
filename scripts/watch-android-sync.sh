#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$ROOT/scripts/android-sync-status.sh"
RESUME="$ROOT/scripts/resume-android-sync-fast.sh"
INTERVAL="${ANDROID_SYNC_CHECK_INTERVAL_SECONDS:-1800}"
LOG="$ROOT/logs/android-sync-watch.log"

mkdir -p "$ROOT/logs"

while :; do
  state="$("$STATUS" 2>/dev/null | sed -n 's/^state=//p' | head -n 1 || true)"
  if [[ "$state" != syncing ]]; then
    printf '[%s] Sync state is %s; starting resume worker.\n' \
      "$(date --iso-8601=seconds)" "${state:-unknown}" >>"$LOG"
    PATH="$ROOT/build/host-tools/android-bin:$ROOT/build/host-tools/git-lfs:$PATH" \
      ANDROID_SYNC_NETWORK_JOBS="${ANDROID_SYNC_NETWORK_JOBS:-12}" \
      ANDROID_SYNC_CHECKOUT_JOBS="${ANDROID_SYNC_CHECKOUT_JOBS:-4}" \
      "$RESUME" >>"$LOG" 2>&1 &
  else
    printf '[%s] Lineage repo sync is active.\n' \
      "$(date --iso-8601=seconds)" >>"$LOG"
  fi
  sleep "$INTERVAL"
done
