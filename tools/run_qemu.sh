#!/usr/bin/env bash
# Build the OpenDarwin kernel with buck2 and boot it under QEMU's aarch64
# `virt` machine.
#
# Usage: tools/run_qemu.sh [-d ROOTFS_IMG] [-g] [-- QEMU_ARGS...]
#   -d ROOTFS_IMG  attach ROOTFS_IMG as a virtio-blk-device (mmio) drive;
#                  see tools/make_fat32.py for building one. Without this,
#                  the kernel boots but reports "no virtio-blk device found"
#                  and skips mounting a rootfs.
#   -g             also attach a virtio-gpu-pci device (needs a PCIe ECAM,
#                  which QEMU's virt machine provides automatically once any
#                  PCI device is present).
#   --             everything after this is passed through to qemu-system-aarch64
#                  verbatim (e.g. `-d int,guest_errors` for debugging).
#
# The kernel's boot/linker.ld places entry at KERNEL_LOAD_ADDR (0x40080000),
# 0x80000 above virt's RAM base (0x40000000). QEMU doesn't hand a DTB
# pointer via x0 for an ELF passed to -kernel (only the raw Linux "Image"
# boot protocol gets that) and, as of QEMU 11.x, doesn't auto-generate one
# in RAM for ELF boot either - confirmed empirically, so this script dumps
# virt's DTB itself and loads it explicitly via `-device loader` right past
# the kernel's own 6MB reservation (devicetree.rs's fallback address, kept
# in sync with mmu::KERNEL_LOAD_ADDR + mmu::KERNEL_IMAGE_MAX_LEN below).
# GICv2 (drivers/gic.rs) and PSCI CPU_ON via HVC (drivers/psci.rs, smp.rs)
# match virt's defaults, so no extra -M options are needed for those.
set -euo pipefail

# Must match devicetree.rs's discover() fallback: mmu::KERNEL_LOAD_ADDR
# (0x40080000) + mmu::KERNEL_IMAGE_MAX_LEN (0x600000).
dtb_addr=0x40680000

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

rootfs_img=""
attach_gpu=0
while getopts "d:g" opt; do
    case "$opt" in
        d) rootfs_img="$OPTARG" ;;
        g) attach_gpu=1 ;;
        *)
            echo "usage: $0 [-d ROOTFS_IMG] [-g] [-- QEMU_ARGS...]" >&2
            exit 2
            ;;
    esac
done
shift $((OPTIND - 1))
if [ "${1:-}" = "--" ]; then
    shift
fi

kernel="$(buck2 build //src/kernel:kernel --show-simple-output)"
echo "==> kernel: $kernel" >&2

machine_args=(-cpu max -smp 4 -m 512M)

dtb="$(mktemp -t opendarwin-virt-XXXXXX.dtb)"
trap 'rm -f "$dtb"' EXIT
qemu-system-aarch64 -M "virt,dumpdtb=$dtb" "${machine_args[@]}" -nographic >/dev/null 2>&1

qemu_args=(
    -M virt
    "${machine_args[@]}"
    -nographic
    -kernel "$kernel"
    -device "loader,file=$dtb,addr=$dtb_addr,force-raw=on"
)

if [ -n "$rootfs_img" ]; then
    qemu_args+=(
        -drive "if=none,format=raw,file=$rootfs_img,id=hd0"
        -device virtio-blk-device,drive=hd0
    )
fi

if [ "$attach_gpu" -eq 1 ]; then
    qemu_args+=(-device virtio-gpu-pci)
fi

echo "==> qemu-system-aarch64 ${qemu_args[*]} $*" >&2
exec qemu-system-aarch64 "${qemu_args[@]}" "$@"
