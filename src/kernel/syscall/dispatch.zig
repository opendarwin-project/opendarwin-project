const context = @import("../arch/aarch64/context.zig");
const unix = @import("unix.zig");
const mach = @import("mach.zig");

fn svcImm(elr: u64) u16 {
    const instr = @as([*]const u32, @ptrFromInt(elr - 4))[0];
    return @truncate(instr >> 5);
}

pub export fn handle(frame: *context.Frame) void {
    const imm = svcImm(frame.elr_el1);
    if (imm == 0x81) {
        mach.handle(frame);
    } else {
        unix.handle(frame);
    }
}
