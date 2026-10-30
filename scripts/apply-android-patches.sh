#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$ROOT/android/lineage-24.0/device/apple/snowcastle"
PATCH="$ROOT/patches/android/0001-n104-system-nvme-modules.patch"

[[ -d "$ROOT/android/lineage-24.0/.repo" ]] || {
  printf 'error: Android source tree not found: %s\n' "$ROOT/android/lineage-24.0" >&2
  exit 1
}
[[ -f "$PATCH" ]] || {
  printf 'error: Android patch missing: %s\n' "$PATCH" >&2
  exit 1
}

if grep -Fq 'SNOWCASTLE_NVME_MODULES := nvme-core.ko nvme-apple.ko' "$TREE/BoardConfig.mk" \
  && grep -Fq 'PRODUCT_PACKAGES += modules.load.normal.android' "$TREE/device.mk" \
  && grep -Fq 'name: "modules.load.normal.android"' "$TREE/configs/modprobe/Android.bp" \
  && cmp -s "$TREE/configs/modprobe/modules.load.normal.android" <(printf '%s\n' nvme-core.ko nvme-apple.ko); then
  printf 'Android patch already applied: %s\n' "$(basename "$PATCH")"
elif git -C "$TREE" apply --check "$PATCH" >/dev/null 2>&1; then
  git -C "$TREE" apply "$PATCH"
  printf 'Applied Android patch: %s\n' "$(basename "$PATCH")"
else
  printf 'error: Android patch does not apply cleanly; inspect %s\n' "$TREE" >&2
  exit 1
fi
