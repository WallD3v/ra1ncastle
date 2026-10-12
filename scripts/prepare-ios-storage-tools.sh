#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="$ROOT/artifacts/ios-support-tools/hoolock-support-iphoneos.zip"
OUT="$ROOT/out/ios-support-tools"

archive_sha='ca44c45d85cf422da69ed9c247edc00b04446795fecdf0108ea87b55967d193c'
gdisk_sha='18c0325002759d94b516b728c91b8e3ce35a2288b701f0ebc5fc47820cd1ceea'
resize_sha='57edbca900f8cceba63e9023fa3fd1732775a8f2d5b236055fed71030800f503'

[[ -f "$ARCHIVE" ]] || {
  printf 'error: missing %s\n' "$ARCHIVE" >&2
  exit 1
}

printf '%s  %s\n' "$archive_sha" "$ARCHIVE" | sha256sum --check --status || {
  printf 'error: iOS support-tools archive checksum mismatch\n' >&2
  exit 1
}

mkdir -p "$OUT"
unzip -oq "$ARCHIVE" -d "$OUT"
chmod 0755 "$OUT/gdisk" "$OUT/resize_apfs"

printf '%s  %s\n' "$gdisk_sha" "$OUT/gdisk" | sha256sum --check --status || {
  printf 'error: gdisk checksum mismatch\n' >&2
  exit 1
}
printf '%s  %s\n' "$resize_sha" "$OUT/resize_apfs" | sha256sum --check --status || {
  printf 'error: resize_apfs checksum mismatch\n' >&2
  exit 1
}

file "$OUT/gdisk" "$OUT/resize_apfs"
sha256sum "$ARCHIVE" "$OUT/gdisk" "$OUT/resize_apfs"
printf 'Prepared verified iOS tools in %s (no device access performed).\n' "$OUT"
