//! Kernel entry point and main initialization sequence.

use crate::arch::aarch64::{cpu, exceptions, pac};
use crate::devicetree;
use crate::drivers::{gic, timer, uart, virtio_blk, virtio_gpu};
use crate::fs::fat;
use crate::iokit;
use crate::ipc;
use crate::loader::macho::{self, LoadOptions, Symbol, SymbolKind};
use crate::mm::{MemoryRegion, PAGE_SIZE, Region, mmu, pmm, slab};
use crate::proc::sched;
use crate::smp;

unsafe extern "C" {
    static __userpages_end: u8;
}

struct FossResolverCtx {
    tables: &'static [&'static [Symbol]],
}

fn foss_symbol_value(symbols: &[Symbol], name: &str) -> Option<u64> {
    for sym in symbols {
        if sym.kind != SymbolKind::External {
            continue;
        }
        if sym.name == name
            || (sym.name.len() == name.len() + 1
                && sym.name.starts_with('_')
                && &sym.name[1..] == name)
        {
            return Some(sym.value);
        }
    }
    None
}

fn find_foss_symbol(ctx: &FossResolverCtx, name: &str) -> Option<u64> {
    for symbols in ctx.tables {
        if let Some(v) = foss_symbol_value(symbols, name) {
            return Some(v);
        }
    }
    None
}

fn resolve_foss_symbol(ctx: *mut u8, _ordinal: u8, name: &str) -> Option<u64> {
    let rc = unsafe { &*(ctx as *const FossResolverCtx) };
    if let Some(v) = find_foss_symbol(rc, name) {
        return Some(v);
    }
    uart::print("opendarwin: unresolved FOSS dylib symbol: ");
    uart::print(name);
    uart::print("\n");
    None
}

