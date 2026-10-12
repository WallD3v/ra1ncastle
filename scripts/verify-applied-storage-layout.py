#!/usr/bin/env python3
"""Validate the post-resize primary GPT, backup GPT, and APFS NXSB."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import struct
import uuid
from pathlib import Path


SECTOR = 4096
DISK_GUID = "38d61900-8898-4aad-a6be-7f343356c1ca"
APFS_TYPE = "7c3457ef-0000-11aa-aa11-00306543ecac"
LINUX_TYPE = "0fc63daf-8483-4772-8e79-3d69d8477de4"
APFS_UUID = "07b0ed26-5173-40d0-b433-1fa38569f7c5"
CONTAINER_UUID = "5e6e2733-4efe-422e-bd9e-13aa18cb96a9"
EXPECTED = [
    ("Container", APFS_TYPE, APFS_UUID, 6, 14_052_095),
    ("system", LINUX_TYPE, None, 14_052_096, 14_904_063),
    ("vendor", LINUX_TYPE, None, 14_904_064, 15_002_367),
    ("metadata", LINUX_TYPE, None, 15_002_368, 15_018_751),
    ("userdata", LINUX_TYPE, None, 15_018_752, 15_624_993),
]


def guid(raw: bytes) -> str:
    return str(uuid.UUID(bytes_le=raw))


def parse_header(raw: bytes, offset: int) -> tuple:
    header = raw[offset : offset + SECTOR]
    assert header[:8] == b"EFI PART", "missing GPT signature"
    revision, size, stored_crc = struct.unpack_from("<III", header, 8)
    checked = bytearray(header[:size])
    struct.pack_into("<I", checked, 16, 0)
    assert binascii.crc32(checked) & 0xFFFFFFFF == stored_crc, "bad GPT header CRC"
    current, backup, first, last = struct.unpack_from("<QQQQ", header, 24)
    disk = guid(header[56:72])
    entries_lba, count, entry_size, entries_crc = struct.unpack_from("<QIII", header, 72)
    return revision, current, backup, first, last, disk, entries_lba, count, entry_size, entries_crc


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("primary", type=Path, help="LBA0-LBA6 snapshot")
    parser.add_argument("backup", type=Path, help="LBA15624995-LBA15624999 snapshot")
    args = parser.parse_args()
    primary = args.primary.read_bytes()
    backup = args.backup.read_bytes()
    assert len(primary) == 7 * SECTOR
    assert len(backup) == 5 * SECTOR

    ph = parse_header(primary, SECTOR)
    bh = parse_header(backup, 4 * SECTOR)
    assert ph[1:6] == (1, 15_624_999, 6, 15_624_994, DISK_GUID)
    assert bh[1:6] == (15_624_999, 1, 6, 15_624_994, DISK_GUID)

    primary_entries = primary[2 * SECTOR : 6 * SECTOR]
    backup_entries = backup[: 4 * SECTOR]
    assert primary_entries == backup_entries, "primary and backup entry arrays differ"
    assert binascii.crc32(primary_entries) & 0xFFFFFFFF == ph[-1] == bh[-1]

    for index, expected in enumerate(EXPECTED):
        entry = primary_entries[index * 128 : (index + 1) * 128]
        actual = (
            entry[56:128].decode("utf-16-le").rstrip("\0"),
            guid(entry[:16]),
            guid(entry[16:32]),
            *struct.unpack_from("<QQ", entry, 32),
        )
        name, type_guid, unique_guid, first, last = expected
        assert actual[0] == name and actual[1] == type_guid and actual[3:] == (first, last), actual
        if unique_guid:
            assert actual[2] == unique_guid, actual
        print(index + 1, actual)

    nxsb = primary[6 * SECTOR :]
    assert nxsb[32:36] == b"NXSB"
    block_size = struct.unpack_from("<I", nxsb, 36)[0]
    block_count = struct.unpack_from("<Q", nxsb, 40)[0]
    container_uuid = str(uuid.UUID(bytes=nxsb[72:88]))
    assert (block_size, block_count) == (4096, 14_052_090)
    assert container_uuid == CONTAINER_UUID

    print(f"entries_crc=0x{ph[-1]:08x}")
    print(f"container_bytes={block_size * block_count}")
    print(f"primary_sha256={hashlib.sha256(primary).hexdigest()}")
    print(f"backup_sha256={hashlib.sha256(backup).hexdigest()}")
    print("RA1NCASTLE_APPLIED_STORAGE_LAYOUT=PASS")


if __name__ == "__main__":
    main()
