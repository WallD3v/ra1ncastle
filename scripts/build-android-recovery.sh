#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$ROOT/android/lineage-24.0"
KERNEL_OUT="$ROOT/out/kernel"
PREBUILT_DIR="$TREE/device/apple/snowcastle/prebuilts/kernel"
KERNEL_SOURCE_LINK="$TREE/device/apple/snowcastle/kernel-source"
KERNEL_SOURCE_TREE="$ROOT/sources/linux"

[[ -d "$KERNEL_SOURCE_TREE" ]] || {
  printf 'error: missing kernel source tree: %s\n' "$KERNEL_SOURCE_TREE" >&2
  exit 1
}
if [[ -e "$KERNEL_SOURCE_LINK" || -L "$KERNEL_SOURCE_LINK" ]]; then
  [[ "$(readlink -f "$KERNEL_SOURCE_LINK")" == "$(readlink -f "$KERNEL_SOURCE_TREE")" ]] || {
    printf 'error: unexpected kernel-source path: %s\n' "$KERNEL_SOURCE_LINK" >&2
    exit 1
  }
else
  ln -s "$KERNEL_SOURCE_TREE" "$KERNEL_SOURCE_LINK"
fi

for input in Image.gz t8030-n104.dtb config; do
  [[ -s "$KERNEL_OUT/$input" ]] || {
    printf 'error: missing validated kernel input: %s\n' "$KERNEL_OUT/$input" >&2
    exit 1
  }
done

grep -q '^CONFIG_ARM64_16K_PAGES=y$' "$KERNEL_OUT/config" || {
  echo 'error: kernel is not configured for 16 KiB pages' >&2
  exit 1
}
grep -q '^CONFIG_ANDROID_BINDER_IPC=y$' "$KERNEL_OUT/config" || {
  echo 'error: kernel is missing Android Binder IPC' >&2
  exit 1
}
grep -q '^CONFIG_USB_CONFIGFS_F_FS=y$' "$KERNEL_OUT/config" || {
  echo 'error: kernel is missing USB FunctionFS (needed by adbd)' >&2
  exit 1
}
grep -q '^CONFIG_USB_DWC3_APPLE=y$' "$KERNEL_OUT/config" || {
  echo 'error: kernel is missing the Apple USB device controller' >&2
  exit 1
}
grep -q '^CONFIG_SECURITY_SELINUX=y$' "$KERNEL_OUT/config" || {
  echo 'error: Android Recovery kernel must provide SELinux/selinuxfs' >&2
  exit 1
}
grep -q '^CONFIG_DEFAULT_SECURITY_SELINUX=y$' "$KERNEL_OUT/config" || {
  echo 'error: Android Recovery kernel must activate SELinux as its default LSM' >&2
  exit 1
}
! grep -q '^CONFIG_USB_F_MASS_STORAGE=y$' "$KERNEL_OUT/config" || {
  echo 'error: refusing a kernel with USB mass-storage gadget enabled' >&2
  exit 1
}

mkdir -p "$PREBUILT_DIR"
install -m 0644 "$KERNEL_OUT/Image.gz" "$PREBUILT_DIR/Image.gz"
install -m 0644 "$KERNEL_OUT/t8030-n104.dtb" "$PREBUILT_DIR/t8030-n104.dtb"
(
  cd "$PREBUILT_DIR"
  sha256sum Image.gz t8030-n104.dtb >SHA256SUMS
)

[[ -x "$TREE/.repo/repo/repo" ]] || {
  echo "error: LineageOS tree is not initialized at $TREE" >&2
  exit 1
}

cd "$TREE"
export PATH="$TREE/.repo/repo:$PATH"
# shellcheck disable=SC1091
source build/envsetup.sh
if [[ "${RA1NCASTLE_SKIP_LUNCH:-NO}" == YES ]]; then
  # Use only after this product/variant has already been validated with lunch.
  # This avoids re-running the costly Make variable dump on the NTFS HDD.
  export TARGET_PRODUCT=lineage_snowcastle
  export TARGET_RELEASE=cp2a
  export TARGET_BUILD_VARIANT=userdebug
  export TARGET_BUILD_TYPE=release
  export TARGET_BUILD_APPS=
  # envsetup/lunch sets this when building LineageOS. Preserve the same
  # BoardConfig and product configuration without the expensive lunch query.
  export LINEAGE_BUILD=true
  unset INLINE_KERNEL_BUILDING
  # Use the make-mode target path so Soong builds only the requested image
  # instead of indexing every module in this large checkout on the NTFS disk.
  build/soong/soong_ui.bash --make-mode recoveryimage
else
  lunch lineage_snowcastle-cp2a-userdebug
  m recoveryimage
fi

PRODUCT_OUT="$TREE/out/target/product/snowcastle"
[[ -s "$PRODUCT_OUT/recovery.img" ]] || {
  echo "error: build completed without producing $PRODUCT_OUT/recovery.img" >&2
  exit 1
}
sha256sum "$PRODUCT_OUT/recovery.img"
printf 'RAM-only Android Recovery: %s\n' "$PRODUCT_OUT/recovery.img"

"$ROOT/scripts/package-m1n1-recovery.sh"
"$ROOT/scripts/package-android-recovery-payload.sh"
