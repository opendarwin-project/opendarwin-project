//! SCM1 Rootfs Manifest structures for sparse shared cache dylib blobs.

pub const MAGIC: [u8; 4] = *b"SCM1";

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Manifest {
    pub magic: [u8; 4],
    pub version: u32,
    pub entry_dylib_index: u32,
    pub dylib_count: u32,
    pub dylibs_offset: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Segment {
    pub name: [u8; 16],
    pub vmaddr: u64,
    pub vmsize: u64,
    pub fileoff: u64,
    pub filesize: u64,
    pub maxprot: u32,
    pub initprot: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct DylibBlob {
    pub name_offset: u32,
    pub segment_count: u32,
    pub segments_offset: u32,
    pub trie_offset: u32,
    pub trie_size: u32,
    pub fixups_offset: u32,
    pub fixups_size: u32,
}
