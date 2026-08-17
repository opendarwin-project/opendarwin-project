//! VirtIO MMIO Block device driver.

use crate::device::provider::Info;
use spin::Mutex;

const VIRTIO_MMIO_MAGIC_VALUE: usize = 0x000;
const VIRTIO_MMIO_DEVICE_ID: usize = 0x008;
const VIRTIO_MMIO_STATUS: usize = 0x070;
const VIRTIO_MMIO_QUEUE_SEL: usize = 0x030;
const VIRTIO_MMIO_QUEUE_NUM_MAX: usize = 0x034;
const VIRTIO_MMIO_QUEUE_NUM: usize = 0x038;
const VIRTIO_MMIO_QUEUE_READY: usize = 0x044;
const VIRTIO_MMIO_QUEUE_NOTIFY: usize = 0x050;
const VIRTIO_MMIO_QUEUE_DESC_LOW: usize = 0x080;
const VIRTIO_MMIO_QUEUE_DESC_HIGH: usize = 0x084;
const VIRTIO_MMIO_QUEUE_AVAIL_LOW: usize = 0x090;
const VIRTIO_MMIO_QUEUE_AVAIL_HIGH: usize = 0x094;
const VIRTIO_MMIO_QUEUE_USED_LOW: usize = 0x0a0;
const VIRTIO_MMIO_QUEUE_USED_HIGH: usize = 0x0a4;

const VIRTIO_STATUS_ACKNOWLEDGE: u32 = 1;
const VIRTIO_STATUS_DRIVER: u32 = 2;
const VIRTIO_STATUS_DRIVER_OK: u32 = 4;
const VIRTIO_STATUS_FEATURES_OK: u32 = 8;

const VIRTIO_BLK_T_IN: u32 = 0;

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

const QUEUE_SIZE: usize = 16;

#[repr(C, align(16))]
#[derive(Clone, Copy, Default)]
struct VirtqDesc {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
}

#[repr(C, align(2))]
#[derive(Clone, Copy)]
struct VirtqAvail {
    flags: u16,
    idx: u16,
    ring: [u16; QUEUE_SIZE],
}

impl Default for VirtqAvail {
    fn default() -> Self {
        Self {
            flags: 0,
            idx: 0,
            ring: [0; QUEUE_SIZE],
        }
    }
}

#[repr(C, align(4))]
#[derive(Clone, Copy, Default)]
struct VirtqUsedElem {
    id: u32,
    len: u32,
}

#[repr(C, align(4))]
#[derive(Clone, Copy)]
struct VirtqUsed {
    flags: u16,
    idx: u16,
    ring: [VirtqUsedElem; QUEUE_SIZE],
}

impl Default for VirtqUsed {
    fn default() -> Self {
        Self {
            flags: 0,
            idx: 0,
            ring: [VirtqUsedElem::default(); QUEUE_SIZE],
        }
    }
}

#[repr(C)]
#[derive(Default)]
struct VirtioBlkReq {
    type_: u32,
    reserved: u32,
    sector: u64,
}

pub struct VirtioBlockDevice {
    mmio_base: u64,
    desc: [VirtqDesc; QUEUE_SIZE],
    avail: VirtqAvail,
    used: VirtqUsed,
    req: VirtioBlkReq,
    status_byte: u8,
    last_used_idx: u16,
}

impl VirtioBlockDevice {
    pub const fn new(base: u64) -> Self {
        Self {
            mmio_base: base,
            desc: [VirtqDesc {
                addr: 0,
                len: 0,
                flags: 0,
                next: 0,
            }; QUEUE_SIZE],
            avail: VirtqAvail {
                flags: 0,
                idx: 0,
                ring: [0; QUEUE_SIZE],
            },
            used: VirtqUsed {
                flags: 0,
                idx: 0,
                ring: [VirtqUsedElem { id: 0, len: 0 }; QUEUE_SIZE],
            },
            req: VirtioBlkReq {
                type_: 0,
                reserved: 0,
                sector: 0,
            },
            status_byte: 0,
            last_used_idx: 0,
        }
    }

