#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

dtc_bin="${DTC:-dtc}"
if ! command -v "$dtc_bin" >/dev/null 2>&1; then
  # A completed kernel build already has a native host dtc.  This keeps
  # artifact verification usable when the distro package was later removed;
  # fresh build hosts still get device-tree-compiler via install-deps-ubuntu.sh.
  bundled_dtc="$BUILD_DIR/linux-n104/scripts/dtc/dtc"
  [[ -x "$bundled_dtc" ]] || die "missing command: dtc (and no built kernel dtc)"
  dtc_bin="$bundled_dtc"
fi
if ! command -v fdtget >/dev/null 2>&1; then
  bundled_dtc_tools="$BUILD_DIR/host-tools/dtc-1.7.2"
  [[ -x "$bundled_dtc_tools/fdtget" ]] || \
    die 'missing command: fdtget (and no bundled dtc host tools)'
  export PATH="$bundled_dtc_tools:$PATH"
  if [[ -d "$bundled_dtc_tools/libfdt" ]]; then
    export LD_LIBRARY_PATH="$bundled_dtc_tools/libfdt${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
fi

need_cmd file
need_cmd gzip
need_cmd sha256sum

for dir in m1n1 kernel initramfs payload; do
  [[ -s "$OUT_DIR/$dir/SHA256SUMS" ]] || die "missing checksum manifest: out/$dir/SHA256SUMS"
  (cd "$OUT_DIR/$dir" && sha256sum --check SHA256SUMS)
done

gzip -t "$OUT_DIR/kernel/Image.gz"
gzip -t "$OUT_DIR/initramfs/initramfs.cpio.gz"

file "$OUT_DIR/m1n1/m1n1-idevice.macho" | rg -q 'Mach-O 64-bit arm64 executable'
file "$BUILD_DIR/initramfs-root/bin/busybox" | rg -q 'ARM aarch64.*statically linked'
file "$OUT_DIR/kernel/t8030-n104.dtb" | rg -q 'Device Tree Blob'
file "$OUT_DIR/kernel/nvme-core.ko" | rg -q 'relocatable.*ARM aarch64'
file "$OUT_DIR/kernel/nvme-apple.ko" | rg -q 'relocatable.*ARM aarch64'
file "$OUT_DIR/payload/m1n1-linux-n104.macho" | rg -q 'Mach-O 64-bit arm64 executable'

kernel_config="$OUT_DIR/kernel/config"
for symbol in \
  ARM64_16K_PAGES DRM_SIMPLEDRM USB_DWC3_APPLE USB_CONFIGFS \
  USB_CONFIGFS_ACM USB_CONFIGFS_NCM
do
  grep -qx "CONFIG_${symbol}=y" "$kernel_config" || \
    die "required kernel setting missing: CONFIG_${symbol}=y"
done
grep -qx 'CONFIG_NVME_APPLE=m' "$kernel_config" || \
  die 'diagnostic kernel must keep CONFIG_NVME_APPLE=m'
grep -qx 'CONFIG_NVME_CORE=m' "$kernel_config" || \
  die 'diagnostic kernel must keep CONFIG_NVME_CORE=m'

for symbol in \
  USB_CONFIGFS_MASS_STORAGE USB_MASS_STORAGE USB_G_MULTI \
  USB_GADGETFS
do
  grep -qx "# CONFIG_${symbol} is not set" "$kernel_config" || \
    die "safe bring-up kernel setting missing: CONFIG_${symbol}=n"
done
! grep -q '^CONFIG_USB_F_MASS_STORAGE=y$' "$kernel_config" || \
  die 'RAM-only kernel setting violated: CONFIG_USB_F_MASS_STORAGE=y'

busybox_config="$BUILD_DIR/busybox/.config"
grep -qx 'CONFIG_STATIC=y' "$busybox_config" || die 'BusyBox is not static'
for symbol in \
  DD SHRED BLKDISCARD FDISK PARTPROBE LOSETUP FALLOCATE FDFORMAT \
  FSCK FSCK_MINIX FSFREEZE FSTRIM MKDOSFS MKE2FS MKFS_EXT2 \
  MKFS_MINIX MKFS_REISER MKFS_VFAT MKSWAP SWAPON SWAPOFF HDPARM \
  FLASH_ERASEALL FLASH_LOCK FLASH_UNLOCK FLASHCP NANDWRITE NANDDUMP \
  UBIATTACH UBIDETACH UBIMKVOL UBIRMVOL UBIRSVOL UBIUPDATEVOL \
  UBIRENAME DEVMEM I2CSET I2CTRANSFER NBDCLIENT RAIDAUTORUN RESUME \
  RTCWAKE WATCHDOG
do
  ! grep -q "^CONFIG_${symbol}=y$" "$busybox_config" || \
    die "unsafe BusyBox applet enabled: CONFIG_${symbol}"
done

dt_dump="$(mktemp)"
trap 'rm -f "$dt_dump"' EXIT
"$dtc_bin" -I dtb -O dts "$OUT_DIR/kernel/t8030-n104.dtb" >"$dt_dump" 2>/dev/null
rg -q 'compatible = "apple,n104", "apple,t8030"' "$dt_dump"
rg -q 'model = "Apple iPhone 11"' "$dt_dump"
rg -q 'compatible = "apple,simple-framebuffer", "simple-framebuffer"' "$dt_dump"
rg -q 'dr_mode = "peripheral"' "$dt_dump"
rg -q 'compatible = "apple,t8030-nvme-ans2"' "$dt_dump"
rg -q 'compatible = "apple,t8030-sart"' "$dt_dump"

