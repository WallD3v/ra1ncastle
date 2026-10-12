#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

need_cmd ip
need_cmd nc
need_cmd timeout
need_cmd udevadm

duration="${1:-120}"
[[ "$duration" =~ ^[0-9]+$ ]] && ((duration >= 10)) || \
  die "usage: $0 [capture-seconds>=10]"

is_ra1ncastle_device() {
  local properties="$1"
  grep -qx 'ID_VENDOR_ID=1d6b' <<<"$properties" &&
    grep -qx 'ID_MODEL_ID=1040' <<<"$properties"
}

find_ncm_interface() {
  local path properties
  for path in /sys/class/net/*; do
    properties="$(udevadm info --query=property --path="$path" 2>/dev/null || true)"
    if is_ra1ncastle_device "$properties"; then
      basename "$path"
      return 0
    fi
  done
  return 1
}

iface=''
for ((attempt = 0; attempt < 60; attempt++)); do
  if iface="$(find_ncm_interface)"; then
    break
  fi
  sleep 1
done
[[ -n "$iface" ]] || die 'ra1ncastle NCM interface not found after 60 seconds'

printf 'Configuring iPhone NCM interface %s.\n' "$iface"
sudo ip link set "$iface" up
sudo ip addr replace 172.16.42.2/24 dev "$iface"
sudo ip route replace 172.16.42.0/24 dev "$iface" src 172.16.42.2

stamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS_DIR"
klog="$LOGS_DIR/kernel-live-$stamp.txt"
shell_log="$LOGS_DIR/nvme-insmod-$stamp.txt"

printf 'Capturing kernel log for %s seconds in %s\n' "$duration" "$klog"
set +e
timeout -k 2 "$duration" nc 172.16.42.1 2324 | tee "$klog" &
klog_pid=$!
set -e

# Let dmesg -w attach before entering the driver probe.
sleep 2
{
  printf '%s\n' \
    'echo RA1NCASTLE_NVME_INSMOD_BEGIN >/dev/kmsg' \
    '/bin/busybox insmod /lib/modules/nvme-core.ko' \
    'core_rc=$?' \
    'echo "RA1NCASTLE_NVME_CORE_INSMOD rc=$core_rc" >/dev/kmsg' \
    '/bin/busybox insmod /lib/modules/nvme-apple.ko &' \
    'nvme_pid=$!' \
    'echo "RA1NCASTLE_NVME_INSMOD_PID=$nvme_pid" >/dev/kmsg' \
    'echo "nvme insmod pid=$nvme_pid"' \
	'echo "=== IRQ BEFORE ==="' \
	'cat /proc/interrupts' \
    'sleep 5' \
    'echo "RA1NCASTLE_NVME_STACK_5S_BEGIN pid=$nvme_pid" >/dev/kmsg' \
    'cat /proc/$nvme_pid/stack 2>&1' \
    'cat /proc/$nvme_pid/wchan 2>&1' \
	'echo "=== IRQ AFTER 5S ==="' \
	'cat /proc/interrupts' \
    'echo "RA1NCASTLE_NVME_STACK_5S_END pid=$nvme_pid" >/dev/kmsg' \
    'sleep 15' \
    'echo "RA1NCASTLE_NVME_STACK_20S_BEGIN pid=$nvme_pid" >/dev/kmsg' \
    'cat /proc/$nvme_pid/stack 2>&1' \
    'cat /proc/$nvme_pid/wchan 2>&1' \
	'echo "=== IRQ AFTER 20S ==="' \
	'cat /proc/interrupts' \
    'echo "RA1NCASTLE_NVME_STACK_20S_END pid=$nvme_pid" >/dev/kmsg' \
    'wait $nvme_pid' \
    'rc=$?' \
    'echo "RA1NCASTLE_NVME_INSMOD_END rc=$rc" >/dev/kmsg' \
    'echo "insmod rc=$rc"'
  sleep "$duration"
} | timeout -k 2 "$((duration + 5))" nc 172.16.42.1 2323 >"$shell_log" 2>&1 &
shell_pid=$!

set +e
wait "$klog_pid"
klog_status=$?
kill "$shell_pid" 2>/dev/null
wait "$shell_pid" 2>/dev/null
set -e

printf 'Kernel log: %s\nShell/insmod log: %s\n' "$klog" "$shell_log"
if [[ ! -s "$klog" ]]; then
  die 'kernel log stream was empty'
fi
case "$klog_status" in
  0|124) ;;
  *) die "kernel log connection failed with status $klog_status" ;;
esac
