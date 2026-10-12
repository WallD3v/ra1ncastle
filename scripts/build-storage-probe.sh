#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack
require_internal_storage_ack

need_cmd cargo
need_cmd file
need_cmd git
need_cmd make
need_cmd sha256sum

src="$SOURCES_DIR/m1n1"
patch="$PROJECT_ROOT/patches/m1n1/0001-n104-read-only-nvme-gpt-probe.patch"
diagnostic_patch="$PROJECT_ROOT/patches/m1n1/0002-nvme-init-stage-diagnostics.patch"
t8030_sart_patch="$PROJECT_ROOT/patches/m1n1/0003-t8030-sart-compat.patch"
sart_diagnostic_patch="$PROJECT_ROOT/patches/m1n1/0004-sart-init-stage-diagnostics.patch"
static_buffer_patch="$PROJECT_ROOT/patches/m1n1/0005-static-nvme-probe-buffer.patch"
sart_version_patch="$PROJECT_ROOT/patches/m1n1/0006-report-unknown-sart-version.patch"
sart1_alias_patch="$PROJECT_ROOT/patches/m1n1/0007-map-adt-sart1-to-t8020-layout.patch"
nvme_completion_diagnostic_patch="$PROJECT_ROOT/patches/m1n1/0008-nvme-command-completion-diagnostics.patch"
nvme_settle_patch="$PROJECT_ROOT/patches/m1n1/0009-t8030-nvme-controller-settle-delay.patch"
nvme_sart_map_patch="$PROJECT_ROOT/patches/m1n1/0010-map-nvme-queues-through-sart.patch"
sart_readback_patch="$PROJECT_ROOT/patches/m1n1/0011-log-sart-entry-readback.patch"
iboot_adminq_patch="$PROJECT_ROOT/patches/m1n1/0012-reuse-iboot-admin-queue-aperture.patch"
t8030_nvmmu_patch="$PROJECT_ROOT/patches/m1n1/0013-t8030-linear-sq-nvmmu-probe.patch"
tcb_sart_rounding_patch="$PROJECT_ROOT/patches/m1n1/0014-round-nvmmu-tcb-sart-mapping.patch"
t8030_nvmmu_depth_patch="$PROJECT_ROOT/patches/m1n1/0015-t8030-native-nvmmu-depth.patch"
t8030_coastguard_patch="$PROJECT_ROOT/patches/m1n1/0016-t8030-standard-sq-coastguard.patch"
t8030_cid_patch="$PROJECT_ROOT/patches/m1n1/0017-t8030-zero-based-command-id.patch"
active_ns_patch="$PROJECT_ROOT/patches/m1n1/0018-identify-active-namespaces.patch"
nsid_fallback_patch="$PROJECT_ROOT/patches/m1n1/0019-coastguard-directions-and-nsid-fallback.patch"
aligned_io_patch="$PROJECT_ROOT/patches/m1n1/0020-use-16k-aligned-nvme-io-bounce.patch"
iosqe64_patch="$PROJECT_ROOT/patches/m1n1/0021-t8030-use-standard-64-byte-iosqes.patch"
worktree="${RA1NCASTLE_STORAGE_WORKTREE:-/tmp/ra1ncastle-m1n1-storage-$(id -u)}"
probe_m1n1_out="$OUT_DIR/m1n1-storage-probe"
probe_payload_out="$OUT_DIR/payload-storage-probe"

assert_pinned_checkout "$src" "$M1N1_REV"
[[ -s "$patch" ]] || die "missing storage-probe m1n1 patch"
[[ -s "$diagnostic_patch" ]] || die "missing storage-probe diagnostic patch"
[[ -s "$t8030_sart_patch" ]] || die "missing T8030 SART compatibility patch"
[[ -s "$sart_diagnostic_patch" ]] || die "missing SART diagnostic patch"
[[ -s "$static_buffer_patch" ]] || die "missing static probe-buffer patch"
[[ -s "$sart_version_patch" ]] || die "missing SART version-report patch"
[[ -s "$sart1_alias_patch" ]] || die "missing ADT SART1 compatibility patch"
[[ -s "$nvme_completion_diagnostic_patch" ]] || die "missing NVMe completion diagnostic patch"
[[ -s "$nvme_settle_patch" ]] || die "missing T8030 NVMe settle-delay patch"
[[ -s "$nvme_sart_map_patch" ]] || die "missing NVMe queue SART mapping patch"
[[ -s "$sart_readback_patch" ]] || die "missing SART entry readback patch"
[[ -s "$iboot_adminq_patch" ]] || die "missing iBoot admin-queue aperture patch"
[[ -s "$t8030_nvmmu_patch" ]] || die "missing T8030 linear-SQ/NVMMU probe patch"
[[ -s "$tcb_sart_rounding_patch" ]] || die "missing NVMMU TCB SART rounding patch"
[[ -s "$t8030_nvmmu_depth_patch" ]] || die "missing T8030 native NVMMU depth patch"
[[ -s "$t8030_coastguard_patch" ]] || die "missing T8030 standard-SQ CoastGuard patch"
[[ -s "$t8030_cid_patch" ]] || die "missing T8030 zero-based command-ID patch"
[[ -s "$active_ns_patch" ]] || die "missing active namespace identification patch"
[[ -s "$nsid_fallback_patch" ]] || die "missing CoastGuard direction/NSID fallback patch"
[[ -s "$aligned_io_patch" ]] || die "missing 16K-aligned NVMe I/O bounce patch"
[[ -s "$iosqe64_patch" ]] || die "missing T8030 64-byte IOSQE patch"
[[ ! -e "$worktree" ]] || die "temporary worktree already exists: $worktree"

