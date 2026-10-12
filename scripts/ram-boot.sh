#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_ram_only_ack

assert_pinned_checkout "$SOURCES_DIR/remote_boot" "$REMOTE_BOOT_REV"
assert_pinned_checkout "$SOURCES_DIR/usbliter8" "$USBLITER8_REV"

need_cmd irecovery
need_cmd lsusb
need_cmd python3
need_cmd rg
need_cmd sudo

boot_profile="${RA1NCASTLE_BOOT_PROFILE:-ramonly}"
case "$boot_profile" in
  ramonly)
    payload="$OUT_DIR/payload/m1n1-linux-n104.macho"
    boot_out="$OUT_DIR/bootchain"
    ;;
  nvme-disabled)
    payload="$OUT_DIR/payload-nvme-disabled/m1n1-linux-n104-nvme-disabled.macho"
    boot_out="$OUT_DIR/bootchain-nvme-disabled"
    ;;
  nvme-delayed)
    payload="$OUT_DIR/payload-nvme-delayed/m1n1-linux-n104-nvme-delayed.macho"
    boot_out="$OUT_DIR/bootchain-nvme-delayed"
    ;;
  storage-probe)
    require_internal_storage_ack
    payload="$OUT_DIR/payload-storage-probe/m1n1-linux-n104-storage-probe.macho"
    boot_out="$OUT_DIR/bootchain-storage-probe"
    ;;
  *)
    die "unknown RA1NCASTLE_BOOT_PROFILE: $boot_profile"
    ;;
esac
raw_iboot="$SOURCES_DIR/remote_boot/cache/iBoot_n104ap_iPhone12,1_pacsafe.raw"
restore_dt="$SOURCES_DIR/remote_boot/cache/RestoreDeviceTree_n104ap_iPhone12,1.img4"
empty_tc="$SOURCES_DIR/remote_boot/empty_trustcache.bin"
im4m="$SOURCES_DIR/remote_boot/im4m/0x8015.im4m"
usbliter8ctl="$SOURCES_DIR/usbliter8/usbliter8ctl"
ipsw_bin="${IPSW:-$OUT_DIR/host-tools/ipsw}"
restore_tc="$boot_out/RestoreTrustCache_n104ap_iPhone12,1.img4"
restore_rkrn="$boot_out/RestoreKernelCache_n104ap_iPhone12,1.img4"

for artifact in \
  "$payload" "$raw_iboot" "$restore_dt" "$empty_tc" "$im4m" \
  "$usbliter8ctl" "$ipsw_bin"
do
  [[ -s "$artifact" ]] || die "missing boot artifact: $artifact; run scripts/prepare-bootchain.sh"
done

"$PROJECT_ROOT/scripts/verify-artifacts.sh"
if [[ "$boot_profile" == nvme-disabled ]]; then
  (
    cd "$OUT_DIR/payload-nvme-disabled"
    sha256sum --check SHA256SUMS
  )
  [[ "$(fdtget "$OUT_DIR/payload-nvme-disabled/t8030-n104-nvme-disabled.dtb" \
      /soc/nvme@27acc0000 status)" == disabled ]] || \
    die 'NVMe-disabled control DTB does not disable the T8030 NVMe node'
  printf 'Using RAM-only NVMe-disabled A/B control payload.\n'
fi
if [[ "$boot_profile" == nvme-delayed ]]; then
  (
    cd "$OUT_DIR/payload-nvme-delayed"
    sha256sum --check SHA256SUMS
  )
  delay_ms="$(cat "$OUT_DIR/payload-nvme-delayed/probe-delay-ms.txt")"
  [[ "$(fdtget -t i "$OUT_DIR/payload-nvme-delayed/t8030-n104-nvme-delayed.dtb" \
      /soc/nvme@27acc0000 apple,probe-delay-ms)" == "$delay_ms" ]] || \
    die 'NVMe-delayed debug DTB has an invalid probe delay'
  printf 'Using RAM-only NVMe-delayed debug payload (%s ms).\n' "$delay_ms"
fi
if [[ "$boot_profile" == storage-probe ]]; then
  (
    cd "$OUT_DIR/payload-storage-probe"
    sha256sum --check SHA256SUMS
  )
  strings "$payload" | rg 'published read-only NVMe LBA0/LBA5 probe' >/dev/null || \
    die 'storage-probe marker is missing from payload'
  printf 'Using read-only m1n1 storage probe; Linux still has Apple NVMe disabled.\n'
fi

# Create the two volatile-upload containers on the host. Neither operation
# talks to the phone or contains a storage image.
mkdir -p "$boot_out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$ipsw_bin" img4 create \
  --input "$empty_tc" --type rtsc --im4m "$im4m" \
  --output "$tmp/RestoreTrustCache.img4"
"$ipsw_bin" img4 create \
  --input "$payload" --type rkrn --compress none --im4m "$im4m" \
  --output "$tmp/RestoreKernelCache.img4"
install -m644 "$tmp/RestoreTrustCache.img4" "$restore_tc"
install -m644 "$tmp/RestoreKernelCache.img4" "$restore_rkrn"
(
  cd "$boot_out"
  sha256sum \
    RestoreTrustCache_n104ap_iPhone12,1.img4 \
    RestoreKernelCache_n104ap_iPhone12,1.img4 >SHA256SUMS
)

query_device() {
  irecovery -q 2>/dev/null || true
}

wait_for_recovery() {
  local attempt info
  for attempt in $(seq 1 45); do
    info="$(query_device)"
    if printf '%s\n' "$info" | rg -qi '^MODE:[[:space:]]*Recovery' && \
       printf '%s\n' "$info" | rg -qi '^CPID:[[:space:]]*(0x)?8030' && \
       printf '%s\n' "$info" | rg -qi '^MODEL:[[:space:]]*n104ap'; then
      printf '%s\n' "$info"
      return 0
    fi
    sleep 1
  done
  return 1
}

current="$(query_device)"
if printf '%s\n' "$current" | rg -qi '^MODE:[[:space:]]*DFU'; then
  "$PROJECT_ROOT/scripts/check-pwnd-dfu.sh"
  printf 'Uploading PAC-safe raw iBoot with usbliter8ctl...\n'

  # The final DFU_ABORT commonly reports ENODEV because CUSTOM_BOOT has
  # already caused a successful USB disconnect. Recovery enumeration below,
  # rather than that final libusb status, is the authoritative success test.
  set +e
  sudo python3 "$usbliter8ctl" boot "$raw_iboot"
  raw_status="$?"
  set -e
  printf 'usbliter8ctl exit status: %s (ENODEV after CUSTOM_BOOT is expected)\n' "$raw_status"

  wait_for_recovery >/dev/null || die 'patched iBoot did not enumerate in Recovery mode within 45 seconds'
elif printf '%s\n' "$current" | rg -qi '^MODE:[[:space:]]*Recovery'; then
  [[ "${RESUME_PATCHED_RECOVERY:-NO}" == YES ]] || \
    die 'device is already in Recovery; set RESUME_PATCHED_RECOVERY=YES only if this is the patched iBoot from the immediately preceding run'
  printf 'Resuming the explicitly acknowledged patched-Recovery session.\n'
else
  die 'expected PWND DFU or an explicitly acknowledged patched Recovery device'
fi

printf 'Patched Recovery is ready; sending volatile restore objects.\n'
wait_for_recovery

irecovery -f "$restore_dt"
irecovery -c devicetree
irecovery -f "$restore_tc"
irecovery -c firmware
irecovery -f "$restore_rkrn"
irecovery -c bootx

printf 'bootx sent. Waiting for Linux USB ACM/NCM enumeration is now safe.\n'
