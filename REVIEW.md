# ra1ncastle — итоговый технический handoff

Дата фиксации: 2026-10-05.

Этот файл сохранён вне каталога `ra1ncastle`, чтобы пережить очистку отдельных
исходников. Пароли, токены и другие секреты сюда намеренно не включены.

## Цель и оборудование

- iPhone 11, `iPhone12,1`, board `n104ap`.
- Apple A13 / T8030, CPID `0x8030`, BDID `0x04`.
- iOS 16.3.1 (`20D67`).
- RP2350-USB-A с usbliter8.
- Подтверждён DFU `05ac:1227` с `PWND:[usbliter8]`.
- Основная рабочая система — нативная Ubuntu x86_64.

## Достигнутый результат

На физическом N104 полностью подтверждена tethered RAM-цепочка:

```text
DFU -> usbliter8 -> PAC-safe patched raw iBoot -> m1n1
    -> Linux -> BusyBox initramfs -> USB NCM -> shell
```

Подтверждённое ядро:

```text
Linux ra1ncastle 7.2.0-rc1-g38e339f66253 aarch64
KernelPageSize: 16 kB
Device Tree model: Apple iPhone 11
```

USB NCM работает по адресу `172.16.42.1`; устойчивый raw shell доступен на
TCP 2323. Отдельный поток `dmesg -w` использовался на TCP 2324. Интерфейс на
хосте нужно искать по USB VID:PID `1d6b:1040`, а не по изменяющемуся имени
`enx...`. Явный маршрут `172.16.42.0/24` необходим при активном VPN.

Работают Binder-устройства `/dev/binder`, `/dev/hwbinder`, `/dev/vndbinder`.
Унаследованный framebuffer поднят через simpledrm:

```text
828x1792, 32 bpp, stride 3312, simpledrmdrmfb
```

LCD/backlight/touch отдельно не инициализированы. GPU, камера, SEP/Face ID,
baseband и полноценное энергосбережение не доведены.

## Зафиксированные upstream-ревизии

- Linux: документированный A13 snapshot
  `38e339f66253b40b046ef84bd910426eba12f822`.
- Живая альтернативная ветка Linux: `yhavry/Hoolock-linux:t8030`; на момент
  исследования её head был `2f2662c87fff28b83eab6786f53be2c2670ba53f`.
- m1n1: `yhavry/m1n1:t803x`, зафиксированный commit
  `f54f602220101dffaa500ddf2ca3d708243c8b73`.
- remote_boot: `yhavry/remote_boot:d421-a12-a13-postpwned-prep`, commit
  `e9c6b2efcd737869fcc7c0f31ce087c0ad4e259b`.
- Upstream Android device tree: LineageOS `lineage-24.0`, ранее выбран commit
  `4004579eaaf4b2e81fbfb5806d701f1d2ae8dab2`.

В pinned Linux уже существует `arch/arm64/boot/dts/apple/t8030-n104.dts`,
поэтому отдельный минимальный DTS для первого Linux boot не понадобился.

## Цепочка артефактов

1. usbliter8 переводит SecureROM DFU в `PWND`.
2. remote_boot извлекает `iBoot.n104.RELEASE.im4p`, применяет `hBootPatcher
   -air` и PAC-safe sigcheck patch.
3. `usbliter8ctl boot` отправляет raw iBoot; ENODEV после CUSTOM_BOOT ожидаем,
   поскольку устройство переопределяется в Recovery.
4. Через Recovery отправляются RestoreDeviceTree, пустой trustcache и
   restore-kernel container, затем выполняется `bootx`.
5. Restore-kernel payload содержит m1n1 Mach-O, bootargs, N104 DTB,
   `Image.gz` и BusyBox initramfs.
6. m1n1 переносит ADT/framebuffer properties и запускает Linux.

Ключевые скрипты сохранены в `ra1ncastle/scripts/`: `build-all-native.sh`,
`prepare-bootchain.sh`, `ram-boot.sh`, `connect-usb-shell.sh`,
`build-storage-probe.sh`, `capture-storage-probe.sh`,
`capture-kernel-storage.sh` и `probe-nvme-live.sh`.

## T8030 NVMe и SART

Read-only m1n1 probe успешно инициализировал ANS2 и прочитал LBA 0–5 namespace
1. Важные аппаратные выводы:

