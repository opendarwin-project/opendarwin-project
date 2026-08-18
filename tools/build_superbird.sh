#!/usr/bin/env bash
# Build and package the OpenDarwin kernel for Amlogic Meson G12A (Spotify Car Thing / Superbird).
#
# Usage:
#   tools/build_superbird.sh [-b|--boot] [--dtb PATH]
#
# Output:
#   target/superbird/Image          Raw ARM64 Linux Image binary (load at 0x02000000)
#   target/superbird/boot.cmd        U-Boot boot source script
#   target/superbird/README.txt      Flashing & boot instructions
#
# For USB RAM-boot without any of the above packaging, prefer:
#   bazel run //tools/amlogic:ramboot -- [--dtb PATH]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

do_boot=0
dtb_arg=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--boot)
            do_boot=1
            shift
            ;;
        --dtb)
            dtb_arg="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

out_dir="target/superbird"
mkdir -p "$out_dir"

echo "==> Building OpenDarwin kernel Image for Meson G12A (hermetic llvm-objcopy)..."
bazel build //tools/amlogic:superbird_image >&2
image="$(bazel cquery //tools/amlogic:superbird_image --output=files 2>/dev/null)"
cp "$image" "$out_dir/Image"
chmod +w "$out_dir/Image"
echo "==> Image: $out_dir/Image"

cat << 'EOF' > "$out_dir/boot.cmd"
# OpenDarwin Superbird U-Boot Boot Script
# Assumes FAT partition on USB/eMMC containing Image and meson-g12a-superbird.dtb

echo "==> Loading OpenDarwin kernel Image..."
fatload usb 0:1 0x02000000 Image || fatload mmc 1:1 0x02000000 Image

echo "==> Loading Superbird Device Tree..."
fatload usb 0:1 0x08000000 meson-g12a-superbird.dtb || fatload mmc 1:1 0x08000000 meson-g12a-superbird.dtb

echo "==> Booting OpenDarwin via booti..."
booti 0x02000000 - 0x08000000
EOF

if command -v mkimage >/dev/null 2>&1; then
    mkimage -C none -A arm64 -T script -d "$out_dir/boot.cmd" "$out_dir/boot.scr" >/dev/null 2>&1 || true
fi

cat << 'EOF' > "$out_dir/README.txt"
OpenDarwin on Spotify Car Thing (Amlogic Meson G12A / Superbird)
================================================================

1. USB RAM-boot without flashing (recommended for testing):
     bazel run //tools/amlogic:ramboot -- [--dtb path/to/meson-g12a-superbird.dtb]
   Or via this packaging script:
     ./tools/build_superbird.sh --boot [--dtb path/to/meson-g12a-superbird.dtb]

2. SD card / USB Flash Drive boot:
     Copy `Image` (and `meson-g12a-superbird.dtb`) to the root of a FAT32-formatted USB drive.
     In U-Boot:
       fatload usb 0:1 0x02000000 Image
       fatload usb 0:1 0x08000000 meson-g12a-superbird.dtb
       booti 0x02000000 - 0x08000000

3. Visual Display Progress Beacon:
     - Solid Orange: Bootstrap entry
     - Top Bar Yellow: Memory & PMM initialized
     - Top Bar Cyan: GICv3 & Devicetree initialized
     - Top Bar Purple: IOKit & AmlogicFramebuffer matched
     - Multi-color Gradient + Green bar: Scheduler running & userland ready
     - Bright Red: Kernel panic / Exception fault indicator
EOF

echo "==> Build complete: $out_dir/Image ($(stat -c%s "$out_dir/Image" 2>/dev/null || stat -f%z "$out_dir/Image") bytes)"

if [ "$do_boot" -eq 1 ]; then
    boot_args=()
    if [ -n "$dtb_arg" ]; then
        boot_args+=(--dtb "$dtb_arg")
    fi
    echo "==> Initiating RAM-boot over USB..."
    exec bazel run //tools/amlogic:ramboot -- "${boot_args[@]}"
fi
