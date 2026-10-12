#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

need_cmd git
need_cmd curl
need_cmd sha256sum

mkdir -p "$SOURCES_DIR" "$DOWNLOADS_DIR"

clone_pinned "$USBLITER8_URL" "$USBLITER8_REV" "$SOURCES_DIR/usbliter8"
clone_pinned "$M1N1_URL" "$M1N1_REV" "$SOURCES_DIR/m1n1"
clone_pinned "$LINUX_URL" "$LINUX_REV" "$SOURCES_DIR/linux"
clone_pinned "$REMOTE_BOOT_URL" "$REMOTE_BOOT_REV" "$SOURCES_DIR/remote_boot"
clone_pinned "$HOOLOCK_DOCS_URL" "$HOOLOCK_DOCS_REV" "$SOURCES_DIR/hoolock-docs-a13"
clone_pinned "$SNOWCASTLE_URL" "$SNOWCASTLE_REV" "$SOURCES_DIR/android_device_apple_snowcastle"

update_submodules_https "$SOURCES_DIR/m1n1"
update_submodules_https "$SOURCES_DIR/remote_boot"

busybox_archive="$DOWNLOADS_DIR/busybox-$BUSYBOX_VERSION.tar.bz2"
if [[ ! -f "$busybox_archive" ]]; then
  curl --fail --location \
    "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2" \
    --output "$busybox_archive"
fi
printf '%s  %s\n' "$BUSYBOX_SHA256" "$busybox_archive" | sha256sum --check --status \
  || die "BusyBox checksum mismatch"

if [[ ! -d "$SOURCES_DIR/busybox-$BUSYBOX_VERSION" ]]; then
  tar -xjf "$busybox_archive" -C "$SOURCES_DIR"
fi

printf 'Pinned sources are ready under %s.\n' "$SOURCES_DIR"
