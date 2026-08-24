#!/usr/bin/env bash
# Rebuilds the embedded ramdisk (src/kernel/ramdisk.fat32.zst): a minimal
# FAT32 image, `zrip`-compressed (zstd) and checked into the tree so kernel-lib's
# `include_bytes!` can embed it directly (see src/kernel/ramdisk.rs).
#
# Not part of the buck2 build graph - run this manually whenever the
# embedded rootfs content changes, then commit the regenerated .zst blob.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

content_dir="$(mktemp -d)"
trap 'rm -rf "$content_dir"' EXIT

cat > "$content_dir/HELLO.TXT" <<'EOF'
Hello from the OpenDarwin embedded ramdisk!
This FAT32 image was compressed with zrip (zstd) and linked directly
into the kernel binary - no removable storage or virtio-blk needed.
EOF

echo "==> building deps//rust:brush-brush"
sh_bin="$(buck2 build deps//rust:brush-brush --target-platforms=root//platforms:macos-arm64 --show-simple-output)"
sh_stripped="$content_dir/sh"
cp "$sh_bin" "$sh_stripped"
strip -S -x "$sh_stripped" 2>/dev/null || strip "$sh_stripped" 2>/dev/null || true

echo "==> building //tools/mkramdisk:mkramdisk"
mkramdisk="$(buck2 build //tools/mkramdisk:mkramdisk --show-simple-output)"

fat_img="$(mktemp -t ramdisk-XXXXXX.fat32.img)"
trap 'rm -rf "$content_dir" "$fat_img"' EXIT

echo "==> creating FAT32 image"
python3 tools/make_fat32.py "$fat_img" --multi \
    HELLO.TXT="$content_dir/HELLO.TXT" \
    bin/sh="$sh_stripped" \
    sh="$sh_stripped"

echo "==> compressing ramdisk"
"$mkramdisk" "$fat_img" src/kernel/ramdisk.fat32.zst

echo "==> wrote src/kernel/ramdisk.fat32.zst"
