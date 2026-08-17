//! dyld shared cache parsing and symbol export trie lookup.

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CacheHeader {
    pub magic: [u8; 16],
    pub mapping_offset: u32,
    pub mapping_count: u32,
    pub images_offset_old: u32,
    pub images_count_old: u32,
    pub dyld_base_address: u64,
    pub code_signature_offset: u64,
    pub code_signature_size: u64,
    pub slide_info_offset_unused: u64,
    pub slide_info_size_unused: u64,
    pub local_symbols_offset: u64,
    pub local_symbols_size: u64,
    pub uuid: [u8; 16],
    pub cache_type: u64,
    pub branch_pool_offsets_offset: u32,
    pub branch_pool_offsets_count: u32,
    pub dyld_sub_cache_entries_offset: u64,
    pub dyld_sub_cache_entries_count: u32,
    pub symbols_sub_cache_uuid: [u8; 16],
    pub closure_regions_offset: u64,
    pub closure_regions_size: u64,
    pub closure_trie_offset: u64,
    pub closure_trie_size: u64,
    pub platform: u32,
    pub format_version: u32,
    pub dylibs_expected_on_disk: u32,
    pub simulator: u32,
    pub dylibs_sub_cache_array_offset: u64,
    pub dylibs_sub_cache_array_count: u32,
    pub max_address: u64,
    pub mappings_with_slides_offset: u64,
    pub mappings_with_slides_count: u32,
    pub dylibs_image_array_offset: u64,
    pub dylibs_image_array_count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MappingInfo {
    pub address: u64,
    pub size: u64,
    pub file_offset: u64,
    pub max_prot: u32,
    pub init_prot: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MappingAndSlideInfo {
    pub address: u64,
    pub size: u64,
    pub file_offset: u64,
    pub slide_info_file_offset: u64,
    pub slide_info_file_size: u64,
    pub flags: u64,
    pub max_prot: u32,
    pub init_prot: u32,
}

pub type Mapping = MappingInfo;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct ImageInfo {
    pub address: u64,
    pub mod_time: u64,
    pub inode: u64,
    pub path_file_offset: u32,
    pub pad: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlideInfo5Header {
    pub version: u32,
    pub page_size: u32,
    pub page_starts_count: u32,
    pub pad: u32,
    pub value_add: u64,
}

pub fn read_header(bytes: &[u8]) -> Option<&CacheHeader> {
    if bytes.len() < core::mem::size_of::<CacheHeader>() {
        return None;
    }
    let magic = &bytes[0..16];
    if !magic.starts_with(b"dyld_v1") {
        return None;
    }
    unsafe { Some(&*(bytes.as_ptr() as *const CacheHeader)) }
}

pub fn mappings<'a>(bytes: &'a [u8], header: &CacheHeader) -> &'a [MappingInfo] {
    let off = header.mapping_offset as usize;
    let count = header.mapping_count as usize;
    let sz = core::mem::size_of::<MappingInfo>();
    if off + count * sz > bytes.len() {
        return &[];
    }
    unsafe {
        let ptr = bytes.as_ptr().add(off) as *const MappingInfo;
        core::slice::from_raw_parts(ptr, count)
    }
}

pub fn find_mapping_with_slide<'a>(
    bytes: &'a [u8],
    header: &CacheHeader,
) -> &'a [MappingAndSlideInfo] {
    if header.mappings_with_slides_count == 0 {
        return &[];
    }
    let off = header.mappings_with_slides_offset as usize;
    let count = header.mappings_with_slides_count as usize;
    let sz = core::mem::size_of::<MappingAndSlideInfo>();
    if off + count * sz > bytes.len() {
        return &[];
    }
    unsafe {
        let ptr = bytes.as_ptr().add(off) as *const MappingAndSlideInfo;
        core::slice::from_raw_parts(ptr, count)
    }
}

pub fn find_image(bytes: &[u8], header: &CacheHeader, path: &str) -> Option<u64> {
    let off = if header.dylibs_image_array_offset != 0 {
        header.dylibs_image_array_offset as usize
    } else {
        header.images_offset_old as usize
    };
    let count = if header.dylibs_image_array_count != 0 {
        header.dylibs_image_array_count as usize
    } else {
        header.images_count_old as usize
    };
    let sz = core::mem::size_of::<ImageInfo>();
    if off + count * sz > bytes.len() {
        return None;
    }
    let images: &[ImageInfo] = unsafe {
        let ptr = bytes.as_ptr().add(off) as *const ImageInfo;
        core::slice::from_raw_parts(ptr, count)
    };

    for img in images {
        let poff = img.path_file_offset as usize;
        if poff >= bytes.len() {
            continue;
        }
        let rest = &bytes[poff..];
        let end = rest.iter().position(|&b| b == 0).unwrap_or(rest.len());
        if let Ok(p) = core::str::from_utf8(&rest[..end]) {
            if p == path {
                return Some(img.address);
            }
        }
    }
    None
}

