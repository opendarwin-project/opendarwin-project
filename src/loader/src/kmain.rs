//! Kernel entry point and subsystem initialization orchestrator.

use alloc::string::String;
use alloc::vec::Vec;

use kernel::arch::aarch64::cpu;
use kernel::arch::aarch64::exceptions;
use kernel::arch::aarch64::pac;
use kernel::devicetree;
use kernel::drivers::{display, gic, timer, uart, virtio_blk, virtio_gpu};
use kernel::iokit;
use kernel::ipc;
use kernel::mm::mmu::{self, PAGE_SIZE, Prot, Region};
use kernel::mm::{pmm, slab};
use kernel::proc::sched;
use kernel::smp;

use crate::kext;
use crate::macho::{self, LoadError, LoadOptions, Symbol};

struct LoadedDylib {
    install_name: String,
    path: String,
    slide: u64,
    regions: Vec<Region>,
    symbols: Vec<Symbol>,
    pending_bind: Option<macho::PendingBind>,
}

struct DynamicResolverCtx<'a> {
    dylibs: &'a [LoadedDylib],
}

fn dynamic_symbol_resolver(ctx: *mut u8, _ordinal: u8, name: &str) -> Option<u64> {
    let resolver_ctx = unsafe { &*(ctx as *const DynamicResolverCtx) };
    for dylib in resolver_ctx.dylibs {
        for sym in &dylib.symbols {
            if sym.name == name
                || (sym.name.starts_with('_') && &sym.name[1..] == name)
                || (name.starts_with('_') && &name[1..] == sym.name)
            {
                return Some(sym.address);
            }
        }
    }
    None
}

