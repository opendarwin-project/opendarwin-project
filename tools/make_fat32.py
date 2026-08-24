#!/usr/bin/env python3
"""Hand-build a minimal FAT32 image with files/directories for kernel smoke tests.

Usage:
  make_fat32.py <out.img> <name-or-path> <source-file>
  make_fat32.py <out.img> --multi <path>=<source-file> ...
"""

import math
import struct
import sys
from pathlib import PurePosixPath

SECTOR = 512
SECTORS_PER_CLUSTER = 1
RESERVED_SECTORS = 32
NUM_FATS = 2
ATTR_DIR = 0x10
ATTR_ARCHIVE = 0x20
ATTR_LFN = 0x0F


class Node:
    def __init__(self, name, is_dir):
        self.name = name
        self.is_dir = is_dir
        self.children = {}
        self.data = b""
        self.cluster = 0
        self.clusters = 1


def sanitize_short(name, used):
    base, dot, ext = name.rpartition(".")
    if not dot:
        base, ext = name, ""

    def clean(s):
        out = "".join(c for c in s.upper() if c.isalnum() or c in "_$~")
        return out or "X"

    raw_base = clean(base)[:8]
    raw_ext = clean(ext)[:3]
    candidate = (raw_base, raw_ext)
    n = 1
    while candidate in used:
        suffix = "~" + str(n)
        candidate = ((clean(base)[: 8 - len(suffix)] + suffix)[:8], raw_ext)
        n += 1
    used.add(candidate)
    return candidate


def lfn_entries(long_name, short11):
    # FAT checksum is ignored by the kernel reader, but fill it for sanity.
    chk = 0
    for b in short11:
        chk = (((chk & 1) << 7) + (chk >> 1) + b) & 0xFF
    chars = [ord(c) if ord(c) < 0x10000 else ord("?") for c in long_name]
    chunks = [chars[i : i + 13] for i in range(0, len(chars), 13)] or [[]]
    entries = []
    positions = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
    for idx in range(len(chunks) - 1, -1, -1):
        ent = bytearray([0xFF] * 32)
        ent[0] = idx + 1
        if idx == len(chunks) - 1:
            ent[0] |= 0x40
        ent[11] = ATTR_LFN
        ent[13] = chk
        chunk = chunks[idx]
        vals = chunk + ([0] if len(chunk) < 13 else [])
        vals += [0xFFFF] * (13 - len(vals))
        for p, ch in zip(positions, vals):
            struct.pack_into("<H", ent, p, ch)
        entries.append(bytes(ent))
    return entries


def short_entry(node, short_base, short_ext, is_dir):
    ent = bytearray(32)
    ent[0:8] = short_base.encode("ascii").ljust(8, b" ")
    ent[8:11] = short_ext.encode("ascii").ljust(3, b" ")
    ent[11] = ATTR_DIR if is_dir else ATTR_ARCHIVE
    struct.pack_into("<H", ent, 20, (node.cluster >> 16) & 0xFFFF)
    struct.pack_into("<H", ent, 26, node.cluster & 0xFFFF)
    struct.pack_into("<I", ent, 28, 0 if is_dir else len(node.data))
    return bytes(ent)


def add_path(root, path, data):
    parts = [p for p in PurePosixPath(path).parts if p not in ("/", "")]
    cur = root
    for part in parts[:-1]:
        cur = cur.children.setdefault(part, Node(part, True))
    leaf = Node(parts[-1], False)
    leaf.data = data
    cur.children[parts[-1]] = leaf


def walk_dirs(node):
    yield node
    for child in node.children.values():
        if child.is_dir:
            yield from walk_dirs(child)


def walk_all(node):
    yield node
    for child in node.children.values():
        yield from walk_all(child)


