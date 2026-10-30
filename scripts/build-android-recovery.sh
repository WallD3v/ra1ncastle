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
KERNEL_OUT="$ROOT/out/kernel"
PREBUILT_DIR="$TREE/device/apple/snowcastle/prebuilts/kernel"
KERNEL_SOURCE_LINK="$TREE/device/apple/snowcastle/kernel-source"
KERNEL_SOURCE_TREE="$ROOT/sources/linux"

"$ROOT/scripts/apply-android-patches.sh"

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

for input in Image.gz t8030-n104.dtb config nvme-core.ko nvme-apple.ko; do
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
install -m 0644 "$KERNEL_OUT/nvme-core.ko" "$PREBUILT_DIR/nvme-core.ko"
install -m 0644 "$KERNEL_OUT/nvme-apple.ko" "$PREBUILT_DIR/nvme-apple.ko"
(
  cd "$PREBUILT_DIR"
  sha256sum Image.gz t8030-n104.dtb nvme-core.ko nvme-apple.ko >SHA256SUMS
)

[[ -x "$TREE/.repo/repo/repo" ]] || {
  echo "error: LineageOS tree is not initialized at $TREE" >&2
  exit 1
}

# Register a distinct ra1ncastle product while preserving the upstream device
# target. Android requires the product name and product makefile basename to
# match; snowcastle remains only the hardware/device codename.
DEVICE_DIR="$TREE/device/apple/snowcastle"
PRODUCT_MK="$DEVICE_DIR/lineage_snowcastle.mk"
RA1NCASTLE_PRODUCT_MK="$DEVICE_DIR/ra1ncastle.mk"
PRODUCTS_MK="$DEVICE_DIR/AndroidProducts.mk"
python3 - "$PRODUCT_MK" "$RA1NCASTLE_PRODUCT_MK" "$PRODUCTS_MK" <<'PY'
from pathlib import Path
import sys

base_path, branded_path, products_path = map(Path, sys.argv[1:])
base = base_path.read_text()
base = base.replace("PRODUCT_NAME := ra1ncastle", "PRODUCT_NAME := lineage_snowcastle")
base = base.replace("PRODUCT_MODEL := Ra1ncastle", "PRODUCT_MODEL := Snowcastle")
base_path.write_text(base)

branded = base.replace("PRODUCT_NAME := lineage_snowcastle", "PRODUCT_NAME := ra1ncastle")
branded = branded.replace("PRODUCT_MODEL := Snowcastle", "PRODUCT_MODEL := Ra1ncastle")
branded += """

# Present the ra1ncastle project name in Recovery while keeping PRODUCT_DEVICE
# bound to the upstream snowcastle hardware tree for device-specific build logic.
PRODUCT_SYSTEM_PROPERTIES += \\
    ro.lineage.device=ra1ncastle \\
    ro.product.system.device=ra1ncastle
"""
branded_path.write_text(branded)

products = products_path.read_text()
makefile_entry = "    $(LOCAL_DIR)/ra1ncastle.mk \\\n"
if makefile_entry not in products:
    products = products.replace(
        "PRODUCT_MAKEFILES := \\\n",
        "PRODUCT_MAKEFILES := \\\n" + makefile_entry,
        1,
    )
lunch_entry = "    $(eval COMMON_LUNCH_CHOICES += ra1ncastle-$(build_type)) \\\n"
if lunch_entry not in products:
    products = products.replace(
        "$(foreach build_type, user userdebug eng, \\\n",
        "$(foreach build_type, user userdebug eng, \\\n" + lunch_entry,
        1,
    )
if "$(LOCAL_DIR)/ra1ncastle.mk" not in products or lunch_entry not in products:
    raise SystemExit("failed to register the ra1ncastle Android product")
products_path.write_text(products)
PY

cd "$TREE"
export PATH="$TREE/.repo/repo:$PATH"
# shellcheck disable=SC1091
source build/envsetup.sh
if [[ "${RA1NCASTLE_SKIP_LUNCH:-NO}" == YES ]]; then
  # Use only after this product/variant has already been validated with lunch.
  # This avoids re-running the costly Make variable dump on the NTFS HDD.
  export TARGET_PRODUCT=ra1ncastle
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
  lunch ra1ncastle-cp2a-userdebug
  m recoveryimage
fi

PRODUCT_OUT="$TREE/out/target/product/snowcastle"
[[ -s "$PRODUCT_OUT/recovery.img" ]] || {
  echo "error: build completed without producing $PRODUCT_OUT/recovery.img" >&2
  exit 1
}
assert_last_property() {
  local prop_file="$1" prop_name="$2" expected="$3" actual
  actual="$(awk -F= -v key="$prop_name" \
    '$1 == key { value = substr($0, index($0, "=") + 1) } END { print value }' \
    "$prop_file")"
  [[ "$actual" == "$expected" ]] || {
    echo "error: $prop_name in $prop_file is '$actual', expected '$expected'" >&2
    exit 1
  }
}
for prop_file in "$PRODUCT_OUT/system/build.prop" \
    "$PRODUCT_OUT/recovery/root/prop.default"; do
  [[ -s "$prop_file" ]] || {
    echo "error: missing generated Recovery property file: $prop_file" >&2
    exit 1
  }
  assert_last_property "$prop_file" ro.lineage.device ra1ncastle
  assert_last_property "$prop_file" ro.product.system.device ra1ncastle
done
sha256sum "$PRODUCT_OUT/recovery.img"
printf 'RAM-only Android Recovery: %s\n' "$PRODUCT_OUT/recovery.img"

"$ROOT/scripts/package-m1n1-recovery.sh"
"$ROOT/scripts/package-android-recovery-payload.sh"
