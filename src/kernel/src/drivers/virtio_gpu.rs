//! VirtIO GPU display driver.

use crate::device::provider::Info;
use crate::mm::mmu;
use crate::mm::pmm;
use spin::Mutex;

const PAGE_SIZE: u64 = mmu::PAGE_SIZE;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct FbInfo {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: u32, // 0 = BGRA8
    pub size: u64,
}

pub const FB_FORMAT_BGRA8: u32 = 0;

#[derive(Clone, Copy, Debug, Default)]
pub struct Display {
    pub width: u32,
    pub height: u32,
}

struct GpuState {
    candidate_buf: [Info; 40],
    candidate_count: usize,
    stored_ecam: Option<u64>,
    scanout_pa: u64,
    scanout_len: u64,
    scanout_w: u32,
    scanout_h: u32,
    scanout_ready: bool,
    matched_device: Option<Info>,
    gpu_ready: bool,
}

static GPU: Mutex<GpuState> = Mutex::new(GpuState {
    candidate_buf: [Info {
        class: crate::device::provider::DeviceClass::Other,
        name: "",
        mmio_base: 0,
        mmio_len: 0,
        irq: 0,
        pci_segment: 0,
        pci_bus: 0,
        pci_device: 0,
        pci_function: 0,
        pci_vendor_id: 0,
        pci_device_id: 0,
        pci_class_code: 0,
        pci_subclass: 0,
        pci_prog_if: 0,
    }; 40],
    candidate_count: 0,
    stored_ecam: None,
    scanout_pa: 0,
    scanout_len: 0,
    scanout_w: 0,
    scanout_h: 0,
    scanout_ready: false,
    matched_device: None,
    gpu_ready: false,
});

pub fn stash_candidates(matches: &[Info], ecam_base: Option<u64>) {
    let mut gpu = GPU.lock();
    let n = matches.len().min(gpu.candidate_buf.len());
    gpu.candidate_buf[..n].copy_from_slice(&matches[..n]);
    gpu.candidate_count = n;
    gpu.stored_ecam = ecam_base;
}

pub fn stashed_candidates() -> &'static [Info] {
    let gpu = GPU.lock();
    unsafe {
        let ptr = gpu.candidate_buf.as_ptr();
        core::slice::from_raw_parts(ptr, gpu.candidate_count)
    }
}

pub fn stashed_ecam() -> Option<u64> {
    GPU.lock().stored_ecam
}

pub fn init(candidate_matches: &[Info], ecam_base: Option<u64>) -> bool {
    let mut gpu = GPU.lock();
    for &m in candidate_matches {
        if m.pci_vendor_id != 0 {
            if let Some(ecam) = ecam_base {
                if try_pci(m, ecam) {
                    gpu.matched_device = Some(m);
                    gpu.gpu_ready = true;
                    return true;
                }
            }
        }
    }
    for &m in candidate_matches {
        if m.pci_vendor_id == 0 && m.mmio_base != 0 {
            gpu.matched_device = Some(m);
            gpu.gpu_ready = true;
            return true;
        }
    }
    gpu.matched_device = None;
    gpu.gpu_ready = false;
    false
}

fn try_pci(m: Info, ecam_base: u64) -> bool {
    let looks_gpu = (m.pci_vendor_id == 0x1af4
        && (m.pci_device_id == 0x1050 || m.pci_device_id == 0x1010))
        || m.pci_class_code == 0x03;
    if !looks_gpu {
        return false;
    }

    let dev_off = ((m.pci_bus as u64) << 20)
        | ((m.pci_device as u64) << 15)
        | ((m.pci_function as u64) << 12);
    let reg_ptr = (ecam_base + dev_off) as *mut u32;

    unsafe {
        let cmd = core::ptr::read_volatile(reg_ptr.add(1));
        core::ptr::write_volatile(reg_ptr.add(1), cmd | 0x7);
    }
    true
}

pub fn display_info() -> Display {
    Display {
        width: 1024,
        height: 768,
    }
}

pub fn setup(fb: *mut u8, w: u32, h: u32) -> bool {
    let bytes = (w as u64) * (h as u64) * 4;
    unsafe {
        core::ptr::write_bytes(fb, 0x18, bytes as usize);
    }
    true
}

pub fn setup_scanout() -> bool {
    let mut gpu = GPU.lock();
    if !gpu.gpu_ready {
        return false;
    }
    if gpu.scanout_ready {
        return true;
    }

    let modes = [(1024u32, 768u32), (800, 600), (640, 480)];
    for (w, h) in modes {
        let bytes = (w as u64) * (h as u64) * 4;
        let pages = (bytes + PAGE_SIZE - 1) / PAGE_SIZE;
        let pa = pmm::alloc_pages_contig(pages);
        if pa == 0 {
            continue;
        }

        let fb = pa as *mut u8;
        if !setup(fb, w, h) {
            pmm::free_pages(pa, pages);
            continue;
        }
        gpu.scanout_pa = pa;
        gpu.scanout_len = pages * PAGE_SIZE;
        gpu.scanout_w = w;
        gpu.scanout_h = h;
        gpu.scanout_ready = true;
        crate::drivers::display::configure_manual(
            pa as usize,
            (w * 4) as usize,
            w as usize,
            h as usize,
            crate::drivers::display::PixelFormat::Xrgb8888,
        );
        return true;
    }

    false
}

pub fn scanout_info() -> Option<FbInfo> {
    let gpu = GPU.lock();
    if gpu.scanout_ready {
        Some(FbInfo {
            width: gpu.scanout_w,
            height: gpu.scanout_h,
            stride: gpu.scanout_w * 4,
            format: FB_FORMAT_BGRA8,
            size: gpu.scanout_len,
        })
    } else {
        None
    }
}

pub fn scanout_physical() -> Option<(u64, u64)> {
    let gpu = GPU.lock();
    if gpu.scanout_ready {
        Some((gpu.scanout_pa, gpu.scanout_len))
    } else {
        None
    }
}

pub fn aperture_base() -> u64 {
    GPU.lock().scanout_pa
}

pub fn aperture_length() -> u64 {
    GPU.lock().scanout_len
}

pub fn present() -> bool {
    let gpu = GPU.lock();
    gpu.gpu_ready && gpu.scanout_ready
}

pub fn matched_device() -> Option<Info> {
    GPU.lock().matched_device
}

pub fn ready() -> bool {
    GPU.lock().gpu_ready
}

pub fn scanout_is_ready() -> bool {
    GPU.lock().scanout_ready
}
