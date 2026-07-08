#!/usr/bin/env python3
"""Hand-build a minimal FAT32 image with one file in the root directory, for
testing src/kernel/fs/fat.zig + drivers/virtio_blk.zig against `zig build
qemu -Drootfs=<image>`.

Pure userspace, no device nodes and no root/mkfs.fat dependency - just writes
bytes to a plain file.

Usage: make_fat32.py <out.img> <8.3-name, e.g. TEST.TXT> <source-file>
"""

import struct
import sys

SECTOR = 512
SECTORS_PER_CLUSTER = 1
RESERVED_SECTORS = 32
NUM_FATS = 2


def build(out_path, file_name_8_3, file_data, total_sectors=16 * 1024):  # 8MB image
    fat_size = 512  # sectors per FAT, generously oversized for this tiny image
    first_data_sector = RESERVED_SECTORS + NUM_FATS * fat_size
    root_cluster = 2

    img = bytearray(total_sectors * SECTOR)

    # --- BPB (boot sector) ---
    bs = bytearray(SECTOR)
    bs[0:3] = b"\xeb\x58\x90"
    bs[3:11] = b"MSWIN4.1"
    struct.pack_into("<H", bs, 11, SECTOR)  # bytes per sector
    bs[13] = SECTORS_PER_CLUSTER
    struct.pack_into("<H", bs, 14, RESERVED_SECTORS)
    bs[16] = NUM_FATS
    struct.pack_into("<H", bs, 17, 0)  # root entries (0 for FAT32)
    struct.pack_into("<H", bs, 19, 0)  # total sectors 16 (0 -> use 32-bit field)
    bs[21] = 0xF8  # media descriptor
    struct.pack_into("<H", bs, 22, 0)  # FAT size 16 (0 for FAT32)
    struct.pack_into("<H", bs, 24, 63)  # sectors per track (unused by our reader)
    struct.pack_into("<H", bs, 26, 255)  # heads (unused)
    struct.pack_into("<I", bs, 28, 0)  # hidden sectors
    struct.pack_into("<I", bs, 32, total_sectors)  # total sectors 32
    struct.pack_into("<I", bs, 36, fat_size)  # FAT size 32
    struct.pack_into("<H", bs, 40, 0)  # ext flags
    struct.pack_into("<H", bs, 42, 0)  # fs version
    struct.pack_into("<I", bs, 44, root_cluster)  # root cluster
    struct.pack_into("<H", bs, 48, 1)  # fsinfo sector
    struct.pack_into("<H", bs, 50, 6)  # backup boot sector
    bs[66] = 0x29  # boot signature
    struct.pack_into("<I", bs, 67, 0x12345678)  # volume id
    bs[71:82] = b"ROOTFS     "[:11]
    bs[82:90] = b"FAT32   "
    bs[510] = 0x55
    bs[511] = 0xAA
    img[0:SECTOR] = bs

    # --- FATs: cluster 0/1 reserved, cluster 2 (root dir) EOC, cluster 3 (file) EOC ---
    def write_fat(fat_index):
        base = (RESERVED_SECTORS + fat_index * fat_size) * SECTOR
        struct.pack_into("<I", img, base + 0, 0x0FFFFFF8)
        struct.pack_into("<I", img, base + 4, 0x0FFFFFFF)
        struct.pack_into("<I", img, base + 8, 0x0FFFFFFF)  # cluster 2 (root dir): EOC
        struct.pack_into("<I", img, base + 12, 0x0FFFFFFF)  # cluster 3 (file): EOC

    write_fat(0)
    write_fat(1)

    # --- Root directory (cluster 2) ---
    root_dir_offset = first_data_sector * SECTOR  # cluster 2 == first data cluster
    name, ext = (file_name_8_3.split(".") + [""])[:2]
    name = name.ljust(8)[:8].upper().encode("ascii")
    ext = ext.ljust(3)[:3].upper().encode("ascii")
    entry = bytearray(32)
    entry[0:8] = name
    entry[8:11] = ext
    entry[11] = 0x20  # archive attribute
    file_cluster = 3
    struct.pack_into("<H", entry, 20, (file_cluster >> 16) & 0xFFFF)
    struct.pack_into("<H", entry, 26, file_cluster & 0xFFFF)
    struct.pack_into("<I", entry, 28, len(file_data))
    img[root_dir_offset : root_dir_offset + 32] = entry

    # --- File data (cluster 3) ---
    file_offset = (first_data_sector + SECTORS_PER_CLUSTER) * SECTOR
    img[file_offset : file_offset + len(file_data)] = file_data

    with open(out_path, "wb") as f:
        f.write(img)


if __name__ == "__main__":
    out = sys.argv[1]
    fname = sys.argv[2]
    data = open(sys.argv[3], "rb").read()
    build(out, fname, data)
    print(f"wrote {out}: {fname} ({len(data)} bytes)")
