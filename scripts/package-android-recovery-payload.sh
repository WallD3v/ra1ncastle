#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

TREE="$ROOT/android/lineage-24.0"
PRODUCT_OUT="$TREE/out/target/product/snowcastle"
ANDROID_DEVICE="$TREE/device/apple/snowcastle"
M1N1="$OUT_DIR/m1n1/m1n1-idevice.macho"
KERNEL="$PRODUCT_OUT/kernel"
DTB="$PRODUCT_OUT/dtb.img"
RAMDISK="$PRODUCT_OUT/ramdisk-recovery.img"
BOOTARGS_FILE="$PRODUCT_OUT/m1n1-vars-recovery.txt"
KERNEL_CONFIG="$OUT_DIR/kernel/config"
RECOVERY_ROOT="$PRODUCT_OUT/recovery/root"
MODULES_LOAD="$RECOVERY_ROOT/system/etc/modules.load.normal"
PROFILE_DIR="$OUT_DIR/payload-android-recovery"
PAYLOAD="$PROFILE_DIR/m1n1-linux-n104-android-recovery.macho"

for artifact in "$M1N1" "$KERNEL" "$DTB" "$RAMDISK" "$BOOTARGS_FILE" \
  "$KERNEL_CONFIG" "$MODULES_LOAD"; do
  [[ -s "$artifact" ]] || die "missing Android recovery payload input: $artifact"
done

cmp -s "$KERNEL" "$OUT_DIR/kernel/Image.gz" || \
  die 'Android recovery kernel differs from the validated T8030 kernel'
cmp -s "$DTB" "$OUT_DIR/kernel/t8030-n104.dtb" || \
  die 'Android recovery DTB differs from the validated iPhone 11 DTB'
gzip -t "$KERNEL" || die 'Android recovery kernel is not a valid gzip image'
gzip -t "$RAMDISK" || die 'Android recovery ramdisk is not a valid gzip image'
grep -qx 'CONFIG_NVME_CORE=m' "$KERNEL_CONFIG" || \
  die 'refusing Android recovery unless NVMe core remains modular'
grep -qx 'CONFIG_NVME_APPLE=m' "$KERNEL_CONFIG" || \
  die 'refusing Android recovery unless Apple NVMe remains modular'
grep -qx 'CONFIG_SECURITY_SELINUX=y' "$KERNEL_CONFIG" || \
  die 'refusing Android recovery without kernel SELinux/selinuxfs support'
grep -qx 'CONFIG_DEFAULT_SECURITY_SELINUX=y' "$KERNEL_CONFIG" || \
  die 'refusing Android recovery unless SELinux is the default LSM'
grep -qx 'CONFIG_LSM="selinux"' "$KERNEL_CONFIG" || \
  die 'refusing Android recovery unless SELinux is active in the LSM list'
if find "$RECOVERY_ROOT" -type f -iname 'nvme*.ko' -print -quit | rg -q .; then
  die 'refusing Android recovery with an NVMe module staged in its ramdisk'
fi
if grep -Ev '^[[:space:]]*(#|$)' "$MODULES_LOAD" | rg -qi 'nvme'; then
  die 'refusing Android recovery with NVMe listed for automatic module loading'
fi

bootargs_count="$(rg -c '^chosen\.bootargs=' "$BOOTARGS_FILE" || true)"
[[ "$bootargs_count" == 1 ]] || die 'expected exactly one recovery chosen.bootargs entry'
bootargs="$(sed -n 's/^chosen\.bootargs=//p' "$BOOTARGS_FILE")"
[[ "$bootargs" == *androidboot.init_fatal_reboot_target=recovery* ]] || \
  die 'Android recovery bootargs do not identify recovery mode'

mkdir -p "$PROFILE_DIR"
temporary="$(mktemp "$PROFILE_DIR/.payload.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
{
  cat "$M1N1"
  printf 'chosen.bootargs=%s\n' "$bootargs"
  cat "$DTB" "$KERNEL" "$RAMDISK"
} > "$temporary"
mv -f "$temporary" "$PAYLOAD"
trap - EXIT

printf '%s\n' "$bootargs" > "$PROFILE_DIR/bootargs.txt"
printf '%s\n' \
  'profile=android-recovery' \
  'storage=ram-only' \
  'nvme=modular-and-not-staged-or-autoloaded' > "$PROFILE_DIR/PROFILE"

m1n1_size="$(stat -c %s "$M1N1")"
dtb_size="$(stat -c %s "$DTB")"
kernel_size="$(stat -c %s "$KERNEL")"
ramdisk_size="$(stat -c %s "$RAMDISK")"
bootargs_size="$(stat -c %s "$PROFILE_DIR/bootargs.txt")"
expected_size="$((m1n1_size + 16 + bootargs_size + dtb_size + kernel_size + ramdisk_size))"
actual_size="$(stat -c %s "$PAYLOAD")"
[[ "$actual_size" -eq "$expected_size" ]] || \
  die "Android recovery payload size mismatch: got $actual_size, expected $expected_size"

(
  cd "$PROFILE_DIR"
  sha256sum \
    m1n1-linux-n104-android-recovery.macho \
    bootargs.txt PROFILE >SHA256SUMS
  sha256sum --check SHA256SUMS
)
file "$PAYLOAD" | rg -q 'Mach-O 64-bit arm64 executable' || \
  die 'Android recovery payload does not start with the expected M1N1 iDevice image'
printf 'RAM-only Android Recovery iBoot payload: %s bytes\n' "$actual_size"
