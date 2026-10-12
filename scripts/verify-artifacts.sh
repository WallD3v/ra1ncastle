#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

need_cmd dtc
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
dtc -I dtb -O dts "$OUT_DIR/kernel/t8030-n104.dtb" >"$dt_dump" 2>/dev/null
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
