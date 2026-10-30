#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-scripts/build-all.sh}"

if [[ "$#" -gt 1 ]]; then
  printf 'usage: %s [scripts/build-all.sh|scripts/build-kernel.sh]\n' \
    "${BASH_SOURCE[0]}" >&2
  exit 2
fi

case "$target" in
  scripts/build-all.sh|scripts/build-kernel.sh) ;;
  *)
    printf 'error: unsupported native build target: %s\n' "$target" >&2
    exit 2
    ;;
esac

if [[ "$ROOT" != *[' ':]* ]]; then
  exec "$ROOT/$target"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: missing command: %s\n' "$1" >&2
    exit 1
  }
}

need_cmd mountpoint
need_cmd sudo

alias_root="${RA1NCASTLE_BUILD_ALIAS:-/tmp/ra1ncastle-build-$(id -u)}"
mkdir -p "$alias_root"

if mountpoint -q "$alias_root"; then
  printf 'error: build alias is already mounted: %s\n' "$alias_root" >&2
  exit 1
fi

cleanup() {
  sudo umount "$alias_root" || true
  rmdir "$alias_root" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

printf 'Temporarily bind-mounting the workspace at %s for the old kernel build system.\n' "$alias_root"
sudo mount --bind "$ROOT" "$alias_root"
"$alias_root/$target"
