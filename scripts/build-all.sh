#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/build-m1n1.sh"
"$ROOT/scripts/build-kernel.sh"
"$ROOT/scripts/build-initramfs.sh"
"$ROOT/scripts/package-payload.sh"
"$ROOT/scripts/verify-artifacts.sh"
