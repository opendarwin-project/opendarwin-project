//! Mach and VM primitives: mach_task_self, mach_vm_map, mmap, munmap.

const common = @import("common.zig");
const C = common;

pub export fn mach_task_self() c_uint {
    return @truncate(C.machTrap0(C.MACH_task_self_trap));
}

pub export fn mach_vm_map(
    target: c_uint,
    address: *u64,
    size: u64,
    mask: u64,
    flags: c_int,
    object: c_uint,
    offset: u64,
    copy: bool,
    cur_protection: c_int,
    max_protection: c_int,
    inheritance: c_int,
) c_int {
    _ = object;
    _ = offset;
    _ = copy;
    _ = max_protection;
    _ = inheritance;
    return @intCast(C.machTrap6(
        C.MACH_mach_vm_map_trap,
        target,
        @intFromPtr(address),
        size,
        mask,
        @as(usize, @intCast(flags)),
        @as(usize, @intCast(cur_protection)),
    ));
}

pub export fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque {
    _ = fd;
    _ = offset;
    _ = flags;
    var mapped_addr: u64 = if (addr) |p| @intFromPtr(p) else 0;
    const vm_flags: c_int = if (mapped_addr == 0) 1 else 0; // VM_FLAGS_ANYWHERE
    const kr = mach_vm_map(mach_task_self(), &mapped_addr, len, 0, vm_flags, 0, 0, false, prot, prot, 0);
    if (kr != C.KERN_SUCCESS) {
        common.errno = 12; // ENOMEM
        return @ptrFromInt(C.usize_max); // MAP_FAILED
    }
    return @ptrFromInt(mapped_addr);
}

pub export fn munmap(_: ?*anyopaque, _: usize) c_int {
    return 0;
}

pub export var mach_task_self_: c_uint = 0; // Initialized lazily

pub export fn mach_error_string(_: c_int) ?[*:0]const u8 {
    return "mach error";
}