def dir_bytes(node):
    used = set()
    out = bytearray()
    for child in node.children.values():
        sb, se = sanitize_short(child.name, used)
        short11 = sb.encode("ascii").ljust(8, b" ") + se.encode("ascii").ljust(3, b" ")
        if child.name.upper() != (sb + ("." + se if se else "")):
            for ent in lfn_entries(child.name, short11):
                out += ent
        out += short_entry(child, sb, se, child.is_dir)
    out += b"\x00" * SECTOR
    return bytes(out[: math.ceil(len(out) / SECTOR) * SECTOR])


def build(out_path, files, total_sectors=64 * 1024):
    root = Node("", True)
    for path, data in files:
        add_path(root, path, data)

    next_cluster = 2
    for node in walk_all(root):
        node.cluster = next_cluster
        payload_len = len(dir_bytes(node)) if node.is_dir else len(node.data)
        node.clusters = max(1, math.ceil(payload_len / SECTOR))
        next_cluster += node.clusters

    fat_size = max(512, math.ceil((next_cluster * 4) / SECTOR))
    first_data_sector = RESERVED_SECTORS + NUM_FATS * fat_size
    min_sectors = first_data_sector + next_cluster * SECTORS_PER_CLUSTER + 1024
    if total_sectors is None or total_sectors < min_sectors:
        total_sectors = min_sectors

    img = bytearray(total_sectors * SECTOR)
    bs = bytearray(SECTOR)
    bs[0:3] = b"\xeb\x58\x90"
    bs[3:11] = b"MSWIN4.1"
    struct.pack_into("<H", bs, 11, SECTOR)
    bs[13] = SECTORS_PER_CLUSTER
    struct.pack_into("<H", bs, 14, RESERVED_SECTORS)
    bs[16] = NUM_FATS
    struct.pack_into("<H", bs, 17, 0)
    struct.pack_into("<H", bs, 19, 0)
    bs[21] = 0xF8
    struct.pack_into("<H", bs, 22, 0)
    struct.pack_into("<H", bs, 24, 63)
    struct.pack_into("<H", bs, 26, 255)
    struct.pack_into("<I", bs, 28, 0)
    struct.pack_into("<I", bs, 32, total_sectors)
    struct.pack_into("<I", bs, 36, fat_size)
    struct.pack_into("<H", bs, 40, 0)
    struct.pack_into("<H", bs, 42, 0)
    struct.pack_into("<I", bs, 44, root.cluster)
    struct.pack_into("<H", bs, 48, 1)
    struct.pack_into("<H", bs, 50, 6)
    bs[66] = 0x29
    struct.pack_into("<I", bs, 67, 0x12345678)
    bs[71:82] = b"ROOTFS     "[:11]
    bs[82:90] = b"FAT32   "
    bs[510:512] = b"\x55\xaa"
    img[0:SECTOR] = bs

    def write_fat(fat_index):
        base = (RESERVED_SECTORS + fat_index * fat_size) * SECTOR
        struct.pack_into("<I", img, base + 0, 0x0FFFFFF8)
        struct.pack_into("<I", img, base + 4, 0x0FFFFFFF)
        for node in walk_all(root):
            for j in range(node.clusters):
                cluster = node.cluster + j
                value = 0x0FFFFFFF if j == node.clusters - 1 else cluster + 1
                struct.pack_into("<I", img, base + cluster * 4, value)

    write_fat(0)
    write_fat(1)

    for node in walk_all(root):
        payload = dir_bytes(node) if node.is_dir else node.data
        start = (first_data_sector + (node.cluster - 2)) * SECTOR
        img[start : start + len(payload)] = payload

    with open(out_path, "wb") as f:
        f.write(img)


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    out = argv[1]
    specs = []
    if argv[2] == "--multi":
        for spec in argv[3:]:
            name, src = spec.split("=", 1)
            specs.append((name, src))
    else:
        specs.append((argv[2], argv[3]))
    files = []
    for name, src in specs:
        with open(src, "rb") as f:
            files.append((name, f.read()))
    build(out, files)
    for name, src in specs:
        size = len(open(src, "rb").read())
        note = " [autorun]" if name == "MAIN" or name.endswith("/MAIN") else ""
        print(f"wrote {out}: {name} <- {src} ({size} bytes){note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
