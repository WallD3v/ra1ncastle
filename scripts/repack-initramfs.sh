#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

stage="$BUILD_DIR/initramfs-root"
output="$OUT_DIR/initramfs/initramfs.cpio.gz"

[[ -x "$stage/bin/busybox" ]] || \
  die "missing staged BusyBox; run scripts/build-all-native.sh first"

need_cmd cpio
need_cmd fakeroot
need_cmd gzip

install -m755 "$PROJECT_ROOT/initramfs/init" "$stage/init"
mkdir -p "$stage/dev" "$stage/sbin" "$stage/lib/modules" "$OUT_DIR/initramfs"
install -m755 "$PROJECT_ROOT/initramfs/klog-follow" "$stage/sbin/klog-follow"
install -m644 "$OUT_DIR/kernel/nvme-core.ko" "$stage/lib/modules/nvme-core.ko"
install -m644 "$OUT_DIR/kernel/nvme-apple.ko" "$stage/lib/modules/nvme-apple.ko"

# fakeroot state is per invocation. Recreate the two device nodes while the
# archive is generated so an incremental init edit does not require rebuilding
# all of BusyBox or the kernel.
fakeroot -- sh -eu -c '
  stage="$1"
  output="$2"
  unlink "$stage/dev/console" 2>/dev/null || true
  unlink "$stage/dev/null" 2>/dev/null || true
  mknod -m 600 "$stage/dev/console" c 5 1
  mknod -m 666 "$stage/dev/null" c 1 3
  cd "$stage"
  find . -print0 | sort -z | cpio --null -o --format=newc --owner=0:0 | gzip -9n >"$output"
' sh "$stage" "$output"

(
  cd "$OUT_DIR/initramfs"
  sha256sum initramfs.cpio.gz >SHA256SUMS
)

"$ROOT/scripts/package-payload.sh"
"$ROOT/scripts/verify-artifacts.sh"
