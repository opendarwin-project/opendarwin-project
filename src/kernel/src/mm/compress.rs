//! In-memory page compression using `lz4rip` for XNU-style memory compression.

use spin::Mutex;

pub const PAGE_SIZE: usize = 4096;
pub const MAX_COMPRESSED_PAGES: usize = 256;

#[derive(Clone, Copy)]
pub struct CompressedPageSlot {
    pub compressed_len: u16,
    pub original_pfn: u64,
    pub in_use: bool,
    pub data: [u8; PAGE_SIZE],
}

impl CompressedPageSlot {
    pub const fn empty() -> Self {
        Self {
            compressed_len: 0,
            original_pfn: 0,
            in_use: false,
            data: [0; PAGE_SIZE],
        }
    }
}

pub struct MemoryCompressor {
    slots: [CompressedPageSlot; MAX_COMPRESSED_PAGES],
    count: usize,
    total_uncompressed_bytes: usize,
    total_compressed_bytes: usize,
}

impl MemoryCompressor {
    pub const fn new() -> Self {
        Self {
            slots: [CompressedPageSlot::empty(); MAX_COMPRESSED_PAGES],
            count: 0,
            total_uncompressed_bytes: 0,
            total_compressed_bytes: 0,
        }
    }
}

static COMPRESSOR: Mutex<MemoryCompressor> = Mutex::new(MemoryCompressor::new());

/// Compress a 4096-byte physical page into the target buffer.
/// Returns the compressed length on success.
pub fn compress_page(src: &[u8; PAGE_SIZE], dst: &mut [u8]) -> Option<usize> {
    let compressed = lz4rip::compress(src);
    if compressed.len() < PAGE_SIZE && compressed.len() <= dst.len() {
        dst[..compressed.len()].copy_from_slice(&compressed);
        Some(compressed.len())
    } else {
        None
    }
}

/// Decompress a previously compressed buffer back into a 4096-byte page.
pub fn decompress_page(src: &[u8], dst: &mut [u8; PAGE_SIZE]) -> bool {
    match lz4rip::decompress(src, PAGE_SIZE) {
        Ok(decompressed) if decompressed.len() == PAGE_SIZE => {
            dst.copy_from_slice(&decompressed);
            true
        }
        _ => false,
    }
}

/// Store a 4KB page in the compressed memory pool.
/// Returns the slot index if compression was beneficial, or None if incompressible/full.
pub fn store_page(pfn: u64, page_data: &[u8; PAGE_SIZE]) -> Option<usize> {
    let mut state = COMPRESSOR.lock();
    for i in 0..MAX_COMPRESSED_PAGES {
        if !state.slots[i].in_use {
            let mut comp_buf = [0u8; PAGE_SIZE];
            let comp_len = compress_page(page_data, &mut comp_buf)?;
            let slot = &mut state.slots[i];
            slot.data[..comp_len].copy_from_slice(&comp_buf[..comp_len]);
            slot.compressed_len = comp_len as u16;
            slot.original_pfn = pfn;
            slot.in_use = true;
            state.count += 1;
            state.total_uncompressed_bytes += PAGE_SIZE;
            state.total_compressed_bytes += comp_len;
            return Some(i);
        }
    }
    None
}

/// Retrieve and decompress a page from the compressed pool.
pub fn fetch_page(slot_idx: usize, dst: &mut [u8; PAGE_SIZE]) -> bool {
    if slot_idx >= MAX_COMPRESSED_PAGES {
        return false;
    }
    let mut state = COMPRESSOR.lock();
    let comp_len = state.slots[slot_idx].compressed_len as usize;
    if !state.slots[slot_idx].in_use {
        return false;
    }

    let mut comp_buf = [0u8; PAGE_SIZE];
    comp_buf[..comp_len].copy_from_slice(&state.slots[slot_idx].data[..comp_len]);
    let ok = decompress_page(&comp_buf[..comp_len], dst);
    if ok {
        state.slots[slot_idx].in_use = false;
        state.count -= 1;
        state.total_uncompressed_bytes -= PAGE_SIZE;
        state.total_compressed_bytes -= comp_len;
    }
    ok
}

pub fn compression_stats() -> (usize, usize, usize) {
    let state = COMPRESSOR.lock();
    (
        state.count,
        state.total_uncompressed_bytes,
        state.total_compressed_bytes,
    )
}
