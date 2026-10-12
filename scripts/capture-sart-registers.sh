#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

need_cmd ip
need_cmd nc
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
output="$LOGS_DIR/sart-registers.txt"

{
  printf '%s\n' \
    'base=$((0x27ac50000))' \
    'i=0' \
    'echo RA1NCASTLE_SART_BEGIN' \
    'while [ "$i" -lt 16 ]; do' \
    '  ca=$((base + i * 4))' \
    '  pa=$((base + 0x40 + i * 4))' \
    '  cfg=$(/bin/busybox dd if=/dev/mem bs=4 skip=$((ca / 4)) count=1 2>/dev/null | /bin/busybox od -An -tx4 | /bin/busybox tr -d " \\n")' \
    '  paddr=$(/bin/busybox dd if=/dev/mem bs=4 skip=$((pa / 4)) count=1 2>/dev/null | /bin/busybox od -An -tx4 | /bin/busybox tr -d " \\n")' \
    '  echo "entry=$i cfg=0x${cfg:-READ_FAILED} paddr_page=0x${paddr:-READ_FAILED}"' \
    '  i=$((i + 1))' \
    'done' \
    'echo RA1NCASTLE_SART_END' \
    'exit'
  sleep 1
} | timeout 20 nc 172.16.42.1 2323 | tee "$output"

grep -q '^RA1NCASTLE_SART_BEGIN' "$output" || die "SART register capture did not start"
grep -q '^RA1NCASTLE_SART_END' "$output" || die "SART register capture was incomplete"
