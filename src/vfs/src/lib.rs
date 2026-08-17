#![no_std]

pub mod fat;
pub mod namei;
pub mod vfs;

pub use fat::{BlockReader, FAT_VFS_OPS, FAT_VNODE_OPS, mount as mount_fat, read_file as read_fat_file, set_block_reader};
pub use namei::{lookup, lookupat};
pub use vfs::*;
