//! Internal shared helpers for libSystem modules.
//! Not exported directly — modules import this and re-export what they need.

pub const usize_max = ~@as(usize, 0);

// ── errno ──────────────────────────────────────────────────────────────
pub export var errno: c_int = 0;

// ── syscall numbers ────────────────────────────────────────────────────
pub const SYS_exit: usize = 1;
pub const SYS_read: usize = 3;
pub const SYS_write: usize = 4;
pub const SYS_open: usize = 5;
pub const SYS_close: usize = 6;
pub const SYS_getpid: usize = 20;
pub const SYS_stat: usize = 38;
pub const SYS_kill: usize = 37;
pub const SYS_sigaction: usize = 46;
pub const SYS_sigprocmask: usize = 48;
pub const SYS_fstat: usize = 62;
pub const SYS_sigreturn: usize = 184;
pub const SYS_lseek: usize = 199;
pub const SYS_socket: usize = 97;
pub const SYS_socketpair: usize = 135;
pub const SYS_getsockname: usize = 150;
pub const SYS_stat64: usize = 338;
pub const SYS_fstat64: usize = 339;
pub const SYS_lstat64: usize = 340;
pub const SYS___semwait_signal: usize = 334;
pub const SYS_pthread_kill: usize = 328;
pub const SYS_bsdthread_create: usize = 360;
pub const SYS_bsdthread_terminate: usize = 361;
pub const SYS_bsdthread_register: usize = 366;
pub const SYS_thread_selfid: usize = 372;
pub const SYS_ulock_wake: usize = 516;
pub const SYS_ulock_wait2: usize = 544;

// ── Mach trap numbers ──────────────────────────────────────────────────
pub const MACH_task_self_trap: usize = 28;
pub const MACH_mach_vm_map_trap: usize = 15;
pub const KERN_SUCCESS: usize = 0;

// ── vm / mmap constants ────────────────────────────────────────────────
pub const MAP_PRIVATE_ANON: c_int = 0x1002;
pub const VM_PROT_READ_WRITE: c_int = 3;
pub const ENOMEM: c_int = 12;
pub const EINVAL: c_int = 22;
pub const ENOTSUP: c_int = 45;
pub const ENOSYS: c_int = 78;

// ── BSD syscall wrappers ───────────────────────────────────────────────

pub fn darwinSyscall3(number: usize, arg0: usize, arg1: usize, arg2: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x80
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

pub fn darwinSyscall5(number: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x80
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

pub fn darwinSyscall6(number: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x80
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
          [arg5] "{x5}" (arg5),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

// ── Mach trap wrappers ─────────────────────────────────────────────────

pub fn machTrap0(number: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x81
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

pub fn machTrap5(number: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x81
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

pub fn machTrap6(number: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x81
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
          [arg5] "{x5}" (arg5),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

// ── errno helpers ──────────────────────────────────────────────────────

pub fn setErrnoFromNegative(ret: usize) c_int {
    if (ret > usize_max - 4096) {
        errno = @intCast(0 -% ret);
        return -1;
    }
    return @intCast(ret);
}

pub fn stubErr(comptime name: []const u8) c_int {
    reportStub(name);
    errno = ENOSYS;
    return -1;
}

pub fn stubUsize(comptime name: []const u8) usize {
    _ = stubErr(name);
    return usize_max;
}

pub fn stubNull(comptime name: []const u8) ?*anyopaque {
    _ = stubErr(name);
    return null;
}

pub fn reportStub(comptime name: []const u8) void {
    const prefix = "libSystem stub: ";
    const suffix = "\n";
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(prefix.ptr), prefix.len);
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(name.ptr), name.len);
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(suffix.ptr), suffix.len);
}

// ── string helpers (internal, for sysctl etc.) ────────────────────────

pub fn cstrLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

pub fn cstrEq(s: [*:0]const u8, comptime want: []const u8) bool {
    var i: usize = 0;
    while (i < want.len) : (i += 1) {
        if (s[i] != want[i]) return false;
    }
    return s[want.len] == 0;
}

pub fn sysctlCopyOut(oldp: ?*anyopaque, oldlenp: ?*usize, src: [*]const u8, len: usize) c_int {
    if (oldlenp) |lenp| {
        if (oldp) |dst| {
            const n = @min(lenp.*, len);
            @memcpy(@as([*]u8, @ptrCast(dst))[0..n], src[0..n]);
        }
        lenp.* = len;
    }
    return 0;
}

pub fn sysctlCopyValue(comptime T: type, oldp: ?*anyopaque, oldlenp: ?*usize, value: T) c_int {
    var tmp = value;
    const bytes: [*]const u8 = @ptrCast(&tmp);
    return sysctlCopyOut(oldp, oldlenp, bytes, @sizeOf(T));
}

// ── debug hex output ──────────────────────────────────────────────────

pub fn writeHexValue(value_in: usize) void {
    var hex: [18]u8 = undefined;
    hex[0] = '0';
    hex[1] = 'x';
    var value = value_in;
    var i: usize = 18;
    while (i > 2) {
        i -= 1;
        const digit: u8 = @truncate(value & 0xf);
        hex[i] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
        value >>= 4;
    }
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(&hex), hex.len);
}
