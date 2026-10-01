//! VirtIO MMIO block device driver, backed by the `virtio-drivers` crate
//! (rcore-os/virtio-drivers) rather than a hand-rolled virtqueue.
//!
//! Only [`Hal`] (DMA allocation) and the MMIO transport wiring are
//! OpenDarwin-specific; feature negotiation, the split virtqueue, and the
//! block request protocol are the crate's.

use crate::device::provider::Info;
use crate::mm::pmm;
use core::ptr::NonNull;
use spin::Mutex;
use virtio_drivers::device::blk::VirtIOBlk;
use virtio_drivers::transport::mmio::{MmioTransport, VirtIOHeader};
use virtio_drivers::transport::{DeviceType, Transport};
use virtio_drivers::{BufferDirection, Hal, PhysAddr};

/// QEMU's `virt` machine maps each virtio-mmio slot to a fixed 512-byte
/// window (4.2.2 of the VirtIO spec's minimum MMIO region), covering the
/// legacy/modern header plus config space `MmioTransport::new` expects.
const MMIO_REGION_SIZE: usize = 0x200;

/// Kernel `Hal` for virtio-drivers: OpenDarwin runs with a single flat
/// identity VA==PA mapping (see mm/mmu.rs) and no IOMMU, so "sharing" a
/// buffer with a device is a no-op and MMIO physical addresses are usable
/// directly as pointers.
struct KernelHal;

// SAFETY: `dma_alloc` returns PMM pages (physically contiguous, zeroed,
// page-aligned, exclusively owned until `dma_dealloc`); `mmio_phys_to_virt`
// is valid because every physical address in the machine's RAM/MMIO ranges
// is identity-mapped; `share`/`unshare` are no-ops because there's no IOMMU
// isolating the device from guest RAM, so the buffer's own address is
// already what the device needs.
unsafe impl Hal for KernelHal {
    fn dma_alloc(pages: usize, _direction: BufferDirection) -> (PhysAddr, NonNull<u8>) {
        let base = pmm::alloc_pages_contig(pages as u64);
        let ptr = NonNull::new(base as *mut u8).expect("pmm: dma_alloc returned null");
        (base, ptr)
    }

    unsafe fn dma_dealloc(paddr: PhysAddr, _vaddr: NonNull<u8>, pages: usize) -> i32 {
        pmm::free_pages(paddr, pages as u64);
        0
    }

    unsafe fn mmio_phys_to_virt(paddr: PhysAddr, _size: usize) -> NonNull<u8> {
        NonNull::new(paddr as *mut u8).expect("virtio: null MMIO physical address")
    }

    unsafe fn share(buffer: NonNull<[u8]>, _direction: BufferDirection) -> PhysAddr {
        buffer.as_ptr() as *mut u8 as PhysAddr
    }

    unsafe fn unshare(_paddr: PhysAddr, _buffer: NonNull<[u8]>, _direction: BufferDirection) {}
}

struct BlkState {
    device: Option<VirtIOBlk<KernelHal, MmioTransport<'static>>>,
    matched: Option<Info>,
}

// SAFETY: OpenDarwin's kernel is single-threaded from this driver's
// perspective (all callers hold `BLK`'s lock for the duration of any
// request), and `MmioTransport`/`VirtIOBlk` only ever touch memory reachable
// through that lock.
unsafe impl Send for BlkState {}

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
        let Some(header) = NonNull::new(m.mmio_base as *mut VirtIOHeader) else {
            continue;
        };
        // SAFETY: `m.mmio_base` came from devicetree discovery of a
        // `virtio,mmio` region, identity-mapped and valid for the static
        // lifetime of the kernel.
        let transport = match unsafe { MmioTransport::new(header, MMIO_REGION_SIZE) } {
            Ok(t) => t,
            Err(_) => continue,
        };
        if transport.device_type() != DeviceType::Block {
            continue;
        }
        let Ok(dev) = VirtIOBlk::<KernelHal, _>::new(transport) else {
            continue;
        };
        blk.device = Some(dev);
        blk.matched = Some(m);
        return true;
    }
    blk.device = None;
    blk.matched = None;
    false
}

pub fn read_blocks(sector: u64, count: u32, buf: &mut [u8]) -> bool {
    let bytes = count as usize * 512;
    if buf.len() < bytes {
        return false;
    }
    let mut blk = BLK.lock();
    let Some(dev) = &mut blk.device else {
        return false;
    };
    dev.read_blocks(sector as usize, &mut buf[..bytes]).is_ok()
}

pub fn write_blocks(_sector: u64, _count: u32, _buf: &[u8]) -> bool {
    false // Read-only rootfs
}

pub fn matched_device() -> Option<Info> {
    BLK.lock().matched
}