cleanup() {
  git -C "$src" worktree remove --force "$worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

git -C "$src" worktree add --detach "$worktree" "$M1N1_REV"
git -C "$worktree" submodule update --init --recursive
git -C "$worktree" apply "$patch"
git -C "$worktree" apply "$diagnostic_patch"
git -C "$worktree" apply "$t8030_sart_patch"
git -C "$worktree" apply "$sart_diagnostic_patch"
git -C "$worktree" apply "$static_buffer_patch"
git -C "$worktree" apply "$sart_version_patch"
git -C "$worktree" apply "$sart1_alias_patch"
git -C "$worktree" apply "$nvme_completion_diagnostic_patch"
git -C "$worktree" apply "$nvme_settle_patch"
git -C "$worktree" apply "$nvme_sart_map_patch"
git -C "$worktree" apply "$sart_readback_patch"
git -C "$worktree" apply "$iboot_adminq_patch"
git -C "$worktree" apply "$t8030_nvmmu_patch"
git -C "$worktree" apply "$tcb_sart_rounding_patch"
git -C "$worktree" apply "$t8030_nvmmu_depth_patch"
git -C "$worktree" apply "$t8030_coastguard_patch"
git -C "$worktree" apply "$t8030_cid_patch"
git -C "$worktree" apply "$active_ns_patch"
git -C "$worktree" apply "$nsid_fallback_patch"
git -C "$worktree" apply "$aligned_io_patch"
git -C "$worktree" apply "$iosqe64_patch"
git -C "$worktree" diff --check

make_args=(-j"$(jobs)" CHAINLOADING=1)
if [[ "$(uname -m)" == aarch64 || "$(uname -m)" == arm64 ]]; then
  make_args+=(ARCH=)
fi
make -C "$worktree" "${make_args[@]}"

mkdir -p "$probe_m1n1_out" "$probe_payload_out"
install -m644 "$worktree/build/m1n1-idevice.macho" "$probe_m1n1_out/"
install -m644 "$worktree/build/monitor-stub.macho" "$probe_m1n1_out/"
install -m644 "$worktree/build/m1n1.bin" "$probe_m1n1_out/"

strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'published read-only NVMe LBA0/LBA5 probe' >/dev/null || \
  die "storage-probe marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'exec-timeout:op=' >/dev/null || \
  die "NVMe completion diagnostic marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'waiting 200 ms for T8030 controller to settle' >/dev/null || \
  die "T8030 NVMe settle-delay marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'queue DMA ASQ=' >/dev/null || \
  die "NVMe queue SART mapping marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'sart: mapped entry' >/dev/null || \
  die "SART entry readback marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'inherited iBoot AQA=' >/dev/null || \
  die "iBoot admin-queue aperture marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'T8030 selecting standard-SQ/CoastGuard mode' >/dev/null || \
  die "T8030 standard-SQ/CoastGuard marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'active NVMe namespace' >/dev/null || \
  die "active namespace identification marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'probing NSID 1..16' >/dev/null || \
  die "NSID fallback marker is missing from m1n1"
strings "$probe_m1n1_out/m1n1-idevice.macho" | \
  grep 'with 64-byte IOSQEs' >/dev/null || \
  die "T8030 64-byte IOSQE marker is missing from m1n1"

bootargs='console=tty0 console=ttySAC0,115200n8 earlycon keep_bootcon loglevel=8 ignore_loglevel printk.time=1 rdinit=/init panic=-1 clk_ignore_unused pd_ignore_unused'
{
  cat "$probe_m1n1_out/m1n1-idevice.macho"
  printf 'chosen.bootargs=%s\n' "$bootargs"
  cat "$OUT_DIR/kernel/t8030-n104.dtb"
  cat "$OUT_DIR/kernel/Image.gz"
  cat "$OUT_DIR/initramfs/initramfs.cpio.gz"
} >"$probe_payload_out/m1n1-linux-n104-storage-probe.macho"

printf '%s\n' "$bootargs" >"$probe_payload_out/bootargs.txt"
(
  cd "$probe_m1n1_out"
  sha256sum m1n1-idevice.macho monitor-stub.macho m1n1.bin >SHA256SUMS
)
(
  cd "$probe_payload_out"
  sha256sum m1n1-linux-n104-storage-probe.macho bootargs.txt >SHA256SUMS
)

(cd "$probe_m1n1_out" && sha256sum --check SHA256SUMS)
(cd "$probe_payload_out" && sha256sum --check SHA256SUMS)
file "$probe_payload_out/m1n1-linux-n104-storage-probe.macho" | \
  grep -q 'Mach-O 64-bit arm64 executable'

printf 'Built read-only storage probe: %s bytes\n' \
  "$(stat -c %s "$probe_payload_out/m1n1-linux-n104-storage-probe.macho")"
