//! Flattened Device Tree (DTB) parsing and device discovery.

use crate::device::provider::{DeviceClass, Info};
use crate::drivers::uart;
use crate::mm::mmu;
use core::sync::atomic::{AtomicU64, Ordering};

#[unsafe(no_mangle)]
pub static dtb_phys_addr: AtomicU64 = AtomicU64::new(0);

pub const MAX_VIRTIO_CANDIDATES: usize = 40;
const DTB_MAP_WINDOW: u64 = 0x10_0000; // 1 MB

#[derive(Clone, Copy)]
pub struct Found {
    pub uart_base: Option<u64>,
    pub gic_dist_base: Option<u64>,
    pub gic_cpu_base: Option<u64>,
    pub memory_base: Option<u64>,
    pub memory_size: Option<u64>,
    pub virtio_blk_matches: [Info; MAX_VIRTIO_CANDIDATES],
    pub virtio_blk_count: usize,
    pub virtio_gpu_matches: [Info; MAX_VIRTIO_CANDIDATES],
    pub virtio_gpu_count: usize,
    pub pci_ecam_base: Option<u64>,
}

impl Default for Found {
    fn default() -> Self {
        Self {
            uart_base: None,
            gic_dist_base: None,
            gic_cpu_base: None,
            memory_base: None,
            memory_size: None,
            virtio_blk_matches: [Info {
                class: DeviceClass::Other,
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
            }; MAX_VIRTIO_CANDIDATES],
            virtio_blk_count: 0,
            virtio_gpu_matches: [Info {
                class: DeviceClass::Other,
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
            }; MAX_VIRTIO_CANDIDATES],
            virtio_gpu_count: 0,
            pci_ecam_base: None,
        }
    }
}

#[repr(C)]
struct FdtHeader {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
}

const FDT_MAGIC: u32 = 0xd00dfeed;
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

fn read_be_u32(bytes: &[u8]) -> u32 {
    u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

fn read_be_u64(bytes: &[u8]) -> u64 {
    if bytes.len() >= 8 {
        u64::from_be_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ])
    } else if bytes.len() >= 4 {
        read_be_u32(bytes) as u64
    } else {
        0
    }
}

pub fn discover() -> Option<Found> {
    let dtb_addr = dtb_phys_addr.load(Ordering::Acquire);
    if dtb_addr == 0 {
        return None;
    }

    mmu::map_extra(
        dtb_addr,
        DTB_MAP_WINDOW,
        mmu::Prot {
            writable: false,
            executable: false,
            user: false,
            device: false,
        },
    );

    let blob =
        unsafe { core::slice::from_raw_parts(dtb_addr as *const u8, DTB_MAP_WINDOW as usize) };
    if blob.len() < core::mem::size_of::<FdtHeader>() {
        return None;
    }

    let magic = read_be_u32(&blob[0..4]);
    if magic != FDT_MAGIC {
        uart::print("devicetree: invalid magic\n");
        return None;
    }

    let totalsize = read_be_u32(&blob[4..8]) as usize;
    let struct_off = read_be_u32(&blob[8..12]) as usize;
    let strings_off = read_be_u32(&blob[12..16]) as usize;

    if struct_off >= blob.len() || strings_off >= blob.len() {
        return None;
    }

    let mut found = Found::default();
    let mut offset = struct_off;

    let mut addr_cells: usize = 2;
    let mut size_cells: usize = 1;

    let mut current_node_name = "";
    let mut node_depth: usize = 0;

    while offset + 4 <= blob.len() && offset < struct_off + totalsize {
        let token = read_be_u32(&blob[offset..offset + 4]);
        offset += 4;

        match token {
            FDT_BEGIN_NODE => {
                let name_start = offset;
                while offset < blob.len() && blob[offset] != 0 {
                    offset += 1;
                }
                let name_bytes = &blob[name_start..offset];
                current_node_name = core::str::from_utf8(name_bytes).unwrap_or("");
                offset = (offset + 4) & !3; // 4-byte align
                node_depth += 1;
            }
            FDT_END_NODE => {
                if node_depth > 0 {
                    node_depth -= 1;
                }
            }
            FDT_PROP => {
                if offset + 8 > blob.len() {
                    break;
                }
                let prop_len = read_be_u32(&blob[offset..offset + 4]) as usize;
                let name_off = read_be_u32(&blob[offset + 4..offset + 8]) as usize;
                offset += 8;

                if offset + prop_len > blob.len() {
                    break;
                }
                let prop_val = &blob[offset..offset + prop_len];
                offset = (offset + prop_len + 3) & !3;

                let prop_name_start = strings_off + name_off;
                let mut prop_name_end = prop_name_start;
                while prop_name_end < blob.len() && blob[prop_name_end] != 0 {
                    prop_name_end += 1;
                }
                let prop_name = if prop_name_end <= blob.len() {
                    core::str::from_utf8(&blob[prop_name_start..prop_name_end]).unwrap_or("")
                } else {
                    ""
                };

                if node_depth == 1 {
                    if prop_name == "#address-cells" && prop_val.len() >= 4 {
                        addr_cells = read_be_u32(prop_val) as usize;
                    } else if prop_name == "#size-cells" && prop_val.len() >= 4 {
                        size_cells = read_be_u32(prop_val) as usize;
                    }
                }

                if current_node_name.starts_with("memory") && prop_name == "reg" {
                    let addr_stride = addr_cells * 4;
                    let size_stride = size_cells * 4;
                    if prop_val.len() >= addr_stride + size_stride {
                        let base = read_be_u64(&prop_val[0..addr_stride]);
                        let size = read_be_u64(&prop_val[addr_stride..addr_stride + size_stride]);
                        if size > 0 {
                            found.memory_base = Some(base);
                            found.memory_size = Some(size);
                        }
                    }
                }

                if (current_node_name.starts_with("pl011")
                    || current_node_name.starts_with("uart@"))
                    && prop_name == "reg"
                    && prop_val.len() >= 8
                {
                    let base = read_be_u64(&prop_val[0..8]);
                    found.uart_base = Some(base);
                    mmu::map_extra(
                        base,
                        mmu::PAGE_SIZE,
                        mmu::Prot {
                            writable: true,
                            executable: false,
                            user: false,
                            device: true,
                        },
                    );
                }

                if (current_node_name.starts_with("intc@")
                    || current_node_name.starts_with("interrupt-controller@"))
                    && prop_name == "reg"
                    && prop_val.len() >= 32
                {
                    let dist_base = read_be_u64(&prop_val[0..8]);
                    let dist_size = read_be_u64(&prop_val[8..16]);
                    let cpu_base = read_be_u64(&prop_val[16..24]);
                    let cpu_size = read_be_u64(&prop_val[24..32]);

                    found.gic_dist_base = Some(dist_base);
                    found.gic_cpu_base = Some(cpu_base);

                    mmu::map_extra(
                        dist_base,
                        dist_size.max(mmu::PAGE_SIZE),
                        mmu::Prot {
                            writable: true,
                            executable: false,
                            user: false,
                            device: true,
                        },
                    );
                    mmu::map_extra(
                        cpu_base,
                        cpu_size.max(mmu::PAGE_SIZE),
                        mmu::Prot {
                            writable: true,
                            executable: false,
                            user: false,
                            device: true,
                        },
                    );
                }

                if current_node_name.starts_with("virtio_mmio@")
                    && prop_name == "reg"
                    && prop_val.len() >= 16
                {
                    let base = read_be_u64(&prop_val[0..8]);
                    let size = read_be_u64(&prop_val[8..16]);

                    if found.virtio_blk_count < MAX_VIRTIO_CANDIDATES {
                        mmu::map_extra(
                            base,
                            size.max(mmu::PAGE_SIZE),
                            mmu::Prot {
                                writable: true,
                                executable: false,
                                user: false,
                                device: true,
                            },
                        );

                        found.virtio_blk_matches[found.virtio_blk_count] = Info {
                            class: DeviceClass::Block,
                            name: "virtio-blk-mmio",
                            mmio_base: base,
                            mmio_len: size,
                            ..Default::default()
                        };
                        found.virtio_blk_count += 1;
                    }
                }

                if (current_node_name.starts_with("pcie@") || current_node_name.starts_with("pci@"))
                    && prop_name == "reg"
                    && prop_val.len() >= 16
                {
                    let base = read_be_u64(&prop_val[0..8]);
                    let size = read_be_u64(&prop_val[8..16]).min(16 << 20); // 16 MB
                    found.pci_ecam_base = Some(base);

                    mmu::map_extra(
                        base,
                        size,
                        mmu::Prot {
                            writable: true,
                            executable: false,
                            user: false,
                            device: true,
                        },
                    );

                    scan_pci_ecam(base, &mut found);
                }
            }
            FDT_NOP => {}
            FDT_END => break,
            _ => {}
        }
    }

    Some(found)
}

