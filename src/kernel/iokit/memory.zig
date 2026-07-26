//! Minimal IOMemoryDescriptor / IOMemoryMap for BAR aperture sharing.

const types = @import("types.zig");
const mmu = @import("../mm/mmu.zig");

pub const IOMemoryMap = struct {
    virtual_address: u64 = 0,
    length: u64 = 0,
    physical_address: u64 = 0,
};

pub const IOMemoryDescriptor = struct {
    physical_address: u64 = 0,
    length: u64 = 0,
    mapped: bool = false,
    map_info: IOMemoryMap = .{},

    pub fn initWithPhysicalRange(self: *IOMemoryDescriptor, phys: u64, len: u64) void {
        self.* = .{
            .physical_address = phys,
            .length = len,
        };
    }

    /// Identity-map the range as device memory (same pattern as virtio BAR maps).
    pub fn map(self: *IOMemoryDescriptor) types.IOReturn {
        if (self.length == 0 or self.physical_address == 0) return types.kIOReturnBadArgument;
        if (!self.mapped) {
            mmu.mapExtra(self.physical_address, self.length, .{
                .writable = true,
                .executable = false,
                .user = false,
                .device = true,
            });
            self.mapped = true;
            self.map_info = .{
                .virtual_address = self.physical_address,
                .length = self.length,
                .physical_address = self.physical_address,
            };
        }
        return types.kIOReturnSuccess;
    }

    pub fn getVirtualAddress(self: *const IOMemoryDescriptor) u64 {
        return self.map_info.virtual_address;
    }

    pub fn getLength(self: *const IOMemoryDescriptor) u64 {
        return self.length;
    }

    pub fn getPhysicalAddress(self: *const IOMemoryDescriptor) u64 {
        return self.physical_address;
    }
};