    pub fn start(&mut self) -> bool {
        let base = self.mmio_base;
        unsafe {
            let magic =
                core::ptr::read_volatile((base + VIRTIO_MMIO_MAGIC_VALUE as u64) as *const u32);
            if magic != 0x74726976 {
                return false;
            }
            let device_id =
                core::ptr::read_volatile((base + VIRTIO_MMIO_DEVICE_ID as u64) as *const u32);
            if device_id != 2 {
                return false;
            }

            // Reset
            core::ptr::write_volatile((base + VIRTIO_MMIO_STATUS as u64) as *mut u32, 0);
            let mut status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER;
            core::ptr::write_volatile((base + VIRTIO_MMIO_STATUS as u64) as *mut u32, status);
            status |= VIRTIO_STATUS_FEATURES_OK;
            core::ptr::write_volatile((base + VIRTIO_MMIO_STATUS as u64) as *mut u32, status);

            // Configure queue 0
            core::ptr::write_volatile((base + VIRTIO_MMIO_QUEUE_SEL as u64) as *mut u32, 0);
            let max_q =
                core::ptr::read_volatile((base + VIRTIO_MMIO_QUEUE_NUM_MAX as u64) as *const u32);
            if max_q < QUEUE_SIZE as u32 {
                return false;
            }
            core::ptr::write_volatile(
                (base + VIRTIO_MMIO_QUEUE_NUM as u64) as *mut u32,
                QUEUE_SIZE as u32,
            );

            let desc_addr = core::ptr::addr_of!(self.desc) as u64;
            let avail_addr = core::ptr::addr_of!(self.avail) as u64;
            let used_addr = core::ptr::addr_of!(self.used) as u64;

            core::ptr::write_volatile(
                (base + VIRTIO_MMIO_QUEUE_DESC_LOW as u64) as *mut u32,
                desc_addr as u32,
            );
            core::ptr::write_volatile(
                (base + VIRTIO_MMIO_QUEUE_DESC_HIGH as u64) as *mut u32,
                (desc_addr >> 32) as u32,
            );
            core::ptr::write_volatile(
                (base + VIRTIO_MMIO_QUEUE_AVAIL_LOW as u64) as *mut u32,
                avail_addr as u32,
            );
            core::ptr::write_volatile(
                (base + VIRTIO_MMIO_QUEUE_AVAIL_HIGH as u64) as *mut u32,
                (avail_addr >> 32) as u32,
            );
            core::ptr::write_volatile(
                (base + VIRTIO_MMIO_QUEUE_USED_LOW as u64) as *mut u32,
                used_addr as u32,
            );
            core::ptr::write_volatile(
                (base + VIRTIO_MMIO_QUEUE_USED_HIGH as u64) as *mut u32,
                (used_addr >> 32) as u32,
            );

            core::ptr::write_volatile((base + VIRTIO_MMIO_QUEUE_READY as u64) as *mut u32, 1);

            status |= VIRTIO_STATUS_DRIVER_OK;
            core::ptr::write_volatile((base + VIRTIO_MMIO_STATUS as u64) as *mut u32, status);
        }
        true
    }

    pub fn read_blocks(&mut self, sector: u64, count: u32, buf: &mut [u8]) -> bool {
        let bytes_to_read = count as usize * 512;
        if buf.len() < bytes_to_read {
            return false;
        }

        self.req.type_ = VIRTIO_BLK_T_IN;
        self.req.reserved = 0;
        self.req.sector = sector;
        self.status_byte = 0xff;

        self.desc[0].addr = core::ptr::addr_of!(self.req) as u64;
        self.desc[0].len = core::mem::size_of::<VirtioBlkReq>() as u32;
        self.desc[0].flags = VRING_DESC_F_NEXT;
        self.desc[0].next = 1;

        self.desc[1].addr = buf.as_mut_ptr() as u64;
        self.desc[1].len = bytes_to_read as u32;
        self.desc[1].flags = VRING_DESC_F_NEXT | VRING_DESC_F_WRITE;
        self.desc[1].next = 2;

        self.desc[2].addr = core::ptr::addr_of!(self.status_byte) as u64;
        self.desc[2].len = 1;
        self.desc[2].flags = VRING_DESC_F_WRITE;
        self.desc[2].next = 0;

        let avail_idx = self.avail.idx;
        self.avail.ring[(avail_idx as usize) % QUEUE_SIZE] = 0;
        core::sync::atomic::fence(core::sync::atomic::Ordering::SeqCst);
        self.avail.idx = avail_idx.wrapping_add(1);

        unsafe {
            core::ptr::write_volatile(
                (self.mmio_base + VIRTIO_MMIO_QUEUE_NOTIFY as u64) as *mut u32,
                0,
            );
        }

        while unsafe { core::ptr::read_volatile(&self.used.idx) } == self.last_used_idx {
            core::hint::spin_loop();
        }
        self.last_used_idx = self.last_used_idx.wrapping_add(1);

        self.status_byte == 0
    }
}

struct BlkState {
    device: Option<VirtioBlockDevice>,
    matched: Option<Info>,
}

static BLK: Mutex<BlkState> = Mutex::new(BlkState {
    device: None,
    matched: None,
});

pub fn init(candidate_matches: &[Info]) -> bool {
    let mut blk = BLK.lock();
    for &m in candidate_matches {
        if m.mmio_base == 0 {
            continue;
        }
        let mut dev = VirtioBlockDevice::new(m.mmio_base);
        if dev.start() {
            blk.device = Some(dev);
            blk.matched = Some(m);
            return true;
        }
    }
    blk.device = None;
    blk.matched = None;
    false
}

pub fn read_blocks(sector: u64, count: u32, buf: &mut [u8]) -> bool {
    let mut blk = BLK.lock();
    if let Some(dev) = &mut blk.device {
        dev.read_blocks(sector, count, buf)
    } else {
        false
    }
}

pub fn write_blocks(_sector: u64, _count: u32, _buf: &[u8]) -> bool {
    false // Read-only rootfs
}

pub fn matched_device() -> Option<Info> {
    BLK.lock().matched
}
