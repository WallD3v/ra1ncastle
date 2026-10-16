#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$ROOT/android/lineage-24.0"
DEVICE="$TREE/device/apple/snowcastle"
PRODUCT_OUT="$TREE/out/target/product/snowcastle"
M1N1_SOURCE="$ROOT/sources/m1n1/build/m1n1.bin"
SOONG_VARIABLES="$TREE/out/soong/soong.ra1ncastle.variables"

for input in \
  "$M1N1_SOURCE" \
  "$SOONG_VARIABLES" \
  "$PRODUCT_OUT/kernel" \
  "$PRODUCT_OUT/dtb.img" \
  "$PRODUCT_OUT/ramdisk-recovery.img" \
  "$PRODUCT_OUT/recovery.img"; do
  [[ -s "$input" ]] || {
    printf 'error: missing required recovery packaging input: %s\n' "$input" >&2
    exit 1
  }
done

BOOTARGS="$(jq -er '
  [.. | objects | select(has("InternalKernelCmdline")) |
    .InternalKernelCmdline | join(" ")] |
  if length == 1 then .[0] else error("expected one InternalKernelCmdline") end
' "$SOONG_VARIABLES")"
[[ "$BOOTARGS" == *androidboot.init_fatal_reboot_target=recovery* ]] || {
  echo 'error: generated recovery bootargs do not identify recovery mode' >&2
  exit 1
}

install -m 0644 "$M1N1_SOURCE" "$DEVICE/prebuilts/m1n1.bin"
install -m 0644 "$M1N1_SOURCE" "$PRODUCT_OUT/m1n1.bin"
printf 'chosen.bootargs=%s\n' "$BOOTARGS" > "$PRODUCT_OUT/m1n1-vars-recovery.txt"

output="$PRODUCT_OUT/m1n1-recovery.bin"
temporary="$(mktemp "$PRODUCT_OUT/.m1n1-recovery.bin.XXXXXX")"
trap 'rm -f "$temporary"' EXIT

if [[ -s "$DEVICE/prebuilts/m1n1-syscfg.payload" ]]; then
  cat \
    "$PRODUCT_OUT/m1n1.bin" \
    "$PRODUCT_OUT/m1n1-vars-recovery.txt" \
    "$PRODUCT_OUT/dtb.img" \
    "$DEVICE/prebuilts/m1n1-syscfg.payload" \
    "$PRODUCT_OUT/kernel" \
    "$PRODUCT_OUT/ramdisk-recovery.img" > "$temporary"
else
  cat \
    "$PRODUCT_OUT/m1n1.bin" \
    "$PRODUCT_OUT/m1n1-vars-recovery.txt" \
    "$PRODUCT_OUT/dtb.img" \
    "$PRODUCT_OUT/kernel" \
    "$PRODUCT_OUT/ramdisk-recovery.img" > "$temporary"
fi

mv -f "$temporary" "$output"
trap - EXIT
sha256sum "$output"
printf 'ra1ncastle M1N1 Recovery payload: %s\n' "$output"
