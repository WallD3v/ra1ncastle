#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

m1n1="$OUT_DIR/m1n1/m1n1-idevice.macho"
dtb="$OUT_DIR/kernel/t8030-n104.dtb"
kernel="$OUT_DIR/kernel/Image.gz"
initramfs="$OUT_DIR/initramfs/initramfs.cpio.gz"

for artifact in "$m1n1" "$dtb" "$kernel" "$initramfs"; do
  [[ -s "$artifact" ]] || die "missing artifact: $artifact"
done

mkdir -p "$OUT_DIR/payload"
bootargs='console=tty0 console=ttySAC0,115200n8 earlycon keep_bootcon loglevel=8 ignore_loglevel printk.time=1 rdinit=/init panic=-1 clk_ignore_unused pd_ignore_unused'

{
  cat "$m1n1"
  printf 'chosen.bootargs=%s\n' "$bootargs"
  cat "$dtb"
  cat "$kernel"
  cat "$initramfs"
} >"$OUT_DIR/payload/m1n1-linux-n104.macho"

printf '%s\n' "$bootargs" >"$OUT_DIR/payload/bootargs.txt"
(
  cd "$OUT_DIR/payload"
  sha256sum m1n1-linux-n104.macho bootargs.txt >SHA256SUMS
)
ls -lh "$OUT_DIR/payload/m1n1-linux-n104.macho"
