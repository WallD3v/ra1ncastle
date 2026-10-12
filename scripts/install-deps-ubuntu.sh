#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
load_local_profile

[[ "$(. /etc/os-release; printf '%s' "$ID")" == ubuntu ]] || die "this installer is intentionally Ubuntu-only"

# Keep unrelated or stale third-party repositories from breaking the
# reproducible build-host bootstrap. This does not edit the host's APT config.
ubuntu_sources=/etc/apt/sources.list.d/ubuntu.sources
[[ -f "$ubuntu_sources" ]] || die "official Ubuntu deb822 source not found: $ubuntu_sources"
apt_source_args=(
  -o "Dir::Etc::sourcelist=$ubuntu_sources"
  -o "Dir::Etc::sourceparts=-"
)

sudo apt-get "${apt_source_args[@]}" update
sudo apt-get "${apt_source_args[@]}" install -y \
  autoconf automake bc binutils-aarch64-linux-gnu bison build-essential \
  ca-certificates clang cmake cpio curl device-tree-compiler fakeroot flex \
  gcc-aarch64-linux-gnu git irecovery libelf-dev libirecovery-1.0-dev \
  libssl-dev libtool-bin libusb-1.0-0 libusb-1.0-0-dev lld llvm make \
  ninja-build picocom pkg-config python3 python3-pip python3-usb python3-venv ripgrep \
  rustup usbutils xxd xz-utils zstd

rustup toolchain install stable
rustup target add aarch64-unknown-none-softfloat

printf 'Dependencies installed. Install ipsw %s with scripts/install-ipsw.sh.\n' "$IPSW_VERSION"
