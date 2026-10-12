#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

src="$SOURCES_DIR/busybox-$BUSYBOX_VERSION"
obj="$BUILD_DIR/busybox"
stage="$BUILD_DIR/initramfs-root"

[[ -d "$src" ]] || die "BusyBox source missing; run scripts/fetch-sources.sh"
need_cmd make
need_cmd cpio
need_cmd gzip
need_cmd fakeroot

cross="$(host_cross_prefix)"
rm -rf "$obj" "$stage"
mkdir -p "$obj" "$stage" "$OUT_DIR/initramfs"

make -C "$src" O="$obj" ARCH=arm64 CROSS_COMPILE="$cross" defconfig

sed -i 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' "$obj/.config"

# BusyBox 1.37.0 enables the x86-only SHA-NI implementations in defconfig.
# GCC 15 then rejects the ARM64 cross-build because the x86 assembly symbol is
# unavailable.  Keep the initramfs architecture-neutral and deliberately omit
# applets which can repartition, format, erase, or copy raw block devices.
disable_busybox_config() {
  local symbol="$1"
  sed -i \
    -e "/^CONFIG_${symbol}=.*/d" \
    -e "/^# CONFIG_${symbol} is not set$/d" \
    "$obj/.config"
  printf '# CONFIG_%s is not set\n' "$symbol" >>"$obj/.config"
}

for symbol in \
  SHA1_HWACCEL SHA256_HWACCEL TC \
  DD SHRED BLKDISCARD FDISK PARTPROBE LOSETUP \
  FALLOCATE FDFORMAT FSCK FSCK_MINIX FSFREEZE FSTRIM \
  MKDOSFS MKFS_EXT2 MKFS_MINIX MKFS_REISER MKFS_VFAT \
  MKE2FS MKSWAP SWAPON SWAPOFF \
  HDPARM FLASH_ERASEALL FLASH_LOCK FLASH_UNLOCK FLASHCP \
  NANDWRITE NANDDUMP \
  UBIATTACH UBIDETACH UBIMKVOL UBIRMVOL UBIRSVOL \
  UBIUPDATEVOL UBIRENAME \
  DEVMEM I2CSET I2CTRANSFER NBDCLIENT RAIDAUTORUN RESUME \
  RTCWAKE WATCHDOG
do
  disable_busybox_config "$symbol"
done
# oldconfig exits after consuming the required defaults, which gives `yes` a
# normal SIGPIPE. Capture make's status rather than letting pipefail turn that
# expected SIGPIPE into exit 141.
set +o pipefail
yes '' | make -C "$src" O="$obj" ARCH=arm64 CROSS_COMPILE="$cross" oldconfig >/dev/null
oldconfig_status="${PIPESTATUS[1]}"
set -o pipefail
[[ "$oldconfig_status" -eq 0 ]] || die "BusyBox oldconfig failed with status $oldconfig_status"

for symbol in \
  SHA1_HWACCEL SHA256_HWACCEL DD SHRED BLKDISCARD FDISK PARTPROBE \
  LOSETUP FALLOCATE FDFORMAT FSCK FSCK_MINIX FSFREEZE FSTRIM \
  MKDOSFS MKE2FS MKFS_EXT2 MKFS_MINIX MKFS_REISER MKFS_VFAT \
  MKSWAP SWAPON SWAPOFF HDPARM FLASH_ERASEALL FLASH_LOCK \
  FLASH_UNLOCK FLASHCP NANDWRITE NANDDUMP UBIATTACH UBIDETACH \
  UBIMKVOL UBIRMVOL UBIRSVOL UBIUPDATEVOL UBIRENAME DEVMEM \
  I2CSET I2CTRANSFER NBDCLIENT RAIDAUTORUN RESUME RTCWAKE WATCHDOG
do
  ! grep -q "^CONFIG_${symbol}=y$" "$obj/.config" || \
    die "unsafe BusyBox applet unexpectedly enabled: CONFIG_${symbol}"
done

make -C "$src" O="$obj" ARCH=arm64 CROSS_COMPILE="$cross" -j"$(jobs)"
make -C "$src" O="$obj" ARCH=arm64 CROSS_COMPILE="$cross" \
  CONFIG_PREFIX="$stage" install

mkdir -p "$stage"/{dev,proc,sys,run,tmp,root,etc,usr/bin,usr/sbin,lib/modules}
install -m755 "$PROJECT_ROOT/initramfs/init" "$stage/init"
install -m755 "$PROJECT_ROOT/initramfs/klog-follow" "$stage/sbin/klog-follow"
install -m644 "$OUT_DIR/kernel/nvme-core.ko" "$stage/lib/modules/nvme-core.ko"
install -m644 "$OUT_DIR/kernel/nvme-apple.ko" "$stage/lib/modules/nvme-apple.ko"

fakeroot -- sh -eu -c '
  stage="$1"
  output="$2"
  mknod -m 600 "$stage/dev/console" c 5 1
  mknod -m 666 "$stage/dev/null" c 1 3
  cd "$stage"
  find . -print0 | sort -z | cpio --null -o --format=newc --owner=0:0 | gzip -9n >"$output"
' sh "$stage" "$OUT_DIR/initramfs/initramfs.cpio.gz"

(
  cd "$OUT_DIR/initramfs"
  sha256sum initramfs.cpio.gz >SHA256SUMS
)
