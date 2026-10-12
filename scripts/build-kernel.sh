#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

# This old kernel's merge_config.sh has unquoted shell tests and breaks when an
# absolute -O path contains spaces. Work from the project root and keep every
# path handed to that helper free of spaces. build-all-native.sh provides a
# temporary bind-mount alias when the real workspace path contains spaces.
[[ "$PROJECT_ROOT" != *[' ':]* ]] || die "kernel source path contains spaces; run scripts/build-all-native.sh"
cd "$PROJECT_ROOT"
src_repo="$PROJECT_ROOT/sources/linux"
linux_patch="$PROJECT_ROOT/patches/linux/0001-t8030-read-only-nvme-bringup.patch"
android_write_patch="$PROJECT_ROOT/patches/linux/0002-t8030-android-write-allowlist.patch"
src="${RA1NCASTLE_LINUX_WORKTREE:-/tmp/ra1ncastle-linux-t8030-$(id -u)}"
docs="$PROJECT_ROOT/sources/hoolock-docs-a13"
obj="$BUILD_DIR/linux-n104"
assert_pinned_checkout "$src_repo" "$LINUX_REV"
assert_pinned_checkout "$docs" "$HOOLOCK_DOCS_REV"
[[ -s "$linux_patch" ]] || die "missing T8030 Linux patch: $linux_patch"
[[ -s "$android_write_patch" ]] || die "missing Android-write allowlist patch: $android_write_patch"
[[ ! -e "$src" ]] || die "temporary Linux worktree already exists: $src"

need_cmd make
need_cmd clang
need_cmd ld.lld
need_cmd dtc
need_cmd git

cleanup() {
  git -C "$src_repo" worktree remove --force "$src" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

git -C "$src_repo" worktree add --detach "$src" "$LINUX_REV"
git -C "$src" apply "$linux_patch"
git -C "$src" apply "$android_write_patch"
git -C "$src" diff --check

mkdir -p "$obj" "$OUT_DIR/kernel"
base_config="$BUILD_DIR/kernel-n104-base.config"
cp "$docs/config_16k" "$base_config"

"$src/scripts/kconfig/merge_config.sh" -m -O "$obj" \
  "$base_config" "$PROJECT_ROOT/config/kernel-n104-ramonly.fragment"

make -C "$src" O="$obj" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig

"$src/scripts/config" --file "$obj/.config" --state ARM64_16K_PAGES | rg -q '^y$'
"$src/scripts/config" --file "$obj/.config" --state USB_DWC3_APPLE | rg -q '^y$'
"$src/scripts/config" --file "$obj/.config" --state NVME_CORE | rg -q '^m$'
"$src/scripts/config" --file "$obj/.config" --state NVME_APPLE | rg -q '^m$'
"$src/scripts/config" --file "$obj/.config" --state USB_CONFIGFS | rg -q '^y$'
"$src/scripts/config" --file "$obj/.config" --state USB_CONFIGFS_ACM | rg -q '^y$'
"$src/scripts/config" --file "$obj/.config" --state USB_CONFIGFS_NCM | rg -q '^y$'
"$src/scripts/config" --file "$obj/.config" --state USB_CONFIGFS_MASS_STORAGE | rg -q '^n$'
! rg -q '^CONFIG_USB_F_MASS_STORAGE=y$' "$obj/.config"
"$src/scripts/config" --file "$obj/.config" --state USB_G_MULTI | rg -q '^n$'

make -C "$src" O="$obj" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$(jobs)" \
  Image.gz apple/t8030-n104.dtb modules

install -m644 "$obj/arch/arm64/boot/Image.gz" "$OUT_DIR/kernel/Image.gz"
install -m644 "$obj/arch/arm64/boot/dts/apple/t8030-n104.dtb" \
  "$OUT_DIR/kernel/t8030-n104.dtb"
install -m644 "$obj/drivers/nvme/host/nvme-apple.ko" \
  "$OUT_DIR/kernel/nvme-apple.ko"
install -m644 "$obj/drivers/nvme/host/nvme-core.ko" \
  "$OUT_DIR/kernel/nvme-core.ko"
install -m644 "$obj/.config" "$OUT_DIR/kernel/config"
(
  cd "$OUT_DIR/kernel"
  sha256sum Image.gz t8030-n104.dtb nvme-core.ko nvme-apple.ko config >SHA256SUMS
)
