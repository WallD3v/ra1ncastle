#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCES_DIR="$PROJECT_ROOT/sources"
BUILD_DIR="$PROJECT_ROOT/build"
OUT_DIR="$PROJECT_ROOT/out"
DOWNLOADS_DIR="$PROJECT_ROOT/downloads"
LOGS_DIR="$PROJECT_ROOT/logs"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/config/sources.env"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

proxy_env_args() {
  local name
  for name in \
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy no_proxy
  do
    if [[ -v "$name" ]]; then
      printf '%s=%s\0' "$name" "${!name}"
    fi
  done
}

load_local_profile() {
  local profile="$PROJECT_ROOT/config/local.env"
  [[ -f "$profile" ]] || die "missing config/local.env; copy config/local.env.example and fill it after the requested hardware/host answers are recorded"
  # shellcheck source=/dev/null
  source "$profile"

  [[ -n "${RP2350_BOARD:-}" ]] || die "RP2350_BOARD is empty"
  [[ -n "${UBUNTU_VERSION:-}" ]] || die "UBUNTU_VERSION is empty"
  case "${HOST_ARCH:-}" in
    x86_64|aarch64|arm64) ;;
    *) die "HOST_ARCH must be x86_64, aarch64, or arm64" ;;
  esac
  [[ -n "${IOS_VERSION:-}" ]] || die "IOS_VERSION is empty"
  [[ -n "${SPARE_IPHONE_AVAILABLE:-}" ]] || die "SPARE_IPHONE_AVAILABLE is unanswered"
  [[ -n "${BACKUP_STATUS:-}" ]] || die "BACKUP_STATUS is unanswered"
}

require_ram_only_ack() {
  load_local_profile
  [[ "${I_ACCEPT_RAM_ONLY:-NO}" == YES ]] || die "set I_ACCEPT_RAM_ONLY=YES only after reviewing docs/safety.md"
}

require_internal_storage_ack() {
  load_local_profile
  [[ "${I_ACCEPT_INTERNAL_STORAGE_RISK:-NO}" == YES ]] || \
    die "set I_ACCEPT_INTERNAL_STORAGE_RISK=YES only after accepting the internal-storage recovery and data-loss risk"
}

require_android_write_ack() {
  require_internal_storage_ack
  [[ "${I_ACCEPT_ANDROID_WRITE_PROFILE:-NO}" == YES ]] || \
    die "set I_ACCEPT_ANDROID_WRITE_PROFILE=YES only after reviewing the android-write profile in docs/safety.md"
}

# Immutable n104 Android write contract: inclusive 4 KiB LBAs from the GPT
# captured in docs/apfs-partition-plan.md. These values are copied into the
# android-write FDT and independently re-checked before USB upload.
ANDROID_WRITE_NSID=1
ANDROID_WRITE_LBA_START=14052096
ANDROID_WRITE_LBA_END=15624993

jobs() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'
}

host_cross_prefix() {
  case "$(uname -m)" in
    aarch64|arm64) printf '%s' "" ;;
    x86_64) printf '%s' "aarch64-linux-gnu-" ;;
    *) die "unsupported build-host architecture: $(uname -m)" ;;
  esac
}

assert_pinned_checkout() {
  local dir="$1" expected="$2"
  [[ -d "$dir/.git" ]] || die "not a git checkout: $dir"
  local actual
  actual="$(git -C "$dir" rev-parse HEAD)"
  [[ "$actual" == "$expected" ]] || die "$dir is at $actual, expected $expected"
}

clone_pinned() {
  local url="$1" rev="$2" dir="$3"
  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$(dirname "$dir")"
    git clone --filter=blob:none --no-checkout "$url" "$dir"
  elif [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    die "refusing to replace local changes in $dir"
  fi
  git -C "$dir" fetch --depth=1 origin "$rev"
  git -C "$dir" checkout --detach "$rev"
}

update_submodules_https() {
  local dir="$1"
  git -C "$dir" submodule sync --recursive
  git -C "$dir" \
    -c url.https://github.com/.insteadOf=git@github.com: \
    -c url.https://github.com/.insteadOf=ssh://git@github.com/ \
    submodule update --init --recursive --depth=1
}
