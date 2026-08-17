//! Mach-O dyld chained fixups parsing and binding.

pub type Resolver = fn(ctx: *mut u8, ordinal: u8, name: &str) -> Option<u64>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DyldError {
    InvalidHeader,
    InvalidStarts,
    InvalidImport,
    ResolutionFailed,
    BufferTooSmall,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct DyldChainedFixupsHeader {
    pub fixups_version: u32,
    pub starts_offset: u32,
    pub imports_offset: u32,
    pub symbols_offset: u32,
    pub imports_count: u32,
    pub imports_format: u32,
    pub symbols_format: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct DyldChainedStartsInImage {
    pub seg_count: u32,
    pub seg_info_offset: [u32; 1],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct DyldChainedStartsInSegment {
    pub size: u32,
    pub page_size: u16,
    pub pointer_format: u16,
    pub segment_offset: u64,
    pub max_valid_pointer: u32,
    pub page_count: u16,
    pub page_start: [u16; 1],
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Import<'a> {
    pub name: &'a str,
    pub lib_ordinal: u8,
    pub weak: bool,
}

pub const DYLD_CHAINED_PTR_ARM64E: u16 = 1;
pub const DYLD_CHAINED_PTR_64: u16 = 2;
pub const DYLD_CHAINED_PTR_32: u16 = 3;
pub const DYLD_CHAINED_PTR_32_SIGN_EXTENDED: u16 = 4;
pub const DYLD_CHAINED_PTR_ARM64E_KERNEL: u16 = 7;
pub const DYLD_CHAINED_PTR_64_OFFSET: u16 = 6;
pub const DYLD_CHAINED_PTR_ARM64E_USERLAND: u16 = 11;
pub const DYLD_CHAINED_PTR_ARM64E_USERLAND24: u16 = 12;

pub fn find_chained_fixups(bytes: &[u8]) -> Option<&DyldChainedFixupsHeader> {
    if bytes.len() < core::mem::size_of::<DyldChainedFixupsHeader>() {
        return None;
    }
    unsafe { Some(&*(bytes.as_ptr() as *const DyldChainedFixupsHeader)) }
}

fn read_symbol<'a>(symbols_pool: &'a [u8], offset: usize) -> Option<&'a str> {
    if offset >= symbols_pool.len() {
        return None;
    }
    let rest = &symbols_pool[offset..];
    let end = rest.iter().position(|&b| b == 0).unwrap_or(rest.len());
    core::str::from_utf8(&rest[..end]).ok()
}

pub fn apply_chained_fixups(
    fixups_bytes: &[u8],
    segment_bytes: &mut [u8],
    segment_vmaddr: u64,
    slide: u64,
    resolver: Option<Resolver>,
    resolver_ctx: *mut u8,
) -> Result<(), DyldError> {
    if fixups_bytes.len() < core::mem::size_of::<DyldChainedFixupsHeader>() {
        return Err(DyldError::InvalidHeader);
    }
    let header = unsafe { &*(fixups_bytes.as_ptr() as *const DyldChainedFixupsHeader) };
    let starts_off = header.starts_offset as usize;
    if starts_off >= fixups_bytes.len() {
        return Err(DyldError::InvalidStarts);
    }

    let starts_in_image = unsafe {
        &*(fixups_bytes.as_ptr().add(starts_off) as *const DyldChainedStartsInImage)
    };

    let seg_count = starts_in_image.seg_count as usize;
    let seg_offsets_slice = unsafe {
        let ptr = fixups_bytes
            .as_ptr()
            .add(starts_off + core::mem::size_of::<u32>()) as *const u32;
        core::slice::from_raw_parts(ptr, seg_count)
    };

    let imports_off = header.imports_offset as usize;
    let symbols_off = header.symbols_offset as usize;
    let symbols_pool = if symbols_off < fixups_bytes.len() {
        &fixups_bytes[symbols_off..]
    } else {
        &[]
    };

    for &seg_info_off in seg_offsets_slice {
        if seg_info_off == 0 {
            continue;
        }
        let seg_starts_off = starts_off + seg_info_off as usize;
        if seg_starts_off >= fixups_bytes.len() {
            continue;
        }
        let seg_starts = unsafe {
            &*(fixups_bytes.as_ptr().add(seg_starts_off) as *const DyldChainedStartsInSegment)
        };

        let page_size = seg_starts.page_size as usize;
        if page_size == 0 {
            continue;
        }
        let pointer_format = seg_starts.pointer_format;
        let page_count = seg_starts.page_count as usize;
        let seg_offset = seg_starts.segment_offset;

        if seg_offset != segment_vmaddr && seg_offset != 0 {
            // Segment offset within mapping
        }

        let page_starts_slice = unsafe {
            let ptr = fixups_bytes.as_ptr().add(
                seg_starts_off
                    + core::mem::size_of::<DyldChainedStartsInSegment>()
                    - core::mem::size_of::<u16>(),
            ) as *const u16;
            core::slice::from_raw_parts(ptr, page_count)
        };

        for (page_idx, &start_val) in page_starts_slice.iter().enumerate() {
            if start_val == 0xffff {
                continue;
            }
            let page_offset = page_idx * page_size;
            let mut chain_off = page_offset + (start_val as usize);

            loop {
                if chain_off + 8 > segment_bytes.len() {
                    break;
                }

                let raw = u64::from_le_bytes([
                    segment_bytes[chain_off],
                    segment_bytes[chain_off + 1],
                    segment_bytes[chain_off + 2],
                    segment_bytes[chain_off + 3],
                    segment_bytes[chain_off + 4],
                    segment_bytes[chain_off + 5],
                    segment_bytes[chain_off + 6],
                    segment_bytes[chain_off + 7],
                ]);

                let (_is_bind, next_stride) = match pointer_format {
                    DYLD_CHAINED_PTR_ARM64E | DYLD_CHAINED_PTR_ARM64E_USERLAND | DYLD_CHAINED_PTR_ARM64E_USERLAND24 => {
                        let bind = (raw & (1 << 62)) != 0;
                        let next = ((raw >> 51) & 0x7ff) as usize;
                        if bind {
                            let ordinal = (raw & 0xffff) as usize;
                            let addend = ((raw >> 32) & 0x7ffff) as i64;
                            let name_off = if imports_off + (ordinal + 1) * 4 <= fixups_bytes.len() {
                                let imp_raw = u32::from_le_bytes([
                                    fixups_bytes[imports_off + ordinal * 4],
                                    fixups_bytes[imports_off + ordinal * 4 + 1],
                                    fixups_bytes[imports_off + ordinal * 4 + 2],
                                    fixups_bytes[imports_off + ordinal * 4 + 3],
                                ]);
                                (imp_raw & 0x00ff_ffff) as usize
                            } else {
                                0
                            };
                            let sym_name = read_symbol(symbols_pool, name_off).unwrap_or("");
                            if let Some(res) = resolver {
                                if let Some(target) = res(resolver_ctx, 0, sym_name) {
                                    let bound_val = (target as i64 + addend) as u64;
                                    segment_bytes[chain_off..chain_off + 8]
                                        .copy_from_slice(&bound_val.to_le_bytes());
                                } else {
                                    return Err(DyldError::ResolutionFailed);
                                }
                            }
                        } else {
                            let target = raw & 0x0000_ffff_ffff_ffff;
                            let slid = target.wrapping_add(slide);
                            let updated = (raw & !0x0000_ffff_ffff_ffff) | (slid & 0x0000_ffff_ffff_ffff);
                            segment_bytes[chain_off..chain_off + 8]
                                .copy_from_slice(&updated.to_le_bytes());
                        }
                        (bind, next * 8)
                    }
                    DYLD_CHAINED_PTR_64 | DYLD_CHAINED_PTR_64_OFFSET => {
                        let bind = (raw & (1 << 63)) != 0;
                        let next = ((raw >> 51) & 0xfff) as usize;
                        if bind {
                            let ordinal = (raw & 0x00ff_ffff) as usize;
                            let addend = ((raw >> 24) & 0xff) as i64;
                            let name_off = if imports_off + (ordinal + 1) * 4 <= fixups_bytes.len() {
                                let imp_raw = u32::from_le_bytes([
                                    fixups_bytes[imports_off + ordinal * 4],
                                    fixups_bytes[imports_off + ordinal * 4 + 1],
                                    fixups_bytes[imports_off + ordinal * 4 + 2],
                                    fixups_bytes[imports_off + ordinal * 4 + 3],
                                ]);
                                (imp_raw & 0x00ff_ffff) as usize
                            } else {
                                0
                            };
                            let sym_name = read_symbol(symbols_pool, name_off).unwrap_or("");
                            if let Some(res) = resolver {
                                if let Some(target) = res(resolver_ctx, 0, sym_name) {
                                    let bound_val = (target as i64 + addend) as u64;
                                    segment_bytes[chain_off..chain_off + 8]
                                        .copy_from_slice(&bound_val.to_le_bytes());
                                } else {
                                    return Err(DyldError::ResolutionFailed);
                                }
                            }
                        } else {
                            let target = raw & 0x0000_007f_ffff_ffff;
                            let slid = target.wrapping_add(slide);
                            let updated = (raw & !0x0000_007f_ffff_ffff) | (slid & 0x0000_007f_ffff_ffff);
                            segment_bytes[chain_off..chain_off + 8]
                                .copy_from_slice(&updated.to_le_bytes());
                        }
                        (bind, next * 4)
                    }
                    _ => (false, 0),
                };

                if next_stride == 0 {
                    break;
                }
                chain_off += next_stride;
            }
        }
    }

    Ok(())
}
