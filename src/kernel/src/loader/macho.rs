//! Mach-O loaders for arm64 executables, dylibs, and relocatable kernel objects.

use crate::fs::vfs;
use crate::loader::dyld;
use crate::mm::mmu::{PAGE_SIZE, Prot, Region};
use crate::mm::pmm;
use object::macho;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadError {
    BadMagic,
    WrongArch,
    UnsupportedFileType,
    NoEntryPoint,
    Truncated,
    TooManyRelocations,
    OutOfRegions,
    UnsupportedImportFormat,
    UnsupportedPointerFormat,
    UnsupportedRelocation,
    UnresolvedSymbol,
    Io,
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
    Local,
    External,
}

#[derive(Clone, Copy, Debug)]
pub struct Symbol {
    pub name: &'static str,
    pub value: u64,
    pub sect: u8,
    pub kind: SymbolKind,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Section {
    pub sectname: [u8; 16],
    pub segname: [u8; 16],
    pub addr: u64,
    pub size: u64,
    pub flags: u32,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Relocation {
    pub address: u64,
    pub symbolnum: u32,
    pub pcrel: bool,
    pub length: u8,
    pub is_extern: bool,
    pub reloc_type: u8,
}

#[derive(Clone, Copy, Default)]
pub struct SegInfo {
    pub vmaddr: u64,
    pub vmsize: u64,
    pub fileoff: u64,
    pub filesize: u64,
    pub initprot: u32,
}

#[derive(Clone, Copy, Default)]
pub struct PendingBind {
    pub segs: &'static [SegInfo],
    pub base_pa: u64,
    pub min_vmaddr: u64,
    pub file_len: u64,
    pub bind_off: u32,
    pub bind_size: u32,
    pub lazy_bind_off: u32,
    pub lazy_bind_size: u32,
    pub chained_fixups_off: u32,
    pub chained_fixups_size: u32,
}

pub struct LoadResult {
    pub entry: u64,
    pub mach_header: u64,
    pub slide: u64,
    pub sections: &'static [Section],
    pub local_symbols: &'static [Symbol],
    pub external_symbols: &'static [Symbol],
    pub undefined_symbols: &'static [Symbol],
    pub local_relocs: &'static [Relocation],
    pub external_relocs: &'static [Relocation],
    pub pending_bind: Option<PendingBind>,
}

pub type KernelResolver = fn(ctx: *mut u8, name: &str) -> Option<u64>;

pub struct KernelObjectOptions {
    pub resolver: KernelResolver,
    pub resolver_ctx: *mut u8,
}

pub struct KernelObjectResult {
    pub base: u64,
    pub len: u64,
    pub sections: &'static [Section],
    pub local_symbols: &'static [Symbol],
    pub external_symbols: &'static [Symbol],
    pub undefined_symbols: &'static [Symbol],
    pub constructors: &'static [u64],
}

static LAST_UNRESOLVED_SYMBOL: spin::Mutex<&str> = spin::Mutex::new("");

pub fn last_unresolved_symbol() -> &'static str {
    *LAST_UNRESOLVED_SYMBOL.lock()
}

fn page_align(n: u64) -> u64 {
    (n + PAGE_SIZE - 1) & !(PAGE_SIZE - 1)
}

fn alloc_dyn_slice<T: Default + Copy>(count: usize) -> &'static mut [T] {
    if count == 0 {
        return &mut [];
    }
    let bytes = count * core::mem::size_of::<T>();
    let pages = page_align(bytes as u64) / PAGE_SIZE;
    let pa = pmm::alloc_pages_contig(pages);
    if pa == 0 {
        panic!("macho: alloc_pages_contig failed (dyn storage)");
    }
    unsafe {
        let slice = core::slice::from_raw_parts_mut(pa as *mut T, count);
        for item in slice.iter_mut() {
            *item = T::default();
        }
        slice
    }
}

pub fn rootfs_path_for_install_name(install_name: &str) -> &'static str {
    if install_name == "/usr/lib/libSystem.B.dylib" {
        "usr/lib/libSystem.B.dylib"
    } else if install_name == "/System/Library/Frameworks/IOKit.framework/IOKit" {
        "System/Library/Frameworks/IOKit.framework/IOKit"
    } else if install_name == "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight" {
        "System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    } else {
        "unknown"
    }
}

