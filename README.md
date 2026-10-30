<div align="center">

# ra1ncastle

### Linux and Android bring-up for iPhone 11

**A tethered, research-grade porting project for Apple T8030 / A13 (`n104ap`).**

![Target](https://img.shields.io/badge/target-iPhone%2011-222222?logo=apple&logoColor=white)
![Architecture](https://img.shields.io/badge/architecture-ARM64-7c3aed)
![Status](https://img.shields.io/badge/status-experimental-orange)
![Boot](https://img.shields.io/badge/boot-tethered-blue)

</div>

> [!CAUTION]
> This is experimental low-level software for a specific device. The validated
> boot path is **tethered and RAM-resident**. Do not use the Android-write
> profile on hardware: its host-side allowlist tests pass, but full I/O-path
> and device validation remain outstanding. Read [the safety notes](docs/safety.md)
> before building or booting anything.

`ra1ncastle` explores what it takes to bring Linux—and eventually Android—to
an iPhone 11. The work is organized around a conservative sequence: get a
repeatable tethered Linux boot, understand the hardware, bring up Android
Recovery, then validate every storage and boot step before attempting a full
Android system launch.

## Project status

| Milestone | Status |
| --- | --- |
| PWND DFU → patched iBoot → m1n1 → Linux | **Validated** |
| 16 KiB ARM64 Linux, USB NCM, interactive RAM shell | **Validated** |
| T8030 NVMe discovery and GPT parsing | **Validated; default profile is read-only** |
| Android Recovery reaches init and exposes ADB | **Validated** |
| Full Android System boot | **Not yet achieved** |
| Android-write profile | **Experimental; not safe to use on hardware yet** |

The device used during development has already been repartitioned to reserve
space for Android. The Android partitions have **not** been populated with an
Android system. Keep the exact device state and backup requirements in mind;
this repository is not a one-click installer.

## Boot architecture

```text
iPhone 11 in DFU
      │
      ▼
  usbliter8 ──► patched raw iBoot ──► m1n1
                                      │
                                      ▼
                        16 KiB ARM64 Linux kernel
                                      │
                                      ▼
                  BusyBox initramfs in volatile RAM
                                      │
                         USB NCM / diagnostic shell
                                      │
                     Android Recovery (RAM-only)
                                      │
                       Android System (future)
```

The current work targets `iPhone12,1`, board `n104ap`, and the T8030/A13 SoC.
The boot chain is not persistent: each experimental boot requires the host,
USB, and the DFU boot process.

## Safety model

- The default Linux environment runs from RAM and does not install Android or
  intentionally write internal storage.
- NVMe investigation is separated from Android installation. The normal
  diagnostic path is read-only; storage-probe tooling is separately selected
  and limited to GPT discovery.
- The Android-write profile is a separate artifact with an intended namespace
  and LBA allowlist. The kernel compiles with the current driver restrictions,
  and host-side allowlist tests pass. The full kernel I/O path and device
  behavior remain unvalidated. Do not boot it on the iPhone
  until the documented gates pass.
- Apple firmware and locally extracted device files are not included. Do not
  commit firmware, IPSWs, local configuration, build outputs, or device logs.

See [Storage safety boundaries](docs/safety.md),
[the partition plan](docs/apfs-partition-plan.md), and
[the bring-up review](REVIEW.md) before using the scripts.

## Getting started

The scripts target a Linux host. Before building:

1. Read the safety documents linked above.
2. Copy `config/local.env.example` to `config/local.env` and fill in the host
   and device details. That local file is ignored by Git.
3. Confirm that the connected device is an iPhone 11 (`iPhone12,1` / `n104ap`)
   and that you have a current, recoverable backup.
4. Review the pinned revisions in [`config/sources.env`](config/sources.env).
5. Set the RAM-only acknowledgement only after you understand the boot and
   recovery risks.

The usual host-side preparation flow is:

```bash
./scripts/install-deps-ubuntu.sh
./scripts/install-ipsw.sh
./scripts/fetch-sources.sh
./scripts/check-pwnd-dfu.sh
./scripts/build-all-native.sh
```

Then, with the phone deliberately placed in PWND DFU and all preflight checks
passing:

```bash
./scripts/prepare-bootchain.sh
./scripts/ram-boot.sh
./scripts/connect-usb-shell.sh --ncm
```

`build-all-native.sh` uses a temporary bind mount when the checkout path
contains spaces, because the legacy kernel build system cannot handle them.
The mount is removed when the build exits. It runs the complete native build by
default; to rebuild just the kernel, use
`./scripts/build-all-native.sh scripts/build-kernel.sh`. The bind mount may
prompt for `sudo`. For a kernel-only build, the object tree can instead be
placed at a space-free path (for example, `/tmp`, which is temporary):

```bash
RA1NCASTLE_KERNEL_OBJ=/tmp/ra1ncastle-kernel-n104 ./scripts/build-kernel.sh
```

Build and boot commands should be run only after reviewing their script and
the relevant safety acknowledgments.

## Useful workflows

### Repack the initramfs

After changing only `initramfs/init`, rebuild the initramfs and payload without
recompiling the kernel:

```bash
./scripts/repack-initramfs.sh
```

### Inspect the read-only storage probe

This separate profile captures only the initial GPT sectors; it does not mount
APFS or authorize writes:

```bash
./scripts/build-storage-probe.sh
RA1NCASTLE_BOOT_PROFILE=storage-probe ./scripts/ram-boot.sh
./scripts/capture-storage-probe.sh
```

### Capture diagnostics

```bash
./scripts/capture-kernel-storage.sh
./scripts/capture-m1n1-log.sh
```

The command-line scripts under `scripts/` are the source of truth for their
options and safeguards. Do not substitute partitioning, formatting, flashing,
or filesystem commands for the guarded project workflow.

## Roadmap to the first Android System boot

1. Rebuild the kernel with the current NVMe ioctl restrictions.
2. Add and pass host-side tests for admin-command rejection and every allowlist
   boundary; verify the resulting artifacts and profile manifest.
3. Reboot Android Recovery and validate ADB, fastbootd, and the partition map
   without writing storage.
4. Build Android images and confirm their expanded sizes fit the intended
   partitions.
5. Complete the backup and storage preflight. Any write to the iPhone requires
   a separate explicit go/no-go after the preceding checks.
6. Only after those gates, install the Android partitions and tether-boot the
   Android system while collecting init, kernel, display, and ADB logs.

The detailed gates and partition contract are in
[`docs/android-first-boot-plan.md`](docs/android-first-boot-plan.md).

## Repository map

| Path | Purpose |
| --- | --- |
| `scripts/` | Build, package, preflight, boot, and capture tools |
| `patches/` | Linux, m1n1, and Android bring-up patches |
| `initramfs/` | RAM-root startup and diagnostics |
| `config/` | Pinned revisions, kernel settings, and local config template |
| `docs/` | Safety boundaries, hardware findings, and boot plans |
| `REVIEW.md` | Design review and known technical risks |

## Contributing

Keep changes reproducible, preserve the default read-only boot path, and update
the relevant safety and bring-up notes alongside code changes. Never include
private firmware, device-specific credentials, or generated artifacts in a
pull request.