fn scan_pci_ecam(ecam_base: u64, found: &mut Found) {
    for bus in 0..16u8 {
        for dev in 0..32u8 {
            for func in 0..8u8 {
                let dev_off = ((bus as u64) << 20) | ((dev as u64) << 15) | ((func as u64) << 12);
                let reg_ptr = (ecam_base + dev_off) as *const u32;

                let id_reg = unsafe { core::ptr::read_volatile(reg_ptr) };
                let vendor_id = (id_reg & 0xffff) as u16;
                let device_id = (id_reg >> 16) as u16;

                if vendor_id == 0xffff || vendor_id == 0 {
                    if func == 0 {
                        break;
                    }
                    continue;
                }

                let class_reg = unsafe { core::ptr::read_volatile(reg_ptr.add(2)) };
                let class_code = ((class_reg >> 24) & 0xff) as u8;
                let subclass = ((class_reg >> 16) & 0xff) as u8;
                let prog_if = ((class_reg >> 8) & 0xff) as u8;

                let is_virtio_gpu =
                    vendor_id == 0x1af4 && (device_id == 0x1050 || device_id == 0x1010);
                let is_display = class_code == 0x03;

                if (is_virtio_gpu || is_display) && found.virtio_gpu_count < MAX_VIRTIO_CANDIDATES {
                    let bar0 = unsafe { core::ptr::read_volatile(reg_ptr.add(4)) } as u64;
                    if bar0 != 0 && (bar0 & 1) == 0 {
                        let bar0_base = bar0 & !0xf;
                        mmu::map_extra(
                            bar0_base,
                            0x1_0000,
                            mmu::Prot {
                                writable: true,
                                executable: false,
                                user: false,
                                device: true,
                            },
                        );
                    }

                    found.virtio_gpu_matches[found.virtio_gpu_count] = Info {
                        class: DeviceClass::Display,
                        name: if is_virtio_gpu {
                            "virtio-gpu-pci"
                        } else {
                            "pci-display"
                        },
                        mmio_base: bar0 & !0xf,
                        mmio_len: 0x1_0000,
                        pci_bus: bus,
                        pci_device: dev,
                        pci_function: func,
                        pci_vendor_id: vendor_id,
                        pci_device_id: device_id,
                        pci_class_code: class_code,
                        pci_subclass: subclass,
                        pci_prog_if: prog_if,
                        ..Default::default()
                    };
                    found.virtio_gpu_count += 1;
                }
            }
        }
    }
}
