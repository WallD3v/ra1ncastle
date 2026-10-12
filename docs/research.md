# Upstream/ref audit (2026-09-29)

## Linux

`HoolockLinux/linux` no longer advertises a `t8030` branch. The documented SHA
`38e339f66253b40b046ef84bd910426eba12f822` remains fetchable, and
`yhavry/Hoolock-linux:t8030` is the live branch. Its current head during the
audit was `2f2662c87fff28b83eab6786f53be2c2670ba53f`, 12 commits after the
documented SHA. Those later commits add SART, ANS/NVMe, PCIe and D421 Wi-Fi.

For the RAM-only milestone this project deliberately pins the older documented
SHA. It already provides T8030 CPU/AIC/PMGR, SMC/RTC/reboot, cpufreq, USB,
simpledrm, D421 display work, and an N104 device tree, while predating the
T8030 internal-NVMe enablement.

## m1n1

`HoolockLinux/m1n1:idevice` does not define `T8030` in `src/soc.h`. The A13
bring-up is in `yhavry/m1n1`. The relevant refs observed were:

- `d421-t8030-base` at `9f8a9ff42ab555010c6fdbbb72dfb98c9c0d44dc`;
- `t803x` at `f54f602220101dffaa500ddf2ca3d708243c8b73`;
- `t8030-cpufreq-oled` at `12bc896b9e1cd3d42db68d90c2be0086b7e59ec1`.

The project pins `t803x`. It includes the A13 Lightning/Thunder initialization
fixes, SMP start handling, framebuffer `/chosen` handoff and T8030 cpufreq, but
omits the D421-specific MIPI OLED brightness proxy added by the last branch.

## raw-iBoot transport

The stock `HoolockLinux/remote_boot` path is a checkm8/gaster flow and carries
no `0x8030.im4m`. The applicable A13 path is
`yhavry/remote_boot:d421-a12-a13-postpwned-prep`, pinned here at
`e9c6b2efcd737869fcc7c0f31ce087c0ad4e259b`.

Despite the branch name, its selector accepts CPID `0x8030` with any `*ap`
model. It derives `n104` from `n104ap`, checks the DFU serial for `PWND`,
prepares PAC-safe raw iBoot, and invokes the upstream `usbliter8ctl`. Its A13
boot path then uses only volatile Recovery uploads and `bootx`.

## Resolved on physical N104 hardware

- usbliter8, raw iBoot, m1n1, Linux and USB NCM all re-enumerate reliably;
- inherited framebuffer geometry is 828x1792, 32 bpp, stride 3312;
- T8030 ANS2 is a hybrid CoastGuard design: NVMMU TCB validation with normal
  64-byte SQ entries and normal NVMe doorbells, not T8103 linear SQ;
- read-only namespace-1 access works and the on-device GPT validates.

## Remaining uncertainties

- the correct Linux DMA strategy for T8030's limited SART entries (a fixed,
  serialized bounce window is the conservative first implementation);
- LCD/backlight/touch initialization beyond inherited simpledrm;
- a recoverable APFS shrink and Android partition layout; no storage write is
  authorized by the read-only probe milestone.
