//! Chained-fixups (LC_DYLD_CHAINED_FIXUPS) support for modern Mach-O binaries.

pub const LC_DYLD_CHAINED_FIXUPS: u32 = 0x34 | 0x80000000;
pub const PTR_ARM64E_USERLAND24: u16 = 12;
const CHAIN_START_NONE: u16 = 0xFFFF;
const DYLD_CHAINED_IMPORT: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DyldError {
    Truncated,
    UnsupportedImportFormat,
    UnsupportedPointerFormat,
    UnresolvedSymbol,
}

pub type Resolver = fn(ctx: *mut u8, ordinal: u8, name: &str) -> Option<u64>;

#[derive(Clone, Copy)]
pub struct Import<'a> {
    pub ordinal: u8,
    pub name: &'a str,
}

#[repr(C)]
struct ChainedFixupsHeader {
    fixups_version: u32,
    starts_offset: u32,
    imports_offset: u32,
    symbols_offset: u32,
    imports_count: u32,
    imports_format: u32,
    symbols_format: u32,
}

struct SegStarts<'a> {
    page_size: u16,
    pointer_format: u16,
    segment_offset: u64,
    page_starts: &'a [u16],
}

fn read_u16_le(bytes: &[u8]) -> u16 {
    u16::from_le_bytes([bytes[0], bytes[1]])
}

fn read_u32_le(bytes: &[u8]) -> u32 {
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

fn read_u64_le(bytes: &[u8]) -> u64 {
    u64::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ])
}

fn read_seg_starts<'a>(bytes: &'a [u8]) -> Result<SegStarts<'a>, DyldError> {
    if bytes.len() < 22 {
        return Err(DyldError::Truncated);
    }
    let page_size = read_u16_le(&bytes[4..6]);
    let pointer_format = read_u16_le(&bytes[6..8]);
    let segment_offset = read_u64_le(&bytes[8..16]);
    let page_count = read_u16_le(&bytes[20..22]) as usize;
    let starts_bytes = &bytes[22..];
    if starts_bytes.len() < page_count * 2 {
        return Err(DyldError::Truncated);
    }
    let page_starts =
        unsafe { core::slice::from_raw_parts(starts_bytes.as_ptr() as *const u16, page_count) };
    Ok(SegStarts {
        page_size,
        pointer_format,
        segment_offset,
        page_starts,
    })
}

fn read_import<'a>(
    fixups_bytes: &'a [u8],
    hdr: &ChainedFixupsHeader,
    index: u8,
) -> Result<Import<'a>, DyldError> {
    let imports_start = hdr.imports_offset as usize;
    let off = imports_start + (index as usize) * 4;
    if off + 4 > fixups_bytes.len() {
        return Err(DyldError::Truncated);
    }
    let entry = read_u32_le(&fixups_bytes[off..off + 4]);
    let lib_ordinal = (entry & 0xff) as u8;
    let name_offset = (entry >> 9) as usize;

    let symbols_start = hdr.symbols_offset as usize;
    let str_pos = symbols_start + name_offset;
    if str_pos >= fixups_bytes.len() {
        return Err(DyldError::Truncated);
    }
    let name_bytes = &fixups_bytes[str_pos..];
    let end = name_bytes
        .iter()
        .position(|&b| b == 0)
        .unwrap_or(name_bytes.len());
    let name = core::str::from_utf8(&name_bytes[..end]).map_err(|_| DyldError::Truncated)?;
    Ok(Import {
        ordinal: lib_ordinal,
        name,
    })
}

pub fn apply_chained_fixups(
    fixups_bytes: &[u8],
    base_pa: u64,
    resolver: Resolver,
    resolver_ctx: *mut u8,
) -> Result<(), DyldError> {
    if fixups_bytes.len() < core::mem::size_of::<ChainedFixupsHeader>() {
        return Err(DyldError::Truncated);
    }
    let hdr = unsafe { &*(fixups_bytes.as_ptr() as *const ChainedFixupsHeader) };
    if hdr.imports_format != DYLD_CHAINED_IMPORT {
        return Err(DyldError::UnsupportedImportFormat);
    }

    let starts_start = hdr.starts_offset as usize;
    if starts_start + 4 > fixups_bytes.len() {
        return Err(DyldError::Truncated);
    }
    let starts_bytes = &fixups_bytes[starts_start..];
    let seg_count = read_u32_le(&starts_bytes[0..4]) as usize;

    for seg_idx in 0..seg_count {
        let off_pos = 4 + seg_idx * 4;
        if off_pos + 4 > starts_bytes.len() {
            break;
        }
        let seg_info_off = read_u32_le(&starts_bytes[off_pos..off_pos + 4]) as usize;
        if seg_info_off == 0 {
            continue;
        }

        let s = read_seg_starts(&starts_bytes[seg_info_off..])?;
        if s.pointer_format != PTR_ARM64E_USERLAND24 {
            return Err(DyldError::UnsupportedPointerFormat);
        }

        for (page, &start) in s.page_starts.iter().enumerate() {
            if start == CHAIN_START_NONE {
                continue;
            }
            let mut slot_pa =
                base_pa + s.segment_offset + (page as u64) * (s.page_size as u64) + (start as u64);
            loop {
                let ptr = slot_pa as *mut u64;
                let raw = unsafe { *ptr };
                let auth = (raw >> 63) & 1;
                let bind = (raw >> 62) & 1;
                let next = (raw >> 51) & 0x7FF;

                if bind == 1 {
                    let ordinal = (raw & 0xFF) as u8;
                    let addend_field = (raw >> 32) & 0x7FFFF;
                    let import = read_import(fixups_bytes, hdr, ordinal)?;
                    let resolved = resolver(resolver_ctx, import.ordinal, import.name)
                        .ok_or(DyldError::UnresolvedSymbol)?;
                    let addend = if auth == 0 { addend_field } else { 0 };
                    unsafe {
                        *ptr = resolved.wrapping_add(addend);
                    }
                } else {
                    let target = if auth == 0 {
                        raw & 0x7FFF_FFFF_FFF
                    } else {
                        raw & 0xFFFF_FFFF
                    };
                    unsafe {
                        *ptr = base_pa.wrapping_add(target);
                    }
                }

                if next == 0 {
                    break;
                }
                slot_pa += next * 8;
            }
        }
    }

    Ok(())
}

pub fn find_chained_fixups<'a>(
    image: &'a [u8],
    ncmds: u32,
    load_commands_off: usize,
) -> Option<&'a [u8]> {
    let mut off = load_commands_off;
    for _ in 0..ncmds {
        if off + 8 > image.len() {
            return None;
        }
        let cmd = read_u32_le(&image[off..off + 4]);
        let cmdsize = read_u32_le(&image[off + 4..off + 8]) as usize;
        if cmd == LC_DYLD_CHAINED_FIXUPS {
            let dataoff = read_u32_le(&image[off + 8..off + 12]) as usize;
            let datasize = read_u32_le(&image[off + 12..off + 16]) as usize;
            if dataoff + datasize > image.len() {
                return None;
            }
            return Some(&image[dataoff..dataoff + datasize]);
        }
        off += cmdsize;
    }
    None
}
