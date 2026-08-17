//! Kext image loading from FAT filesystem and Mach-O execution.

use crate::drivers::uart;
use crate::fs::fat;
use crate::kext::api::{KEXT_SUCCESS, KextEntry};
use crate::kext::plist;
use crate::kext::registry;
use crate::loader::macho::{self, LoadOptions};
use crate::mm::mmu::{self, Region};

static KEXT_SCRATCH: spin::Mutex<[u8; 256 * 1024]> = spin::Mutex::new([0; 256 * 1024]);
static PLIST_SCRATCH: spin::Mutex<[u8; 64 * 1024]> = spin::Mutex::new([0; 64 * 1024]);

fn kernel_resolver(_ctx: *mut u8, _ordinal: u8, name: &str) -> Option<u64> {
    if name == "_kext_kernel_api" || name == "kext_kernel_api" {
        return Some(core::ptr::addr_of!(registry::KERNEL_API) as u64);
    }
    if name == "_kext_log" || name == "kext_log" {
        return Some(registry::kext_log as *const () as usize as u64);
    }
    if name == "_kext_register_driver" || name == "kext_register_driver" {
        return Some(registry::kext_register_driver as *const () as usize as u64);
    }
    None
}

pub fn load_image(name: &str, image: &[u8]) -> bool {
    let mut regions = [Region::default(); 8];
    let mut regions_used = 0;

    let res = macho::load_with_options(
        image,
        &mut regions,
        &mut regions_used,
        LoadOptions {
            resolver: Some(kernel_resolver),
            resolver_ctx: core::ptr::null_mut(),
            user_accessible: false,
            link_at_preferred_va: false,
            defer_binding: false,
        },
    );

    let load_result = match res {
        Ok(r) => r,
        Err(_) => {
            uart::print("opendarwin: kext load failed: ");
            uart::print(name);
            uart::print("\n");
            return false;
        }
    };

    for r in &regions[..regions_used] {
        mmu::map_extra(r.pa, r.len, r.prot);
        mmu::inherit_extra_in_task_tables(r.pa, r.len, r.prot);
    }

    let entry: KextEntry = unsafe { core::mem::transmute(load_result.entry as usize) };
    let rc = entry(&registry::KERNEL_API);
    if rc != KEXT_SUCCESS {
        uart::print("opendarwin: kext entry failed: ");
        uart::print(name);
        uart::print("\n");
        return false;
    }

    uart::print("opendarwin: kext loaded: ");
    uart::print(name);
    uart::print("\n");
    true
}

pub fn load_from_fat(name: &str) -> bool {
    let mut scratch = KEXT_SCRATCH.lock();
    let Some(n) = fat::read_file(name, &mut *scratch) else {
        return false;
    };
    load_image(name, &scratch[..n])
}

pub fn load_bundle_from_fat(bundle_name: &str) -> bool {
    let mut info_path_buf = [0u8; 128];
    let info_path = format_path(bundle_name, "/Contents/Info.plist", &mut info_path_buf);

    let mut plist_scratch = PLIST_SCRATCH.lock();
    let Some(info_len) = fat::read_file(info_path, &mut *plist_scratch) else {
        return false;
    };

    let Ok(info) = plist::parse_info_plist(&plist_scratch[..info_len]) else {
        uart::print("opendarwin: kext plist failed: ");
        uart::print(bundle_name);
        uart::print("\n");
        return false;
    };

    uart::print("opendarwin: kext bundle: ");
    uart::print(info.bundle_id());
    uart::print(" executable ");
    uart::print(info.exe_name());
    uart::print("\n");

    let mut exe_path_buf = [0u8; 160];
    let exe_path = format_exe_path(bundle_name, info.exe_name(), &mut exe_path_buf);
    drop(plist_scratch);

    let mut kext_scratch = KEXT_SCRATCH.lock();
    let Some(exe_len) = fat::read_file(exe_path, &mut *kext_scratch) else {
        uart::print("opendarwin: kext executable missing: ");
        uart::print(exe_path);
        uart::print("\n");
        return false;
    };

    load_image(info.bundle_id(), &kext_scratch[..exe_len])
}

fn format_path<'a>(base: &str, sub: &str, buf: &'a mut [u8]) -> &'a str {
    let mut n = 0;
    for &b in base.as_bytes() {
        if n < buf.len() {
            buf[n] = b;
            n += 1;
        }
    }
    for &b in sub.as_bytes() {
        if n < buf.len() {
            buf[n] = b;
            n += 1;
        }
    }
    core::str::from_utf8(&buf[..n]).unwrap_or("")
}

fn format_exe_path<'a>(base: &str, exe: &str, buf: &'a mut [u8]) -> &'a str {
    let mut n = 0;
    for &b in base.as_bytes() {
        if n < buf.len() {
            buf[n] = b;
            n += 1;
        }
    }
    let prefix = b"/Contents/MacOS/";
    for &b in prefix {
        if n < buf.len() {
            buf[n] = b;
            n += 1;
        }
    }
    for &b in exe.as_bytes() {
        if n < buf.len() {
            buf[n] = b;
            n += 1;
        }
    }
    core::str::from_utf8(&buf[..n]).unwrap_or("")
}
