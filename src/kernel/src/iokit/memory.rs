//! Memory descriptors for IOKit memory-mapped ranges (IOMemoryDescriptor).

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct IOMemoryDescriptor {
    pub va: u64,
    pub pa: u64,
    pub length: u64,
}

impl IOMemoryDescriptor {
    pub const fn with_physical_range(pa: u64, length: u64) -> Self {
        Self {
            va: pa, // Identity-mapped
            pa,
            length,
        }
    }

    pub fn get_virtual_address(&self) -> u64 {
        self.va
    }

    pub fn get_length(&self) -> u64 {
        self.length
    }
}
