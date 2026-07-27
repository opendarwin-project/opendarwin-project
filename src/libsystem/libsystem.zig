//! Minimal FOSS libSystem/libsystem_c replacement for OpenDarwin userland.
//!
//! This is intentionally tiny: enough symbols for the first simple Darwin
//! Mach-O smoke binaries while the kernel grows real dylib loading support.
//! It must not depend on Apple's libSystem.

const usize_max = ~@as(usize, 0);

pub export var errno: c_int = 0;
pub export var __dyld_private: usize = 0;
// Nonzero process-wide guard for compiler-generated stack protectors.
pub export var __stack_chk_guard: usize = 0x595a_5b5c_5d5e_5f60;

/// Compiler-rt signed 128-bit division used by Zig's optimized Darwin code.
/// Use a bit-at-a-time unsigned divide so this implementation does not itself
/// lower to the builtin it supplies.
pub export fn __divti3(a: i128, b: i128) callconv(.c) i128 {
    if (b == 0) return 0;
    const negative = (a < 0) != (b < 0);
    const au: u128 = @bitCast(a);
    const bu: u128 = @bitCast(b);
    const dividend: u128 = if (a < 0) 0 -% au else au;
    const divisor: u128 = if (b < 0) 0 -% bu else bu;
    var quotient: u128 = 0;
    var remainder: u128 = 0;
    var bit: u8 = 128;
    while (bit != 0) {
        bit -= 1;
        const shift: u7 = @intCast(bit);
        remainder = (remainder << 1) | ((dividend >> shift) & 1);
        if (remainder >= divisor) {
            remainder -%= divisor;
            quotient |= @as(u128, 1) << shift;
            continue;
        }
    }
    return @bitCast(if (negative) 0 -% quotient else quotient);
}

const TlvDescriptor = extern struct {
    thunk: usize,
    key: usize,
    offset: usize,
};

var tlv_storage: [512 * 1024]u8 align(16) = [_]u8{0} ** (512 * 1024);
const MACH_task_self_trap: usize = 28;
const MACH_mach_vm_map_trap: usize = 15;
const KERN_SUCCESS: usize = 0;

const SYS_exit: usize = 1;
const SYS_read: usize = 3;
const SYS_write: usize = 4;
const SYS_close: usize = 6;
const SYS_getpid: usize = 20;
const SYS_kill: usize = 37;
const SYS_socket: usize = 97;
const SYS_socketpair: usize = 135;
const SYS_getsockname: usize = 150;
const SYS___semwait_signal: usize = 334;
const SYS_pthread_kill: usize = 328;
const SYS_bsdthread_create: usize = 360;
const SYS_bsdthread_terminate: usize = 361;
const SYS_bsdthread_register: usize = 366;
const SYS_thread_selfid: usize = 372;
const SYS_ulock_wake: usize = 516;
const SYS_ulock_wait2: usize = 544;
const SYS_sigaction: usize = 46;
const SYS_sigprocmask: usize = 48;
const SYS_sigreturn: usize = 184;

// Pull Darwin IOKitLib exports into libSystem.
comptime {
    _ = @import("iokit.zig");
}

