#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

need_cmd fdtget
need_cmd fdtput
need_cmd sha256sum

m1n1="$OUT_DIR/m1n1/m1n1-idevice.macho"
dtb="$OUT_DIR/kernel/t8030-n104.dtb"
kernel="$OUT_DIR/kernel/Image.gz"
initramfs="$OUT_DIR/initramfs/initramfs.cpio.gz"
bootargs_file="$OUT_DIR/payload/bootargs.txt"
control_out="$OUT_DIR/payload-nvme-disabled"
control_dtb="$control_out/t8030-n104-nvme-disabled.dtb"
control_payload="$control_out/m1n1-linux-n104-nvme-disabled.macho"

for artifact in "$m1n1" "$dtb" "$kernel" "$initramfs" "$bootargs_file"; do
  [[ -s "$artifact" ]] || die "missing artifact: $artifact"
done

mkdir -p "$control_out"
cp "$dtb" "$control_dtb"
fdtput -t s "$control_dtb" /soc/nvme@27acc0000 status disabled
[[ "$(fdtget "$control_dtb" /soc/nvme@27acc0000 status)" == disabled ]] || \
  die 'failed to disable the T8030 NVMe node in the control DTB'

bootargs="$(cat "$bootargs_file")"
{
  cat "$m1n1"
  printf 'chosen.bootargs=%s\n' "$bootargs"
  cat "$control_dtb"
  cat "$kernel"
  cat "$initramfs"
} >"$control_payload"

cp "$bootargs_file" "$control_out/bootargs.txt"
(
  cd "$control_out"
  sha256sum \
    m1n1-linux-n104-nvme-disabled.macho \
    t8030-n104-nvme-disabled.dtb \
    bootargs.txt >SHA256SUMS
)

printf 'Built RAM-only NVMe-disabled A/B control payload: %s bytes\n' \
  "$(stat -c %s "$control_payload")"
