#![no_std]

extern crate alloc;

pub mod dyld;
pub mod kext;
pub mod kmain;
pub mod macho;
pub mod rootfs_manifest;
pub mod shared_cache;

pub use dyld::{DyldError, Import, Resolver, apply_chained_fixups, find_chained_fixups};
pub use kmain::kmain;
pub use macho::{
    LoadError, LoadOptions, LoadResult, PendingBind, Section, SegInfo, Symbol, SymbolKind,
    apply_pending_bind, list_needed_dylibs, load, load_path, load_with_options,
    rootfs_path_for_install_name,
};
pub use rootfs_manifest::{DylibBlob, MAGIC as MANIFEST_MAGIC, Manifest, Segment};
pub use shared_cache::{
    CacheHeader, ImageInfo, Mapping, MappingAndSlideInfo, MappingInfo, SlideInfo5Header,
    address_to_file_offset, apply_slide, find_image, find_mapping_with_slide,
    linkedit_dataoff_to_address, lookup_export, mappings, read_header,
};
