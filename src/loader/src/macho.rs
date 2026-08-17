//! Mach-O 64-bit binary and dylib loader.

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;
use core::mem::size_of;

use kernel::mm::mmu::{PAGE_SIZE, Prot, Region};
use kernel::mm::pmm;
use object::macho;

use crate::dyld::{self, DyldError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadError {
    Truncated,
    BadMagic,
    UnsupportedCpu,
    NoSegments,
    AllocationFailed,
    Dyld(DyldError),
    Io,
}

impl From<DyldError> for LoadError {
    fn from(e: DyldError) -> Self {
        LoadError::Dyld(e)
    }
}

#[derive(Clone, Copy, Default)]
pub struct LoadOptions {
    pub resolver: Option<dyld::Resolver>,
    pub resolver_ctx: *mut u8,
    pub user_accessible: bool,
    pub link_at_preferred_va: bool,
    pub defer_binding: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SymbolKind {
    Undefined,
    External,
    Local,
}

#[derive(Clone, Debug)]
pub struct Symbol {
    pub name: String,
    pub address: u64,
    pub kind: SymbolKind,
}

#[derive(Clone, Debug, Default)]
pub struct Section {
    pub segname: [u8; 16],
    pub sectname: [u8; 16],
    pub addr: u64,
    pub size: u64,
    pub offset: u32,
    pub align: u32,
}

#[derive(Clone, Debug, Default)]
pub struct SegInfo {
    pub name: [u8; 16],
    pub vmaddr: u64,
    pub vmsize: u64,
    pub fileoff: u64,
    pub filesize: u64,
    pub maxprot: u32,
    pub initprot: u32,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct PendingBind {
    pub fixups_dataoff: u64,
    pub fixups_datasize: u64,
    pub target_pa: u64,
    pub target_size: u64,
    pub target_vmaddr: u64,
    pub slide: u64,
}

pub struct LoadResult {
    pub entry: u64,
    pub slide: u64,
    pub min_vmaddr: u64,
    pub max_vmaddr: u64,
    pub external_symbols: Vec<Symbol>,
    pub pending_bind: Option<PendingBind>,
}

const MH_MAGIC_64: u32 = 0xfeedfacf;
const CPU_TYPE_ARM64: u32 = 0x0100000c;

const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x02;
const LC_DYSYMTAB: u32 = 0x0b;
const LC_LOAD_DYLIB: u32 = 0x0c;
const LC_LOAD_WEAK_DYLIB: u32 = 0x80000018;
const LC_MAIN: u32 = 0x80000028;
const LC_REEXPORT_DYLIB: u32 = 0x8000001f;
const LC_DYLD_CHAINED_FIXUPS: u32 = 0x80000034;

const N_EXT: u8 = 0x01;
const N_TYPE: u8 = 0x0e;
const N_UNDF: u8 = 0x00;
const N_SECT: u8 = 0x0e;

pub fn list_needed_dylibs(path: &str) -> Result<Vec<String>, LoadError> {
    let (vp, file_size) = vfs::open_file(path).ok_or(LoadError::Io)?;
    if file_size < size_of::<macho::MachHeader64<object::Endianness>>() as u64 {
        vfs::vrele(vp);
        return Err(LoadError::Truncated);
    }

    let mut header_bytes = [0u8; 8192];
    let to_read = (file_size as usize).min(header_bytes.len());
    if !vfs::read_exact(vp, 0, &mut header_bytes[..to_read]) {
        vfs::vrele(vp);
        return Err(LoadError::Io);
    }
    vfs::vrele(vp);

    let magic = u32::from_le_bytes([
        header_bytes[0],
        header_bytes[1],
        header_bytes[2],
        header_bytes[3],
    ]);
    if magic != MH_MAGIC_64 {
        return Err(LoadError::BadMagic);
    }

    let ncmds = u32::from_le_bytes([
        header_bytes[16],
        header_bytes[17],
        header_bytes[18],
        header_bytes[19],
    ]);
    let sizeofcmds = u32::from_le_bytes([
        header_bytes[20],
        header_bytes[21],
        header_bytes[22],
        header_bytes[23],
    ]);

    let mut cmd_buf: Vec<u8> = Vec::new();
    let cmd_slice: &[u8] = if (32 + sizeofcmds as usize) <= to_read {
        &header_bytes[32..32 + sizeofcmds as usize]
    } else {
        cmd_buf.resize(sizeofcmds as usize, 0);
        let (vp2, _) = vfs::open_file(path).ok_or(LoadError::Io)?;
        let ok = vfs::read_exact(vp2, 32, &mut cmd_buf);
        vfs::vrele(vp2);
        if !ok {
            return Err(LoadError::Io);
        }
        &cmd_buf
    };

    let mut dylibs = Vec::new();
    let mut off = 0;
    for _ in 0..ncmds {
        if off + 8 > cmd_slice.len() {
            break;
        }
        let cmd = u32::from_le_bytes([
            cmd_slice[off],
            cmd_slice[off + 1],
            cmd_slice[off + 2],
            cmd_slice[off + 3],
        ]);
        let cmdsize = u32::from_le_bytes([
            cmd_slice[off + 4],
            cmd_slice[off + 5],
            cmd_slice[off + 6],
            cmd_slice[off + 7],
        ]) as usize;

        if cmdsize == 0 || off + cmdsize > cmd_slice.len() {
            break;
        }

        if cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB {
            if cmdsize >= 24 {
                let str_off = u32::from_le_bytes([
                    cmd_slice[off + 8],
                    cmd_slice[off + 9],
                    cmd_slice[off + 10],
                    cmd_slice[off + 11],
                ]) as usize;

                if str_off < cmdsize {
                    let str_bytes = &cmd_slice[off + str_off..off + cmdsize];
                    let end = str_bytes.iter().position(|&b| b == 0).unwrap_or(str_bytes.len());
                    if let Ok(name) = core::str::from_utf8(&str_bytes[..end]) {
                        if !name.is_empty() && !dylibs.iter().any(|d: &String| d == name) {
                            dylibs.push(String::from(name));
                        }
                    }
                }
            }
        }

        off += cmdsize;
    }

    Ok(dylibs)
}

pub fn rootfs_path_for_install_name(install_name: &str) -> String {
    if let Some(suffix) = install_name.strip_prefix("@rpath/") {
        let candidates = [
            format!("System/Library/Frameworks/{}", suffix),
            format!("System/Library/PrivateFrameworks/{}", suffix),
            format!("usr/lib/{}", suffix),
            String::from(suffix),
        ];
        for candidate in candidates {
            if vfs::file_size(&candidate).is_some() {
                return candidate;
            }
        }
        return format!("System/Library/Frameworks/{}", suffix);
    }

    if let Some(suffix) = install_name.strip_prefix("@executable_path/") {
        return String::from(suffix);
    }

    String::from(install_name.trim_start_matches('/'))
}

pub fn load(image: &[u8], regions: &mut [Region], regions_used: &mut usize) -> Result<LoadResult, LoadError> {
    load_with_options(image, regions, regions_used, LoadOptions::default())
}

pub fn load_with_options(
    image: &[u8],
    regions: &mut [Region],
    regions_used: &mut usize,
    options: LoadOptions,
) -> Result<LoadResult, LoadError> {
    load_internal(image, None, regions, regions_used, options)
}

pub fn load_path(
    path: &str,
    regions: &mut [Region],
    regions_used: &mut usize,
    options: LoadOptions,
) -> Result<LoadResult, LoadError> {
    let (vp, file_size) = vfs::open_file(path).ok_or(LoadError::Io)?;
    let mut header_buf = [0u8; 8192];
    let to_read = (file_size as usize).min(header_buf.len());
    if !vfs::read_exact(vp, 0, &mut header_buf[..to_read]) {
        vfs::vrele(vp);
        return Err(LoadError::Io);
    }
    let res = load_internal(
        &header_buf[..to_read],
        Some((vp, file_size)),
        regions,
        regions_used,
        options,
    );
    vfs::vrele(vp);
    res
}

fn load_internal(
    header_bytes: &[u8],
    file_vnode: Option<(*mut vfs::Vnode, u64)>,
    regions: &mut [Region],
    regions_used: &mut usize,
    options: LoadOptions,
) -> Result<LoadResult, LoadError> {
    if header_bytes.len() < size_of::<macho::MachHeader64<object::Endianness>>() {
        return Err(LoadError::Truncated);
    }

    let magic = u32::from_le_bytes([
        header_bytes[0],
        header_bytes[1],
        header_bytes[2],
        header_bytes[3],
    ]);
    if magic != MH_MAGIC_64 {
        return Err(LoadError::BadMagic);
    }

    let cputype = u32::from_le_bytes([
        header_bytes[4],
        header_bytes[5],
        header_bytes[6],
        header_bytes[7],
    ]);
    if cputype != CPU_TYPE_ARM64 {
        return Err(LoadError::UnsupportedCpu);
    }

    let ncmds = u32::from_le_bytes([
        header_bytes[16],
        header_bytes[17],
        header_bytes[18],
        header_bytes[19],
    ]);
    let sizeofcmds = u32::from_le_bytes([
        header_bytes[20],
        header_bytes[21],
        header_bytes[22],
        header_bytes[23],
    ]);

    let mut cmd_buf: Vec<u8> = Vec::new();
    let cmd_slice: &[u8] = if (32 + sizeofcmds as usize) <= header_bytes.len() {
        &header_bytes[32..32 + sizeofcmds as usize]
    } else if let Some((vp, _)) = file_vnode {
        cmd_buf.resize(sizeofcmds as usize, 0);
        if !vfs::read_exact(vp, 32, &mut cmd_buf) {
            return Err(LoadError::Io);
        }
        &cmd_buf
    } else {
        return Err(LoadError::Truncated);
    };

    let mut segs = Vec::new();
    let mut entry_point: Option<u64> = None;
    let mut chained_fixups: Option<(u64, u64)> = None;
    let mut symtab_info: Option<(u32, u32, u32, u32)> = None; // (symoff, nsyms, stroff, strsize)

    let mut off = 0;
    for _ in 0..ncmds {
        if off + 8 > cmd_slice.len() {
            break;
        }
        let cmd = u32::from_le_bytes([
            cmd_slice[off],
            cmd_slice[off + 1],
            cmd_slice[off + 2],
            cmd_slice[off + 3],
        ]);
        let cmdsize = u32::from_le_bytes([
            cmd_slice[off + 4],
            cmd_slice[off + 5],
            cmd_slice[off + 6],
            cmd_slice[off + 7],
        ]) as usize;

        if cmdsize == 0 || off + cmdsize > cmd_slice.len() {
            break;
        }

        match cmd {
            LC_SEGMENT_64 => {
                if cmdsize >= 72 {
                    let mut name = [0u8; 16];
                    name.copy_from_slice(&cmd_slice[off + 8..off + 24]);
                    let vmaddr = u64::from_le_bytes([
                        cmd_slice[off + 24],
                        cmd_slice[off + 25],
                        cmd_slice[off + 26],
                        cmd_slice[off + 27],
                        cmd_slice[off + 28],
                        cmd_slice[off + 29],
                        cmd_slice[off + 30],
                        cmd_slice[off + 31],
                    ]);
                    let vmsize = u64::from_le_bytes([
                        cmd_slice[off + 32],
                        cmd_slice[off + 33],
                        cmd_slice[off + 34],
                        cmd_slice[off + 35],
                        cmd_slice[off + 36],
                        cmd_slice[off + 37],
                        cmd_slice[off + 38],
                        cmd_slice[off + 39],
                    ]);
                    let fileoff = u64::from_le_bytes([
                        cmd_slice[off + 40],
                        cmd_slice[off + 41],
                        cmd_slice[off + 42],
                        cmd_slice[off + 43],
                        cmd_slice[off + 44],
                        cmd_slice[off + 45],
                        cmd_slice[off + 46],
                        cmd_slice[off + 47],
                    ]);
                    let filesize = u64::from_le_bytes([
                        cmd_slice[off + 48],
                        cmd_slice[off + 49],
                        cmd_slice[off + 50],
                        cmd_slice[off + 51],
                        cmd_slice[off + 52],
                        cmd_slice[off + 53],
                        cmd_slice[off + 54],
                        cmd_slice[off + 55],
                    ]);
                    let maxprot = u32::from_le_bytes([
                        cmd_slice[off + 56],
                        cmd_slice[off + 57],
                        cmd_slice[off + 58],
                        cmd_slice[off + 59],
                    ]);
                    let initprot = u32::from_le_bytes([
                        cmd_slice[off + 60],
                        cmd_slice[off + 61],
                        cmd_slice[off + 62],
                        cmd_slice[off + 63],
                    ]);

                    if vmsize > 0 && !name.starts_with(b"__PAGEZERO") && (initprot != 0 || maxprot != 0) {
                        segs.push(SegInfo {
                            name,
                            vmaddr,
                            vmsize,
                            fileoff,
                            filesize,
                            maxprot,
                            initprot,
                        });
                    }
                }
            }
            LC_MAIN => {
                if cmdsize >= 24 {
                    let entryoff = u64::from_le_bytes([
                        cmd_slice[off + 8],
                        cmd_slice[off + 9],
                        cmd_slice[off + 10],
                        cmd_slice[off + 11],
                        cmd_slice[off + 12],
                        cmd_slice[off + 13],
                        cmd_slice[off + 14],
                        cmd_slice[off + 15],
                    ]);
                    entry_point = Some(entryoff);
                }
            }
            LC_DYLD_CHAINED_FIXUPS => {
                if cmdsize >= 16 {
                    let dataoff = u32::from_le_bytes([
                        cmd_slice[off + 8],
                        cmd_slice[off + 9],
                        cmd_slice[off + 10],
                        cmd_slice[off + 11],
                    ]) as u64;
                    let datasize = u32::from_le_bytes([
                        cmd_slice[off + 12],
                        cmd_slice[off + 13],
                        cmd_slice[off + 14],
                        cmd_slice[off + 15],
                    ]) as u64;
                    chained_fixups = Some((dataoff, datasize));
                }
            }
            LC_SYMTAB => {
                if cmdsize >= 24 {
                    let symoff = u32::from_le_bytes([
                        cmd_slice[off + 8],
                        cmd_slice[off + 9],
                        cmd_slice[off + 10],
                        cmd_slice[off + 11],
                    ]);
                    let nsyms = u32::from_le_bytes([
                        cmd_slice[off + 12],
                        cmd_slice[off + 13],
                        cmd_slice[off + 14],
                        cmd_slice[off + 15],
                    ]);
                    let stroff = u32::from_le_bytes([
                        cmd_slice[off + 16],
                        cmd_slice[off + 17],
                        cmd_slice[off + 18],
                        cmd_slice[off + 19],
                    ]);
                    let strsize = u32::from_le_bytes([
                        cmd_slice[off + 20],
                        cmd_slice[off + 21],
                        cmd_slice[off + 22],
                        cmd_slice[off + 23],
                    ]);
                    symtab_info = Some((symoff, nsyms, stroff, strsize));
                }
            }
            _ => {}
        }

        off += cmdsize;
    }

    if segs.is_empty() {
        return Err(LoadError::NoSegments);
    }

    let mut min_vmaddr = u64::MAX;
    let mut max_vmaddr = 0u64;
    for s in &segs {
        if s.vmaddr < min_vmaddr {
            min_vmaddr = s.vmaddr;
        }
        let end = s.vmaddr + s.vmsize;
        if end > max_vmaddr {
            max_vmaddr = end;
        }
    }

    let total_span = max_vmaddr - min_vmaddr;
    let page_count = ((total_span + PAGE_SIZE - 1) / PAGE_SIZE) as u64;

    let base_pa = pmm::alloc_pages_contig(page_count);
    if base_pa == 0 {
        return Err(LoadError::AllocationFailed);
    }

    let slide = base_pa.wrapping_sub(min_vmaddr);

    let mut linkedit_pa = 0u64;
    let mut linkedit_fileoff = 0u64;
    let mut linkedit_filesize = 0u64;

    *regions_used = 0;
    for s in &segs {
        let seg_offset = s.vmaddr - min_vmaddr;
        let seg_pa = base_pa + seg_offset;
        let seg_pages = ((s.vmsize + PAGE_SIZE - 1) / PAGE_SIZE) as u64;
        let seg_len = seg_pages * PAGE_SIZE;

        let is_linkedit = s.name.starts_with(b"__LINKEDIT");
        if is_linkedit {
            linkedit_pa = seg_pa;
            linkedit_fileoff = s.fileoff;
            linkedit_filesize = s.filesize;
        }

        if s.filesize > 0 {
            let dst = unsafe { core::slice::from_raw_parts_mut(seg_pa as *mut u8, s.filesize as usize) };
            if let Some((vp, _)) = file_vnode {
                if !vfs::read_exact(vp, s.fileoff, dst) {
                    return Err(LoadError::Io);
                }
            } else if (s.fileoff + s.filesize) as usize <= header_bytes.len() {
                dst.copy_from_slice(&header_bytes[s.fileoff as usize..(s.fileoff + s.filesize) as usize]);
            }
        }

        let prot = Prot {
            writable: (s.initprot & 2) != 0,
            executable: (s.initprot & 4) != 0,
            user: options.user_accessible,
            device: false,
        };

        if *regions_used < regions.len() {
            regions[*regions_used] = Region {
                pa: seg_pa,
                len: seg_len,
                prot,
                _pad: 0,
            };
            *regions_used += 1;
        }
    }

    // Extract external symbols from LC_SYMTAB if present
    let mut external_symbols = Vec::new();
    if let Some((symoff, nsyms, stroff, strsize)) = symtab_info {
        let mut sym_buf = Vec::new();
        let mut str_buf = Vec::new();

        let sym_bytes_len = (nsyms as usize) * 16;
        let str_bytes_len = strsize as usize;

        let sym_slice: Option<&[u8]> = if linkedit_pa != 0
            && symoff as u64 >= linkedit_fileoff
            && (symoff as u64 + sym_bytes_len as u64) <= (linkedit_fileoff + linkedit_filesize)
        {
            let off_in_linkedit = (symoff as u64 - linkedit_fileoff) as usize;
            unsafe {
                let ptr = (linkedit_pa as *const u8).add(off_in_linkedit);
                Some(core::slice::from_raw_parts(ptr, sym_bytes_len))
            }
        } else if let Some((vp, _)) = file_vnode {
            sym_buf.resize(sym_bytes_len, 0);
            if vfs::read_exact(vp, symoff as u64, &mut sym_buf) {
                Some(&sym_buf)
            } else {
                None
            }
        } else {
            None
        };

        let str_slice: Option<&[u8]> = if linkedit_pa != 0
            && stroff as u64 >= linkedit_fileoff
            && (stroff as u64 + str_bytes_len as u64) <= (linkedit_fileoff + linkedit_filesize)
        {
            let off_in_linkedit = (stroff as u64 - linkedit_fileoff) as usize;
            unsafe {
                let ptr = (linkedit_pa as *const u8).add(off_in_linkedit);
                Some(core::slice::from_raw_parts(ptr, str_bytes_len))
            }
        } else if let Some((vp, _)) = file_vnode {
            str_buf.resize(str_bytes_len, 0);
            if vfs::read_exact(vp, stroff as u64, &mut str_buf) {
                Some(&str_buf)
            } else {
                None
            }
        } else {
            None
        };

        if let (Some(syms), Some(strs)) = (sym_slice, str_slice) {
            for i in 0..nsyms as usize {
                let s_off = i * 16;
                let n_strx = u32::from_le_bytes([
                    syms[s_off],
                    syms[s_off + 1],
                    syms[s_off + 2],
                    syms[s_off + 3],
                ]) as usize;
                let n_type = syms[s_off + 4];
                let _n_sect = syms[s_off + 5];
                let _n_desc = u16::from_le_bytes([syms[s_off + 6], syms[s_off + 7]]);
                let n_value = u64::from_le_bytes([
                    syms[s_off + 8],
                    syms[s_off + 9],
                    syms[s_off + 10],
                    syms[s_off + 11],
                    syms[s_off + 12],
                    syms[s_off + 13],
                    syms[s_off + 14],
                    syms[s_off + 15],
                ]);

                let is_ext = (n_type & N_EXT) != 0;
                let typ = n_type & N_TYPE;
                let kind = if typ == N_UNDF {
                    SymbolKind::Undefined
                } else if is_ext {
                    SymbolKind::External
                } else {
                    SymbolKind::Local
                };

                if kind == SymbolKind::External && typ == N_SECT {
                    if n_strx < strs.len() {
                        let rest = &strs[n_strx..];
                        let end = rest.iter().position(|&b| b == 0).unwrap_or(rest.len());
                        if let Ok(name_str) = core::str::from_utf8(&rest[..end]) {
                            external_symbols.push(Symbol {
                                name: String::from(name_str),
                                address: n_value.wrapping_add(slide),
                                kind,
                            });
                        }
                    }
                }
            }
        }
    }

    let mut pending_bind = None;
    if let Some((fixups_off, fixups_size)) = chained_fixups {
        let first_seg = &segs[0];
        let target_pa = base_pa + (first_seg.vmaddr - min_vmaddr);
        let target_size = first_seg.vmsize;

        if options.defer_binding {
            pending_bind = Some(PendingBind {
                fixups_dataoff: fixups_off,
                fixups_datasize: fixups_size,
                target_pa,
                target_size,
                target_vmaddr: first_seg.vmaddr,
                slide,
            });
        } else {
            let mut fixups_buf = Vec::new();
            fixups_buf.resize(fixups_size as usize, 0);

            let ok = if let Some((vp, _)) = file_vnode {
                vfs::read_exact(vp, fixups_off, &mut fixups_buf)
            } else if (fixups_off + fixups_size) as usize <= header_bytes.len() {
                fixups_buf.copy_from_slice(
                    &header_bytes[fixups_off as usize..(fixups_off + fixups_size) as usize],
                );
                true
            } else {
                false
            };

            if ok {
                let seg_slice = unsafe {
                    core::slice::from_raw_parts_mut(target_pa as *mut u8, target_size as usize)
                };
                dyld::apply_chained_fixups(
                    &fixups_buf,
                    seg_slice,
                    first_seg.vmaddr,
                    slide,
                    options.resolver,
                    options.resolver_ctx,
                )?;
            }
        }
    }

    let entry = if let Some(eoff) = entry_point {
        min_vmaddr.wrapping_add(slide).wrapping_add(eoff)
    } else {
        min_vmaddr.wrapping_add(slide)
    };

    Ok(LoadResult {
        entry,
        slide,
        min_vmaddr,
        max_vmaddr,
        external_symbols,
        pending_bind,
    })
}

pub fn apply_pending_bind(
    bind: PendingBind,
    resolver: dyld::Resolver,
    ctx: *mut u8,
    file_path: &str,
) -> Result<(), LoadError> {
    if bind.fixups_datasize == 0 {
        return Ok(());
    }

    let mut fixups_buf = Vec::new();
    fixups_buf.resize(bind.fixups_datasize as usize, 0);

    let (vp, _) = vfs::open_file(file_path).ok_or(LoadError::Io)?;
    let ok = vfs::read_exact(vp, bind.fixups_dataoff, &mut fixups_buf);
    vfs::vrele(vp);

    if !ok {
        return Err(LoadError::Io);
    }

    let seg_slice = unsafe {
        core::slice::from_raw_parts_mut(bind.target_pa as *mut u8, bind.target_size as usize)
    };

    dyld::apply_chained_fixups(
        &fixups_buf,
        seg_slice,
        bind.target_vmaddr,
        bind.slide,
        Some(resolver),
        ctx,
    )?;

    Ok(())
}
