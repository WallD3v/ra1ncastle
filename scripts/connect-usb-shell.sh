#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

need_cmd udevadm

is_ra1ncastle_device() {
  local properties="$1"
  grep -qx 'ID_VENDOR_ID=1d6b' <<<"$properties" || return 1
  grep -Eq '^ID_MODEL_ID=104(0|1)$' <<<"$properties"
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

find_acm_device() {
  local tty properties
  for tty in /dev/ttyACM*; do
    [[ -c "$tty" ]] || continue
    properties="$(udevadm info --query=property --name="$tty" 2>/dev/null || true)"
    if is_ra1ncastle_device "$properties"; then
      printf '%s\n' "$tty"
      return 0
    fi
  done
  return 1
}

udevadm settle

case "${1:---ncm}" in
  --ncm)
    need_cmd ip
    iface=''
    for ((attempt = 0; attempt < 30; attempt++)); do
      if iface="$(find_ncm_interface)"; then
        break
      fi
      sleep 1
    done
    [[ -n "$iface" ]] || \
      die "ra1ncastle NCM interface (USB 1d6b:1040 or 1d6b:1041) not found after 30 seconds"

    printf 'Configuring iPhone NCM interface %s.\n' "$iface"
    sudo ip link set "$iface" up
    sudo ip addr replace 172.16.42.2/24 dev "$iface"
    sudo ip route replace 172.16.42.0/24 dev "$iface" src 172.16.42.2
    # A host route beats VPNs that later install their own 172.16.42.0/24
    # route, keeping the iPhone shell from being redirected into a tunnel. A
    # dedicated policy table survives VPN clients that rewrite main-table
    # routes after this script starts.
    sudo ip route replace 172.16.42.1/32 dev "$iface" src 172.16.42.2
    sudo ip route replace 172.16.42.1/32 dev "$iface" src 172.16.42.2 table 1041
    sudo ip rule del pref 1041 to 172.16.42.1/32 lookup 1041 2>/dev/null || true
    sudo ip rule add pref 1041 to 172.16.42.1/32 lookup 1041

    route="$(ip route get 172.16.42.1)"
    printf 'Route: %s\n' "$route"
    grep -q "dev $iface" <<<"$route" || \
      die "172.16.42.1 is not routed through $iface"

    if command -v nc >/dev/null 2>&1; then
      printf 'Opening raw shell at 172.16.42.1:2323 (there may be no prompt).\n'
      exec nc -v 172.16.42.1 2323
    elif command -v socat >/dev/null 2>&1; then
      printf 'Opening raw shell at 172.16.42.1:2323 with socat.\n'
      exec socat -,rawer,echo=0 TCP:172.16.42.1:2323
    elif command -v python3 >/dev/null 2>&1; then
      printf 'Opening raw shell at 172.16.42.1:2323 with Python fallback.\n'
      exec python3 -c '
import socket, sys, threading

sock = socket.create_connection(("172.16.42.1", 2323))

def receive():
    try:
        while data := sock.recv(4096):
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
    finally:
        sock.close()

threading.Thread(target=receive, daemon=True).start()
try:
    while data := sys.stdin.buffer.read1(4096):
        sock.sendall(data)
except (BrokenPipeError, KeyboardInterrupt):
    pass
'
    else
      die "install netcat-openbsd, socat, or Python 3"
    fi
    ;;
  --acm)
    need_cmd picocom
    tty=''
    for ((attempt = 0; attempt < 30; attempt++)); do
      if tty="$(find_acm_device)"; then
        break
      fi
      sleep 1
    done
    [[ -n "$tty" ]] || \
      die "ra1ncastle ACM device (USB 1d6b:1040 or 1d6b:1041) not found after 30 seconds"
    printf 'Opening %s. Exit picocom with Ctrl-A Ctrl-X.\n' "$tty"
    exec picocom --baud 115200 "$tty"
    ;;
  *)
    die "usage: $0 [--ncm|--acm]"
    ;;
esac