fn darwinSyscall3(number: usize, arg0: usize, arg1: usize, arg2: usize) usize {
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

fn darwinSyscall5(number: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
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

fn darwinSyscall6(number: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
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

fn machTrap0(number: usize) usize {
    return asm volatile (
        \\mov x16, %[number]
        \\svc #0x81
        : [ret] "={x0}" (-> usize),
        : [number] "r" (number),
        : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}

fn machTrap5(number: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
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

fn machTrap6(number: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
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

fn setErrnoFromNegative(ret: usize) c_int {
    // OpenDarwin's early syscall layer currently returns simple integer
    // results. Treat small negative values as errno-style failures so callers
    // see the libc convention once the kernel starts returning them.
    if (ret > usize_max - 4096) {
        errno = @intCast(0 -% ret);
        return -1;
    }
    return @intCast(ret);
}

pub export fn syscall(number: c_long, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) c_long {
    _ = arg3;
    _ = arg4;
    _ = arg5;
    return @intCast(darwinSyscall3(@intCast(number), arg0, arg1, arg2));
}

/// Initial Mach-O entry has no caller in the milestone loader. The kernel
/// seeds LR with this function so a hosted `main` returning normally follows
/// Darwin's process-exit semantics instead of jumping to address zero.
pub export fn opendarwin_user_return(status: u64) noreturn {
    _exit(@intCast(status & 0xff));
}

pub export fn write(fd: c_int, buf: [*]const u8, len: usize) isize {
    const ret = darwinSyscall3(SYS_write, @intCast(fd), @intFromPtr(buf), len);
    return @intCast(setErrnoFromNegative(ret));
}

pub export fn memcpy(dst: ?*anyopaque, src: ?*const anyopaque, len: usize) ?*anyopaque {
    const d = dst orelse return null;
    const s = src orelse return d;
    const out: [*]volatile u8 = @ptrCast(d);
    const input: [*]const volatile u8 = @ptrCast(s);
    for (0..len) |i| out[i] = input[i];
    return d;
}

pub export fn memmove(dst: ?*anyopaque, src: ?*const anyopaque, len: usize) ?*anyopaque {
    const d = dst orelse return null;
    const s = src orelse return d;
    const out: [*]volatile u8 = @ptrCast(d);
    const input: [*]const volatile u8 = @ptrCast(s);
    if (@intFromPtr(out) <= @intFromPtr(input)) {
        for (0..len) |i| out[i] = input[i];
    } else {
        var i = len;
        while (i != 0) {
            i -= 1;
            out[i] = input[i];
        }
    }
    return d;
}

pub export fn memset(dst: ?*anyopaque, value: c_int, len: usize) ?*anyopaque {
    const d = dst orelse return null;
    const out: [*]volatile u8 = @ptrCast(d);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    var i: usize = 0;
    while (i < len) : (i += 1) out[i] = byte;
    return d;
}

pub export fn strlen(s: [*:0]const u8) usize {
    return cstrLen(s);
}

pub export fn __error() *c_int {
    return &errno;
}

pub export fn _exit(status: c_int) noreturn {
    _ = darwinSyscall3(SYS_exit, @intCast(status), 0, 0);
    while (true) asm volatile ("wfe");
}

pub export fn exit(status: c_int) noreturn {
    _exit(status);
}

pub export fn dyld_stub_binder() void {
    // Placeholder for binaries that still carry a lazy-bind helper reference.
    // The kernel loader should eagerly bind for the first milestone, so reaching
    // this function means a lazy symbol escaped resolution.
    _exit(127);
}

fn cstrLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

fn cstrEq(s: [*:0]const u8, comptime want: []const u8) bool {
    var i: usize = 0;
    while (i < want.len) : (i += 1) {
        if (s[i] != want[i]) return false;
    }
    return s[want.len] == 0;
}

fn sysctlCopyOut(oldp: ?*anyopaque, oldlenp: ?*usize, src: [*]const u8, len: usize) c_int {
    if (oldlenp) |lenp| {
        if (oldp) |dst| {
            const n = @min(lenp.*, len);
            @memcpy(@as([*]u8, @ptrCast(dst))[0..n], src[0..n]);
        }
        lenp.* = len;
    }
    return 0;
}

fn sysctlCopyValue(comptime T: type, oldp: ?*anyopaque, oldlenp: ?*usize, value: T) c_int {
    var tmp = value;
    const bytes: [*]const u8 = @ptrCast(&tmp);
    return sysctlCopyOut(oldp, oldlenp, bytes, @sizeOf(T));
}

fn reportStub(comptime name: []const u8) void {
    const prefix = "libSystem stub: ";
    const suffix = "\n";
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(prefix.ptr), prefix.len);
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(name.ptr), name.len);
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(suffix.ptr), suffix.len);
}

fn stubErr(comptime name: []const u8) c_int {
    reportStub(name);
    errno = 78; // ENOSYS on Darwin
    return -1;
}

fn stubUsize(comptime name: []const u8) usize {
    _ = stubErr(name);
    return usize_max;
}

fn stubNull(comptime name: []const u8) ?*anyopaque {
    _ = stubErr(name);
    return null;
}

var dyld_log_count: usize = 0;

fn writeHexValue(value_in: usize) void {
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

fn logDyldLookup(addr: usize, base: usize) void {
    const n = @atomicRmw(usize, &dyld_log_count, .Add, 1, .monotonic);
    if (n >= 12) return;
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr("dyld lookup ".ptr), 12);
    writeHexValue(addr);
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr(" -> ".ptr), 4);
    writeHexValue(base);
    _ = darwinSyscall3(SYS_write, 2, @intFromPtr("\n".ptr), 1);
}

const MH_MAGIC_64: u32 = 0xfeedfacf;
const MAIN_IMAGE_BASE: usize = 0x1_0000_0000;
const MAIN_IMAGE_LIMIT: usize = 0x2_0000_0000;
const LC_SEGMENT_64: u32 = 0x19;

fn preferredMachHeaderAddress(candidate: usize) ?usize {
    const filetype = @as(*const u32, @ptrFromInt(candidate + 12)).*;
    if (filetype != 2 and filetype != 6) return null; // MH_EXECUTE or MH_DYLIB
    const ncmds = @as(*const u32, @ptrFromInt(candidate + 16)).*;
    if (ncmds == 0 or ncmds > 128) return null;
    var off: usize = candidate + 32;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        const cmd = @as(*const u32, @ptrFromInt(off)).*;
        const cmdsize = @as(*const u32, @ptrFromInt(off + 4)).*;
        if (cmdsize < 8 or cmdsize > 4096) return null;
        if (cmd == LC_SEGMENT_64 and cmdsize >= 72) {
            const vmaddr = @as(*const u64, @ptrFromInt(off + 24)).*;
            if (vmaddr >= MAIN_IMAGE_BASE) return @intCast(vmaddr);
            return candidate;
        }
        off += cmdsize;
    }
    return null;
}

fn findMachHeader(addr: ?*const anyopaque) ?*anyopaque {
    _ = addr;
    // The current loader does not yet publish enough image metadata for Zig's
    // debug allocator/unwinder to safely inspect loaded Mach-O images. A null
    // result is the documented "not in an image" answer and avoids parsing
    // low physical aliases as if they were preferred VM addresses.
    return null;
}

pub export fn abort() noreturn {
    reportStub("abort");
    _exit(134);
}

pub export fn __stack_chk_fail() noreturn {
    _exit(127);
}
const MallocHeader = extern struct {
    magic: usize,
    requested: usize,
    total: usize,
};
const MALLOC_MAGIC: usize = 0x4f44574d414c4c4f; // ODW MALLO
const MALLOC_ALIGN: usize = 16;

fn mallocHeader(ptr: ?*anyopaque) ?*MallocHeader {
    const p = ptr orelse return null;
    const addr = @intFromPtr(p);
    if (addr < @sizeOf(MallocHeader)) return null;
    const header: *MallocHeader = @ptrFromInt(addr - @sizeOf(MallocHeader));
    if (header.magic != MALLOC_MAGIC) return null;
    return header;
}

pub export fn malloc(size: usize) ?*anyopaque {
    const requested = if (size == 0) 1 else size;
    const payload_off = (@sizeOf(MallocHeader) + (MALLOC_ALIGN - 1)) & ~(MALLOC_ALIGN - 1);
    const total = (payload_off + requested + 4095) & ~@as(usize, 4095);
    const base = mmap(null, total, VM_PROT_READ_WRITE, MAP_PRIVATE_ANON, -1, 0);
    if (base == null or @intFromPtr(base.?) == usize_max) return null;
    const header: *MallocHeader = @ptrCast(@alignCast(base.?));
    header.* = .{ .magic = MALLOC_MAGIC, .requested = requested, .total = total };
    return @ptrFromInt(@intFromPtr(base.?) + payload_off);
}
pub export fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (ptr == null) return malloc(size);
    if (size == 0) {
        free(ptr);
        return null;
    }
    const old_size = malloc_size(ptr);
    const next = malloc(size) orelse return null;
    const n = if (old_size < size) old_size else size;
    _ = memcpy(next, ptr, n);
    free(ptr);
    return next;
}
pub export fn free(ptr: ?*anyopaque) void {
    const header = mallocHeader(ptr) orelse return;
    _ = munmap(header, header.total);
}
pub export fn malloc_size(ptr: ?*anyopaque) usize {
    const header = mallocHeader(ptr) orelse return 0;
    return header.requested;
}
pub export fn posix_memalign(_: *?*anyopaque, _: usize, _: usize) c_int {
    return stubErr("posix_memalign");
}
pub export fn bzero(ptr: [*]u8, len: usize) void {
    const out: [*]volatile u8 = @ptrCast(ptr);
    var i: usize = 0;
    while (i < len) : (i += 1) out[i] = 0;
}
pub export fn arc4random_buf(ptr: [*]u8, len: usize) void {
    // Deterministic milestone entropy until the kernel exposes a CSPRNG.
    const out: [*]volatile u8 = @ptrCast(ptr);
    var i: usize = 0;
    while (i < len) : (i += 1) out[i] = 0;
}
pub export fn _NSGetExecutablePath(_: [*]u8, _: *u32) c_int {
    return stubErr("_NSGetExecutablePath");
}
pub export fn __availability_version_check(_: u32, _: ?*const anyopaque) c_int {
    reportStub("__availability_version_check");
    return 1;
}
pub export fn __dyld_get_image_header_containing_address(addr: ?*const anyopaque) ?*anyopaque {
    return findMachHeader(addr);
}
pub export fn _dyld_get_image_header_containing_address(addr: ?*const anyopaque) ?*anyopaque {
    return findMachHeader(addr);
}
pub export fn _dyld_image_path_containing_address(addr: ?*const anyopaque) ?[*:0]const u8 {
    const p = @intFromPtr(addr orelse return null);
    if (p >= MAIN_IMAGE_BASE and p < MAIN_IMAGE_LIMIT) return "/MAIN\x00";
    return "/usr/lib/libSystem.B.dylib\x00";
}

