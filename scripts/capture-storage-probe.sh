#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_internal_storage_ack

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
route="$(ip route get 172.16.42.1)"
grep -q "dev $iface" <<<"$route" || die "iPhone route does not use $iface"

mkdir -p "$LOGS_DIR"
transcript="$LOGS_DIR/storage-probe-transcript.txt"
encoded="$LOGS_DIR/nvme-lba0-lba5.base64"
binary="$LOGS_DIR/nvme-lba0-lba5.bin"

{
  printf '%s\n' \
    'probe=/proc/device-tree/chosen/ra1ncastle,nvme-lba0-lba5' \
    'status=/proc/device-tree/chosen/ra1ncastle,nvme-probe-status' \
    'error=/proc/device-tree/chosen/ra1ncastle,nvme-probe-error' \
    'if [ -r "$status" ]; then echo -n RA1NCASTLE_PROBE_STATUS=; cat "$status"; echo; fi' \
    'if [ -r "$error" ]; then echo -n RA1NCASTLE_PROBE_ERROR=; cat "$error"; echo; fi' \
    'if [ -r "$probe" ]; then' \
    '  echo RA1NCASTLE_PROBE_BEGIN' \
    '  /bin/busybox base64 "$probe"' \
    '  echo RA1NCASTLE_PROBE_END' \
    'else' \
    '  echo RA1NCASTLE_PROBE_MISSING' \
    'fi' \
    'exit'
  sleep 1
} | timeout 20 nc 172.16.42.1 2323 >"$transcript"

if ! grep -q '^RA1NCASTLE_PROBE_BEGIN' "$transcript"; then
  tr -d '\000' <"$transcript"
  die "storage probe was not published; the stage above identifies the m1n1 failure"
fi
grep -q '^RA1NCASTLE_PROBE_END' "$transcript" || \
  die "storage probe transfer was incomplete"

awk '
  /^RA1NCASTLE_PROBE_BEGIN/ { capture=1; next }
  /^RA1NCASTLE_PROBE_END/ { capture=0 }
  capture { gsub(/\r/, ""); print }
' "$transcript" >"$encoded"
base64 --decode "$encoded" >"$binary"

"$ROOT/scripts/parse-gpt-probe.py" "$binary" | \
  tee "$LOGS_DIR/storage-probe-gpt.txt"
sha256sum "$binary" | tee "$LOGS_DIR/storage-probe-sha256.txt"
