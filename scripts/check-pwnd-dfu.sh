#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

need_cmd lsusb
need_cmd irecovery
need_cmd rg

mkdir -p "$LOGS_DIR/preflight"

lsusb >"$LOGS_DIR/preflight/lsusb.txt"
lsusb -v -d 05ac:1227 >"$LOGS_DIR/preflight/lsusb-05ac-1227.txt" 2>&1 \
  || die "Apple DFU device 05ac:1227 not found"
irecovery -q >"$LOGS_DIR/preflight/irecovery-q.txt" 2>&1 \
  || die "irecovery could not query the device"

rg -q 'PWND:\[usbliter8\]' "$LOGS_DIR/preflight/lsusb-05ac-1227.txt" \
  || die "DFU serial does not contain PWND:[usbliter8]"
rg -qi '^CPID:[[:space:]]*(0x)?8030' "$LOGS_DIR/preflight/irecovery-q.txt" \
  || die "unexpected CPID; expected T8030/0x8030"
rg -qi '^MODEL:[[:space:]]*n104ap' "$LOGS_DIR/preflight/irecovery-q.txt" \
  || die "unexpected MODEL; expected n104ap"
rg -qi '^PRODUCT:[[:space:]]*iPhone12,1' "$LOGS_DIR/preflight/irecovery-q.txt" \
  || die "unexpected PRODUCT; expected iPhone12,1"

printf 'Verified PWND DFU T8030/n104ap. Logs: %s\n' "$LOGS_DIR/preflight"
cat "$LOGS_DIR/preflight/irecovery-q.txt"

