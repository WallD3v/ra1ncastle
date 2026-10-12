#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

src="$SOURCES_DIR/m1n1"
assert_pinned_checkout "$src" "$M1N1_REV"
need_cmd make
need_cmd cargo

make_args=(-j"$(jobs)" CHAINLOADING=1)
if [[ "$(uname -m)" == aarch64 || "$(uname -m)" == arm64 ]]; then
  make_args+=(ARCH=)
fi

make -C "$src" "${make_args[@]}"

mkdir -p "$OUT_DIR/m1n1"
install -m644 "$src/build/m1n1-idevice.macho" "$OUT_DIR/m1n1/"
install -m644 "$src/build/monitor-stub.macho" "$OUT_DIR/m1n1/"
install -m644 "$src/build/m1n1.bin" "$OUT_DIR/m1n1/"
(
  cd "$OUT_DIR/m1n1"
  sha256sum m1n1-idevice.macho monitor-stub.macho m1n1.bin >SHA256SUMS
)
