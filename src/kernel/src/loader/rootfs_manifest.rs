//! Binary manifest format for shared-cache blobs and rootfs images (SCM1).

pub const MAGIC: [u8; 4] = *b"SCM1";
pub const MAX_DYLIBS: usize = 4;
pub const MAX_SEGMENTS_PER_DYLIB: usize = 8;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Segment {
    pub va: u64,
    pub len: u32,
    pub blob: [u8; 12],
    pub slide_len: u32,
    pub slide_mapping_va: u64,
    pub slide_blob: [u8; 12],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct DylibBlob {
    pub mach_header_va: u64,
    pub segment_count: u32,
    pub segments: [Segment; MAX_SEGMENTS_PER_DYLIB],
    pub trie_len: u32,
    pub trie_blob: [u8; 12],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Manifest {
    pub magic: [u8; 4],
    pub shared_region_start: u64,
    pub dylib_count: u32,
    pub dylibs: [DylibBlob; MAX_DYLIBS],
    pub main_blob: [u8; 12],
    pub main_len: u32,
}

impl Default for Manifest {
    fn default() -> Self {
        Self {
            magic: MAGIC,
            shared_region_start: 0,
            dylib_count: 0,
            dylibs: [DylibBlob::default(); MAX_DYLIBS],
            main_blob: [0; 12],
            main_len: 0,
        }
    }
}
