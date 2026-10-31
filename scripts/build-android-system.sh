#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Android's soong_ui launcher does not quote TOP paths. Re-enter this source
# tree through a no-space bind mount in a private user/mount namespace.
if [[ "$ROOT" == *" "* && "${RA1NCASTLE_BUILD_PATH_ALIAS:-}" != YES ]]; then
  command -v unshare >/dev/null 2>&1 || {
    echo 'error: Android build path contains spaces and unshare is unavailable' >&2
    exit 1
  }
  alias_root="/tmp/ra1ncastle-build-${UID}"
  mkdir -p "$alias_root"
  exec unshare -Urnm bash -c '
    set -euo pipefail
    mount --bind "$1" "$2"
    export RA1NCASTLE_BUILD_PATH_ALIAS=YES
    cd "$2"
    exec "$2/scripts/$3"
  ' _ "$ROOT" "$alias_root" "$(basename "${BASH_SOURCE[0]}")"
fi
TREE="$ROOT/android/lineage-24.0"
DEVICE="$TREE/device/apple/snowcastle"
KERNEL_OUT="$ROOT/out/kernel"
PREBUILT_DIR="$DEVICE/prebuilts/kernel"
PRODUCT_OUT="$TREE/out/target/product/snowcastle"

"$ROOT/scripts/apply-android-patches.sh"

for input in Image.gz t8030-n104.dtb config nvme-core.ko nvme-apple.ko; do
  [[ -s "$KERNEL_OUT/$input" ]] || {
    printf 'error: missing validated kernel input: %s\n' "$KERNEL_OUT/$input" >&2
    exit 1
  }
done

grep -qx 'CONFIG_NVME_CORE=m' "$KERNEL_OUT/config" || {
  echo 'error: NVMe core must remain modular' >&2
  exit 1
}
grep -qx 'CONFIG_NVME_APPLE=m' "$KERNEL_OUT/config" || {
  echo 'error: Apple NVMe must remain modular' >&2
  exit 1
}

mkdir -p "$PREBUILT_DIR"
for input in Image.gz t8030-n104.dtb nvme-core.ko nvme-apple.ko; do
  if ! cmp -s "$KERNEL_OUT/$input" "$PREBUILT_DIR/$input"; then
    install -m 0644 "$KERNEL_OUT/$input" "$PREBUILT_DIR/$input"
  fi
done
(
  cd "$PREBUILT_DIR"
  sha256sum Image.gz t8030-n104.dtb nvme-core.ko nvme-apple.ko >SHA256SUMS
  sha256sum --check SHA256SUMS
)

[[ -x "$TREE/.repo/repo/repo" ]] || {
  printf 'error: LineageOS tree is not initialized at %s\n' "$TREE" >&2
  exit 1
}

cd "$TREE"
export PATH="$TREE/.repo/repo:$PATH"
export TARGET_PRODUCT=ra1ncastle
export TARGET_RELEASE=cp2a
export TARGET_BUILD_VARIANT=userdebug
export TARGET_BUILD_TYPE=release
export TARGET_BUILD_APPS=
export LINEAGE_BUILD=true
export SNOWCASTLE_RAMONLY_RECOVERY=false
unset INLINE_KERNEL_BUILDING
# The normal boot ramdisk must contain/load NVMe before first-stage mount_all;
# system/vendor are built independently and checked against the captured GPT.
build_args=()
if [[ -n "${RA1NCASTLE_BUILD_JOBS:-}" ]]; then
  [[ "$RA1NCASTLE_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || {
    echo 'error: RA1NCASTLE_BUILD_JOBS must be a positive integer' >&2
    exit 1
  }
  build_args+=("-j$RA1NCASTLE_BUILD_JOBS")
fi
build/soong/soong_ui.bash --make-mode "${build_args[@]}" bootimage systemimage vendorimage

for image in boot.img system.img vendor.img; do
  [[ -s "$PRODUCT_OUT/$image" ]] || {
    printf 'error: build completed without producing %s\n' "$PRODUCT_OUT/$image" >&2
    exit 1
  }
done

# Parse the generated first-stage ramdisk tree instead of trusting make vars.
load_list="$PRODUCT_OUT/ramdisk/lib/modules/modules.load"
[[ -s "$load_list" ]] || {
  printf 'error: missing first-stage module list: %s\n' "$load_list" >&2
  exit 1
}
grep -Fxq nvme-core.ko "$load_list" || {
  echo 'error: nvme-core.ko is absent from first-stage module list' >&2
  exit 1
}
grep -Fxq nvme-apple.ko "$load_list" || {
  echo 'error: nvme-apple.ko is absent from first-stage module list' >&2
  exit 1
}
for module in nvme-core.ko nvme-apple.ko; do
  [[ -s "$PRODUCT_OUT/ramdisk/lib/modules/0.0/$module" ]] || {
    printf 'error: first-stage ramdisk is missing %s\n' "$module" >&2
    exit 1
  }
done

system_bytes="$(stat -c %s "$PRODUCT_OUT/system.img")"
vendor_bytes="$(stat -c %s "$PRODUCT_OUT/vendor.img")"
# GPT was captured from the n104 hardware and is documented in
# docs/android-first-boot-plan.md. Refuse oversized raw images before any flash.
(( system_bytes <= 3489660928 )) || {
  printf 'error: system.img is %s bytes; p2 holds 3489660928\n' "$system_bytes" >&2
  exit 1
}
(( vendor_bytes <= 402653184 )) || {
  printf 'error: vendor.img is %s bytes; p3 holds 402653184\n' "$vendor_bytes" >&2
  exit 1
}

printf 'Host build only; no device storage was written.\n'
printf 'boot.img:   %s bytes\n' "$(stat -c %s "$PRODUCT_OUT/boot.img")"
printf 'system.img: %s / 3489660928 bytes\n' "$system_bytes"
printf 'vendor.img: %s / 402653184 bytes\n' "$vendor_bytes"
sha256sum "$PRODUCT_OUT/boot.img" "$PRODUCT_OUT/system.img" "$PRODUCT_OUT/vendor.img"
