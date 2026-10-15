Я разрабатываю ra1ncastle — Android/Linux для обычного iPhone 11 (не Pro и не Pro Max).

Моя конфигурация:
- Устройство: iPhone 11, identifier iPhone12,1
- Board config: n104ap
- SoC: Apple A13 / T8030
- Есть плата на RP2350 для usbliter8
- Эксплойт успешно работает
- После подключения к компьютеру устройство определяется с `PWND:[usbliter8]`
- Рабочая ОС сейчас: нативная Ubuntu Linux
- Также имеется Windows с WSL, но сборку и USB-отладку будем выполнять в нативной Ubuntu
- Проект должен сначала загружаться целиком из RAM и не изменять NAND/APFS
- Запись во внутреннюю память и изменение разметки пока запрещены

Цель:
Создать рабочую tethered-цепочку:

DFU
→ usbliter8
→ patched/raw iBoot или совместимый промежуточный загрузчик
→ m1n1
→ Linux для T8030/n104ap
→ initramfs с shell через USB
→ затем Android на базе LineageOS

Известная исходная база:
1. usbliter8:
   https://github.com/JoshAtticus/usbliter8
   Он поддерживает A13 и позволяет через `usbliter8ctl` загружать raw iBoot.
2. HoolockLinux:
   https://github.com/HoolockLinux/linux
   https://github.com/HoolockLinux/m1n1
   https://github.com/HoolockLinux/remote_boot
   Нужно найти и проверить актуальную ветку `t8030`.
3. Документация экспериментальной поддержки A13:
   https://github.com/yhavry/Hoolock-Docs-A13
   Ранее упоминалась ветка `t8030` и commit
   `38e339f66253b40b046ef84bd910426eba12f822`.
4. Исходная device-конфигурация LineageOS:
   https://github.com/LineageOS/android_device_apple_snowcastle
5. Старый Sandcastle:
   https://github.com/corellium/projectsandcastle

Известное состояние A13-порта:
- Реализованы либо экспериментально доступны SMC, RTC, reboot/poweroff,
  CPU frequency scaling, hwmon, часть MIPI DSI и simpledrm.
- Опубликованная поддержка экрана в основном проверялась на iPhone 11 Pro
  `D421`, а у меня обычный iPhone 11 `N104` с LCD.
- Для N104, вероятно, потребуется отдельный DTS/DTSI и исследование
  framebuffer, LCD/backlight, touch и GPIO.
- На первом этапе достаточно сохранить framebuffer, инициализированный
  iBoot, и использовать simpledrm.
- GPU, камера, SEP/Face ID, baseband и полноценный power management пока
  не являются целями.
- Ядро и Android userspace должны учитывать 16-КиБ page size.

Первый milestone:
1. Проверить pwnDFU с Linux-хоста.
2. Найти точные актуальные репозитории/ветки для A13/T8030.
3. Собрать m1n1 и Linux.
4. Подготовить минимальный n104ap device tree.
5. Создать initramfs с BusyBox.
6. Загрузить всё через usbliter8/iBoot без записи на внутренний накопитель.
7. Получить kernel log и интерактивный shell через USB serial или USB Ethernet.
8. Зафиксировать воспроизводимые команды сборки и загрузки в README/скриптах.
9. После успешного Linux bring-up перейти к ADB и Android на базе LineageOS.

Работай практически: исследуй актуальные upstream-репозитории, создай структуру
проекта в текущей папке, добавь скрипты для установки зависимостей, сборки и
RAM-загрузки, но не выполняй команды, изменяющие NAND/APFS устройства.

Перед сборкой уточни у меня:
- модель моей RP2350-платы;
- версию Ubuntu;
- архитектуру компьютера (`x86_64` или ARM64);
- текущую версию iOS;
- вывод `lsusb -v` или `irecovery -q` после успешного usbliter8;
- имеется ли запасной iPhone и сохранена ли резервная копия.

Начни с проверки доступных веток `t8030`, документации загрузки через raw iBoot
и составления точной цепочки артефактов. Не переходи сразу к Android: сначала
добейся стабильной загрузки Linux/initramfs на n104ap.