// Mach-O mangles `export fn foo` to the asm symbol `_foo`, so the decls above
// (whose Zig names already start with an underscore to look C-like) actually
// emit one underscore too many: `pub export fn _dyld_image_path_containing_address`
// becomes `__dyld_image_path_containing_address`, which is *not* what a C
// caller references.  Alias the real C-level names here; `nm -u` on any client
// (tools/symbol_gap.py) otherwise reports them as missing.
comptime {
    @export(&__availability_version_check, .{ .name = "_availability_version_check", .linkage = .strong });
    @export(&_dyld_get_image_header_containing_address, .{ .name = "dyld_get_image_header_containing_address", .linkage = .strong });
    @export(&_dyld_image_path_containing_address, .{ .name = "dyld_image_path_containing_address", .linkage = .strong });
    @export(&__tlv_bootstrap, .{ .name = "_tlv_bootstrap", .linkage = .strong });
}
const MAX_TLV_RECORDS = 16;
const MAX_TLV_THREADS = 64;
const TLV_BLOCK_SIZE = 1024 * 1024;

const TlvRecord = struct {
    template_base: usize = 0,
    storage: [MAX_TLV_THREADS]?[*]u8 = [_]?[*]u8{null} ** MAX_TLV_THREADS,
};

var tlv_records: [MAX_TLV_RECORDS]TlvRecord = [_]TlvRecord{.{}} ** MAX_TLV_RECORDS;
var tlv_record_count: usize = 0;

fn currentTlvThreadIndex() usize {
    const tid = darwinSyscall3(SYS_thread_selfid, 0, 0, 0);
    if (tid == 0) return 0;
    return @min(tid - 1, MAX_TLV_THREADS - 1);
}

fn findOrCreateTlvRecord(template_base: usize) *TlvRecord {
    var i: usize = 0;
    while (i < tlv_record_count) : (i += 1) {
        if (tlv_records[i].template_base == template_base) return &tlv_records[i];
    }
    if (tlv_record_count >= MAX_TLV_RECORDS) return &tlv_records[MAX_TLV_RECORDS - 1];
    const rec = &tlv_records[tlv_record_count];
    rec.* = .{ .template_base = template_base };
    tlv_record_count += 1;
    return rec;
}

fn tlvStorageFor(record: *TlvRecord) ?[*]u8 {
    const idx = currentTlvThreadIndex();
    if (record.storage[idx]) |storage| return storage;
    const mapped = mmap(null, TLV_BLOCK_SIZE, VM_PROT_READ_WRITE, MAP_PRIVATE_ANON, -1, 0);
    if (mapped == null or @intFromPtr(mapped.?) == usize_max) {
        reportStub("tlv mmap failed");
        return null;
    }
    const storage: [*]u8 = @ptrCast(mapped.?);
    record.storage[idx] = storage;
    return storage;
}

fn isTlvRecordKey(key: usize) bool {
    const start = @intFromPtr(&tlv_records);
    const end = start + @sizeOf(@TypeOf(tlv_records));
    return key >= start and key < end and ((key - start) % @sizeOf(TlvRecord)) == 0;
}