fn spawn_zig_smoke_from_fat() -> bool {
    let target = "MAIN";
    let Ok(main_deps) = macho::list_needed_dylibs(target) else {
        uart::print("opendarwin: failed to list dependencies for MAIN\n");
        return false;
    };

    let mut queue_install: Vec<String> = main_deps;
    let mut loaded_dylibs: Vec<LoadedDylib> = Vec::new();

    while !queue_install.is_empty() {
        let install_name = queue_install.remove(0);
        if loaded_dylibs.iter().any(|d| d.install_name == install_name) {
            continue;
        }

        let path = macho::rootfs_path_for_install_name(&install_name);

        let mut regions = [Region::default(); 16];
        let mut regions_used = 0;

        let res = macho::load_path(
            &path,
            &mut regions,
            &mut regions_used,
            LoadOptions {
                resolver: None,
                resolver_ctx: core::ptr::null_mut(),
                user_accessible: true,
                link_at_preferred_va: false,
                defer_binding: true,
            },
        );

        let load_result = match res {
            Ok(r) => r,
            Err(_) => {
                uart::print("opendarwin: dylib load failed: ");
                uart::print(&path);
                uart::print("\n");
                continue;
            }
        };

        if let Ok(transitive) = macho::list_needed_dylibs(&path) {
            for dep in transitive {
                if !queue_install.contains(&dep) && !loaded_dylibs.iter().any(|d| d.install_name == dep) {
                    queue_install.push(dep);
                }
            }
        }

        let dylib_regions = regions[..regions_used].to_vec();
        loaded_dylibs.push(LoadedDylib {
            install_name,
            path,
            slide: load_result.slide,
            regions: dylib_regions,
            symbols: load_result.external_symbols,
            pending_bind: load_result.pending_bind,
        });
    }

    let resolver_ctx = DynamicResolverCtx {
        dylibs: &loaded_dylibs,
    };
    let ctx_ptr = &resolver_ctx as *const _ as *mut u8;

    for dylib in &loaded_dylibs {
        if let Some(bind) = dylib.pending_bind {
            if let Err(_e) = macho::apply_pending_bind(bind, dynamic_symbol_resolver, ctx_ptr, &dylib.path) {
                uart::print("opendarwin: fixups failed for ");
                uart::print(&dylib.path);
                uart::print("\n");
            }
        }
    }

    let mut main_regions = [Region::default(); 16];
    let mut main_regions_used = 0;

    let res = macho::load_path(
        target,
        &mut main_regions,
        &mut main_regions_used,
        LoadOptions {
            resolver: Some(dynamic_symbol_resolver),
            resolver_ctx: ctx_ptr,
            user_accessible: true,
            link_at_preferred_va: false,
            defer_binding: false,
        },
    );

    let main_result = match res {
        Ok(r) => r,
        Err(e) => {
            uart::print("opendarwin: main load failed: ");
            match e {
                LoadError::Truncated => uart::print("Truncated\n"),
                LoadError::BadMagic => uart::print("BadMagic\n"),
                LoadError::UnsupportedCpu => uart::print("UnsupportedCpu\n"),
                LoadError::NoSegments => uart::print("NoSegments\n"),
                LoadError::AllocationFailed => uart::print("AllocationFailed\n"),
                LoadError::Dyld(_) => uart::print("Dyld\n"),
                LoadError::Io => uart::print("Io\n"),
            }
            return false;
        }
    };

    let stack_pages = 8u64;
    let stack_pa = pmm::alloc_pages_contig(stack_pages);
    let stack_len = stack_pages * PAGE_SIZE;
    let stack_top = stack_pa + stack_len - 16;
    let stack_region = Region {
        pa: stack_pa,
        len: stack_len,
        prot: Prot {
            writable: true,
            executable: false,
            user: true,
            device: false,
        },
        _pad: 0,
    };

    let mut task_regions = Vec::new();
    for r in &main_regions[..main_regions_used] {
        task_regions.push(*r);
    }
    task_regions.push(stack_region);

    let idx = sched::spawn(&task_regions, main_result.entry, stack_top);
    let table = sched::task_table(idx);

    for dylib in &loaded_dylibs {
        for r in &dylib.regions {
            mmu::map_pages(table, r.pa, r.pa, r.len, r.prot);
            mmu::map_pages(table, r.pa.wrapping_sub(dylib.slide), r.pa, r.len, r.prot);
        }
    }

    for r in &main_regions[..main_regions_used] {
        mmu::map_pages(table, r.pa.wrapping_sub(main_result.slide), r.pa, r.len, r.prot);
    }

    let mut exit_addr = 0u64;
    for dylib in &loaded_dylibs {
        for sym in &dylib.symbols {
            if sym.name == "exit" || sym.name == "_exit" {
                exit_addr = sym.address;
                break;
            }
        }
        if exit_addr != 0 {
            break;
        }
    }

    sched::set_initial_register(idx, 0, 1); // argc
    sched::set_initial_register(idx, 1, stack_pa); // argv
    sched::set_initial_register(idx, 2, stack_pa + 16); // envp
    sched::set_initial_register(idx, 3, stack_pa + 16); // apple
    sched::set_initial_register(idx, 30, exit_addr); // LR

    uart::print("opendarwin: userland spawned successfully from FAT rootfs\n");
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn kmain(dtb_arg: u64) -> ! {
    if mmu::kernel_load_addr() == 0x0200_0000 {
        display::early_marker();

        // Install VBAR_EL1/VBAR_EL2 before touching any EL2 system register:
        // an unhandled exception during the MMU/HCR/SPSR setup below would
        // otherwise hit whatever vector U-Boot/BL31 left in VBAR_EL2 (usually
        // a silent reset back to the boot ROM) instead of our red fault
        // screen.
        exceptions::init();

        if cpu::current_el() == cpu::ExceptionLevel::El2 {
            mmu::prepare_superbird_el1_mmu();
            let sp: usize;
            unsafe {
                core::arch::asm!("mov {0}, sp", out(reg) sp, options(nomem, nostack));
                cpu::drop_to_el1(el1_kmain as usize, sp, dtb_arg as usize, cpu::SCTLR_EL1_MMU_ENABLED);
            }
        }
    }

    el1_kmain(dtb_arg);
}

fn el1_kmain(_dtb_arg: u64) -> ! {
    exceptions::init();
    // The Superbird's UART pads are unreachable without disassembling the
    // unit, but `uart_AO` (0xff80_3000) is still the board console TF-A/
    // U-Boot already configured; QEMU's PL011 lives at 0x0900_0000 and
    // doesn't exist on real silicon, so probing it there would stall on a
    // bus access to a nonexistent device with no fault to catch.
    uart::init(if mmu::kernel_load_addr() == 0x0200_0000 { 0xff80_3000 } else { 0x0900_0000 });
    display::init_early();
    display::mark_stage(display::BootStage::Bootstrap);
    uart::print("   OpenDarwin Kernel (AArch64)\n");
    uart::print("========================================\n\n");

    let dtb_found = devicetree::discover();
    let (default_ram_base, default_ram_size) = if mmu::kernel_load_addr() == 0x0200_0000 {
        (0x0000_0000, 512 * 1024 * 1024)
    } else {
        (0x4000_0000, 1024 * 1024 * 1024)
    };
    let (ram_base, ram_size) = if let Some(found) = &dtb_found {
        (found.memory_base.unwrap_or(default_ram_base), found.memory_size.unwrap_or(default_ram_size))
    } else {
        (default_ram_base, default_ram_size)
    };
    let kernel_load = mmu::kernel_load_addr();
    let kernel_end = mmu::kernel_reserved_end();
    let free_start = (kernel_end + 0x10_0000 - 1) & !(0x10_0000 - 1);
    let free_size = ram_size.saturating_sub(free_start.saturating_sub(ram_base));

    let mem_regions = if kernel_load == 0x0200_0000 {
        // Superbird: reserve 2MB at 0x1000_0000 for scanout buffer
        [
            pmm::MemoryRegion {
                base: free_start,
                size: (0x1000_0000u64).saturating_sub(free_start),
            },
            pmm::MemoryRegion {
                base: 0x1020_0000,
                size: (0x2000_0000u64).saturating_sub(0x1020_0000),
            },
        ]
    } else {
        [
            pmm::MemoryRegion {
                base: free_start,
                size: free_size,
            },
            pmm::MemoryRegion {
                base: 0,
                size: 0,
            },
        ]
    };
    let active_regions = if mem_regions[1].size > 0 { &mem_regions[..] } else { &mem_regions[0..1] };
    pmm::init(active_regions);
    let kernel_region = mmu::Region {
        pa: kernel_load,
        len: mmu::KERNEL_IMAGE_MAX_LEN,
        prot: mmu::Prot {
            writable: true,
            executable: true,
            user: false,
            device: false,
        },
        _pad: 0,
    };
    mmu::enable(&[kernel_region]);
    mmu::set_page_allocator(|| pmm::alloc_pages_contig(1));
    slab::init();
    display::mark_stage(display::BootStage::MemoryReady);

    let mut rootfs_mounted = false;
    if let Some(found) = &dtb_found {
        if virtio_blk::init(&found.virtio_blk_matches[..found.virtio_blk_count]) {
            vfs::set_block_reader(virtio_blk::read_blocks);
            if vfs::mount_fat() {
                uart::print("opendarwin: mounted FAT root filesystem\n");
                rootfs_mounted = true;
            } else {
                uart::print("opendarwin: failed to mount FAT root filesystem\n");
            }
        } else {
            uart::print("opendarwin: no virtio-blk device found\n");
        }

        virtio_gpu::init(&found.virtio_gpu_matches[..found.virtio_gpu_count], found.pci_ecam_base);

        if found.has_amlogic_vpu {
            display::init_amlogic_vpu(display::VPU_BASE, display::CANVAS_BASE);
        }

        if let Some(dist) = found.gic_dist_base {
            if found.gic_version == gic::GicVersion::V3 {
                if let Some(redist) = found.gic_redist_base {
                    gic::set_v3_bases(dist, redist);
                }
            } else if let Some(cpu) = found.gic_cpu_base {
                gic::set_bases(dist, cpu);
            }
        }
    } else {
        uart::print("opendarwin: devicetree discovery failed, using fallback bootstrap\n");
        if virtio_blk::init(&[]) {
            vfs::set_block_reader(virtio_blk::read_blocks);
            if vfs::mount_fat() {
                rootfs_mounted = true;
            }
        }
    }

    if !rootfs_mounted {
        // No block device (real hardware with no removable storage, or
        // QEMU without `-d`): fall back to the FAT32 image linked into the
        // kernel binary (`kernel::ramdisk`, `tools/build_ramdisk.sh`).
        if kernel::ramdisk::mount() {
            uart::print("opendarwin: mounted embedded ramdisk root filesystem\n");
            rootfs_mounted = true;
        } else {
            uart::print("opendarwin: failed to mount embedded ramdisk\n");
        }
    }

    // The Superbird has no DTB in RAM-boot mode (`dtb_found` is always
    // `None` here), but its interrupt controller is a fixed part of the
    // silicon layout: GIC-400 (GICv2-architecture MMIO interface, *not*
    // GICv3 system registers) at GICD 0xffc0_1000 / GICC 0xffc0_2000 (see
    // `gic` module docs) - unlike QEMU's `virt` GICv2, which is always
    // discovered from the DTB. Without this, `gic::init()` would fall back
    // to QEMU's bootstrap GICv2 distributor address, which doesn't exist on
    // real silicon and faults.
    if mmu::kernel_load_addr() == 0x0200_0000 && dtb_found.is_none() {
        gic::set_bases(gic::AMLOGIC_DIST_BASE, gic::AMLOGIC_CPU_BASE);
    }
    gic::init();
    gic::enable(timer::IRQ);
    timer::init(10);
    display::mark_stage(display::BootStage::DeviceTreeReady);
    ipc::init_ipc();
    iokit::init_iokit();
    if let Some(found) = &dtb_found {
        if found.has_amlogic_vpu {
            iokit::root::publish_platform_device(
                "vpu",
                "ff900000",
                &["amlogic,meson-g12a-vpu", "amlogic,meson-vpu"],
                &[(0xff90_0000, 0x10_0000), (0xff63_8000, 0x2000)],
                &[],
            );
        }
    }
    iokit::match_and_start_drivers();
    display::mark_stage(display::BootStage::IokitReady);
    if pac::available() {
    }

    if rootfs_mounted {
        let mut hello_buf = [0u8; 256];
        if let Some(n) = vfs::read_fat_file("HELLO.TXT", &mut hello_buf) {
            uart::print("opendarwin: HELLO.TXT (");
            uart::print_dec(n as u64);
            uart::print(" bytes): ");
            uart::print_bytes(&hello_buf[..n]);
        } else {
            uart::print("opendarwin: HELLO.TXT read failed\n");
        }

        kext::load_bundle_from_fat("SampleKext.kext");
        let _ = spawn_zig_smoke_from_fat();
    }

    smp::wake_secondaries();
    kernel::arch::aarch64::cpu::unmask_irq();

    display::mark_stage(display::BootStage::Running);
    uart::print("opendarwin: starting scheduler on core 0\n");
    sched::run_core(0);
}
