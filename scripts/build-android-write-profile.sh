#!/usr/bin/env bash

# Build a distinct, opt-in payload. The driver is responsible for consuming
# this FDT contract and failing closed; this script never modifies out/payload.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack
require_android_write_ack

need_cmd cpio
need_cmd fakeroot
need_cmd fdtget
need_cmd fdtput
need_cmd sha256sum

m1n1="$OUT_DIR/m1n1/m1n1-idevice.macho"
dtb="$OUT_DIR/kernel/t8030-n104.dtb"
kernel="$OUT_DIR/kernel/Image.gz"
stage="$BUILD_DIR/initramfs-root"
bootargs_file="$OUT_DIR/payload/bootargs.txt"
profile_out="$OUT_DIR/payload-android-write"
profile_dtb="$profile_out/t8030-n104-android-write.dtb"
profile_initramfs="$profile_out/initramfs-android-write.cpio.gz"
profile_payload="$profile_out/m1n1-linux-n104-android-write.macho"
nvme_node=/soc/nvme@27acc0000

for artifact in "$m1n1" "$dtb" "$kernel" "$bootargs_file" "$stage/bin/busybox"; do
  [[ -s "$artifact" ]] || die "missing artifact: $artifact"
done

start_hi=$((ANDROID_WRITE_LBA_START >> 32)); start_lo=$((ANDROID_WRITE_LBA_START & 0xffffffff))
end_hi=$((ANDROID_WRITE_LBA_END >> 32)); end_lo=$((ANDROID_WRITE_LBA_END & 0xffffffff))
expected_ranges="$(printf '%x %x %x %x' "$start_hi" "$start_lo" "$end_hi" "$end_lo")"

rm -rf "$profile_out"
mkdir -p "$profile_out"
cp "$dtb" "$profile_dtb"
fdtput -t x "$profile_dtb" "$nvme_node" ra1ncastle,write-allow-nsid "$ANDROID_WRITE_NSID"
fdtput -t x "$profile_dtb" "$nvme_node" ra1ncastle,write-allow-lba-ranges \
  "$start_hi" "$start_lo" "$end_hi" "$end_lo"
[[ "$(fdtget -t x "$profile_dtb" "$nvme_node" ra1ncastle,write-allow-nsid)" == "$(printf '%x' "$ANDROID_WRITE_NSID")" ]] || die 'failed to set Android-write NSID'
[[ "$(fdtget -t x "$profile_dtb" "$nvme_node" ra1ncastle,write-allow-lba-ranges)" == "$expected_ranges" ]] || die 'failed to set Android-write LBA range'

# Make a second archive from the already-built static BusyBox stage. This is
# the only profile that swaps init: default and diagnostic profiles retain the
# universal /sys/block/*/ro watcher.
profile_stage="$BUILD_DIR/initramfs-android-write-root"
rm -rf "$profile_stage"
cp -a "$stage" "$profile_stage"
install -m755 "$PROJECT_ROOT/initramfs/init-android-write" "$profile_stage/init"
fakeroot -- sh -eu -c '
  stage="$1"; output="$2"
  unlink "$stage/dev/console" 2>/dev/null || true
  unlink "$stage/dev/null" 2>/dev/null || true
  mknod -m 600 "$stage/dev/console" c 5 1
  mknod -m 666 "$stage/dev/null" c 1 3
  cd "$stage"
  find . -print0 | sort -z | cpio --null -o --format=newc --owner=0:0 | gzip -9n >"$output"
' sh "$profile_stage" "$profile_initramfs"
gzip -t "$profile_initramfs"

bootargs="$(cat "$bootargs_file")"
{
  cat "$m1n1"
  printf 'chosen.bootargs=%s\n' "$bootargs"
  cat "$profile_dtb"
  cat "$kernel"
  cat "$profile_initramfs"
} >"$profile_payload"
cp "$bootargs_file" "$profile_out/bootargs.txt"
cat >"$profile_out/PROFILE" <<EOF
profile=android-write
nsid=$ANDROID_WRITE_NSID
logical-sector-bytes=4096
write-allow-lba-start=$ANDROID_WRITE_LBA_START
write-allow-lba-end=$ANDROID_WRITE_LBA_END
EOF
(
  cd "$profile_out"
  sha256sum m1n1-linux-n104-android-write.macho t8030-n104-android-write.dtb \
    initramfs-android-write.cpio.gz bootargs.txt PROFILE >SHA256SUMS
)
printf 'Built separate Android-write payload: NSID %s, inclusive LBAs %s..%s (%s bytes)\n' \
  "$ANDROID_WRITE_NSID" "$ANDROID_WRITE_LBA_START" "$ANDROID_WRITE_LBA_END" \
  "$(stat -c %s "$profile_payload")"