/// Darwin's TLV thunk ABI is *not* the normal AAPCS one: the compiler emits a
/// bare `blr` through the descriptor's thunk slot inline, in the middle of a
/// function, and assumes the callee clobbers **nothing except x0** (which
/// carries the descriptor in and the resolved address out). A plain Zig
/// function violates that immediately by using caller-saved GPRs/NEON as
/// scratch, silently corrupting the caller's live values - that is what was
/// destroying the `*Threaded` argument in Zig's worker threads, and under
/// `-Doptimize=ReleaseFast` the denser register allocation also kept live
/// values in x19-x28 / q8-q31 across TLV sites (including `std.debug.print`
/// → threadlocal panic state), which the previous x1-x18/q0-q7-only spill
/// missed and left `Io.Threaded.allocator.vtable` pointing at garbage.
///
/// So the exported symbol is a naked trampoline that spills every register
/// the Darwin TLV contract requires before delegating to the Zig impl.
pub export fn __tlv_bootstrap() callconv(.naked) void {
    asm volatile (
        \\stp x29, x30, [sp, #-16]!
        \\mov x29, sp
        \\stp x1, x2, [sp, #-16]!
        \\stp x3, x4, [sp, #-16]!
        \\stp x5, x6, [sp, #-16]!
        \\stp x7, x8, [sp, #-16]!
        \\stp x9, x10, [sp, #-16]!
        \\stp x11, x12, [sp, #-16]!
        \\stp x13, x14, [sp, #-16]!
        \\stp x15, x16, [sp, #-16]!
        \\stp x17, x18, [sp, #-16]!
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp q0, q1, [sp, #-32]!
        \\stp q2, q3, [sp, #-32]!
        \\stp q4, q5, [sp, #-32]!
        \\stp q6, q7, [sp, #-32]!
        \\stp q8, q9, [sp, #-32]!
        \\stp q10, q11, [sp, #-32]!
        \\stp q12, q13, [sp, #-32]!
        \\stp q14, q15, [sp, #-32]!
        \\stp q16, q17, [sp, #-32]!
        \\stp q18, q19, [sp, #-32]!
        \\stp q20, q21, [sp, #-32]!
        \\stp q22, q23, [sp, #-32]!
        \\stp q24, q25, [sp, #-32]!
        \\stp q26, q27, [sp, #-32]!
        \\stp q28, q29, [sp, #-32]!
        \\stp q30, q31, [sp, #-32]!
        \\bl %[impl]
        \\ldp q30, q31, [sp], #32
        \\ldp q28, q29, [sp], #32
        \\ldp q26, q27, [sp], #32
        \\ldp q24, q25, [sp], #32
        \\ldp q22, q23, [sp], #32
        \\ldp q20, q21, [sp], #32
        \\ldp q18, q19, [sp], #32
        \\ldp q16, q17, [sp], #32
        \\ldp q14, q15, [sp], #32
        \\ldp q12, q13, [sp], #32
        \\ldp q10, q11, [sp], #32
        \\ldp q8, q9, [sp], #32
        \\ldp q6, q7, [sp], #32
        \\ldp q4, q5, [sp], #32
        \\ldp q2, q3, [sp], #32
        \\ldp q0, q1, [sp], #32
        \\ldp x27, x28, [sp], #16
        \\ldp x25, x26, [sp], #16
        \\ldp x23, x24, [sp], #16
        \\ldp x21, x22, [sp], #16
        \\ldp x19, x20, [sp], #16
        \\ldp x17, x18, [sp], #16
        \\ldp x15, x16, [sp], #16
        \\ldp x13, x14, [sp], #16
        \\ldp x11, x12, [sp], #16
        \\ldp x9, x10, [sp], #16
        \\ldp x7, x8, [sp], #16
        \\ldp x5, x6, [sp], #16
        \\ldp x3, x4, [sp], #16
        \\ldp x1, x2, [sp], #16
        \\ldp x29, x30, [sp], #16
        \\ret
        :
        : [impl] "X" (&tlvBootstrapImpl),
    );
}

fn tlvBootstrapImpl(desc: *TlvDescriptor) callconv(.c) ?*anyopaque {
    // Darwin TLV descriptors live in __DATA,__thread_vars and point into the
    // following __thread_{data,bss} template by offset. Keep one TLV block per
    // kernel thread so Zig's Thread.current, panic_stage, and signal-stack TLVs
    // are not shared between pthreads.
    if (desc.key == 0 or !isTlvRecordKey(desc.key)) {
        const this_addr = @intFromPtr(desc);
        const thunk = desc.thunk;
        var start = this_addr;
        while (start >= 24) {
            const prev: *const TlvDescriptor = @ptrFromInt(start - 24);
            if (prev.thunk != thunk or prev.offset >= @as(*const TlvDescriptor, @ptrFromInt(start)).offset) break;
            start -= 24;
        }
        var end = start;
        var last_offset: usize = 0;
        while (true) {
            const cur: *const TlvDescriptor = @ptrFromInt(end);
            if (cur.thunk != thunk or cur.offset < last_offset) break;
            last_offset = cur.offset;
            end += 24;
            if (end - start > 4096) break;
        }
        desc.key = @intFromPtr(findOrCreateTlvRecord(end));
    }
    const record: *TlvRecord = @ptrFromInt(desc.key);
    const storage = tlvStorageFor(record) orelse return null;
    return @ptrFromInt(@intFromPtr(storage) + desc.offset);
}
pub export fn sys_icache_invalidate(_: ?*anyopaque, _: usize) void {
    reportStub("sys_icache_invalidate");
}

pub export fn open(_: [*:0]const u8, _: c_int, _: c_int) c_int {
    return stubErr("open");
}
pub export fn openat(_: c_int, _: [*:0]const u8, _: c_int, _: c_int) c_int {
    return stubErr("openat");
}
pub export fn close(fd: c_int) c_int {
    const ret = darwinSyscall3(SYS_close, @intCast(fd), 0, 0);
    return @intCast(setErrnoFromNegative(ret));
}
pub export fn @"close$NOCANCEL"(fd: c_int) c_int {
    return close(fd);
}
pub export fn read(fd: c_int, buf: [*]u8, len: usize) isize {
    const ret = darwinSyscall3(SYS_read, @intCast(fd), @intFromPtr(buf), len);
    return @intCast(setErrnoFromNegative(ret));
}
const Iovec = extern struct {
    base: [*]const u8,
    len: usize,
};

pub export fn readv(_: c_int, _: ?*const anyopaque, _: c_int) isize {
    return @intCast(stubErr("readv"));
}
pub export fn writev(fd: c_int, iov: ?[*]const Iovec, iovcnt: c_int) isize {
    const vecs = iov orelse {
        errno = EINVAL;
        return -1;
    };
    if (iovcnt < 0) {
        errno = EINVAL;
        return -1;
    }
    var total: isize = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(iovcnt))) : (i += 1) {
        const len = vecs[i].len;
        if (len == 0) continue;
        const n = write(fd, vecs[i].base, len);
        if (n < 0) return if (total != 0) total else -1;
        total += n;
        if (@as(usize, @intCast(n)) != len) break;
    }
    return total;
}
pub export fn pread(_: c_int, _: [*]u8, _: usize, _: i64) isize {
    return @intCast(stubErr("pread"));
}
pub export fn preadv(_: c_int, _: ?*const anyopaque, _: c_int, _: i64) isize {
    return @intCast(stubErr("preadv"));
}
pub export fn pwrite(_: c_int, _: [*]const u8, _: usize, _: i64) isize {
    return @intCast(stubErr("pwrite"));
}
pub export fn pwritev(_: c_int, _: ?*const anyopaque, _: c_int, _: i64) isize {
    return @intCast(stubErr("pwritev"));
}
pub export fn lseek(_: c_int, _: i64, _: c_int) i64 {
    return @intCast(stubErr("lseek"));
}
pub export fn fcntl(_: c_int, cmd: c_int, _: usize) c_int {
    reportStub("fcntl");
    return switch (cmd) {
        1 => 0, // F_GETFD
        2 => 0, // F_SETFD
        3 => 0, // F_GETFL
        4 => 0, // F_SETFL
        else => blk: {
            errno = EINVAL;
            break :blk -1;
        },
    };
}
pub export fn ioctl(_: c_int, _: usize, _: usize) c_int {
    return stubErr("ioctl");
}
pub export fn fstat(_: c_int, _: ?*anyopaque) c_int {
    return stubErr("fstat");
}
pub export fn fstatat(_: c_int, _: [*:0]const u8, _: ?*anyopaque, _: c_int) c_int {
    return stubErr("fstatat");
}
pub export fn fsync(_: c_int) c_int {
    return stubErr("fsync");
}
pub export fn ftruncate(_: c_int, _: i64) c_int {
    return stubErr("ftruncate");
}
pub export fn isatty(fd: c_int) c_int {
    if (fd >= 0 and fd <= 2) return 1;
    errno = 25; // ENOTTY
    return 0;
}
pub export fn getcwd(_: [*]u8, _: usize) ?[*]u8 {
    _ = stubErr("getcwd");
    return null;
}
pub export fn chdir(_: [*:0]const u8) c_int {
    return stubErr("chdir");
}
pub export fn fchdir(_: c_int) c_int {
    return stubErr("fchdir");
}
pub export fn mkdirat(_: c_int, _: [*:0]const u8, _: c_int) c_int {
    return stubErr("mkdirat");
}
pub export fn unlinkat(_: c_int, _: [*:0]const u8, _: c_int) c_int {
    return stubErr("unlinkat");
}
pub export fn renameat(_: c_int, _: [*:0]const u8, _: c_int, _: [*:0]const u8) c_int {
    return stubErr("renameat");
}
pub export fn linkat(_: c_int, _: [*:0]const u8, _: c_int, _: [*:0]const u8, _: c_int) c_int {
    return stubErr("linkat");
}
pub export fn symlinkat(_: [*:0]const u8, _: c_int, _: [*:0]const u8) c_int {
    return stubErr("symlinkat");
}
pub export fn readlinkat(_: c_int, _: [*:0]const u8, _: [*]u8, _: usize) isize {
    return @intCast(stubErr("readlinkat"));
}
pub export fn faccessat(_: c_int, _: [*:0]const u8, _: c_int, _: c_int) c_int {
    return stubErr("faccessat");
}
pub export fn @"realpath$DARWIN_EXTSN"(_: [*:0]const u8, _: [*]u8) ?[*]u8 {
    _ = stubErr("realpath$DARWIN_EXTSN");
    return null;
}
pub export fn __getdirentries64(_: c_int, _: [*]u8, _: usize, _: *i64) isize {
    return @intCast(stubErr("__getdirentries64"));
}

pub export fn mach_task_self() c_uint {
    return @truncate(machTrap0(MACH_task_self_trap));
}

pub export fn mach_vm_map(target: c_uint, address: *u64, size: u64, mask: u64, flags: c_int, object: c_uint, offset: u64, copy: bool, cur_protection: c_int, max_protection: c_int, inheritance: c_int) c_int {
    _ = object;
    _ = offset;
    _ = copy;
    _ = max_protection;
    _ = inheritance;
    return @intCast(machTrap6(MACH_mach_vm_map_trap, target, @intFromPtr(address), size, mask, @as(usize, @intCast(flags)), @as(usize, @intCast(cur_protection))));
}

pub export fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque {
    _ = fd;
    _ = offset;
    _ = flags;
    var mapped_addr: u64 = if (addr) |p| @intFromPtr(p) else 0;
    const vm_flags: c_int = if (mapped_addr == 0) 1 else 0; // VM_FLAGS_ANYWHERE
    const kr = mach_vm_map(mach_task_self(), &mapped_addr, len, 0, vm_flags, 0, 0, false, prot, prot, 0);
    if (kr != KERN_SUCCESS) {
        errno = 12; // ENOMEM
        return @ptrFromInt(usize_max); // MAP_FAILED
    }
    return @ptrFromInt(mapped_addr);
}
pub export fn munmap(_: ?*anyopaque, _: usize) c_int {
    return 0;
}
const LibcTimespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

var clock_ms: usize = 0;

pub export fn clock_gettime(_: c_int, tp: ?*anyopaque) c_int {
    const out = tp orelse {
        errno = EINVAL;
        return -1;
    };
    // Until wall-clock syscalls are exposed, provide a monotonic coarse clock
    // that advances on observation. `nanosleep` itself is kernel-timer backed.
    clock_ms +%= 5;
    const ts = @as(*LibcTimespec, @ptrCast(@alignCast(out)));
    ts.tv_sec = @intCast(clock_ms / 1000);
    ts.tv_nsec = @intCast((clock_ms % 1000) * 1_000_000);
    return 0;
}
pub export fn clock_getres(_: c_int, tp: ?*anyopaque) c_int {
    if (tp) |out| {
        const ts = @as(*LibcTimespec, @ptrCast(@alignCast(out)));
        ts.tv_sec = 0;
        ts.tv_nsec = 5_000_000;
    }
    return 0;
}
/// Darwin has no dedicated nanosleep syscall; libc's nanosleep() is built
/// on top of __semwait_signal(cond_sem=0, mutex_sem=0, timeout=1,
/// relative=1, tv_sec, tv_nsec).
pub export fn nanosleep(req: ?*const anyopaque, rem: ?*anyopaque) c_int {
    _ = rem;
    const p = req orelse {
        errno = EINVAL;
        return -1;
    };
    const ts = @as(*const LibcTimespec, @ptrCast(@alignCast(p))).*;
    const ret = darwinSyscall6(
        SYS___semwait_signal,
        0,
        0,
        1,
        1,
        @bitCast(@as(i64, @intCast(ts.tv_sec))),
        @bitCast(@as(i64, @intCast(ts.tv_nsec))),
    );
    return @intCast(setErrnoFromNegative(ret));
}
pub export fn getpid() c_int {
    const ret = darwinSyscall3(SYS_getpid, 0, 0, 0);
    return @intCast(setErrnoFromNegative(ret));
}
pub export fn kill(pid: c_int, sig: c_int) c_int {
    const ret = darwinSyscall3(SYS_kill, @intCast(pid), @intCast(sig), 0);
    return @intCast(setErrnoFromNegative(ret));
}
pub export fn fork() c_int {
    return stubErr("fork");
}
pub export fn execve(_: [*:0]const u8, _: ?*const anyopaque, _: ?*const anyopaque) c_int {
    return stubErr("execve");
}
pub export fn wait4(_: c_int, _: *c_int, _: c_int, _: ?*anyopaque) c_int {
    return stubErr("wait4");
}
pub export fn setpgid(_: c_int, _: c_int) c_int {
    return stubErr("setpgid");
}
pub export fn setregid(_: c_int, _: c_int) c_int {
    return stubErr("setregid");
}
pub export fn setreuid(_: c_int, _: c_int) c_int {
    return stubErr("setreuid");
}
/// Darwin arm64's `sigset_t` used by Zig is a 32-bit mask, not Linux's
/// larger sigset. Keep this exact width: callers commonly place it next
/// to a stack canary.
pub export fn sigemptyset(set: ?*anyopaque) c_int {
    if (set) |p| @as(*u32, @ptrCast(@alignCast(p))).* = 0;
    return 0;
}

const SignalAltStack = extern struct {
    sp: ?*anyopaque,
    size: usize,
    flags: c_int,
};

var installed_alt_stack: SignalAltStack = .{ .sp = null, .size = 0, .flags = 0 };

/// User-facing sigaction struct (no trampoline) — what Zig's std.start passes.
/// Layout: handler(8) + mask(4) + flags(4) = 16 bytes on aarch64.
const UserSigaction = extern struct {
    handler: usize, // union { sa_handler, sa_sigaction }
    sa_mask: u32,
    sa_flags: i32,
};

/// Kernel-facing __sigaction struct (with trampoline) — what syscall 46 expects.
/// Layout: handler(8) + tramp(8) + mask(4) + flags(4) = 24 bytes on aarch64.
const KernelSigaction = extern struct {
    handler: usize,
    sa_tramp: usize,
    sa_mask: u32,
    sa_flags: i32,
};

const SIGKILL: c_int = 9;
const SIGSTOP: c_int = 17;
const NSIG: c_int = 32;
const SA_SIGINFO: i32 = 0x0040;
const SA_ONSTACK: i32 = 0x0001;
const SA_RESTART: i32 = 0x0002;
const SA_RESETHAND: i32 = 0x0004;
const SA_NOCLDSTOP: i32 = 0x0008;
const SA_NODEFER: i32 = 0x0010;
const SA_NOCLDWAIT: i32 = 0x0020;
const SIG_BLOCK: c_int = 1;
const SIG_UNBLOCK: c_int = 2;
const SIG_SETMASK: c_int = 3;
const UC_TRAD: c_int = 1;
const UC_FLAVOR: c_int = 30;

const SaHandler = *const fn (c_int) callconv(.c) void;
const SaSigaction = *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) void;

/// XNU arm64 signal trampoline. The kernel enters here with:
///   x0=handler, x1=infostyle, x2=sig, x3=siginfo*, x4=ucontext*, x5=token
/// After the user handler returns, we restore via sigreturn(2).
pub export fn __sigtramp(
    handler: usize,
    style: c_int,
    sig: c_int,
    sinfo: ?*anyopaque,
    uctx: ?*anyopaque,
    token: usize,
) callconv(.c) void {
    if (style == UC_FLAVOR) {
        const fn_ptr: SaSigaction = @ptrFromInt(handler);
        fn_ptr(sig, sinfo, uctx);
    } else {
        const fn_ptr: SaHandler = @ptrFromInt(handler);
        fn_ptr(sig);
    }
    _ = darwinSyscall3(SYS_sigreturn, @intFromPtr(uctx), @intCast(style), token);
    // sigreturn restores the interrupted context and does not return.
    while (true) {}
}

/// Forward sigaction to the kernel (syscall 46), matching XNU's ABI.
///
/// The kernel's `sigaction` syscall expects:
///   - signum: signal number
///   - nsa:    pointer to `__user64_sigaction` (24 bytes, includes sa_tramp)
///   - osa:    pointer to `user64_sigaction` (16 bytes, no sa_tramp)
///
/// This libc wrapper converts between the public `struct sigaction` (16 bytes,
/// no trampoline) and the kernel's `__sigaction` (24 bytes, with trampoline).
pub export fn sigaction(sig: c_int, act: ?*const anyopaque, oldact: ?*anyopaque) c_int {
    if (sig <= 0 or sig >= NSIG) {
        errno = EINVAL;
        return -1;
    }
    // SIGKILL and SIGSTOP cannot be caught — kernel rejects them too.
    if (sig == SIGKILL or sig == SIGSTOP) {
        errno = EINVAL;
        return -1;
    }

    // Build the kernel-facing struct (24 bytes) from the user-facing struct.
    var kern_act: KernelSigaction = undefined;
    if (act) |input| {
        const user_sa: *const UserSigaction = @ptrCast(@alignCast(input));
        kern_act = .{
            .handler = user_sa.handler,
            .sa_tramp = @intFromPtr(&__sigtramp),
            .sa_mask = user_sa.sa_mask,
            .sa_flags = user_sa.sa_flags,
        };
    }

    // Allocate space for the kernel's old-action copy-out (16 bytes, no tramp).
    var kernel_oldact: UserSigaction = undefined;

    const nsa_ptr: usize = if (act != null) @intFromPtr(&kern_act) else 0;
    const osa_ptr: usize = if (oldact != null) @intFromPtr(&kernel_oldact) else 0;

    // syscall 46: sigaction(signum, nsa, osa)
    const ret = darwinSyscall3(SYS_sigaction, @intCast(sig), nsa_ptr, osa_ptr);
    const err = setErrnoFromNegative(ret);
    if (err != 0) return -1;

    // Copy the kernel's 16-byte old action back to the caller.
    if (oldact) |out| {
        @as([*]u8, @ptrCast(out))[0..@sizeOf(UserSigaction)].* = @as([*]const u8, @ptrCast(&kernel_oldact))[0..@sizeOf(UserSigaction)].*;
    }

    return 0;
}

pub export fn sigprocmask(how: c_int, set: ?*const anyopaque, oldset: ?*anyopaque) c_int {
    if (how != SIG_BLOCK and how != SIG_UNBLOCK and how != SIG_SETMASK) {
        errno = EINVAL;
        return -1;
    }
    const ret = darwinSyscall3(
        SYS_sigprocmask,
        @intCast(how),
        if (set) |p| @intFromPtr(p) else 0,
        if (oldset) |p| @intFromPtr(p) else 0,
    );
    return @intCast(setErrnoFromNegative(ret));
}

/// Record the alternate signal stack configured by Zig's hosted startup.
/// The kernel handles actual alternate-stack delivery; this API stores
/// the configuration so that later sigaltstack() queries return the
/// installed stack.
pub export fn sigaltstack(ss: ?*const anyopaque, old_ss: ?*anyopaque) c_int {
    if (old_ss) |out| @as(*SignalAltStack, @ptrCast(@alignCast(out))).* = installed_alt_stack;
    if (ss) |input| {
        const next = @as(*const SignalAltStack, @ptrCast(@alignCast(input))).*;
        installed_alt_stack = next;
    }
    return 0;
}

pub export fn socket(domain: c_int, typ: c_int, protocol: c_int) c_int {
    const ret = darwinSyscall3(SYS_socket, @intCast(domain), @intCast(typ), @intCast(protocol));
    return @intCast(setErrnoFromNegative(ret));
}
pub export fn socketpair(domain: c_int, typ: c_int, protocol: c_int, sv: *[2]c_int) c_int {
    const ret = darwinSyscall5(SYS_socketpair, @intCast(domain), @intCast(typ), @intCast(protocol), @intFromPtr(sv), 0);
    return @intCast(setErrnoFromNegative(ret));
}
pub export fn connect(_: c_int, _: ?*const anyopaque, _: u32) c_int {
    return stubErr("connect");
}
pub export fn bind(_: c_int, _: ?*const anyopaque, _: u32) c_int {
    return stubErr("bind");
}
pub export fn listen(_: c_int, _: c_int) c_int {
    return stubErr("listen");
}
pub export fn accept(_: c_int, _: ?*anyopaque, _: ?*u32) c_int {
    return stubErr("accept");
}
pub export fn shutdown(_: c_int, _: c_int) c_int {
    return stubErr("shutdown");
}
pub export fn setsockopt(_: c_int, _: c_int, _: c_int, _: ?*const anyopaque, _: u32) c_int {
    return stubErr("setsockopt");
}
pub export fn getsockname(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int {
    const ret = darwinSyscall3(SYS_getsockname, @intCast(fd), @intFromPtr(addr orelse null), @intFromPtr(len orelse null));
    return @intCast(setErrnoFromNegative(ret));
}
pub export fn recvmsg(_: c_int, _: ?*anyopaque, _: c_int) isize {
    return @intCast(stubErr("recvmsg"));
}
pub export fn sendmsg(_: c_int, _: ?*const anyopaque, _: c_int) isize {
    return @intCast(stubErr("sendmsg"));
}
pub export fn sendfile(_: c_int, _: c_int, _: i64, _: *i64, _: ?*anyopaque, _: c_int) c_int {
    return stubErr("sendfile");
}
pub export fn getaddrinfo(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*const anyopaque, _: ?*?*anyopaque) c_int {
    return stubErr("getaddrinfo");
}
pub export fn freeaddrinfo(_: ?*anyopaque) void {
    reportStub("freeaddrinfo");
}
pub export fn if_nametoindex(_: [*:0]const u8) u32 {
    _ = stubErr("if_nametoindex");
    return 0;
}

pub export fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int {
    _ = newp;
    _ = newlen;
    if (cstrEq(name, "hw.ncpu") or cstrEq(name, "hw.activecpu") or cstrEq(name, "hw.logicalcpu") or cstrEq(name, "hw.physicalcpu")) {
        return sysctlCopyValue(u32, oldp, oldlenp, 4);
    }
    if (cstrEq(name, "hw.pagesize")) {
        return sysctlCopyValue(u32, oldp, oldlenp, 4096);
    }
    if (cstrEq(name, "hw.memsize")) {
        return sysctlCopyValue(u64, oldp, oldlenp, 128 * 1024 * 1024);
    }
    if (cstrEq(name, "kern.osrelease")) {
        return sysctlCopyOut(oldp, oldlenp, "24.0.0\x00".ptr, 7);
    }
    if (cstrEq(name, "kern.ostype")) {
        return sysctlCopyOut(oldp, oldlenp, "Darwin\x00".ptr, 7);
    }
    return stubErr("sysctlbyname");
}

const MAX_PTHREADS = 4;
const PTHREAD_STACK_SIZE = 16 * 1024 * 1024;
const MAP_PRIVATE_ANON: c_int = 0x1002;
const VM_PROT_READ_WRITE: c_int = 3;
const ENOMEM: c_int = 12;
const EINVAL: c_int = 22;
const ENOTSUP: c_int = 45;

const Pthread = extern struct {
    id: u64 = 0,
    result: ?*anyopaque = null,
};
var main_pthread: Pthread = .{ .id = 1 };
var pthreads: [MAX_PTHREADS]Pthread = [_]Pthread{.{}} ** MAX_PTHREADS;
var next_pthread: usize = 0;
var bsdthread_registered: bool = false;

fn currentThreadId() u64 {
    return darwinSyscall3(SYS_thread_selfid, 0, 0, 0);
}

fn pthreadStart(pthread_addr: usize, start_addr: usize, arg_addr: usize) callconv(.c) noreturn {
    const pthread: *Pthread = @ptrFromInt(pthread_addr);
    pthread.id = currentThreadId();
    const start: *const fn (?*anyopaque) callconv(.c) ?*anyopaque = @ptrFromInt(start_addr);
    pthread.result = start(@ptrFromInt(arg_addr));
    _ = darwinSyscall3(SYS_bsdthread_terminate, 0, 0, 0);
    while (true) asm volatile ("wfe");
}

pub export fn pthread_self() usize {
    const id = currentThreadId();
    if (id == 0 or id == 1) return @intFromPtr(&main_pthread);
    for (&pthreads) |*pthread| {
        if (pthread.id == id) return @intFromPtr(pthread);
    }
    return @intFromPtr(&main_pthread);
}
pub export fn pthread_threadid_np(thread: ?*anyopaque, out: *u64) c_int {
    if (thread) |p| {
        out.* = @as(*const Pthread, @ptrCast(@alignCast(p))).id;
    } else {
        out.* = currentThreadId();
    }
    return 0;
}
pub export fn pthread_equal(a: usize, b: usize) c_int {
    return if (a == b) 1 else 0;
}
pub export fn pthread_kill(thread: ?*anyopaque, sig: c_int) c_int {
    const tid = if (thread) |p| @as(*const Pthread, @ptrCast(@alignCast(p))).id else currentThreadId();
    const ret = darwinSyscall3(SYS_pthread_kill, @intCast(tid), @intCast(sig), 0);
    return @intCast(setErrnoFromNegative(ret));
}
pub export fn pthread_create(out: ?*usize, _: ?*const anyopaque, start: ?*const anyopaque, arg: ?*anyopaque) c_int {
    const start_addr = @intFromPtr(start orelse return EINVAL);
    const slot = @atomicRmw(usize, &next_pthread, .Add, 1, .monotonic);
    if (slot >= MAX_PTHREADS) return ENOMEM;
    const pthread = &pthreads[slot];
    pthread.* = .{};
    if (!bsdthread_registered) {
        const registered = darwinSyscall5(SYS_bsdthread_register, @intFromPtr(&pthreadStart), 0, 0, 0, 0);
        if (registered != 0) return ENOTSUP;
        bsdthread_registered = true;
    }
    const stack = mmap(null, PTHREAD_STACK_SIZE, VM_PROT_READ_WRITE, MAP_PRIVATE_ANON, -1, 0) orelse return ENOMEM;
    if (@intFromPtr(stack) == usize_max) return ENOMEM;
    const stack_top = @intFromPtr(stack) + PTHREAD_STACK_SIZE;
    const result = darwinSyscall5(SYS_bsdthread_create, start_addr, @intFromPtr(arg), stack_top, @intFromPtr(pthread), 0);
    if (result > usize_max - 4096) return @intCast(0 -% result);
    pthread.id = result;
    if (out) |dest| dest.* = @intFromPtr(pthread);
    return 0;
}
pub export fn pthread_detach(_: ?*anyopaque) c_int {
    return 0;
}
pub export fn pthread_attr_init(attr: ?*anyopaque) c_int {
    if (attr) |p| {
        const bytes: [*]volatile u8 = @ptrCast(p);
        var i: usize = 0;
        while (i < 64) : (i += 1) bytes[i] = 0;
    }
    return 0;
}
pub export fn pthread_attr_destroy(_: ?*anyopaque) c_int {
    return 0;
}
pub export fn pthread_attr_setstacksize(_: ?*anyopaque, _: usize) c_int {
    return 0;
}
pub export fn pthread_attr_setguardsize(_: ?*anyopaque, _: usize) c_int {
    return 0;
}
pub export fn __ulock_wait2(operation: u32, addr: ?*anyopaque, value: u64, timeout: u64, value2: u64) c_int {
    const p = addr orelse return -EINVAL;
    const ret = darwinSyscall5(SYS_ulock_wait2, operation, @intFromPtr(p), value, timeout, value2);
    if (ret == usize_max - 34) return 0; // -EAGAIN: value changed before sleeping
    return @intCast(@as(isize, @bitCast(ret)));
}
pub export fn __ulock_wake(operation: u32, addr: ?*anyopaque, wake_value: u64) c_int {
    const p = addr orelse return -EINVAL;
    const ret = darwinSyscall3(SYS_ulock_wake, operation, @intFromPtr(p), wake_value);
    return @intCast(@as(isize, @bitCast(ret)));
}
pub export fn fchmod(_: c_int, _: c_int) c_int {
    return stubErr("fchmod");
}
pub export fn fchmodat(_: c_int, _: [*:0]const u8, _: c_int, _: c_int) c_int {
    return stubErr("fchmodat");
}
pub export fn fchown(_: c_int, _: c_int, _: c_int) c_int {
    return stubErr("fchown");
}
pub export fn flock(_: c_int, _: c_int) c_int {
    return stubErr("flock");
}
pub export fn fcopyfile(_: c_int, _: c_int, _: ?*anyopaque, _: u32) c_int {
    return stubErr("fcopyfile");
}
pub export fn futimens(_: c_int, _: ?*const anyopaque) c_int {
    return stubErr("futimens");
}
pub export fn utimensat(_: c_int, _: [*:0]const u8, _: ?*const anyopaque, _: c_int) c_int {
    return stubErr("utimensat");
}
pub export fn pipe(_: *[2]c_int) c_int {
    return stubErr("pipe");
}
pub export fn poll(_: ?*anyopaque, _: u32, _: c_int) c_int {
    return stubErr("poll");
}
pub export fn dup2(_: c_int, _: c_int) c_int {
    return stubErr("dup2");
}

const DispatchFunction = *const fn (?*anyopaque) callconv(.c) void;
const DispatchObject = *DispatchObjectStorage;
const DispatchQueue = *DispatchObjectStorage;
const DispatchSource = *DispatchSourceStorage;
const DispatchSourceType = *const DispatchSourceTypeStorage;

const DispatchObjectStorage = extern struct {
    context: ?*anyopaque = null,
};
const DispatchSourceTypeStorage = extern struct {
    tag: usize = 0,
};
const DispatchSourceStorage = extern struct {
    object: DispatchObjectStorage = .{},
    kind: usize = 0,
    queue: ?DispatchQueue = null,
    event_handler: ?DispatchFunction = null,
    cancel_handler: ?DispatchFunction = null,
};

pub export var _dispatch_main_q: DispatchObjectStorage = .{};
pub export var _dispatch_queue_attr_concurrent: DispatchObjectStorage = .{};
pub export const _dispatch_source_type_timer: DispatchSourceTypeStorage = .{ .tag = 1 };

var global_dispatch_queue: DispatchObjectStorage = .{};
var dispatch_queues: [8]DispatchObjectStorage = [_]DispatchObjectStorage{.{}} ** 8;
var dispatch_sources: [16]DispatchSourceStorage = [_]DispatchSourceStorage{.{}} ** 16;
var next_dispatch_queue: usize = 0;
var next_dispatch_source: usize = 0;

pub export fn dispatch_retain(_: DispatchObject) void {}
pub export fn dispatch_release(_: DispatchObject) void {}
pub export fn dispatch_get_context(object: DispatchObject) ?*anyopaque {
    return object.context;
}
pub export fn dispatch_set_context(object: DispatchObject, context: ?*anyopaque) void {
    object.context = context;
}
pub export fn dispatch_set_finalizer_f(_: DispatchObject, _: ?DispatchFunction) void {}
fn dispatchSourceRun(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const source: DispatchSource = @ptrCast(@alignCast(arg orelse return null));
    if (source.event_handler) |handler| handler(source.object.context);
    return null;
}

pub export fn dispatch_activate(object: DispatchObject) void {
    const source: DispatchSource = @ptrCast(@alignCast(object));
    if (source.kind != 1 or source.event_handler == null) return;
    // std.Io.Dispatch installs the waiter before yielding; firing synchronously
    // corrupts its state machine, so use the kernel-backed pthread path.
    _ = pthread_create(null, null, @ptrCast(&dispatchSourceRun), @ptrCast(source));
}
pub export fn dispatch_suspend(_: DispatchObject) void {}
pub export fn dispatch_resume(_: DispatchObject) void {}

pub export fn dispatch_once_f(predicate: *isize, context: ?*anyopaque, function: DispatchFunction) void {
    if (predicate.* == -1) return;
    function(context);
    predicate.* = -1;
}

pub export fn dispatch_get_global_queue(_: isize, _: usize) DispatchQueue {
    return &global_dispatch_queue;
}
pub export fn dispatch_queue_attr_make_initially_inactive(attr: ?DispatchObject) ?DispatchObject {
    return attr;
}
pub export fn dispatch_queue_create_with_target(_: ?[*:0]const u8, _: ?DispatchObject, target: ?DispatchQueue) ?DispatchQueue {
    if (target) |q| return q;
    const slot = @atomicRmw(usize, &next_dispatch_queue, .Add, 1, .monotonic);
    if (slot >= dispatch_queues.len) return null;
    dispatch_queues[slot] = .{};
    return &dispatch_queues[slot];
}
pub export fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?DispatchObject) ?DispatchQueue {
    return dispatch_queue_create_with_target(label, attr, null);
}
pub export fn dispatch_queue_get_label(_: ?DispatchQueue) [*:0]const u8 {
    return "opendarwin\x00";
}
pub export fn dispatch_set_target_queue(_: DispatchObject, _: ?DispatchQueue) void {}
pub export fn dispatch_async_f(queue: DispatchQueue, context: ?*anyopaque, work: DispatchFunction) void {
    _ = queue;
    work(context);
}
pub export fn dispatch_sync_f(queue: DispatchQueue, context: ?*anyopaque, work: DispatchFunction) void {
    dispatch_async_f(queue, context, work);
}
pub export fn dispatch_async_and_wait_f(queue: DispatchQueue, context: ?*anyopaque, work: DispatchFunction) void {
    dispatch_async_f(queue, context, work);
}

pub export fn dispatch_source_create(source_type: DispatchSourceType, handle: usize, mask: usize, queue: ?DispatchQueue) ?DispatchSource {
    _ = handle;
    _ = mask;
    if (source_type != &_dispatch_source_type_timer) return null;
    const slot = @atomicRmw(usize, &next_dispatch_source, .Add, 1, .monotonic);
    if (slot >= dispatch_sources.len) return null;
    dispatch_sources[slot] = .{ .kind = 1, .queue = queue };
    return &dispatch_sources[slot];
}
pub export fn dispatch_source_set_event_handler_f(source: DispatchSource, handler: ?DispatchFunction) void {
    source.event_handler = handler;
}
pub export fn dispatch_source_set_cancel_handler_f(source: DispatchSource, handler: ?DispatchFunction) void {
    source.cancel_handler = handler;
}
pub export fn dispatch_source_cancel(source: DispatchSource) void {
    if (source.cancel_handler) |handler| handler(source.object.context);
}
pub export fn dispatch_source_testcancel(_: DispatchSource) isize {
    return 0;
}
pub export fn dispatch_source_get_handle(_: DispatchSource) usize {
    return 0;
}
pub export fn dispatch_source_get_mask(_: DispatchSource) usize {
    return 0;
}
pub export fn dispatch_source_get_data(_: DispatchSource) usize {
    return 0;
}
pub export fn dispatch_source_merge_data(_: DispatchSource, _: usize) void {}
pub export fn dispatch_source_set_timer(_: DispatchSource, _: u64, _: u64, _: u64) void {}
pub export fn dispatch_source_set_registration_handler_f(_: DispatchSource, _: ?DispatchFunction) void {}
pub export fn dispatch_time(_: u64, delta: i64) u64 {
    return @bitCast(delta);
}
pub export fn dispatch_walltime(_: ?*const anyopaque, delta: i64) u64 {
    return @bitCast(delta);
}
