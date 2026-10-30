# Storage safety boundaries

## Read-only kernel storage bring-up profile

This milestone uploads executable images over DFU/Recovery and runs its root
filesystem from RAM. It may enumerate internal NVMe, but must not write the
iPhone's NAND, APFS container, GPT, NVRAM or boot environment.

Enforced controls:

- the kernel is built with `CONFIG_NVME_APPLE=y`, using a T8030-specific path
  that rejects every non-read namespace command;
- the initramfs exposes no USB mass-storage function;
- the initramfs continuously marks every visible block device read-only;
- the boot wrapper uses only `usbliter8ctl boot`, `irecovery -f`,
  `devicetree`, `firmware`, and `bootx`;
- the default boot profile contains no mount, filesystem creation,
  partitioning, or flashing operation;
- source revisions are pinned and checked before the USB boot step.

Do not run the storage tutorials from Hoolock documentation. In particular, do
not run `resize_apfs`, `gdisk`, `dd`, filesystem creation, `saveenv`, or an IPSW
restore as part of this milestone.

The phone still needs a forced reboot/DFU cycle if an experimental handoff
hangs. A backup remains required as a risk-control measure even though this
project does not intentionally access storage.

## Read-only m1n1 storage-probe profile

The separately selected `storage-probe` profile uses patched m1n1 code that
exports a read function and no write function, to capture only LBA 0 through
LBA 5. This covers the protective MBR, primary GPT header, and the initial partition-entry
array. m1n1 then shuts the ANS controller down before Linux starts and publishes
the 24 KiB snapshot as `/chosen/ra1ncastle,nvme-lba0-lba5` in the Linux FDT.

The profile is opt-in with `RA1NCASTLE_BOOT_PROFILE=storage-probe`, requires
`I_ACCEPT_INTERNAL_STORAGE_RISK=YES`, and is packaged separately from the
main payload. It does not mount APFS; the kernel-side block device remains
guarded by the driver and initramfs read-only controls.

The storage probe is discovery only. It does not authorize APFS writes, GPT
changes, filesystem creation, partition resizing, or flashing.

## Separate Android-write profile

`scripts/build-android-write-profile.sh` creates a distinct artifact below
`out/payload-android-write`; it never alters the default read-only payload.
Its copied DTB carries this immutable contract on `/soc/nvme@27acc0000`:

- `ra1ncastle,write-allow-nsid = <1>`;
- `ra1ncastle,write-allow-lba-ranges = <0 14052096 0 15624993>`.

The latter is a single inclusive u64 start/end pair encoded as four FDT cells,
covering only contiguous Android p2-p5. It excludes GPT, APFS, all unallocated
LBAs, and every other namespace. The matching driver must fail closed if these
properties are missing/malformed or an I/O crosses the range; an FDT property
alone does not enforce writes.

The profile packages a dedicated initramfs. It leaves only `nvme0n1` for the
driver policy and continues marking all other block devices read-only. It does
not mount or write any partition, has no mass-storage gadget, uses USB product
ID `1d6b:1041`, and emits `RA1NCASTLE_ANDROID_WRITE_PROFILE` in kmsg.

It requires `I_ACCEPT_RAM_ONLY=YES`, `I_ACCEPT_INTERNAL_STORAGE_RISK=YES`, and
`I_ACCEPT_ANDROID_WRITE_PROFILE=YES` both to build and boot:

```bash
./scripts/build-android-write-profile.sh
RA1NCASTLE_BOOT_PROFILE=android-write ./scripts/ram-boot.sh
```

The host-side test extracts and compiles the exact LBA-check and I/O-policy
functions from the kernel patch. Run it with:

```bash
./scripts/test-android-write-allowlist.sh
```

This covers inclusive start/end LBAs, crossing and out-of-range requests,
namespace mismatch, gaps, multiple ranges, integer overflow, flush namespace
checks, and rejection of dataset-management, write-zeroes, and unknown I/O
opcodes. It does not exercise the compiled kernel's full block-I/O path,
admin/ioctl routes, or the phone's NVMe controller. The artifact can be built
and verified on the host, but do not boot it on hardware until those remaining
paths have been reviewed and the profile has passed controlled device
validation.
