#!/usr/bin/env python3

import pathlib
import struct
import sys
import uuid

BLOCK_SIZE = 4096


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"usage: {sys.argv[0]} NVME_LBA0_LBA5.bin")

    path = pathlib.Path(sys.argv[1])
    data = path.read_bytes()
    if len(data) != 6 * BLOCK_SIZE:
        fail(f"expected 24576 bytes, got {len(data)}")
    if data[510:512] != b"\x55\xaa":
        fail("protective MBR signature 0x55aa is missing")

    header = data[BLOCK_SIZE : 2 * BLOCK_SIZE]
    if header[:8] != b"EFI PART":
        fail("GPT signature is missing at LBA1")

    (
        revision,
        header_size,
        header_crc,
        _reserved,
        current_lba,
        backup_lba,
        first_usable,
        last_usable,
    ) = struct.unpack_from("<IIIIQQQQ", header, 8)
    disk_guid = uuid.UUID(bytes_le=header[56:72])
    entries_lba, entry_count, entry_size, entries_crc = struct.unpack_from(
        "<QIII", header, 72
    )

    print("GPT probe validated (read-only m1n1 snapshot)")
    print(f"revision=0x{revision:08x} header_size={header_size} header_crc=0x{header_crc:08x}")
    print(f"current_lba={current_lba} backup_lba={backup_lba}")
    print(f"first_usable_lba={first_usable} last_usable_lba={last_usable}")
    print(f"disk_guid={disk_guid}")
    print(
        f"entries_lba={entries_lba} entry_count={entry_count} "
        f"entry_size={entry_size} entries_crc=0x{entries_crc:08x}"
    )

    entries_offset = entries_lba * BLOCK_SIZE
    available = len(data) - entries_offset
    if entries_offset < 0 or entry_size < 128 or available < entry_size:
        fail("partition entries are outside the captured LBA0-LBA5 window")

    max_entries = min(entry_count, available // entry_size)
    print("partitions:")
    found = 0
    for index in range(max_entries):
        off = entries_offset + index * entry_size
        entry = data[off : off + entry_size]
        if entry[:16] == bytes(16):
            continue
        type_guid = uuid.UUID(bytes_le=entry[:16])
        unique_guid = uuid.UUID(bytes_le=entry[16:32])
        first_lba, last_lba, attrs = struct.unpack_from("<QQQ", entry, 32)
        name = entry[56:128].decode("utf-16-le", errors="replace").rstrip("\x00")
        size_bytes = (last_lba - first_lba + 1) * BLOCK_SIZE
        print(
            f"  {index + 1}: name={name!r} type={type_guid} uuid={unique_guid} "
            f"first={first_lba} last={last_lba} size={size_bytes} attrs=0x{attrs:x}"
        )
        found += 1
    if not found:
        fail("no populated GPT entries found in captured window")


if __name__ == "__main__":
    main()
