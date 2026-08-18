#!/usr/bin/env bash
# Rebuilds the embedded ramdisk (src/kernel/src/ramdisk.fat32.lz4): a minimal
# FAT32 image, `lz4rip`-compressed and checked into the tree so kernel-lib's
# `include_bytes!` can embed it directly (see src/kernel/src/ramdisk.rs).
#
# Not part of the buck2 build graph - run this manually whenever the
# embedded rootfs content changes, then commit the regenerated .lz4 blob.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

content_dir="$(mktemp -d)"
trap 'rm -rf "$content_dir"' EXIT

cat > "$content_dir/HELLO.TXT" <<'EOF'
Hello from the OpenDarwin embedded ramdisk!
This FAT32 image was compressed with lz4rip and linked directly
into the kernel binary - no removable storage or virtio-blk needed.
EOF

fat_img="$(mktemp -t ramdisk-XXXXXX.fat32.img)"
trap 'rm -f "$fat_img"' EXIT
python3 tools/make_fat32.py "$fat_img" HELLO.TXT "$content_dir/HELLO.TXT"

mkramdisk="$(buck2 build //tools/mkramdisk:mkramdisk --show-simple-output)"
"$mkramdisk" "$fat_img" src/kernel/src/ramdisk.fat32.lz4

echo "==> wrote src/kernel/src/ramdisk.fat32.lz4"
