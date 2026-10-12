# Exact first-milestone artifact chain

1. SecureROM DFU enumerates as `05ac:1227` and contains
   `PWND:[usbliter8]` after RP2350 exploitation.
2. `remote_boot` downloads the selected public PAC-era
   `iBoot.n104.RELEASE.im4p`, extracts its raw payload, applies
   `hBootPatcher -air`, then applies the fork's PAC-safe sigcheck return-value
   patch. Output: `iBoot_n104ap_iPhone12,1_pacsafe.raw`.
3. `usbliter8ctl boot` DFU-downloads that raw iBoot and triggers the custom
   `CUSTOM_BOOT` request. The phone re-enumerates into the patched iBoot
   Recovery transport.
4. The A13 `remote_boot` flow sends a RestoreDeviceTree container, selects it
   with `devicetree`, sends an empty restore trustcache, selects it with
   `firmware`, then uploads the restore-kernel container and executes `bootx`.
5. The restore-kernel payload is a mock XNU kernel: `m1n1-idevice.macho` with
   concatenated boot arguments, `t8030-n104.dtb`, `Image.gz`, and the compressed
   BusyBox initramfs.
6. m1n1 consumes the iBoot ADT, preserves/fills the inherited framebuffer and
   memory properties, selects the matching `apple,n104` FDT, and enters Linux.
7. Linux uses 16 KiB pages and simpledrm. Its Apple DWC3 controller runs in
   fixed peripheral mode. `/init` creates ACM plus NCM functions in configfs,
   starts a shell on `/dev/ttyGS0`, offers telnet at `192.0.2.1:23`, and runs
   a PTY-independent raw shell at `192.0.2.1:2323`. The raw listener is
   recreated by an outer loop after every disconnect because this BusyBox
   build exits after the first client when `nc -k` and `-e` are combined.

Expected host artifacts:

| Artifact | Producer | Consumer |
|---|---|---|
| `out/m1n1/m1n1-idevice.macho` | m1n1 `t803x` fork | payload packer |
| `out/kernel/t8030-n104.dtb` | Linux T8030 snapshot | m1n1 payload parser |
| `out/kernel/Image.gz` | Linux T8030 snapshot | m1n1 payload parser |
| `out/initramfs/initramfs.cpio.gz` | static BusyBox builder | Linux |
| `out/payload/m1n1-linux-n104.macho` | payload packer | patched iBoot as `rkrn` |
| `sources/remote_boot/cache/iBoot_n104ap_iPhone12,1_pacsafe.raw` | A13 prep flow | usbliter8ctl |
| `sources/remote_boot/cache/RestoreDeviceTree_n104ap_iPhone12,1.img4` | A13 prep flow | patched iBoot |

There is no separate handwritten N104 DTS in this project because the pinned
kernel snapshot already contains `arch/arm64/boot/dts/apple/t8030-n104.dts`.
It enables simple-framebuffer handoff and T8030 DWC3 peripheral mode. It does
not describe an N104 LCD panel/backlight; that remains a later bring-up task.
