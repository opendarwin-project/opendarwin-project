#![no_std]

extern crate alloc;

pub mod arch;
pub mod device;
pub mod devicetree;
pub mod drivers;
pub mod iokit;
pub mod ipc;
pub mod kext;
pub mod mm;
pub mod proc;
pub mod smp;
pub mod syscall;

struct KernelAllocator;

unsafe impl core::alloc::GlobalAlloc for KernelAllocator {
    unsafe fn alloc(&self, layout: core::alloc::Layout) -> *mut u8 {
        let size = layout.size();
        let align = layout.align();
        if size <= 2048 && align <= 2048 {
            mm::slab::alloc(size.max(align))
        } else {
            let pages = (size as u64 + mm::PAGE_SIZE - 1) / mm::PAGE_SIZE;
            let pa = mm::pmm::alloc_pages_contig(pages);
            pa as *mut u8
        }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: core::alloc::Layout) {
        let size = layout.size();
        let align = layout.align();
        if size <= 2048 && align <= 2048 {
            mm::slab::free(ptr);
        } else {
            let pages = (size as u64 + mm::PAGE_SIZE - 1) / mm::PAGE_SIZE;
            mm::pmm::free_pages(ptr as u64, pages);
        }
    }
}

#[global_allocator]
static ALLOCATOR: KernelAllocator = KernelAllocator;

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    drivers::uart::print("\n--- KERNEL PANIC ---\n");
    if let Some(loc) = info.location() {
        drivers::uart::print("Location: ");
        drivers::uart::print(loc.file());
        drivers::uart::print(":");
        drivers::uart::print_dec(loc.line() as u64);
        drivers::uart::print("\n");
    }
    loop {
        arch::aarch64::cpu::wfe();
    }
}
