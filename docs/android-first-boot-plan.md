# Android first-boot plan for n104ap

## Current position

The volatile Linux milestone and read-only internal-storage milestone are
complete. The hardware has booted a 16 KiB kernel, simpledrm, Binder devices,
USB NCM, and the T8030 NVMe controller. The kernel parsed the five-partition
GPT while every namespace reported read-only.

The practical estimate is about 70% to an authentic Android recovery/init boot
with ADB, 55-60% to Android bootanimation, and substantially less to a usable
GUI. A static logo is not counted as Android boot.

## Selected upstream

- LineageOS branch: `lineage-24.0`
- Upstream Android device-tree commit: `4004579eaaf4b2e81fbfb5806d701f1d2ae8dab2`
- partition scheme: `normal`
- page size: 16 KiB
- first target: recovery ramdisk with ADB and fastbootd

Recovery is the first target because it exercises Android init, ueventd,
Binder, USB gadget userspace, framebuffer/minui, and block-device naming without
requiring a complete framework boot.

## On-device partition contract

Only namespace 1 and the following inclusive 4 KiB LBA ranges may ever be
writable in the Android-install profile:

| GPT | Name | First LBA | Last LBA | Bytes |
|---|---|---:|---:|---:|
| p2 | system | 14052096 | 14904063 | 3489660928 |
| p3 | vendor | 14904064 | 15002367 | 402653184 |
| p4 | metadata | 15002368 | 15018751 | 67108864 |
| p5 | userdata | 15018752 | 15624993 | 2483167232 |

The APFS container (`p1`, LBA 6..14052095), GPT sectors, and namespaces 2-7
remain permanently rejected by the transport driver. The default payload stays
read-only. A writable payload must be a separate artifact with a different USB
product string and a conspicuous boot log marker.

Before any hardware write, the allowlist implementation must reject:

- a request crossing either edge of an allowed partition;
- every write to namespace other than namespace 1;
- every write to p1, GPT, or unallocated LBAs;
- discard/DSM, write-zeroes, format, sanitize, firmware, and arbitrary admin
  commands;
- all writable block devices unless the Android-install profile is selected.

The host-side contract is packaged separately by
`build-android-write-profile.sh`: it copies the DTB and writes
`ra1ncastle,write-allow-nsid = <1>` with the one inclusive u64
`ra1ncastle,write-allow-lba-ranges` pair `14052096..15624993`. `ram-boot.sh`
re-reads these exact cells and requires both storage acknowledgements. This is
not enforcement by itself; the driver must consume the contract fail-closed.

## Build sequence

1. Sync LineageOS 24.0 and the upstream/mainline device dependencies.
2. Create an Android kernel worktree from the already validated T8030 source.
3. Apply the ra1ncastle NVMe/SART patch and the Android kernel patches.
4. Extract device firmware locally from an Apple IPSW; never commit or
   redistribute it.
5. Build the upstream Apple-device target for `SNOWCASTLE_PARTITION_SCHEME=normal` and 16 KiB pages.
6. Package the Android recovery kernel and ramdisk into the existing patched-iBoot
   payload format, then tether-boot with `RA1NCASTLE_BOOT_PROFILE=android-recovery`
   without writing a partition. The separate `m1n1-recovery.bin` bundle
   is retained as a build artifact but is not sent through the Linux iDevice loader.
7. Capture framebuffer logs plus ADB enumeration. Only after recovery is stable,
   enable the range-limited install profile and flash p2-p5.

## Success gates

- Gate A: recovery kernel reaches Android init and publishes ADB.
- Gate B: fastbootd reports exactly `system`, `vendor`, `metadata`, `userdata`.
- Gate C: host-side sparse-image expanded sizes fit their target partitions.
- Gate D: write allowlist tests pass, and a metadata-partition canary readback
  succeeds without any change to GPT or APFS hashes.
- Gate E: flash system/vendor, format metadata/userdata, tether-boot Android.
