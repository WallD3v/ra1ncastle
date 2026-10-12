#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_internal_storage_ack

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
for ((attempt = 0; attempt < 45; attempt++)); do
  if iface="$(find_ncm_interface)"; then
    break
  fi
  sleep 1
done
[[ -n "$iface" ]] || die "ra1ncastle NCM interface not found after 45 seconds"

sudo ip link set "$iface" up
sudo ip addr replace 172.16.42.2/24 dev "$iface"
sudo ip route replace 172.16.42.0/24 dev "$iface" src 172.16.42.2

mkdir -p "$LOGS_DIR"
transcript="$LOGS_DIR/kernel-storage-transcript.txt"

{
  printf '%s\n' \
    'echo RA1NCASTLE_KERNEL_STORAGE_BEGIN' \
    'uname -a' \
    'echo === CMDLINE ===' \
    'cat /proc/cmdline' \
    'echo === NVME_DMESG ===' \
    'dmesg | grep -Ei "nvme|sart|rtkit|ANS|apcie|I/O error|timeout"' \
    'echo === PARTITIONS ===' \
    'cat /proc/partitions' \
    'echo === BLOCK ===' \
    'for d in /sys/block/*; do echo "$d ro=$(cat "$d/ro" 2>/dev/null) size=$(cat "$d/size" 2>/dev/null)"; done' \
    'echo === NVME_NODES ===' \
    'ls -l /dev/nvme* 2>&1' \
    'echo RA1NCASTLE_KERNEL_STORAGE_END' \
    'exit'
  sleep 2
} | timeout 30 nc 172.16.42.1 2323 >"$transcript"

tr -d '\000\r' <"$transcript" | tee "$LOGS_DIR/kernel-storage-report.txt"
grep -q '^RA1NCASTLE_KERNEL_STORAGE_END$' "$LOGS_DIR/kernel-storage-report.txt" ||
  die "kernel storage report was incomplete"
