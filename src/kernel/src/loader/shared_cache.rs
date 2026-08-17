//! Parses macOS dyld shared cache headers, slide info v5, and export tries.

#[repr(C)]
#[derive(Clone, Copy)]
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
    pub branch_pools_offset: u32,
    pub branch_pools_count: u32,
    pub dyld_in_cache_mh: u64,
    pub dyld_in_cache_entry: u64,
    pub images_text_offset: u64,
    pub images_text_count: u64,
    pub patch_info_addr: u64,
    pub patch_info_size: u64,
    pub other_image_group_addr_unused: u64,
    pub other_image_group_size_unused: u64,
    pub prog_closures_addr: u64,
    pub prog_closures_size: u64,
    pub prog_closures_trie_addr: u64,
    pub prog_closures_trie_size: u64,
    pub platform: u32,
    pub format_version_bits: u32,
    pub shared_region_start: u64,
    pub shared_region_size: u64,
    pub max_slide: u64,
    pub dylibs_image_array_addr: u64,
    pub dylibs_image_array_size: u64,
    pub dylibs_trie_addr: u64,
    pub dylibs_trie_size: u64,
    pub other_image_array_addr: u64,
    pub other_image_array_size: u64,
    pub other_trie_addr: u64,
    pub other_trie_size: u64,
    pub mapping_with_slide_offset: u32,
    pub mapping_with_slide_count: u32,
    pub dylibs_pbl_state_array_addr_unused: u64,
    pub dylibs_pbl_set_addr: u64,
    pub programs_pbl_set_pool_addr: u64,
    pub programs_pbl_set_pool_size: u64,
    pub program_trie_addr: u64,
    pub program_trie_size: u32,
    pub os_version: u32,
    pub alt_platform: u32,
    pub alt_os_version: u32,
    pub swift_opts_offset: u64,
    pub swift_opts_size: u64,
    pub sub_cache_array_offset: u32,
    pub sub_cache_array_count: u32,
    pub symbol_file_uuid: [u8; 16],
    pub rosetta_read_only_addr: u64,
    pub rosetta_read_only_size: u64,
    pub rosetta_read_write_addr: u64,
    pub rosetta_read_write_size: u64,
    pub images_offset: u32,
    pub images_count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
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

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MappingInfo {
    pub address: u64,
    pub size: u64,
    pub file_offset: u64,
    pub max_prot: u32,
    pub init_prot: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct ImageInfo {
    pub address: u64,
    pub mod_time: u64,
    pub inode: u64,
    pub path_file_offset: u32,
    pub pad: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SlideInfo5Header {
    pub version: u32,
    pub page_size: u32,
    pub page_starts_count: u32,
    pub value_add: u64,
}

pub const SLIDE_V5_PAGE_ATTR_NO_REBASE: u16 = 0xFFFF;

pub fn read_header(bytes: &[u8]) -> Option<&CacheHeader> {
    if bytes.len() < core::mem::size_of::<CacheHeader>() {
        return None;
    }
    if &bytes[0..7] != b"dyld_v1" {
        return None;
    }
    Some(unsafe { &*(bytes.as_ptr() as *const CacheHeader) })
}

#[derive(Clone, Copy, Debug)]
pub struct Mapping {
    pub address: u64,
    pub size: u64,
    pub file_offset: u64,
}

pub fn mappings(bytes: &[u8], header: &CacheHeader, buf: &mut [Mapping]) -> usize {
    let mut n = 0;
    if header.mapping_with_slide_count > 0 {
        let count = header.mapping_with_slide_count as usize;
        for i in 0..count {
            if n >= buf.len() {
                break;
            }
            let off = header.mapping_with_slide_offset as usize
                + i * core::mem::size_of::<MappingAndSlideInfo>();
            if off + core::mem::size_of::<MappingAndSlideInfo>() > bytes.len() {
                break;
            }
            let m = unsafe { &*(bytes.as_ptr().add(off) as *const MappingAndSlideInfo) };
            buf[n] = Mapping {
                address: m.address,
                size: m.size,
                file_offset: m.file_offset,
            };
            n += 1;
        }
    } else {
        let count = header.mapping_count as usize;
        for i in 0..count {
            if n >= buf.len() {
                break;
            }
            let off = header.mapping_offset as usize + i * core::mem::size_of::<MappingInfo>();
            if off + core::mem::size_of::<MappingInfo>() > bytes.len() {
                break;
            }
            let m = unsafe { &*(bytes.as_ptr().add(off) as *const MappingInfo) };
            buf[n] = Mapping {
                address: m.address,
                size: m.size,
                file_offset: m.file_offset,
            };
            n += 1;
        }
    }
    n
}

pub fn find_mapping_with_slide(
    bytes: &[u8],
    header: &CacheHeader,
    addr: u64,
) -> Option<MappingAndSlideInfo> {
    let count = header.mapping_with_slide_count as usize;
    for i in 0..count {
        let off = header.mapping_with_slide_offset as usize
            + i * core::mem::size_of::<MappingAndSlideInfo>();
        if off + core::mem::size_of::<MappingAndSlideInfo>() > bytes.len() {
            break;
        }
        let m = unsafe { *(bytes.as_ptr().add(off) as *const MappingAndSlideInfo) };
        if addr >= m.address && addr < m.address + m.size {
            return Some(m);
        }
    }
    None
}

pub fn address_to_file_offset(bytes: &[u8], header: &CacheHeader, addr: u64) -> Option<u64> {
    let mut buf = [Mapping {
        address: 0,
        size: 0,
        file_offset: 0,
    }; 4];
    let n = mappings(bytes, header, &mut buf);
    for m in &buf[..n] {
        if addr >= m.address && addr < m.address + m.size {
            return Some(m.file_offset + (addr - m.address));
        }
    }
    None
}

pub fn find_image(main_cache_bytes: &[u8], header: &CacheHeader, want_path: &str) -> Option<u64> {
    let count = header.images_count as usize;
    for i in 0..count {
        let off = header.images_offset as usize + i * core::mem::size_of::<ImageInfo>();
        if off + core::mem::size_of::<ImageInfo>() > main_cache_bytes.len() {
            break;
        }
        let img = unsafe { &*(main_cache_bytes.as_ptr().add(off) as *const ImageInfo) };
        let path_off = img.path_file_offset as usize;
        if path_off >= main_cache_bytes.len() {
            continue;
        }
        let path_bytes = &main_cache_bytes[path_off..];
        let end = path_bytes
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(path_bytes.len());
        if let Ok(path) = core::str::from_utf8(&path_bytes[..end]) {
            if path == want_path {
                return Some(img.address);
            }
        }
    }
    None
}

pub fn linkedit_dataoff_to_address(
    linkedit_seg_vmaddr: u64,
    linkedit_seg_fileoff: u64,
    dataoff: u64,
) -> u64 {
    linkedit_seg_vmaddr.wrapping_add(dataoff.wrapping_sub(linkedit_seg_fileoff))
}

pub fn apply_slide(
    region: &mut [u8],
    region_va: u64,
    mapping_address: u64,
    _shared_region_start: u64,
    slide_info_bytes: &[u8],
) {
    if slide_info_bytes.len() < core::mem::size_of::<SlideInfo5Header>() {
        return;
    }
    let hdr = unsafe { &*(slide_info_bytes.as_ptr() as *const SlideInfo5Header) };
    if hdr.version != 5 || hdr.page_size == 0 {
        return;
    }

    let page_size = hdr.page_size as u64;
    let region_page_offset = (region_va.saturating_sub(mapping_address)) / page_size;
    let region_page_count = (region.len() as u64) / page_size;

    let page_starts_bytes = &slide_info_bytes[core::mem::size_of::<SlideInfo5Header>()..];
    let page_starts = unsafe {
        core::slice::from_raw_parts(
            page_starts_bytes.as_ptr() as *const u16,
            hdr.page_starts_count as usize,
        )
    };

    for local_page in 0..region_page_count as usize {
        let global_page = region_page_offset as usize + local_page;
        if global_page >= page_starts.len() {
            break;
        }
        let start = page_starts[global_page];
        if start == SLIDE_V5_PAGE_ATTR_NO_REBASE {
            continue;
        }

        let mut slot_offset = (local_page as u64) * page_size + (start as u64);
        while slot_offset + 8 <= region.len() as u64 {
            let ptr = unsafe { region.as_mut_ptr().add(slot_offset as usize) as *mut u64 };
            let raw = unsafe { *ptr };
            let auth = (raw >> 63) & 1;
            let next = (raw >> 51) & 0x7ff;

            let runtime_offset = if auth == 0 {
                raw & 0x7fff_ffff_fff
            } else {
                raw & 0xffff_ffff
            };

            unsafe {
                *ptr = mapping_address.wrapping_add(runtime_offset);
            }

            if next == 0 {
                break;
            }
            slot_offset += next * 8;
        }
    }
}

pub fn lookup_export(trie_bytes: &[u8], name: &str) -> Option<u64> {
    if trie_bytes.is_empty() {
        return None;
    }
    let mut off = 0;
    let mut name_idx = 0;
    let name_bytes = name.as_bytes();

    while off < trie_bytes.len() {
        let (terminal_size, bytes_read) = read_uleb128(&trie_bytes[off..])?;
        off += bytes_read;

        if name_idx == name_bytes.len() && terminal_size > 0 {
            let (_flags, flags_read) = read_uleb128(&trie_bytes[off..])?;
            let (addr, _) = read_uleb128(&trie_bytes[off + flags_read..])?;
            return Some(addr);
        }

        off += terminal_size as usize;
        if off >= trie_bytes.len() {
            return None;
        }

        let children_count = trie_bytes[off] as usize;
        off += 1;

        let mut matched_child = false;
        for _ in 0..children_count {
            let edge_str_start = off;
            while off < trie_bytes.len() && trie_bytes[off] != 0 {
                off += 1;
            }
            let edge_str = &trie_bytes[edge_str_start..off];
            off += 1; // skip NUL

            let (child_node_off, uleb_len) = read_uleb128(&trie_bytes[off..])?;
            off += uleb_len;

            if !matched_child && name_bytes[name_idx..].starts_with(edge_str) {
                name_idx += edge_str.len();
                off = child_node_off as usize;
                matched_child = true;
            }
        }

        if !matched_child {
            return None;
        }
    }
    None
}

fn read_uleb128(bytes: &[u8]) -> Option<(u64, usize)> {
    let mut result = 0u64;
    let mut shift = 0;
    for (i, &b) in bytes.iter().enumerate() {
        result |= ((b & 0x7f) as u64) << shift;
        if (b & 0x80) == 0 {
            return Some((result, i + 1));
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
    }
    None
}
