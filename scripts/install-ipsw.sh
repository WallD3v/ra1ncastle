#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
load_local_profile

case "$(uname -m)" in
  x86_64) asset_arch=x86_64 ;;
  aarch64|arm64) asset_arch=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

need_cmd curl
need_cmd tar

mkdir -p "$DOWNLOADS_DIR/ipsw-$IPSW_VERSION"
archive="$DOWNLOADS_DIR/ipsw_${IPSW_VERSION}_linux_${asset_arch}.tar.gz"
url="https://github.com/blacktop/ipsw/releases/download/v${IPSW_VERSION}/ipsw_${IPSW_VERSION}_linux_${asset_arch}.tar.gz"

curl --fail --location "$url" --output "$archive"
tar -xzf "$archive" -C "$DOWNLOADS_DIR/ipsw-$IPSW_VERSION"

binary="$(find "$DOWNLOADS_DIR/ipsw-$IPSW_VERSION" -maxdepth 2 -type f -name ipsw -print -quit)"
[[ -n "$binary" ]] || die "ipsw binary not found in release archive"
install -Dm755 "$binary" "$PROJECT_ROOT/out/host-tools/ipsw"
"$PROJECT_ROOT/out/host-tools/ipsw" version

