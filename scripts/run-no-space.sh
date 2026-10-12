#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"
shift || true

case "$target" in
  scripts/prepare-bootchain.sh|scripts/ram-boot.sh) ;;
  *)
    printf 'error: unsupported no-space target: %s\n' "$target" >&2
    exit 2
    ;;
esac

alias_root="${RA1NCASTLE_REMOTE_ALIAS:-/tmp/ra1ncastle-remote-$(id -u)}"
mkdir -p "$alias_root"

if mountpoint -q "$alias_root"; then
  printf 'error: remote-boot alias is already mounted: %s\n' "$alias_root" >&2
  exit 1
fi

cleanup() {
  sudo umount "$alias_root" || true
  rmdir "$alias_root" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

printf 'Temporarily bind-mounting the workspace at %s for remote_boot.\n' "$alias_root"
sudo mount --bind "$ROOT" "$alias_root"
env RA1NCASTLE_NO_SPACE_ACTIVE=1 "$alias_root/$target" "$@"
