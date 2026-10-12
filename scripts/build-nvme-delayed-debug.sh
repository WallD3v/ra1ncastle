#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

need_cmd fdtget
need_cmd fdtput
need_cmd sha256sum

delay_ms="${RA1NCASTLE_NVME_PROBE_DELAY_MS:-60000}"
[[ "$delay_ms" =~ ^[0-9]+$ ]] || die 'NVMe probe delay must be an integer'
(( delay_ms > 0 && delay_ms <= 120000 )) || \
  die 'NVMe probe delay must be between 1 and 120000 ms'

m1n1="$OUT_DIR/m1n1/m1n1-idevice.macho"
dtb="$OUT_DIR/kernel/t8030-n104.dtb"
kernel="$OUT_DIR/kernel/Image.gz"
initramfs="$OUT_DIR/initramfs/initramfs.cpio.gz"
bootargs_file="$OUT_DIR/payload/bootargs.txt"
debug_out="$OUT_DIR/payload-nvme-delayed"
debug_dtb="$debug_out/t8030-n104-nvme-delayed.dtb"
debug_payload="$debug_out/m1n1-linux-n104-nvme-delayed.macho"

for artifact in "$m1n1" "$dtb" "$kernel" "$initramfs" "$bootargs_file"; do
  [[ -s "$artifact" ]] || die "missing artifact: $artifact"
done

mkdir -p "$debug_out"
cp "$dtb" "$debug_dtb"
fdtput -t i "$debug_dtb" /soc/nvme@27acc0000 \
  apple,probe-delay-ms "$delay_ms"
[[ "$(fdtget -t i "$debug_dtb" /soc/nvme@27acc0000 \
    apple,probe-delay-ms)" == "$delay_ms" ]] || \
  die 'failed to add the T8030 NVMe probe delay to the debug DTB'

bootargs="$(cat "$bootargs_file")"
{
  cat "$m1n1"
  printf 'chosen.bootargs=%s\n' "$bootargs"
  cat "$debug_dtb"
  cat "$kernel"
  cat "$initramfs"
} >"$debug_payload"

cp "$bootargs_file" "$debug_out/bootargs.txt"
printf '%s\n' "$delay_ms" >"$debug_out/probe-delay-ms.txt"
(
  cd "$debug_out"
  sha256sum \
    m1n1-linux-n104-nvme-delayed.macho \
    t8030-n104-nvme-delayed.dtb \
    bootargs.txt probe-delay-ms.txt >SHA256SUMS
)

printf 'Built RAM-only NVMe-delayed debug payload (%s ms): %s bytes\n' \
  "$delay_ms" "$(stat -c %s "$debug_payload")"
