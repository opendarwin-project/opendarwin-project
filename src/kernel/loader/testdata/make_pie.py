#!/usr/bin/env python3
"""
Post-process a static arm64 Mach-O into PIE by:
  1. Setting MH_PIE flag in header
  2. Inserting LC_DYLD_INFO_ONLY into the 64-byte gap between end of
     original commands (offset 0x390) and __text section (offset 0x3d0)
  3. Appending rebase opcodes at end-of-file
  4. Updating header ncmds, sizeofcmds, flags

Does NOT shift any segment/section content — the command insert fits in
the pre-existing padding area.
"""

import struct, sys

MH_MAGIC_64 = 0xfeedfacf
LC_SEGMENT_64 = 0x19
LC_UNIXTHREAD = 0x5
LC_DYLD_INFO_ONLY = 0x8000000B
MH_PIE = 0x200000
DYLDINFO_SIZE = 48  # 12 × uint32

REBASE_OPCODE_SET_TYPE_IMM = 0x10
REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB = 0x20
REBASE_OPCODE_DO_REBASE_IMM_TIMES = 0x50
REBASE_OPCODE_DONE = 0x00
REBASE_TYPE_POINTER = 1


def read_u64(data, off):
    return struct.unpack_from('<Q', data, off)[0]


def read_u32(data, off):
    return struct.unpack_from('<I', data, off)[0]


def main():
    with open(sys.argv[1], 'rb') as f:
        data = bytearray(f.read())

    magic = read_u32(data, 0)
    ncmds = read_u32(data, 16)
    sizeofcmds = read_u32(data, 20)
    flags = read_u32(data, 24)

    assert magic == MH_MAGIC_64

    # Parse segments: find __DATA address and the absolute pointer
    off = 32
    segs = []  # (segname, vmaddr, vmsize, fileoff, filesize)
    data_rebase_targets = []  # (vmaddr, fileoff, size) for __DATA sections

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmd == LC_SEGMENT_64:
            segname = data[off+8:off+24].rstrip(b'\x00').decode()
            vmaddr, vmsize = struct.unpack_from('<QQ', data, off+24)
            fileoff, filesize = struct.unpack_from('<QQ', data, off+40)
            nsects = struct.unpack_from('<I', data, off+64)[0]
            segs.append((segname, vmaddr, vmsize, fileoff, filesize))

            if segname == '__DATA':
                for s in range(nsects):
                    so = off + 72 + s * 80
                    saddr, ssize = struct.unpack_from('<QQ', data, so+32)
                    soff = struct.unpack_from('<I', data, so+48)[0]
                    data_rebase_targets.append((saddr, soff, ssize))
        off += cmdsize

    # Build rebase opcodes
    # Find __DATA segment index and vmaddr
    data_seg_vmaddr = None
    data_seg_idx = None
    for i, (sn, sv, *_) in enumerate(segs):
        if sn == '__DATA':
            data_seg_vmaddr = sv
            data_seg_idx = i
            break
    assert data_seg_idx is not None, "No __DATA segment"

    rebase = bytearray()
    for saddr, soff, ssize in data_rebase_targets:
        rel_off = saddr - data_seg_vmaddr  # offset within __DATA
        for ptr_off in range(0, ssize, 8):
            total_off = rel_off + ptr_off
            rebase.append(REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER)
            rebase.append(REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | data_seg_idx)
            v = total_off
            while v >= 128:
                rebase.append((v & 0x7F) | 0x80)
                v >>= 7
            rebase.append(v & 0x7F)
            rebase.append(REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1)
    rebase.append(REBASE_OPCODE_DONE)

    # Append rebase opcodes at end of file
    rebase_foff = len(data)
    data.extend(rebase)

    # ---- Insert LC_DYLD_INFO_ONLY into command area ----
    # The original commands end at offset 32 + sizeofcmds.
    # The __text section starts at offset 0x3d0.
    # Gap = 0x3d0 - (32 + sizeofcmds) bytes.
    # We have DYLDINFO_SIZE bytes to insert; gap must be >= DYLDINFO_SIZE.
    orig_cmd_end = 32 + sizeofcmds
    gap = 0x3d0 - orig_cmd_end
    assert gap >= DYLDINFO_SIZE, f"Gap {gap} < {DYLDINFO_SIZE} bytes"

    # Insert position: after the last real command.
    # We need to find where LC_UNIXTHREAD is and put dyldinfo after it (or before).
    # For simplicity, insert right at the end of original commands.
    insert_pos = orig_cmd_end

    dyldinfo_bytes = struct.pack('<IIIIIIIIIIII',
                                 LC_DYLD_INFO_ONLY, DYLDINFO_SIZE,
                                 rebase_foff, len(rebase),
                                 0, 0, 0, 0, 0, 0, 0, 0)

    # We need to INSERT (not overwrite) the dyldinfo into the command area.
    # Since there's a gap after the commands before __text, we shift the
    # intervening bytes right by DYLDINFO_SIZE.
    # This works as long as the insert point + DYLDINFO_SIZE <= 0x3d0.
    assert insert_pos + DYLDINFO_SIZE <= 0x3d0, f"Insert {hex(insert_pos+48)} > 0x3d0"

    # Actually, since we're inserting into the gap (which is all zeros/padding),
    # we can just overwrite the bytes at insert_pos.
    data[insert_pos:insert_pos + DYLDINFO_SIZE] = dyldinfo_bytes

    # Update header
    struct.pack_into('<I', data, 16, ncmds + 1)
    struct.pack_into('<I', data, 20, sizeofcmds + DYLDINFO_SIZE)
    struct.pack_into('<I', data, 24, flags | MH_PIE)

    with open(sys.argv[2], 'wb') as f:
        f.write(data)

    print(f"Written {len(data)} bytes to {sys.argv[2]}")
    print(f"  ncmds: {ncmds} -> {ncmds + 1}")
    print(f"  sizeofcmds: {sizeofcmds} -> {sizeofcmds + DYLDINFO_SIZE}")
    print(f"  flags: {hex(flags)} -> {hex(flags | MH_PIE)}")
    print(f"  rebase: {len(rebase)} bytes at foff {hex(rebase_foff)}")
    print(f"  gap: {gap} bytes, inserted at {hex(insert_pos)}")
    print(f"  Rebase opcodes: {rebase.hex()}")

    # Verify after write
    print(f"\nVerification:")
    print(f"  Header flags: {hex(read_u32(data, 24))} (MH_PIE: {bool(read_u32(data, 24) & MH_PIE)})")
    print(f"  __DATA pointer: {hex(read_u64(data, 0x4000))}")

    off = 32
    cmd_count = read_u32(data, 16)
    for i in range(cmd_count):
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmd == LC_DYLD_INFO_ONLY:
            ro = read_u32(data, off+8)
            rs = read_u32(data, off+12)
            print(f"  LC_DYLD_INFO_ONLY: cmdsize={cmdsize} rebase_off={hex(ro)} rebase_size={rs}")
            print(f"  Rebase bytes at {hex(ro)}: {data[ro:ro+rs].hex()}")
        off += cmdsize

    # Quick verify: run otool
    import subprocess
    r = subprocess.run(['otool', '-tV', sys.argv[2]], capture_output=True, text=True)
    lines = r.stdout.strip().split('\n')
    print(f"\n  __text ({len(lines)} lines):")
    for l in lines[:5]:
        print(f"    {l}")


if __name__ == '__main__':
    main()