m1n1_size="$(stat -c %s "$OUT_DIR/m1n1/m1n1-idevice.macho")"
dtb_size="$(stat -c %s "$OUT_DIR/kernel/t8030-n104.dtb")"
kernel_size="$(stat -c %s "$OUT_DIR/kernel/Image.gz")"
initramfs_size="$(stat -c %s "$OUT_DIR/initramfs/initramfs.cpio.gz")"
bootargs_size="$(stat -c %s "$OUT_DIR/payload/bootargs.txt")"
payload_size="$(stat -c %s "$OUT_DIR/payload/m1n1-linux-n104.macho")"
prefix='chosen.bootargs='
prefix_size="${#prefix}"
expected_size="$((m1n1_size + prefix_size + bootargs_size + dtb_size + kernel_size + initramfs_size))"
[[ "$payload_size" -eq "$expected_size" ]] || \
  die "payload size mismatch: got $payload_size, expected $expected_size"

printf 'Verified read-only-storage n104 payload: %s bytes\n' "$payload_size"

android_recovery_dir="$OUT_DIR/payload-android-recovery"
if [[ -d "$android_recovery_dir" ]]; then
  for artifact in \
    "$android_recovery_dir/SHA256SUMS" \
    "$android_recovery_dir/m1n1-linux-n104-android-recovery.macho" \
    "$android_recovery_dir/bootargs.txt" "$android_recovery_dir/PROFILE"; do
    [[ -s "$artifact" ]] || die "incomplete Android recovery profile artifact: $artifact"
  done
  (cd "$android_recovery_dir" && sha256sum --check SHA256SUMS)
  grep -qx 'profile=android-recovery' "$android_recovery_dir/PROFILE" || \
    die 'Android recovery profile manifest is invalid'
  grep -qx 'storage=ram-only' "$android_recovery_dir/PROFILE" || \
    die 'Android recovery profile must remain RAM-only'
  grep -qx 'nvme=modular-and-not-staged-or-autoloaded' "$android_recovery_dir/PROFILE" || \
    die 'Android recovery profile has an unexpected NVMe policy'
  grep -qx 'CONFIG_NVME_CORE=m' "$kernel_config" || \
    die 'Android recovery kernel must keep NVMe core modular'
  grep -qx 'CONFIG_NVME_APPLE=m' "$kernel_config" || \
    die 'Android recovery kernel must keep Apple NVMe modular'
  recovery_root="$ROOT/android/lineage-24.0/out/target/product/snowcastle/recovery/root"
  if find "$recovery_root" -type f -iname 'nvme*.ko' -print -quit | rg -q .; then
    die 'Android recovery ramdisk unexpectedly contains an NVMe module'
  fi
  modules_load="$recovery_root/system/etc/modules.load.normal"
  [[ -s "$modules_load" ]] || die 'Android recovery modules.load.normal is missing'
  if grep -Ev '^[[:space:]]*(#|$)' "$modules_load" | rg -qi 'nvme'; then
    die 'Android recovery ramdisk requests automatic NVMe module loading'
  fi
  gzip -t "$ROOT/android/lineage-24.0/out/target/product/snowcastle/kernel"
  gzip -t "$ROOT/android/lineage-24.0/out/target/product/snowcastle/ramdisk-recovery.img"
  printf 'Verified RAM-only Android Recovery payload.\n'
fi

# The write profile is intentionally optional and separate. Verify it whenever
# present so a malformed DT contract can never reach ram-boot.
android_write_dir="$OUT_DIR/payload-android-write"
if [[ -d "$android_write_dir" ]]; then
  need_cmd fdtget
  for artifact in \
    "$android_write_dir/SHA256SUMS" \
    "$android_write_dir/m1n1-linux-n104-android-write.macho" \
    "$android_write_dir/t8030-n104-android-write.dtb" \
    "$android_write_dir/initramfs-android-write.cpio.gz" \
    "$android_write_dir/bootargs.txt" "$android_write_dir/PROFILE"
  do
    [[ -s "$artifact" ]] || die "incomplete Android-write profile artifact: $artifact"
  done
  (cd "$android_write_dir" && sha256sum --check SHA256SUMS)
  [[ "$(fdtget -t x "$android_write_dir/t8030-n104-android-write.dtb" /soc/nvme@27acc0000 ra1ncastle,write-allow-nsid)" == "$(printf '%x' "$ANDROID_WRITE_NSID")" ]] || die 'Android-write profile has an invalid namespace property'
  expected_write_ranges="$(printf '0 %x 0 %x' "$ANDROID_WRITE_LBA_START" "$ANDROID_WRITE_LBA_END")"
  [[ "$(fdtget -t x "$android_write_dir/t8030-n104-android-write.dtb" /soc/nvme@27acc0000 ra1ncastle,write-allow-lba-ranges)" == "$expected_write_ranges" ]] || die 'Android-write profile has an invalid LBA range property'
  grep -qx 'profile=android-write' "$android_write_dir/PROFILE" || die 'Android-write profile manifest is invalid'
  gzip -t "$android_write_dir/initramfs-android-write.cpio.gz"
  printf 'Verified separate Android-write allowlist: NSID %s, LBAs %s..%s\n' "$ANDROID_WRITE_NSID" "$ANDROID_WRITE_LBA_START" "$ANDROID_WRITE_LBA_END"
fi
