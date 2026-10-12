#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

if [[ "$PROJECT_ROOT" == *[' ':]* && "${RA1NCASTLE_NO_SPACE_ACTIVE:-0}" != 1 ]]; then
  exec "$PROJECT_ROOT/scripts/run-no-space.sh" scripts/prepare-bootchain.sh "$@"
fi

assert_pinned_checkout "$SOURCES_DIR/remote_boot" "$REMOTE_BOOT_REV"
assert_pinned_checkout "$SOURCES_DIR/usbliter8" "$USBLITER8_REV"

"$PROJECT_ROOT/scripts/check-pwnd-dfu.sh"

ipsw_bin="${IPSW:-$OUT_DIR/host-tools/ipsw}"
[[ -x "$ipsw_bin" ]] || die "ipsw not found; run scripts/install-ipsw.sh or set IPSW=/path/to/ipsw"

boot_path="$(dirname "$ipsw_bin"):$PATH"
usbliter8ctl="$SOURCES_DIR/usbliter8/usbliter8ctl"
iboot_build="${A12A13_IBOOT_BUILD:-$DEFAULT_IBOOT_BUILD}"
proxy_args=()
while IFS= read -r -d '' arg; do
  proxy_args+=("$arg")
done < <(proxy_env_args)

# This only downloads/extracts/patches host-side boot artifacts. It does not
# send flash commands and does not touch NAND/APFS.
sudo env \
  "${proxy_args[@]}" \
  PATH="$boot_path" \
  USBLITER8CTL="$usbliter8ctl" \
  A12A13_IBOOT_BUILD="$iboot_build" \
  "$SOURCES_DIR/remote_boot/remoteboot.sh" prep