pub fn address_to_file_offset(_header: &CacheHeader, mappings: &[MappingInfo], addr: u64) -> Option<u64> {
    for m in mappings {
        if addr >= m.address && addr < m.address + m.size {
            return Some(m.file_offset + (addr - m.address));
        }
    }
    None
}

pub fn linkedit_dataoff_to_address(mappings: &[MappingInfo], dataoff: u64) -> Option<u64> {
    for m in mappings {
        if (m.init_prot & 2) == 0 && dataoff >= m.file_offset && dataoff < m.file_offset + m.size {
            return Some(m.address + (dataoff - m.file_offset));
        }
    }
    None
}

fn read_uleb128(bytes: &[u8], cursor: &mut usize) -> Option<u64> {
    let mut result: u64 = 0;
    let mut shift = 0;
    loop {
        if *cursor >= bytes.len() {
            return None;
        }
        let byte = bytes[*cursor];
        *cursor += 1;
        result |= ((byte & 0x7F) as u64) << shift;
        if (byte & 0x80) == 0 {
            break;
        }
        shift += 7;
        if shift > 64 {
            return None;
        }
    }
    Some(result)
}

pub fn lookup_export(trie: &[u8], symbol: &str) -> Option<u64> {
    if trie.is_empty() {
        return None;
    }
    let sym_bytes = symbol.as_bytes();
    let mut sym_pos = 0;
    let mut cursor = 0;

    loop {
        if cursor >= trie.len() {
            return None;
        }
        let terminal_size = read_uleb128(trie, &mut cursor)?;
        let children_start = cursor + terminal_size as usize;

        if sym_pos == sym_bytes.len() {
            if terminal_size == 0 {
                return None;
            }
            let flags = read_uleb128(trie, &mut cursor)?;
            if (flags & 0x08) != 0 {
                // Re-export
                return None;
            } else if (flags & 0x10) != 0 {
                // Stub and resolver
                return None;
            } else {
                let address = read_uleb128(trie, &mut cursor)?;
                return Some(address);
            }
        }

        cursor = children_start;
        if cursor >= trie.len() {
            return None;
        }
        let child_count = trie[cursor];
        cursor += 1;

        let mut matched = false;
        for _ in 0..child_count {
            let edge_start = cursor;
            while cursor < trie.len() && trie[cursor] != 0 {
                cursor += 1;
            }
            if cursor >= trie.len() {
                return None;
            }
            let edge_str = &trie[edge_start..cursor];
            cursor += 1; // skip null

            let child_offset = read_uleb128(trie, &mut cursor)?;

            if !matched && sym_pos + edge_str.len() <= sym_bytes.len() {
                if &sym_bytes[sym_pos..sym_pos + edge_str.len()] == edge_str {
                    matched = true;
                    sym_pos += edge_str.len();
                    cursor = child_offset as usize;
                }
            }
        }

        if !matched {
            return None;
        }
    }
}

pub fn apply_slide(data: &mut [u8], slide: u64, slide_info: &[u8]) {
    if slide == 0 || slide_info.len() < core::mem::size_of::<SlideInfo5Header>() {
        return;
    }
    let header = unsafe { &*(slide_info.as_ptr() as *const SlideInfo5Header) };
    if header.version != 5 {
        return;
    }
    let page_size = header.page_size as usize;
    let page_starts_count = header.page_starts_count as usize;
    let starts_slice = unsafe {
        let ptr = slide_info.as_ptr().add(core::mem::size_of::<SlideInfo5Header>()) as *const u16;
        core::slice::from_raw_parts(ptr, page_starts_count)
    };

    for (page_idx, &start_val) in starts_slice.iter().enumerate() {
        if start_val == 0xffff {
            continue;
        }
        let page_offset = page_idx * page_size;
        let mut entry_off = page_offset + (start_val as usize * 4);

        while entry_off + 8 <= data.len() {
            let raw = u64::from_le_bytes([
                data[entry_off],
                data[entry_off + 1],
                data[entry_off + 2],
                data[entry_off + 3],
                data[entry_off + 4],
                data[entry_off + 5],
                data[entry_off + 6],
                data[entry_off + 7],
            ]);

            let is_rebase = (raw & (1 << 62)) == 0;
            let next_delta = ((raw >> 51) & 0x7ff) as usize;

            if is_rebase {
                let target = raw & 0x0000_ffff_ffff_ffff;
                let slid = target.wrapping_add(slide);
                let updated = (raw & !0x0000_ffff_ffff_ffff) | (slid & 0x0000_ffff_ffff_ffff);
                data[entry_off..entry_off + 8].copy_from_slice(&updated.to_le_bytes());
            }

            if next_delta == 0 {
                break;
            }
            entry_off += next_delta * 4;
        }
    }
}
