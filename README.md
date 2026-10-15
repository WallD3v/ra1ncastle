# ra1ncastle: Linux/Android bring-up for iPhone 11 (N104/T8030)

This repository is a reproducible bring-up harness for the tethered chain:

```text
DFU -> usbliter8 -> PAC-safe raw iBoot -> m1n1 -> Linux -> BusyBox initramfs
```

Target: `iPhone12,1`, board `n104ap`, SoC `T8030/A13`. Stable Linux over USB
NCM and kernel-side read-only T8030 NVMe/GPT enumeration are validated.
The APFS container has now been safely shrunk under iOS and dedicated GPT
partitions have been created for the LineageOS normal-partition layout used by ra1ncastle.

The important discovery is that the documented Linux T8030 snapshot already
contains `t8030-n104.dts`; a new minimal DTS is not needed for the first boot.
The live HoolockLinux refs do not expose the old `t8030` branch, so all working
A13 components are pinned explicitly in [config/sources.env](config/sources.env).

## Safety boundary

The Linux root filesystem and boot chain remain RAM-resident. The experimental
Apple NVMe driver is packaged as a module and loaded after USB diagnostics are
online; its T8030 path rejects every non-read namespace command. The initramfs
also marks discovered block devices read-only, publishes automatic probe
results to the kernel log, and builds no USB mass-storage function. A completed
storage operation resized APFS and GPT from jailbroken iOS; no Android
filesystem or image has yet been written. Read [docs/safety.md](docs/safety.md) and
[docs/apfs-partition-plan.md](docs/apfs-partition-plan.md).

## Before any build

Copy `config/local.env.example` to `config/local.env` and record:

- exact RP2350 board model;
- Ubuntu version;
- host architecture (`x86_64` or `arm64/aarch64`);
- current iOS version;
- whether a spare iPhone exists and whether a current backup exists;
- `lsusb -v -d 05ac:1227` and `irecovery -q` after successful usbliter8.

Do not set `I_ACCEPT_RAM_ONLY=YES` until those values and the USB identity have
been reviewed.

## Reproducible workflow

The chain has been validated on an `iPhone12,1`/`n104ap`: Linux
`7.2.0-rc1-g38e339f66253` reached the BusyBox initramfs with a 16 KiB kernel
page size and an interactive shell over USB NCM.

```bash
cp config/local.env.example config/local.env
# Fill config/local.env, then review docs/safety.md.

./scripts/install-deps-ubuntu.sh
./scripts/install-ipsw.sh
./scripts/fetch-sources.sh
./scripts/check-pwnd-dfu.sh
./scripts/build-all-native.sh
./scripts/prepare-bootchain.sh
./scripts/ram-boot.sh
./scripts/connect-usb-shell.sh
```

`build-all-native.sh` invokes `build-all.sh` directly when the workspace path
has no spaces. Otherwise it creates a temporary bind mount below `/tmp`, because
this kernel snapshot rejects source paths containing spaces. The mount is
removed automatically after the build.

`connect-usb-shell.sh` identifies the phone by USB VID:PID `1d6b:1040`, so it
does not depend on a changing MAC-based interface name or confuse the phone's
ACM function with the RP2350. Its default `--ncm` mode installs the explicit
`192.0.2.0/30` link route (reserved TEST-NET-1, avoiding VPN private ranges) and
opens the persistent raw shell at `192.0.2.1:2323`. Use `--acm` to select the
phone's ACM function instead.

After editing only `initramfs/init`, rebuild the initramfs and final payload
without recompiling BusyBox or Linux:

```bash
./scripts/repack-initramfs.sh
```

The separate m1n1 read-only GPT discovery profile can be rebuilt with:

```bash
./scripts/build-storage-probe.sh
RA1NCASTLE_BOOT_PROFILE=storage-probe ./scripts/ram-boot.sh
./scripts/capture-storage-probe.sh
```

This profile reads only NVMe LBA 0-5 inside m1n1, shuts ANS down, and passes the
snapshot to Linux. It does not mount APFS. The latest hardware capture verified
the resized APFS container and all four dedicated Android partitions. The main
kernel payload can be inspected after boot with:

```bash
./scripts/capture-kernel-storage.sh
```

The normal payload now loads `nvme-core.ko` and the read-only
`nvme-apple.ko` automatically after USB setup and publishes
`RA1NCASTLE_NVME_AUTO_*` records. For a driver hang during development, the
raw shell on TCP 2323 and independent `dmesg -w` stream on TCP 2324 remain
available. The command below keeps a complete transcript:

```bash
./scripts/probe-nvme-live.sh 120
```

The resulting files are `logs/kernel-live-*.txt` and
`logs/nvme-insmod-*.txt`. The default driver remains hardware-enforced
read-only even when loaded automatically.

The future Android install payload is deliberately separate from the default
read-only artifact. It carries a fixed namespace-1/p2-p5 DTB allowlist, a
distinct USB product string, and requires two explicit storage acknowledgements.
It must not be used until driver-side fail-closed range enforcement lands; see
[docs/safety.md](docs/safety.md).

Android work is tracked in
[docs/android-first-boot-plan.md](docs/android-first-boot-plan.md). The selected
userspace baseline is LineageOS `lineage-24.0`; the first target is recovery
plus ADB/fastbootd, before a full system boot.

See
[docs/n104-bringup-status.md](docs/n104-bringup-status.md) for the exact
geometry and the hardware-derived CoastGuard parameters.

See [docs/artifact-chain.md](docs/artifact-chain.md) for the exact payload
ordering and [docs/research.md](docs/research.md) for the ref audit and open
hardware questions. The hardware-verified results and remaining warnings are
recorded in [docs/n104-bringup-status.md](docs/n104-bringup-status.md).
