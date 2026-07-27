//! Compiler-rt and basic libc exports: __divti3, _exit, exit, abort,
//! __stack_chk_fail, __error, syscall, opendarwin_user_return, dyld_stub_binder.

const common = @import("common.zig");
const C = common;

pub const usize_max = C.usize_max;

pub export var __dyld_private: usize = 0;
pub export var __stack_chk_guard: usize = 0x595a_5b5c_5d5e_5f60;

/// Compiler-rt signed 128-bit division used by Zig's optimized Darwin code.
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

pub export fn __error() *c_int {
    return &common.errno;
}

pub export fn _exit(status: c_int) noreturn {
    _ = C.darwinSyscall3(C.SYS_exit, @intCast(status), 0, 0);
    while (true) asm volatile ("wfe");
}

pub export fn exit(status: c_int) noreturn {
    _exit(status);
}

pub export fn abort() noreturn {
    C.reportStub("abort");
    _exit(134);
}

pub export fn __assert_rtn(
    _: ?[*:0]const u8,
    _: ?[*:0]const u8,
    _: c_int,
    _: ?[*:0]const u8,
) noreturn {
    _exit(134);
}

pub export fn __stack_chk_fail() noreturn {
    _exit(127);
}

pub export fn opendarwin_user_return(status: u64) noreturn {
    _exit(@intCast(status & 0xff));
}

pub export fn dyld_stub_binder() void {
    _exit(127);
}