pub fn list_needed_dylibs(path: &str, out: &mut [&'static str]) -> Result<usize, LoadError> {
    let (vp, file_size) = vfs::open_file(path).ok_or(LoadError::Io)?;
    if file_size < core::mem::size_of::<macho::MachHeader64<object::Endianness>>() as u64 {
        vfs::vrele(vp);
        return Err(LoadError::Truncated);
    }

    let mut header_bytes = [0u8; 4096];
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
    if magic != macho::MH_MAGIC_64 {
        return Err(LoadError::BadMagic);
    }

    let ncmds = u32::from_le_bytes([
        header_bytes[16],
        header_bytes[17],
        header_bytes[18],
        header_bytes[19],
    ]) as usize;
    let mut off = 32usize;
    let mut count = 0;

    for _ in 0..ncmds {
        if off + 8 > to_read {
            break;
        }
        let cmd = u32::from_le_bytes([
            header_bytes[off],
            header_bytes[off + 1],
            header_bytes[off + 2],
            header_bytes[off + 3],
        ]);
        let cmdsize = u32::from_le_bytes([
            header_bytes[off + 4],
            header_bytes[off + 5],
            header_bytes[off + 6],
            header_bytes[off + 7],
        ]) as usize;

        let is_load_dylib = cmd == macho::LC_LOAD_DYLIB.0
            || cmd == macho::LC_LOAD_WEAK_DYLIB.0
            || cmd == macho::LC_REEXPORT_DYLIB.0;
        if is_load_dylib {
            let str_off = u32::from_le_bytes([
                header_bytes[off + 8],
                header_bytes[off + 9],
                header_bytes[off + 10],
                header_bytes[off + 11],
            ]) as usize;
            if off + str_off < to_read && count < out.len() {
                let name_bytes = &header_bytes[off + str_off..off + cmdsize];
                let end = name_bytes
                    .iter()
                    .position(|&b| b == 0)
                    .unwrap_or(name_bytes.len());
                let raw_str =
                    core::str::from_utf8(&name_bytes[..end]).map_err(|_| LoadError::Truncated)?;
                if raw_str == "/usr/lib/libSystem.B.dylib" {
                    out[count] = "/usr/lib/libSystem.B.dylib";
                    count += 1;
                } else if raw_str == "/System/Library/Frameworks/IOKit.framework/IOKit" {
                    out[count] = "/System/Library/Frameworks/IOKit.framework/IOKit";
                    count += 1;
                } else if raw_str == "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
                {
                    out[count] = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";
                    count += 1;
                }
            }
        }
        off += cmdsize;
    }

    Ok(count)
}

pub fn load(
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

pub fn load_with_options(
    image: &[u8],
    regions: &mut [Region],
    regions_used: &mut usize,
    options: LoadOptions,
) -> Result<LoadResult, LoadError> {
    load(image, regions, regions_used, options)
}

fn load_internal(
    header_bytes: &[u8],
    file_vnode: Option<(*mut vfs::Vnode, u64)>,
    regions: &mut [Region],
    regions_used: &mut usize,
    options: LoadOptions,
) -> Result<LoadResult, LoadError> {
    if header_bytes.len() < 32 {
        return Err(LoadError::Truncated);
    }
    let magic = u32::from_le_bytes([
        header_bytes[0],
        header_bytes[1],
        header_bytes[2],
        header_bytes[3],
    ]);
    if magic != macho::MH_MAGIC_64 {
        return Err(LoadError::BadMagic);
    }

    let cputype = u32::from_le_bytes([
        header_bytes[4],
        header_bytes[5],
        header_bytes[6],
        header_bytes[7],
    ]);
    if (cputype & 0xff00_ffff) != 0x0100_000c {
        return Err(LoadError::WrongArch);
    }

    let filetype = u32::from_le_bytes([
        header_bytes[8],
        header_bytes[9],
        header_bytes[10],
        header_bytes[11],
    ]);
    if filetype != macho::MH_EXECUTE.0
        && filetype != macho::MH_DYLIB.0
        && filetype != macho::MH_OBJECT.0
    {
        return Err(LoadError::UnsupportedFileType);
    }

    let ncmds = u32::from_le_bytes([
        header_bytes[16],
        header_bytes[17],
        header_bytes[18],
        header_bytes[19],
    ]) as usize;

    // Scan segments
    let mut min_vmaddr = !0u64;
    let mut max_vmaddr = 0u64;
    let mut seg_count = 0usize;
    let mut sec_count = 0usize;

    let mut off = 32usize;
    for _ in 0..ncmds {
        if off + 8 > header_bytes.len() {
            break;
        }
        let cmd = u32::from_le_bytes([
            header_bytes[off],
            header_bytes[off + 1],
            header_bytes[off + 2],
            header_bytes[off + 3],
        ]);
        let cmdsize = u32::from_le_bytes([
            header_bytes[off + 4],
            header_bytes[off + 5],
            header_bytes[off + 6],
            header_bytes[off + 7],
        ]) as usize;

        if cmd == macho::LC_SEGMENT_64.0 {
            let seg = unsafe {
                &*(header_bytes.as_ptr().add(off)
                    as *const macho::SegmentCommand64<object::Endianness>)
            };
            let vmsize = seg.vmsize.get(object::Endianness::Little);
            let vmaddr = seg.vmaddr.get(object::Endianness::Little);
            let nsects = seg.nsects.get(object::Endianness::Little) as usize;
            if vmsize > 0 {
                min_vmaddr = min_vmaddr.min(vmaddr);
                max_vmaddr = max_vmaddr.max(vmaddr + vmsize);
                seg_count += 1;
                sec_count += nsects;
            }
        }
        off += cmdsize;
    }

    if seg_count == 0 {
        return Err(LoadError::NoEntryPoint);
    }

    let total_vmsize = page_align(max_vmaddr - min_vmaddr);
    let total_pages = total_vmsize / PAGE_SIZE;
    let base_pa = pmm::alloc_pages_contig(total_pages);
    if base_pa == 0 {
        return Err(LoadError::OutOfRegions);
    }

    let seg_infos = alloc_dyn_slice::<SegInfo>(seg_count);
    let mut cur_seg = 0;

    let mut entry_point = 0u64;
    let mut chained_fixups_data = None;

    off = 32;
    for _ in 0..ncmds {
        if off + 8 > header_bytes.len() {
            break;
        }
        let cmd = u32::from_le_bytes([
            header_bytes[off],
            header_bytes[off + 1],
            header_bytes[off + 2],
            header_bytes[off + 3],
        ]);
        let cmdsize = u32::from_le_bytes([
            header_bytes[off + 4],
            header_bytes[off + 5],
            header_bytes[off + 6],
            header_bytes[off + 7],
        ]) as usize;

        if cmd == macho::LC_SEGMENT_64.0 {
            let seg = unsafe {
                &*(header_bytes.as_ptr().add(off)
                    as *const macho::SegmentCommand64<object::Endianness>)
            };
            let vmaddr = seg.vmaddr.get(object::Endianness::Little);
            let vmsize = seg.vmsize.get(object::Endianness::Little);
            let fileoff = seg.fileoff.get(object::Endianness::Little);
            let filesize = seg.filesize.get(object::Endianness::Little);
            let initprot = seg.initprot.get(object::Endianness::Little).0;

            if vmsize > 0 && cur_seg < seg_infos.len() {
                seg_infos[cur_seg] = SegInfo {
                    vmaddr,
                    vmsize,
                    fileoff,
                    filesize,
                    initprot,
                };
                cur_seg += 1;

                let seg_pa = base_pa + (vmaddr - min_vmaddr);
                let seg_len = page_align(vmsize);

                // Copy segment contents from header buffer or VFS
                if filesize > 0 {
                    let dst = unsafe {
                        core::slice::from_raw_parts_mut(seg_pa as *mut u8, filesize as usize)
                    };
                    if let Some((vp, _)) = file_vnode {
                        vfs::read_exact(vp, fileoff, dst);
                    } else if (fileoff + filesize) as usize <= header_bytes.len() {
                        let src = &header_bytes[fileoff as usize..(fileoff + filesize) as usize];
                        dst.copy_from_slice(src);
                    }
                }

                if *regions_used < regions.len() {
                    regions[*regions_used] = Region {
                        pa: seg_pa,
                        len: seg_len,
                        prot: Prot {
                            writable: (initprot & 2) != 0,
                            executable: (initprot & 4) != 0,
                            user: options.user_accessible,
                            device: false,
                        },
                        _pad: 0,
                    };
                    *regions_used += 1;
                }
            }
        } else if cmd == macho::LC_MAIN.0 {
            let entryoff = u64::from_le_bytes([
                header_bytes[off + 8],
                header_bytes[off + 9],
                header_bytes[off + 10],
                header_bytes[off + 11],
                header_bytes[off + 12],
                header_bytes[off + 13],
                header_bytes[off + 14],
                header_bytes[off + 15],
            ]);
            entry_point = min_vmaddr + entryoff;
        } else if cmd == macho::LC_UNIXTHREAD.0 {
            // ARM64 thread state PC is at offset 16 + 32*8 = 272
            if off + 280 <= header_bytes.len() {
                let pc_off = off + 16 + 32 * 8;
                let pc = u64::from_le_bytes([
                    header_bytes[pc_off],
                    header_bytes[pc_off + 1],
                    header_bytes[pc_off + 2],
                    header_bytes[pc_off + 3],
                    header_bytes[pc_off + 4],
                    header_bytes[pc_off + 5],
                    header_bytes[pc_off + 6],
                    header_bytes[pc_off + 7],
                ]);
                entry_point = pc;
            }
        } else if cmd == macho::LC_DYLD_CHAINED_FIXUPS.0 {
            let dataoff = u32::from_le_bytes([
                header_bytes[off + 8],
                header_bytes[off + 9],
                header_bytes[off + 10],
                header_bytes[off + 11],
            ]);
            let datasize = u32::from_le_bytes([
                header_bytes[off + 12],
                header_bytes[off + 13],
                header_bytes[off + 14],
                header_bytes[off + 15],
            ]);
            chained_fixups_data = Some((dataoff, datasize));
        }
        off += cmdsize;
    }

    let slide = base_pa.wrapping_sub(min_vmaddr);
    let resolved_entry = if options.link_at_preferred_va {
        entry_point
    } else {
        base_pa + (entry_point - min_vmaddr)
    };

    let pending_bind = if options.defer_binding {
        let (cf_off, cf_size) = chained_fixups_data.unwrap_or((0, 0));
        Some(PendingBind {
            segs: seg_infos,
            base_pa,
            min_vmaddr,
            file_len: file_vnode
                .map(|(_, sz)| sz)
                .unwrap_or(header_bytes.len() as u64),
            bind_off: 0,
            bind_size: 0,
            lazy_bind_off: 0,
            lazy_bind_size: 0,
            chained_fixups_off: cf_off,
            chained_fixups_size: cf_size,
        })
    } else {
        None
    };

    Ok(LoadResult {
        entry: resolved_entry,
        mach_header: base_pa,
        slide,
        sections: alloc_dyn_slice::<Section>(sec_count),
        local_symbols: &[],
        external_symbols: &[],
        undefined_symbols: &[],
        local_relocs: &[],
        external_relocs: &[],
        pending_bind,
    })
}

pub fn apply_pending_bind(
    bind: PendingBind,
    resolver: dyld::Resolver,
    resolver_ctx: *mut u8,
) -> Result<(), LoadError> {
    if bind.chained_fixups_size > 0 {
        let slice = mapped_file_slice(
            bind.segs,
            bind.base_pa,
            bind.min_vmaddr,
            bind.file_len,
            bind.chained_fixups_off as u64,
            bind.chained_fixups_size as u64,
        )?;
        dyld::apply_chained_fixups(slice, bind.base_pa, resolver, resolver_ctx)
            .map_err(|_| LoadError::UnresolvedSymbol)?;
    }
    Ok(())
}

fn mapped_file_slice<'a>(
    segs: &[SegInfo],
    base_pa: u64,
    min_vmaddr: u64,
    file_len: u64,
    off: u64,
    len: u64,
) -> Result<&'a [u8], LoadError> {
    if len == 0 {
        return Ok(&[]);
    }
    if off + len > file_len {
        return Err(LoadError::Truncated);
    }
    for s in segs {
        if s.filesize == 0 {
            continue;
        }
        if off >= s.fileoff && off + len <= s.fileoff + s.filesize {
            let pa = base_pa + (s.vmaddr - min_vmaddr) + (off - s.fileoff);
            let ptr = pa as *const u8;
            return Ok(unsafe { core::slice::from_raw_parts(ptr, len as usize) });
        }
    }
    Err(LoadError::Truncated)
}
