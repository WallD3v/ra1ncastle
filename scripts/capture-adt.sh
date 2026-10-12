#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

need_cmd base64
need_cmd ip
need_cmd nc
need_cmd python3
need_cmd timeout
need_cmd udevadm

find_ncm_interface() {
  local path properties
  for path in /sys/class/net/*; do
    properties="$(udevadm info --query=property --path="$path" 2>/dev/null || true)"
    if grep -qx 'ID_VENDOR_ID=1d6b' <<<"$properties" &&
       grep -qx 'ID_MODEL_ID=1040' <<<"$properties"; then
      basename "$path"
      return 0
    fi
  done
  return 1
}

iface=''
for ((attempt = 0; attempt < 30; attempt++)); do
  if iface="$(find_ncm_interface)"; then
    break
  fi
  sleep 1
done
[[ -n "$iface" ]] || die "ra1ncastle NCM interface not found after 30 seconds"

sudo ip link set "$iface" up
sudo ip addr replace 172.16.42.2/24 dev "$iface"
sudo ip route replace 172.16.42.0/24 dev "$iface" src 172.16.42.2

mkdir -p "$LOGS_DIR"
transcript="$LOGS_DIR/adt-transcript.txt"
encoded="$LOGS_DIR/adt.base64"
binary="$LOGS_DIR/adt.bin"
report="$LOGS_DIR/adt-storage-nodes.txt"

{
  printf '%s\n' \
    'found=0' \
    'for p in /sys/class/mtd/mtd*; do' \
    '  [ -r "$p/name" ] || continue' \
    '  [ "$(cat "$p/name")" = "adt" ] || continue' \
    '  dev=/dev/$(basename "$p")' \
    '  echo RA1NCASTLE_ADT_BEGIN' \
    '  /bin/busybox base64 "$dev"' \
    '  echo RA1NCASTLE_ADT_END' \
    '  found=1' \
    'done' \
    '[ "$found" = 1 ] || { echo RA1NCASTLE_ADT_MISSING; cat /proc/mtd 2>&1; }' \
    'exit'
  sleep 1
} | timeout 30 nc 172.16.42.1 2323 >"$transcript"

grep -q '^RA1NCASTLE_ADT_BEGIN' "$transcript" || {
  tr -d '\000' <"$transcript"
  die "ADT RAM MTD was not published"
}
grep -q '^RA1NCASTLE_ADT_END' "$transcript" || die "ADT transfer was incomplete"

awk '
  /^RA1NCASTLE_ADT_BEGIN/ { capture=1; next }
  /^RA1NCASTLE_ADT_END/ { capture=0 }
  capture { gsub(/\r/, ""); print }
' "$transcript" >"$encoded"
base64 --decode "$encoded" >"$binary"

python3 "$ROOT/scripts/inspect-adt-storage.py" "$binary" | tee "$report"
sha256sum "$binary" | tee "$LOGS_DIR/adt-sha256.txt"
printf 'Full storage-node report: %s\n' "$report"
