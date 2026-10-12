#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

need_cmd base64
need_cmd ip
need_cmd nc
need_cmd strings
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
transcript="$LOGS_DIR/m1n1-stage2-log-transcript.txt"
encoded="$LOGS_DIR/m1n1-stage2-log.base64"
binary="$LOGS_DIR/m1n1-stage2-log.bin"
text_log="$LOGS_DIR/m1n1-stage2-log.txt"

{
  printf '%s\n' \
    'found=0' \
    'for p in /sys/class/mtd/mtd*; do' \
    '  [ -r "$p/name" ] || continue' \
    '  [ "$(cat "$p/name")" = "m1n1_stage2.log" ] || continue' \
    '  dev=/dev/$(basename "$p")' \
    '  echo RA1NCASTLE_M1N1_LOG_BEGIN' \
    '  /bin/busybox base64 "$dev"' \
    '  echo RA1NCASTLE_M1N1_LOG_END' \
    '  found=1' \
    'done' \
    '[ "$found" = 1 ] || { echo RA1NCASTLE_M1N1_LOG_MISSING; cat /proc/mtd 2>&1; }' \
    'exit'
  sleep 1
} | timeout 20 nc 172.16.42.1 2323 >"$transcript"

if ! grep -q '^RA1NCASTLE_M1N1_LOG_BEGIN' "$transcript"; then
  tr -d '\000' <"$transcript"
  die "m1n1 RAM log was not published"
fi
grep -q '^RA1NCASTLE_M1N1_LOG_END' "$transcript" || die "m1n1 RAM log transfer incomplete"

awk '
  /^RA1NCASTLE_M1N1_LOG_BEGIN/ { capture=1; next }
  /^RA1NCASTLE_M1N1_LOG_END/ { capture=0 }
  capture { gsub(/\r/, ""); print }
' "$transcript" >"$encoded"
base64 --decode "$encoded" >"$binary"
strings -a -n 4 "$binary" >"$text_log"

printf 'Captured m1n1 RAM log: %s bytes\n' "$(stat -c %s "$binary")"
grep -E -i 'nvme|ans|rtkit|sart|syslog|crash|error|fail|bad.cmd|prp' "$text_log" || true
printf 'Full extracted log: %s\n' "$text_log"
