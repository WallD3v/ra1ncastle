# n104 APFS/GPT partition plan

This plan is specific to the captured iPhone 11 (`n104ap`) disk. It must not be
reused on another device or after the GPT has changed.

## Approved read-only baseline

- Logical sector size: 4096 bytes
- Disk GUID: `38d61900-8898-4aad-a6be-7f343356c1ca`
- Last disk LBA: `15624999`
- Last usable LBA: `15624994`
- Existing partition 1: `Container`, APFS, LBA `6..15624994`
- LBA0-LBA5 SHA-256:
  `7b9935731a484cb9ca21f0f75e37b6ffbef905928d150494cafb40bc12804361`

Re-run the non-writing planner before any mutation:

```bash
./scripts/plan-android-partitions.py
```

## Applied 6 GiB Android layout

The original 8 GiB proposal was discarded when iOS initially reported only
9.0 GiB available. After cleanup, an intentionally smaller layout was selected.
On 2026-09-30 the APFS filesystem was successfully resized under normal,
jailbroken iOS to exactly `57557360640` bytes. The new NXSB was read back and
validated before GPT was changed.

| GPT | Name | First LBA | Last LBA | Bytes | Type |
|---:|---|---:|---:|---:|---|
| 1 | Container | 6 | 14052095 | 57,557,360,640 | Apple APFS (`AF0A`) |
| 2 | system | 14052096 | 14904063 | 3,489,660,928 | Linux (`8300`) |
| 3 | vendor | 14904064 | 15002367 | 402,653,184 | Linux (`8300`) |
| 4 | metadata | 15002368 | 15018751 | 67,108,864 | Linux (`8300`) |
| 5 | userdata | 15018752 | 15624993 | 2,483,167,232 | Linux (`8300`) |

The Android start and all fixed-size partition boundaries are aligned to 1 MiB.
The final usable GPT sector is intentionally left free, giving userdata an even
number of 4096-byte sectors.
The sizes meet Snowcastle's published minimums: system 3 GiB, vendor 256 MiB,
metadata 16 MiB, and userdata 2 GiB.

## Completed transaction and validation

1. Captured primary GPT, backup GPT, and APFS NXSB before mutation.
2. Verified both GPT headers, both entry-array CRCs, disk GUID, APFS partition
   UUID, and matching primary/backup entries.
3. Verified signed Hoolock `resize_apfs` and `gdisk` tools and their entitlements.
4. Resized `disk0s1` to `57557360640` bytes; the operation returned success.
5. Read NXSB back and verified `block_size=4096`, `block_count=14052090`, and
   unchanged APFS container UUID.
6. Replayed the exact GPT transcript on a host loop device with 4096-byte logical
   sectors; machine validation passed.
7. Applied the same transcript to `/dev/disk0`; `gdisk` returned success.
8. Read both GPT copies back and verified CRCs and exact geometry.
9. Rebooted normally into iOS 16.3.1, activated Dopamine again, verified
   `/dev/disk0s1` through `/dev/disk0s5`, and repeated `gdisk v` successfully.
10. Verified the primary GPT and backup GPT are bit-identical across reboot.
    The APFS NXSB checkpoint changed as expected, while its size and UUID remained
    correct.

Never shrink GPT before APFS. Never use Linux APFS write support for this operation.
Do not use `resize_apfs ... 0`; always pass the exact byte count.

## Current gate

Partitioning is complete. The Android partitions remain unformatted and contain
no images. Do not write them from the experimental m1n1 T8030 NVMe path: only its
read path is validated. The next gate is to boot the read-only storage probe,
validate the new GPT from Linux, then build recovery/Android and use its normal
partition-aware flashing path.

Post-write validation:

```bash
./scripts/verify-applied-storage-layout.py \
  logs/storage-after-resize/reboot-primary.bin \
  logs/storage-after-resize/reboot-backup.bin
```

## Pinned iOS support tools

The official Hoolock GitHub Actions artifact with artifact ID `9785223804`
(created 2026-09-01) is stored at
`artifacts/ios-support-tools/hoolock-support-iphoneos.zip`.

```text
ca44c45d85cf422da69ed9c247edc00b04446795fecdf0108ea87b55967d193c  hoolock-support-iphoneos.zip
18c0325002759d94b516b728c91b8e3ce35a2288b701f0ebc5fc47820cd1ceea  gdisk
57edbca900f8cceba63e9023fa3fd1732775a8f2d5b236055fed71030800f503  resize_apfs
```

The archive is retained unchanged. Before deployment, extract it locally and
verify all three hashes. The executables must also retain the upstream platform,
raw-disk, and AppleAPFSUserClient entitlements.
