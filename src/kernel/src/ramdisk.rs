//! Embedded ramdisk rootfs: a minimal FAT32 image, `lz4rip`-compressed and
//! linked straight into the kernel binary (`ramdisk.fat32.lz4`, rebuilt via
//! `tools/build_ramdisk.sh`), so boards with no removable storage or
//! virtio-blk device - the Superbird chief among them - still get a rootfs
//! for `kext`/dylib loading.
//!
//! Decompressed once into a heap buffer at boot and exposed to
//! `vfs::fat` through the same [`vfs::BlockReader`] contract virtio-blk
//! uses - sector-granularity reads against an in-RAM byte slice rather
//! than a real block device.

use alloc::vec::Vec;
use spin::Mutex;

/// `[8-byte LE original length][lz4rip-compressed payload]`, produced by
/// `tools/mkramdisk` - see `tools/build_ramdisk.sh`.
static RAMDISK_LZ4: &[u8] = include_bytes!("ramdisk.fat32.lz4");

const SECTOR_SIZE: usize = 512;

static IMAGE: Mutex<Option<&'static [u8]>> = Mutex::new(None);

/// Decompresses the embedded FAT32 image into a leaked heap buffer and
/// mounts it as the VFS root, using the ordinary sector-reader `BlockReader`
/// contract. Idempotent: repeat calls reuse the already-decompressed image.
pub fn mount() -> bool {
    let mut image = IMAGE.lock();
    if image.is_none() {
        let Some(decompressed) = decompress(RAMDISK_LZ4) else {
            crate::drivers::uart::print("opendarwin: embedded ramdisk decompression failed\n");
            return false;
        };
        // Leaked once for the kernel's lifetime: the ramdisk is the root
        // filesystem, never freed, and `BlockReader` is a plain fn pointer
        // with no captured state to own it otherwise.
        *image = Some(Vec::leak(decompressed));
    }
    drop(image);

    vfs::set_block_reader(read_blocks);
    vfs::mount_fat()
}

fn decompress(blob: &[u8]) -> Option<Vec<u8>> {
    let (len_bytes, compressed) = blob.split_at_checked(8)?;
    let original_len = u64::from_le_bytes(len_bytes.try_into().ok()?) as usize;
    lz4rip::decompress(compressed, original_len)
        .ok()
        .filter(|d| d.len() == original_len)
}

fn read_blocks(sector: u64, count: u32, buf: &mut [u8]) -> bool {
    let Some(image) = *IMAGE.lock() else {
        return false;
    };
    let start = sector as usize * SECTOR_SIZE;
    let len = count as usize * SECTOR_SIZE;
    let Some(end) = start.checked_add(len) else {
        return false;
    };
    let Some(src) = image.get(start..end) else {
        return false;
    };
    let Some(dst) = buf.get_mut(..len) else {
        return false;
    };
    dst.copy_from_slice(src);
    true
}