fn install_name_queued_or_loaded(names: &[&'static str], count: usize, name: &str) -> bool {
    for &existing in &names[..count] {
        if existing == name {
            return true;
        }
    }
    false
}

fn spawn_zig_smoke_from_fat() -> bool {
    const MAX_DYLIBS: usize = 8;
    let mut queue_install = [""; MAX_DYLIBS];
    let mut queue_path = [""; MAX_DYLIBS];
    let mut queue_len = 0;

    uart::print("opendarwin: zig-smoke: reading MAIN LC_LOAD_DYLIB\n");
    let mut main_deps = [""; MAX_DYLIBS];
    let main_dep_count = match macho::list_needed_dylibs("MAIN", &mut main_deps) {
        Ok(c) => c,
        Err(_) => {
            uart::print("opendarwin: MAIN dylib list failed\n");
            return false;
        }
    };

    if main_dep_count == 0 {
        uart::print("opendarwin: MAIN has no LC_LOAD_DYLIB entries\n");
        return false;
    }

    for &install in &main_deps[..main_dep_count] {
        if install_name_queued_or_loaded(&queue_install, queue_len, install) {
            continue;
        }
        if queue_len >= MAX_DYLIBS {
            uart::print("opendarwin: too many MAIN dylib deps\n");
            return false;
        }
        queue_install[queue_len] = install;
        queue_path[queue_len] = macho::rootfs_path_for_install_name(install);
        queue_len += 1;
    }

    let mut all_regions = [Region::default(); 32];
    let mut all_regions_used = 0;
    let mut loaded_install = [""; MAX_DYLIBS];
    let mut loaded_slide = [0u64; MAX_DYLIBS];
    let mut loaded_region_start = [0usize; MAX_DYLIBS];
    let mut loaded_region_count = [0usize; MAX_DYLIBS];
    let mut symbol_tables = [&[][..]; MAX_DYLIBS];
    let mut pending_binds = [macho::PendingBind::default(); MAX_DYLIBS];
    let mut loaded_count = 0;

    let mut qi = 0;
    while qi < queue_len {
        let install = queue_install[qi];
        let path = queue_path[qi];
        qi += 1;

        if install_name_queued_or_loaded(&loaded_install, loaded_count, install) {
            continue;
        }

        uart::print("opendarwin: zig-smoke: loading ");
        uart::print(path);
        uart::print("\n");

        let mut dylib_regions = [Region::default(); 8];
        let mut dylib_regions_used = 0;

        let dylib_result = match macho::load_path(
            path,
            &mut dylib_regions,
            &mut dylib_regions_used,
            LoadOptions {
                defer_binding: true,
                ..Default::default()
            },
        ) {
            Ok(res) => res,
            Err(_) => {
                uart::print("opendarwin: FOSS dylib load failed\n");
                return false;
            }
        };

        if all_regions_used + dylib_regions_used > all_regions.len() || loaded_count >= MAX_DYLIBS {
            uart::print("opendarwin: zig-smoke: too many dylib regions\n");
            return false;
        }

        loaded_install[loaded_count] = install;
        loaded_slide[loaded_count] = dylib_result.slide;
        loaded_region_start[loaded_count] = all_regions_used;
        loaded_region_count[loaded_count] = dylib_regions_used;
        symbol_tables[loaded_count] = dylib_result.external_symbols;
        pending_binds[loaded_count] = dylib_result.pending_bind.unwrap_or_default();

        for &r in &dylib_regions[..dylib_regions_used] {
            all_regions[all_regions_used] = r;
            all_regions_used += 1;
        }
        loaded_count += 1;

        let mut nested = [""; MAX_DYLIBS];
        if let Ok(nested_count) = macho::list_needed_dylibs(path, &mut nested) {
            for &dep in &nested[..nested_count] {
                if dep == install {
                    continue;
                }
                if install_name_queued_or_loaded(&loaded_install, loaded_count, dep) {
                    continue;
                }
                if install_name_queued_or_loaded(&queue_install, queue_len, dep) {
                    continue;
                }
                if queue_len >= MAX_DYLIBS {
                    break;
                }
                queue_install[queue_len] = dep;
                queue_path[queue_len] = macho::rootfs_path_for_install_name(dep);
                queue_len += 1;
            }
        }
    }

    if loaded_count == 0 {
        uart::print("opendarwin: zig-smoke: no dylibs loaded\n");
        return false;
    }

    static STATIC_SYMBOL_TABLES: spin::Mutex<[&'static [Symbol]; MAX_DYLIBS]> =
        spin::Mutex::new([&[]; MAX_DYLIBS]);
    {
        let mut tables = STATIC_SYMBOL_TABLES.lock();
        tables[..loaded_count].copy_from_slice(&symbol_tables[..loaded_count]);
    }
    let tables_guard = STATIC_SYMBOL_TABLES.lock();
    let resolver_ctx = FossResolverCtx {
        tables: unsafe { core::slice::from_raw_parts(tables_guard.as_ptr(), loaded_count) },
    };
    let resolver_ctx_ptr = core::ptr::addr_of!(resolver_ctx) as *mut u8;

    for di in 0..loaded_count {
        if macho::apply_pending_bind(pending_binds[di], resolve_foss_symbol, resolver_ctx_ptr)
            .is_err()
        {
            uart::print("opendarwin: bind failed\n");
            return false;
        }
    }

    let return_entry = find_foss_symbol(&resolver_ctx, "exit").unwrap_or(0);

    uart::print("opendarwin: zig-smoke: loading MAIN\n");
    let mut main_regions = [Region::default(); 8];
    let mut main_regions_used = 0;

    let main_result = match macho::load_path(
        "MAIN",
        &mut main_regions,
        &mut main_regions_used,
        LoadOptions {
            resolver: Some(resolve_foss_symbol),
            resolver_ctx: resolver_ctx_ptr,
            user_accessible: true,
            link_at_preferred_va: true,
            defer_binding: false,
        },
    ) {
        Ok(res) => res,
        Err(_) => {
            uart::print("opendarwin: zig-smoke load failed\n");
            return false;
        }
    };

    uart::print("opendarwin: loaded ");
    uart::print_dec(loaded_count as u64);
    uart::print(" dylibs; MAIN slide=");
    uart::print_hex(main_result.slide);
    uart::print("\n");
    uart::print("opendarwin: zig-smoke: spawning task\n");

    let stack_pages = 4096u64; // 16 MiB
    let stack_len = stack_pages * PAGE_SIZE;
    let stack_pa = pmm::alloc_pages_contig(stack_pages);
    if stack_pa == 0 {
        panic!("zig-smoke: stack alloc_pages_contig failed");
    }

    let mut task_regions = [Region::default(); 9];
    for (i, &r) in main_regions[..main_regions_used].iter().enumerate() {
        task_regions[i] = r;
    }
    task_regions[main_regions_used] = Region {
        pa: stack_pa,
        len: stack_len,
        prot: mmu::Prot {
            writable: true,
            executable: false,
            user: true,
            device: false,
        },
        _pad: 0,
    };

    let idx = sched::spawn(
        &task_regions[..main_regions_used + 1],
        main_result.entry,
        stack_pa + stack_len,
    );
    sched::set_pac_enforcement(idx, false);

    // Initial argc, argv, envp setup
    let startup = stack_pa as *mut u64;
    let argv0 = stack_pa + 32;
    unsafe {
        *startup = argv0;
        *startup.add(1) = 0; // argv terminator
        *startup.add(2) = 0; // envp terminator
        let argv0_bytes = argv0 as *mut u8;
        core::ptr::copy_nonoverlapping(b"zig-smoke\0".as_ptr(), argv0_bytes, 10);
    }

    sched::set_initial_register(idx, 0, 1);
    sched::set_initial_register(idx, 1, stack_pa);
    sched::set_initial_register(idx, 2, stack_pa + 16);
    sched::set_initial_register(idx, 3, stack_pa + 16);
    sched::set_initial_register(idx, 30, return_entry);

    let table = sched::task_table(idx);
    for di in 0..loaded_count {
        let slide = loaded_slide[di];
        let start = loaded_region_start[di];
        let count = loaded_region_count[di];
        for &r in &all_regions[start..start + count] {
            mmu::map_pages(table, r.pa, r.pa, r.len, r.prot);
            mmu::map_pages(table, r.pa.wrapping_sub(slide), r.pa, r.len, r.prot);
        }
    }
    for &r in &main_regions[..main_regions_used] {
        mmu::map_pages(
            table,
            r.pa.wrapping_sub(main_result.slide),
            r.pa,
            r.len,
            r.prot,
        );
    }

    uart::print("opendarwin: zig-smoke + FOSS dylibs loaded and spawned\n");
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn kmain() -> ! {
    // 1. MMU enabled first
    mmu::enable(&mmu::KERNEL_REGIONS);

    // 2. UART init
    uart::init(uart::BOOTSTRAP_BASE);
    uart::print("opendarwin: boot ok\n");
    uart::print("opendarwin: MMU enabled\n");

    // 3. Exception vectors installed
    exceptions::init();
    uart::print("opendarwin: exception vectors installed\n");

    // 4. Device tree discovery
    let dtb_found = devicetree::discover();
    if let Some(found) = &dtb_found {
        if let Some(base) = found.uart_base {
            uart::init(base);
        }
        if let (Some(dist), Some(cpu)) = (found.gic_dist_base, found.gic_cpu_base) {
            gic::set_bases(dist, cpu);
        }
        uart::print("opendarwin: devicetree discovery ok\n");
    } else {
        uart::print("opendarwin: devicetree discovery unavailable, using bootstrap addresses\n");
    }

    // 5. Block driver & rootfs
    let mut rootfs_mounted = false;
    if let Some(found) = &dtb_found {
        if virtio_blk::init(&found.virtio_blk_matches[..found.virtio_blk_count]) {
            uart::print("opendarwin: virtio-blk device ready\n");
            if fat::mount() {
                uart::print("opendarwin: rootfs mounted (VFS/FAT)\n");
                rootfs_mounted = true;
            } else {
                uart::print("opendarwin: rootfs mount failed\n");
            }
        } else {
            uart::print("opendarwin: no virtio-blk device found\n");
        }

        virtio_gpu::stash_candidates(
            &found.virtio_gpu_matches[..found.virtio_gpu_count],
            found.pci_ecam_base,
        );
        if found.virtio_gpu_count > 0 {
            uart::print("opendarwin: virtio-gpu candidates stashed for IOKit\n");
        } else {
            uart::print("opendarwin: no virtio-gpu candidates\n");
        }
    }

    // 6. GIC & Timer
    gic::init();
    gic::enable(timer::IRQ);
    timer::init(5);
    uart::print("opendarwin: timer + GIC ready\n");

    // 7. PMM init
    let mem_base = dtb_found.and_then(|f| f.memory_base);
    let mem_size = dtb_found.and_then(|f| f.memory_size);
    let ram_base = mem_base.unwrap_or(0x4000_0000);
    let ram_size = mem_size.unwrap_or(0x4800_0000 - ram_base);

    let kernel_reserved_end = core::ptr::addr_of!(__userpages_end) as u64;
    let kernel_reserved_base = ram_base;
    let kernel_reserved_size = kernel_reserved_end.saturating_sub(kernel_reserved_base);

    if ram_size > kernel_reserved_size {
        let free_base = kernel_reserved_end;
        let free_size = (ram_base + ram_size) - kernel_reserved_end;
        pmm::init(&[MemoryRegion {
            base: free_base,
            size: free_size,
        }]);
        mmu::set_page_allocator(pmm::alloc_page);
        uart::print("opendarwin: PMM initialized (");
        let mb = free_size / 0x100000;
        uart::print_dec(mb);
        uart::print(" MB free)\n");
    } else {
        uart::print("opendarwin: PMM: no free memory available\n");
    }

    // 8. Slab allocator
    slab::init();
    uart::print("opendarwin: slab allocator ready\n");

    // 9. Mach IPC
    ipc::init_ipc();
    uart::print("opendarwin: IPC subsystem initialized\n");

    // 10. PAC
    if pac::available() {
        pac::enable();
        uart::print("opendarwin: PAC available and enabled (core 0)\n");
    } else {
        uart::print("opendarwin: PAC not available on this CPU\n");
    }

    // 11. IOKit
    iokit::link_force();
    iokit::init_iokit();
    let ecam = virtio_gpu::stashed_ecam();
    _ = iokit::publish_display_candidates(virtio_gpu::stashed_candidates(), ecam);
    _ = iokit::match_and_start_drivers();
    if !virtio_gpu::stashed_candidates().is_empty() && !virtio_gpu::ready() {
        uart::print("opendarwin: no virtio-gpu device found\n");
    }

    // 12. Spawn userspace
    if rootfs_mounted {
        _ = spawn_zig_smoke_from_fat();
    }

    // 13. Unmask IRQ & wake secondaries
    cpu::unmask_irq();

    uart::print("opendarwin: waking secondary cores...\n");
    smp::wake_secondaries();

    uart::print("opendarwin: starting scheduler on core 0...\n");
    sched::run_core(0);
}
