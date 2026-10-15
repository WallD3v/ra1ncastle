# Verified N104 bring-up status

Hardware validation target:

- product: iPhone 11 (`iPhone12,1`)
- board: `n104ap`
- SoC: T8030/A13
- boot transport: usbliter8 PWND DFU, patched raw iBoot, m1n1
- current read-only-kernel payload SHA256:
  `5b4a5d93d1a54d1afd18b25457f311b5aaf6fabe3b3eefc182649b6b846601b6`
- read-only storage-probe SHA256:
  `2cfe1fc5badb05b23fe31c8107f7fbd1f472c32d5efe44638c04ce166f00cae0`

## Confirmed milestone

The complete volatile chain boots successfully:

```text
DFU -> usbliter8 -> patched raw iBoot -> m1n1 -> Linux
    -> BusyBox initramfs -> USB NCM -> persistent raw shell
```

Observed kernel identity:

```text
Linux ra1ncastle 7.2.0-rc1-g38e339f66253 aarch64 GNU/Linux
KernelPageSize: 16 kB
Device Tree model: Apple iPhone 11
```

The raw shell at `172.16.42.1:2323` was disconnected and opened a second
time successfully. `scripts/connect-usb-shell.sh` discovers the interface by
USB VID:PID instead of its changing MAC-derived name and installs an explicit
link route so a host VPN cannot capture `172.16.42.1`.

## Original RAM-only evidence

The original live mount table contained only rootfs, devtmpfs, devpts, proc, sysfs,
tmpfs, and configfs. `/sys/block` contains virtual loop, NBD, and zram devices;
there is no Apple NVMe or other physical block device. No APFS filesystem is
mounted. That baseline preceded the read-only kernel NVMe work below.

## Drivers observed during boot

- Apple DART initialized with a `0x4000` (16 KiB) page size.
- simpledrm initialized from the inherited framebuffer at `0x8fa288000` and
  registered `fb0`.
- Apple SMC and SMC GPIO initialized.
- Apple PMIC RTC registered as `rtc0`; SMC RTC registered as `rtc1`.
- SMC reboot/poweroff handling initialized.
- T8030 DWC3 bound the configfs ACM + NCM gadget successfully.

## Known non-blocking warnings

- `OF: Bad cell count for /soc/spmi@23d180700/pmic@f` appears four times and
  needs a later DTS audit.
- `macsmc-hwmon` reports that no supported sensor types were found.
- LCD panel/backlight control and touch are not yet brought up; the current
  display path is the framebuffer inherited from iBoot through simpledrm.

These warnings do not block the RAM-only Linux/initramfs milestone. Android
work should preserve the 16 KiB page-size requirement and start with an ADB
transport over the already working USB gadget or NCM link.

## Read-only internal-storage milestone

The separate m1n1 storage profile successfully initialized T8030 ANS2 and
captured LBA 0 through LBA 5 from namespace 1. The host-side parser validated
the protective MBR, primary GPT header, and partition-entry CRC. Snapshot
SHA256:

```text
7b9935731a484cb9ca21f0f75e37b6ffbef905928d150494cafb40bc12804361
```

The 64 GB device exposes one GPT partition:

```text
1  Container  APFS  first LBA 6  last LBA 15624994  size 63999954944
```

At the time of this original snapshot there was no unallocated GPT range; all
free space was inside APFS. The later APFS/GPT milestone below created the
dedicated Android partitions.

## APFS/GPT milestone

On 2026-09-30, APFS was resized under normal jailbroken iOS and the disk was
partitioned for ra1ncastle's Android layout. iOS rebooted successfully and all five device nodes
were published. Both GPT copies and the APFS size/UUID passed pre-write,
post-write, and post-reboot validation. No Android partition is formatted yet.

```text
1 Container  6..14052095         57557360640 bytes  APFS
2 system     14052096..14904063   3489660928 bytes  Linux
3 vendor     14904064..15002367    402653184 bytes  Linux
4 metadata   15002368..15018751     67108864 bytes  Linux
5 userdata   15018752..15624993   2483167232 bytes  Linux
```

Post-write primary snapshot SHA256:
`0d01aae5de09d05f5f87564b1902bd0dd089660342f231b2e2b4c4bb32fd6085`.
Backup GPT SHA256:
`322f7690dd1f1f9290550a19c6bc02381784dc3073c3ae7e50ca21f54940ad03`.

Hardware-verified T8030 NVMe details:

- SART v1 uses the T8020-style 8-bit flags layout; the observed allow flags
  are `0x6f`.
- ANS2 requires CoastGuard/NVMMU TCBs, but does not implement the T8103 linear
  submission queue enable path.
- Submission uses ordinary NVMe doorbells and zero-based command IDs.
- Both admin and I/O SQ entries are 64 bytes; leaving the inherited
  `CC.IOSQES=7` made only slot zero work. Explicit `CC.IOSQES=6` fixed
  sequential reads.
- TCB storage uses 128-byte entries in 16 KiB apertures with `NVMMU_NUM=0x3f`.
- Queue, TCB, RTKit, and data DMA buffers used during this probe were all
  explicitly admitted through SART.

The standard `IDENTIFY Controller` command returns status `0xb` on this
firmware. `IDENTIFY Active Namespace List` succeeds once its DMA buffer and the
I/O SQ format are correct and reports namespace 1. This does not affect
ordinary reads.

## Kernel NVMe milestone

The kernel now has a separate T8030 hardware mode derived from the successful
m1n1 probe:

- standard circular submission queues and standard NVMe SQ doorbells;
- CoastGuard/NVMMU TCBs with 64 TCB slots and 64-byte I/O SQ entries;
- T8030 SARTv1 permissions `0x6f`;
- explicit SART admission for queue, TCB, RTKit, and data buffers;
- PRP-list support for the 16 KiB-page block I/O generated by this kernel;
- a hard transport-level rejection of every namespace opcode except read;
- forced read-only state for every namespace block device.

The DTS uses values captured from this phone's ADT: ANS `0x27acc0000`, SART
`0x27ac50000`, interrupt 422, and PMGR offsets `0x80388`/`0x803b0` for
ANS2/APCIE_ST. The kernel and DTB compile successfully, and the payload verifier
requires both T8030 NVMe and SART compatibles. Hardware validation passed: the
automatic initramfs probe observed `nvme0n1` and namespaces `nvme0n2` through
`nvme0n7`, all with `ro=1`, and the kernel parsed GPT partitions `p1` through
`p5`. The successful transcript is `logs/kernel-auto-nvme-ro-20261003.txt`; no
partition was mounted.
