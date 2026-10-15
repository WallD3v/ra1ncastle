#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
load_local_profile

need_cmd repo
need_cmd git
need_cmd git-lfs

[[ "$(uname -m)" == x86_64 ]] || die "LineageOS host build is currently scripted for x86_64"

tree="$ROOT/android/lineage-24.0"
available_kib="$(df -Pk "$ROOT" | awk 'NR == 2 {print $4}')"
(( available_kib >= 450 * 1024 * 1024 )) || \
  die "at least 450 GiB free is required before syncing LineageOS"

mkdir -p "$tree"
cd "$tree"

# repo insists on an identity while initializing its manifest checkout. Keep a
# deterministic build-only identity in this process instead of changing the
# user's global Git configuration.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-ra1ncastle builder}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-builder@ra1ncastle.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

if [[ ! -d .repo ]]; then
  repo init \
    -u https://github.com/LineageOS/android.git \
    -b "$SNOWCASTLE_BRANCH" \
    --git-lfs \
    --no-clone-bundle
fi

mkdir -p .repo/local_manifests
manifest=.repo/local_manifests/ra1ncastle.xml
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<manifest>' \
  '  <project path="device/apple/snowcastle"' \
  '           name="LineageOS/android_device_apple_snowcastle"' \
  '           remote="github"' \
  "           revision=\"$SNOWCASTLE_REV\" />" \
  '  <project path="device/mainline/generic"' \
  '           name="LineageOS/android_device_mainline_generic"' \
  '           remote="github"' \
  "           revision=\"$SNOWCASTLE_BRANCH\" />" \
  '</manifest>' >"$manifest.tmp"
mv "$manifest.tmp" "$manifest"

repo sync -c --force-sync --no-clone-bundle --no-tags -j"$(jobs)"
git lfs install --local

actual="$(git -C device/apple/snowcastle rev-parse HEAD)"
[[ "$actual" == "$SNOWCASTLE_REV" ]] || \
  die "upstream Android device-tree revision mismatch: $actual"

printf 'LineageOS tree ready: %s\n' "$tree"
printf 'Next: prepare the patched kernel and private firmware inputs.\n'
