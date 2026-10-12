#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tree="$ROOT/android/lineage-24.0"

if [[ ! -d "$tree/.repo" ]]; then
  printf 'state=not-initialized\n'
  exit 1
fi

cache_file="$ROOT/logs/android-sync-status.cache"
refresh_size=0
if [[ "${1:-}" == "--refresh-size" ]]; then
  refresh_size=1
elif [[ $# -gt 0 ]]; then
  printf 'usage: %s [--refresh-size]\n' "$0" >&2
  exit 2
fi

if (( refresh_size )); then
  downloaded_bytes="$(du -sb "$tree/.repo" | awk '{print $1}')"
  if [[ -d "$tree/.repo/projects" ]]; then
    project_count="$(find "$tree/.repo/projects" -type d -name '*.git' | wc -l)"
  else
    project_count=0
  fi
  mkdir -p "$ROOT/logs"
  printf '%s %s\n' "$downloaded_bytes" "$project_count" >"$cache_file"
elif [[ -s "$cache_file" ]]; then
  read -r downloaded_bytes project_count <"$cache_file"
else
  downloaded_bytes=0
  project_count=0
fi

syncing=0
paused=0
while read -r pid; do
  [[ -n "$pid" ]] || continue
  cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
  if [[ "$cwd" == "$tree" ]]; then
    syncing=1
    state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [[ "$state" == *T* ]] && paused=1
    break
  fi
done < <(pgrep -f 'main\.py .* -- sync|repo sync' || true)

if (( paused )); then
  printf 'state=paused\n'
elif (( syncing )); then
  printf 'state=syncing\n'
else
  printf 'state=not-running\n'
fi

if (( downloaded_bytes > 0 )); then
  awk -v bytes="$downloaded_bytes" \
    'BEGIN { printf "downloaded=%.1fGiB\n", bytes / 1073741824 }'
  if (( ! refresh_size )); then
    printf 'size-source=cached (use --refresh-size for a slow exact scan)\n'
  fi
else
  printf 'downloaded=unknown (use --refresh-size for a slow exact scan)\n'
fi

if [[ -x "$tree/build/soong/soong_ui.bash" && \
      -d "$tree/device/apple/snowcastle" && \
      -d "$tree/device/mainline/generic" ]]; then
  printf 'checkout=core-present\n'
else
  printf 'checkout=incomplete\n'
fi

printf 'project-checkouts=%s\n' "$project_count"
