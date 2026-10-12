#!/usr/bin/env python3

"""Parse enough of Apple's ADT format to inventory storage-related nodes."""

from __future__ import annotations

import argparse
import hashlib
import struct
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Property:
    name: str
    value: bytes
    template: bool


@dataclass
class Node:
    properties: list[Property]
    children: list["Node"]

    @property
    def name(self) -> str:
        for prop in self.properties:
            if prop.name == "name":
                return prop.value.rstrip(b"\0").decode("ascii", "replace")
        return "<unnamed>"


def u32(data: bytes, offset: int) -> int:
    if offset + 4 > len(data):
        raise ValueError(f"truncated u32 at 0x{offset:x}")
    return struct.unpack_from("<I", data, offset)[0]


def parse_node(data: bytes, offset: int) -> tuple[Node, int]:
    prop_count = u32(data, offset)
    child_count = u32(data, offset + 4)
    offset += 8
    properties: list[Property] = []

    for _ in range(prop_count):
        if offset + 36 > len(data):
            raise ValueError(f"truncated property header at 0x{offset:x}")
        raw_name = data[offset : offset + 32]
        raw_size = u32(data, offset + 32)
        size = raw_size & 0x7FFFFFFF
        offset += 36
        end = offset + size
        if end > len(data):
            raise ValueError(f"truncated property value at 0x{offset:x}, size 0x{size:x}")
        properties.append(
            Property(
                raw_name.split(b"\0", 1)[0].decode("ascii", "replace"),
                data[offset:end],
                bool(raw_size & 0x80000000),
            )
        )
        offset = (end + 3) & ~3

    children: list[Node] = []
    for _ in range(child_count):
        child, offset = parse_node(data, offset)
        children.append(child)
    return Node(properties, children), offset


KEYWORDS = ("ans", "nvme", "sart", "dart", "apcie", "pcie")


def format_value(prop: Property) -> str:
    value = prop.value
    if prop.name in {"name", "compatible", "device_type"}:
        strings = [part.decode("ascii", "replace") for part in value.rstrip(b"\0").split(b"\0")]
        return repr(strings)
    if len(value) == 4:
        return f"u32=0x{struct.unpack('<I', value)[0]:x} raw={value.hex()}"
    if len(value) == 8:
        return f"u64=0x{struct.unpack('<Q', value)[0]:x} raw={value.hex()}"
    digest = hashlib.sha256(value).hexdigest()
    shown = value[:128].hex()
    suffix = "..." if len(value) > 128 else ""
    return f"sha256={digest} raw={shown}{suffix}"


def walk(node: Node, parent: str = ""):
    path = "/" if not parent else f"{parent.rstrip('/')}/{node.name}"
    yield path, node
    for child in node.children:
        yield from walk(child, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("adt", type=Path)
    args = parser.parse_args()
    data = args.adt.read_bytes()
    root, consumed = parse_node(data, 0)
    print(f"ADT bytes={len(data)} parsed={consumed} trailing={len(data) - consumed}")

    matched = 0
    for path, node in walk(root):
        lowered = path.lower()
        if not any(keyword in lowered for keyword in KEYWORDS):
            continue
        matched += 1
        print(f"\nNODE {path}")
        for prop in node.properties:
            marker = " template" if prop.template else ""
            print(f"  {prop.name} size=0x{len(prop.value):x}{marker}: {format_value(prop)}")

    print(f"\nMatched nodes: {matched}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
