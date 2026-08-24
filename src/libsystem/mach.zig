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

pub export fn mprotect(addr: ?*anyopaque, len: usize, prot: c_int) c_int {
    const ptr = addr orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    const ret = C.darwinSyscall3(C.SYS_mprotect, @intFromPtr(ptr), len, @intCast(prot));
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn munmap(addr: ?*anyopaque, len: usize) c_int {
    const ptr = addr orelse return 0;
    const ret = C.darwinSyscall3(C.SYS_munmap, @intFromPtr(ptr), len, 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn task_info(
    target_task: c_uint,
    flavor: c_int,
    task_info_out: ?*anyopaque,
    task_info_outCnt: ?*c_uint,
) c_int {
    _ = target_task;
    _ = flavor;
    if (task_info_out) |out| {
        const bytes = @as([*]u8, @ptrCast(out));
        if (task_info_outCnt) |cnt| {
            const byte_len = @as(usize, cnt.*) * 4;
            @memset(bytes[0..byte_len], 0);
            if (byte_len >= 16) {
                // task_vm_info has page_size: integer_t (i32) at offset 12
                // Query system page size via sysctl hw.pagesize
                var page_size: u32 = 0;
                var len: usize = @sizeOf(u32);
                if (@import("sysctl.zig").sysctlbyname("hw.pagesize", &page_size, &len, null, 0) == 0 and page_size > 0) {
                    const ps_ptr: *i32 = @ptrCast(@alignCast(&bytes[12]));
                    ps_ptr.* = @intCast(page_size);
                }
            }
        }
    }
    return 0; // KERN_SUCCESS
}

pub export var mach_task_self_: c_uint = 0; // Initialized lazily

pub export fn mach_error_string(_: c_int) ?[*:0]const u8 {
    return "mach error";
}
