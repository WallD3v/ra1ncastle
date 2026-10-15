#!/usr/bin/env python3
"""Validate the captured iPhone GPT and print a non-writing partition plan."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import struct
import sys
import uuid
from pathlib import Path


SECTOR_SIZE = 4096
ALIGN_SECTORS = 256  # 1 MiB
EXPECTED_SHA256 = "7b9935731a484cb9ca21f0f75e37b6ffbef905928d150494cafb40bc12804361"
EXPECTED_DISK_GUID = "38d61900-8898-4aad-a6be-7f343356c1ca"
EXPECTED_APFS_TYPE = "7c3457ef-0000-11aa-aa11-00306543ecac"
EXPECTED_APFS_START = 6
EXPECTED_APFS_LAST = 15_624_994


def die(message: str) -> None:
    raise SystemExit(f"error: {message}")


def guid(raw: bytes) -> str:
    return str(uuid.UUID(bytes_le=raw))


def parse_gpt(data: bytes) -> dict[str, object]:
    if len(data) != 6 * SECTOR_SIZE:
        die(f"expected 24576-byte LBA0-LBA5 snapshot, got {len(data)} bytes")
    header = data[SECTOR_SIZE : 2 * SECTOR_SIZE]
    if header[:8] != b"EFI PART":
        die("primary GPT signature is missing")

    revision, header_size, stored_crc = struct.unpack_from("<III", header, 8)
    if not 92 <= header_size <= SECTOR_SIZE:
        die(f"invalid GPT header size {header_size}")
    checked = bytearray(header[:header_size])
    struct.pack_into("<I", checked, 16, 0)
    actual_crc = binascii.crc32(checked) & 0xFFFFFFFF
    if stored_crc != actual_crc:
        die(f"GPT header CRC mismatch: stored 0x{stored_crc:08x}, computed 0x{actual_crc:08x}")

    current_lba, backup_lba, first_usable, last_usable = struct.unpack_from("<QQQQ", header, 24)
    disk_guid = guid(header[56:72])
    entries_lba, entry_count, entry_size, entries_crc = struct.unpack_from("<QIII", header, 72)
    entries_bytes = entry_count * entry_size
    entries_off = entries_lba * SECTOR_SIZE
    entries = data[entries_off : entries_off + entries_bytes]
    if len(entries) != entries_bytes:
        die("partition entries are outside the captured snapshot")
    actual_entries_crc = binascii.crc32(entries) & 0xFFFFFFFF
    if actual_entries_crc != entries_crc:
        die(
            f"GPT entries CRC mismatch: stored 0x{entries_crc:08x}, "
            f"computed 0x{actual_entries_crc:08x}"
        )

    used = []
    for index in range(entry_count):
        entry = entries[index * entry_size : (index + 1) * entry_size]
        if entry[:16] == bytes(16):
            continue
        first, last, attrs = struct.unpack_from("<QQQ", entry, 32)
        name = entry[56:128].decode("utf-16-le").rstrip("\0")
        used.append(
            {
                "index": index + 1,
                "type": guid(entry[:16]),
                "uuid": guid(entry[16:32]),
                "first": first,
                "last": last,
                "attrs": attrs,
                "name": name,
            }
        )

    return {
        "revision": revision,
        "current_lba": current_lba,
        "backup_lba": backup_lba,
        "first_usable": first_usable,
        "last_usable": last_usable,
        "disk_guid": disk_guid,
        "partitions": used,
    }


def aligned_down(value: int, alignment: int) -> int:
    return value - value % alignment


def gib(sectors: int) -> float:
    return sectors * SECTOR_SIZE / 1024**3


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate the original n104 GPT snapshot and print the applied 6 GiB Android layout; never writes storage."
    )
    parser.add_argument(
        "probe",
        nargs="?",
        type=Path,
        default=Path("logs/nvme-lba0-lba5.bin"),
        help="captured LBA0-LBA5 file (default: logs/nvme-lba0-lba5.bin)",
    )
    args = parser.parse_args()
    data = args.probe.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256:
        die(f"snapshot SHA-256 is not the approved baseline: {digest}")

    gpt = parse_gpt(data)
    if gpt["disk_guid"] != EXPECTED_DISK_GUID:
        die(f"unexpected disk GUID {gpt['disk_guid']}")
    parts = gpt["partitions"]
    if len(parts) != 1:
        die(f"expected exactly one GPT partition, found {len(parts)}")
    apfs = parts[0]
    if (
        apfs["index"] != 1
        or apfs["type"] != EXPECTED_APFS_TYPE
        or apfs["first"] != EXPECTED_APFS_START
        or apfs["last"] != EXPECTED_APFS_LAST
    ):
        die(f"APFS partition does not match approved baseline: {apfs}")

    requested_free_sectors = 6 * 1024**3 // SECTOR_SIZE
    android_first = aligned_down(apfs["last"] + 1 - requested_free_sectors, ALIGN_SECTORS)
    new_apfs_last = android_first - 1
    new_apfs_sectors = new_apfs_last - apfs["first"] + 1
    new_apfs_bytes = new_apfs_sectors * SECTOR_SIZE

    sizes = [
        ("system", int(3.25 * 1024**3) // SECTOR_SIZE),
        ("vendor", 384 * 1024**2 // SECTOR_SIZE),
        ("metadata", 64 * 1024**2 // SECTOR_SIZE),
    ]
    layout = []
    cursor = android_first
    for name, sectors in sizes:
        end = cursor + sectors - 1
        layout.append((name, cursor, end))
        cursor = end + 1
    # Keep the final 4096-byte usable sector free so the Linux userdata
    # partition has an even number of 4096-byte sectors.
    layout.append(("userdata", cursor, apfs["last"] - 1))

    if layout[-1][2] > gpt["last_usable"]:
        die("calculated layout extends beyond the last usable GPT sector")
    if layout[-1][2] - layout[-1][1] + 1 < 2 * 1024**3 // SECTOR_SIZE:
        die("calculated userdata is below the upstream device profile's 2 GiB minimum")

    print("VALIDATED READ-ONLY BASELINE")
    print(f"snapshot_sha256={digest}")
    print(f"disk_guid={gpt['disk_guid']}")
    print(f"sector_size={SECTOR_SIZE}")
    print(f"old_apfs=6..{apfs['last']} ({gib(apfs['last'] - 5):.6f} GiB)")
    print(f"resize_apfs_bytes={new_apfs_bytes}")
    print(f"new_apfs=6..{new_apfs_last} ({gib(new_apfs_sectors):.6f} GiB)")
    print()
    print("APPLIED GPT PLAN")
    print(f"1  Container  6..{new_apfs_last}  AF0A")
    for index, (name, first, last) in enumerate(layout, start=2):
        sectors = last - first + 1
        print(f"{index}  {name:<8}  {first}..{last}  8300  {gib(sectors):.6f} GiB")
    print()
    print("This program only validates and prints; it does not write APFS or GPT.")


if __name__ == "__main__":
    main()
