#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
IMAGE="$TEST_DIR/n104-gpt-test.img"
LOOPDEV=''

cleanup() {
  if [[ -n "$LOOPDEV" ]]; then
    losetup -d "$LOOPDEV" || true
  fi
}
trap cleanup EXIT INT TERM

truncate -s 64000000000 "$IMAGE"
dd if="$ROOT/logs/storage-before-resize/primary-gpt-and-nxsb.bin" \
  of="$IMAGE" bs=4096 count=6 conv=notrunc status=none
dd if="$ROOT/logs/storage-before-resize/backup-gpt.bin" \
  of="$IMAGE" bs=4096 seek=15624995 conv=notrunc status=none

LOOPDEV="$(losetup --find --show --sector-size 4096 "$IMAGE")"
[[ "$(blockdev --getss "$LOOPDEV")" == 4096 ]]
[[ "$(blockdev --getsz "$LOOPDEV")" == 125000000 ]] # units are 512-byte sectors

printf '%s\n' \
  d \
  n 1 6 14052095 AF0A \
  c Container \
  n 2 14052096 14904063 8300 \
  c 2 system \
  n 3 14904064 15002367 8300 \
  c 3 vendor \
  n 4 15002368 15018751 8300 \
  c 4 metadata \
  n 5 15018752 15624993 8300 \
  c 5 userdata \
  x c 1 07b0ed26-5173-40d0-b433-1fa38569f7c5 m \
  p v w y | gdisk "$LOOPDEV" | tee "$TEST_DIR/gdisk-write.txt"

sgdisk -p "$LOOPDEV"
sgdisk -i 1 "$LOOPDEV"
sgdisk -v "$LOOPDEV"

python3 - "$LOOPDEV" <<'PY'
import binascii
import os
import struct
import sys
import uuid

path = sys.argv[1]
fd = os.open(path, os.O_RDONLY)
try:
    data = os.pread(fd, 6 * 4096, 0)
finally:
    os.close(fd)

h = data[4096:8192]
assert h[:8] == b"EFI PART"
disk_guid = str(uuid.UUID(bytes_le=h[56:72]))
assert disk_guid == "38d61900-8898-4aad-a6be-7f343356c1ca"
entries_lba, count, size, entries_crc = struct.unpack_from("<QIII", h, 72)
entries = data[entries_lba * 4096 : entries_lba * 4096 + count * size]
assert binascii.crc32(entries) & 0xFFFFFFFF == entries_crc
expected = [
    ("Container", "7c3457ef-0000-11aa-aa11-00306543ecac", "07b0ed26-5173-40d0-b433-1fa38569f7c5", 6, 14052095),
    ("system", "0fc63daf-8483-4772-8e79-3d69d8477de4", None, 14052096, 14904063),
    ("vendor", "0fc63daf-8483-4772-8e79-3d69d8477de4", None, 14904064, 15002367),
    ("metadata", "0fc63daf-8483-4772-8e79-3d69d8477de4", None, 15002368, 15018751),
    ("userdata", "0fc63daf-8483-4772-8e79-3d69d8477de4", None, 15018752, 15624993),
]
for i, (name, type_guid, unique_guid, first, last) in enumerate(expected):
    e = entries[i * size : (i + 1) * size]
    actual = (
        e[56:128].decode("utf-16-le").rstrip("\0"),
        str(uuid.UUID(bytes_le=e[:16])),
        str(uuid.UUID(bytes_le=e[16:32])),
        *struct.unpack_from("<QQ", e, 32),
    )
    assert actual[0] == name, actual
    assert actual[1] == type_guid, actual
    if unique_guid is not None:
        assert actual[2] == unique_guid, actual
    assert actual[3:] == (first, last), actual
    print(i + 1, actual)
print("RA1NCASTLE_4K_GPT_DRY_RUN=PASS")
PY

printf 'Retained sparse test image at %s\n' "$IMAGE"