- SART v1 использует T8020-подобные 8-bit flags; рабочие allow flags `0x6f`.
- ANS2 на T8030 — CoastGuard/NVMMU TCB design, но без T8103 linear-SQ path.
- Используются обычные NVMe doorbells и zero-based command IDs.
- Admin и I/O SQ entries должны быть 64 bytes; `CC.IOSQES=6`.
- TCB entries — 128 bytes в 16 KiB apertures, `NVMMU_NUM=0x3f`.
- `IDENTIFY Controller` возвращает status `0xb`, но Active Namespace List
  работает и указывает namespace 1.
- ADT-derived registers: ANS `0x27acc0000`, SART `0x27ac50000`, IRQ 422,
  PMGR offsets `0x80388`/`0x803b0` для ANS2/APCIE_ST.

Kernel NVMe path был доведён до enumeration `nvme0n1` и namespace 2–7. Все
block devices принудительно имели `ro=1`; GPT p1–p5 распознавались. Транспорт
отвергал namespace opcodes, кроме read. Ни один раздел в этом режиме не
монтировался.

## GPT/APFS на самом iPhone

Важно: APFS и GPT уже были изменены осознанно из jailbroken iOS. iOS после
операции успешно загрузилась, обе GPT-копии и геометрия APFS были повторно
проверены. Android-разделы остались неформатированными.

- Logical sector: 4096 bytes.
- Disk GUID: `38d61900-8898-4aad-a6be-7f343356c1ca`.
- Last disk LBA: `15624999`.
- APFS container сохранён как p1.

Текущая разметка:

| GPT | Name | First LBA | Last LBA | Bytes |
|---:|---|---:|---:|---:|
| 1 | Container | 6 | 14052095 | 57557360640 |
| 2 | system | 14052096 | 14904063 | 3489660928 |
| 3 | vendor | 14904064 | 15002367 | 402653184 |
| 4 | metadata | 15002368 | 15018751 | 67108864 |
| 5 | userdata | 15018752 | 15624993 | 2483167232 |

Post-write primary snapshot SHA256:
`0d01aae5de09d05f5f87564b1902bd0dd089660342f231b2e2b4c4bb32fd6085`.

Backup GPT SHA256:
`322f7690dd1f1f9290550a19c6bc02381784dc3073c3ae7e50ca21f54940ad03`.

Исходный read-only LBA0–LBA5 SHA256:
`7b9935731a484cb9ca21f0f75e37b6ffbef905928d150494cafb40bc12804361`.

Никогда не применять эту геометрию к другому телефону. Не уменьшать GPT до
APFS. Для любых будущих записей p1, GPT, namespace 2–7 и выход за диапазоны
p2–p5 должны аппаратно отвергаться.

## Android-план и незавершённое состояние

Планировался Android на базе LineageOS `lineage-24.0`, normal partition scheme,
16 KiB pages. Первый честный milestone — Android recovery/init с ADB и
fastbootd, а не нарисованный логотип. Далее: проверка имён и размеров p2–p5,
range-limited write allowlist, canary в metadata и лишь затем system/vendor.

Полный Lineage checkout был остановлен и удалён по запросу пользователя
2026-10-05. Каталог:

```text
/run/media/walld3v/Data 2/ra1ncastle/android/lineage-24.0
```

занимал около 267 GiB на NTFS и был единственным удалённым компонентом.
Основной проект `ra1ncastle`, его `sources`, `patches`, `out`, `logs`, `docs`,
boot artifacts и скрипты сохранены. Автоматический hourly sync удалён и не
пересоздаст checkout.

Причина катастрофической скорости: Lineage manifest включал 1241 checkout,
а четыре-шесть параллельных `git index-pack` работали на механическом
ST1000LM035 SMR HDD через NTFS3. Диск был занят на 87–99% при фактической
скорости порядка 1–3 MiB/s и большой write latency. После обрывов ранее было
удалено 135.1 GiB заброшенных `tmp_pack_*`.

Если когда-либо возобновлять Android, лучше использовать ext4 SSD/NVMe не
меньше 500 GiB (предпочтительно 1 TiB) и низкий parallelism (`network=1..2`,
`checkout=1`). SATA SSD `/dev/sda1` имел всего 238 GiB total и был слишком мал
для полного source + build output.

## Что сохранено

Основной проект расположен в:

```text
/run/media/walld3v/Data 2/ra1ncastle
```

Критические сведения дополнительно находятся в:

- `README.md`
- `docs/n104-bringup-status.md`
- `docs/artifact-chain.md`
- `docs/android-first-boot-plan.md`
- `docs/apfs-partition-plan.md`
- `docs/research.md`
- `docs/safety.md`
- `logs/`
- `patches/linux/` и `patches/m1n1/`

Перед удалением Ubuntu эти данные следует скопировать на отдельный носитель.
