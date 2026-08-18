//! Memory descriptors and mappings matching Darwin IOKit/IOMemoryDescriptor.h,
//! IOKit/IODeviceMemory.h, and IOKit/IOMemoryMap.h.

use crate::mm::mmu;

/// Cache attributes for mapped memory ranges.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum IOMapCacheMode {
    #[default]
    Default = 0,
    InhibitCache = 1, // Device-nGnRE
    WriteCombining = 2,
    CopyBack = 3,
}

/// Abstract memory descriptor representing a physical memory or MMIO region.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct IOMemoryDescriptor {
    pub pa: u64,
    pub length: u64,
}

impl IOMemoryDescriptor {
    pub const fn with_physical_range(pa: u64, length: u64) -> Self {
        Self { pa, length }
    }

    pub fn get_virtual_address(&self) -> u64 {
        self.pa
    }

    pub fn get_physical_address(&self) -> u64 {
        self.pa
    }

    pub fn get_length(&self) -> u64 {
        self.length
    }
}

/// Represents an active virtual memory mapping created for a memory descriptor.
#[derive(Clone, Copy, Debug)]
pub struct IOMemoryMap {
    pub va: u64,
    pub pa: u64,
    pub length: u64,
    pub cache_mode: IOMapCacheMode,
}

impl IOMemoryMap {
    pub fn get_virtual_address(&self) -> u64 {
        self.va
    }

    pub fn get_physical_address(&self) -> u64 {
        self.pa
    }

    pub fn get_length(&self) -> u64 {
        self.length
    }

    pub fn get_cache_mode(&self) -> IOMapCacheMode {
        self.cache_mode
    }

    #[inline]
    pub unsafe fn read32(&self, offset: usize) -> u32 {
        let addr = (self.va as usize) + offset;
        unsafe { core::ptr::read_volatile(addr as *const u32) }
    }

    #[inline]
    pub unsafe fn write32(&self, offset: usize, val: u32) {
        let addr = (self.va as usize) + offset;
        unsafe { core::ptr::write_volatile(addr as *mut u32, val) };
    }
}

/// Device physical memory aperture (MMIO or VRAM) matching Darwin `IODeviceMemory`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct IODeviceMemory {
    pub descriptor: IOMemoryDescriptor,
    pub cache_mode: IOMapCacheMode,
}

impl IODeviceMemory {
    pub const fn with_range(pa: u64, length: u64) -> Self {
        Self {
            descriptor: IOMemoryDescriptor::with_physical_range(pa, length),
            cache_mode: IOMapCacheMode::InhibitCache,
        }
    }

    pub const fn with_range_and_cache(pa: u64, length: u64, cache_mode: IOMapCacheMode) -> Self {
        Self {
            descriptor: IOMemoryDescriptor::with_physical_range(pa, length),
            cache_mode,
        }
    }

    pub fn with_sub_range(&self, offset: u64, length: u64) -> Option<Self> {
        if offset.checked_add(length)? <= self.descriptor.length {
            Some(Self {
                descriptor: IOMemoryDescriptor::with_physical_range(
                    self.descriptor.pa + offset,
                    length,
                ),
                cache_mode: self.cache_mode,
            })
        } else {
            None
        }
    }

    pub fn get_physical_address(&self) -> u64 {
        self.descriptor.pa
    }

    pub fn get_length(&self) -> u64 {
        self.descriptor.length
    }

    /// Maps this device memory aperture into kernel virtual memory.
    pub fn map(&self) -> IOMemoryMap {
        let pa = self.descriptor.pa;
        let len = self.descriptor.length;
        let is_device = self.cache_mode == IOMapCacheMode::InhibitCache;

        // Ensure mapped in kernel translation tables
        if pa != 0 && len != 0 {
            mmu::map_extra(
                pa,
                len.max(mmu::PAGE_SIZE),
                mmu::Prot {
                    writable: true,
                    executable: false,
                    user: false,
                    device: is_device,
                },
            );
        }

        // On our current 1:1 kernel physical memory mapping, VA = PA
        IOMemoryMap {
            va: pa,
            pa,
            length: len,
            cache_mode: self.cache_mode,
        }
    }
}
