const types = @import("types.zig");
const SpinLock = @import("../sync/spinlock.zig");

pub const IpcObject = struct {
    lock: SpinLock = .{},
    io_bits: types.io_bits_t = 0,
    io_references: types.io_references_t = 0,

    pub fn init(self: *IpcObject, typ: types.IOT) void {
        self.* = .{
            .lock = .{},
            .io_bits = types.io_makebits(typ, 1),
            .io_references = 1,
        };
    }

    pub fn typeOf(self: *const IpcObject) types.IOT {
        return types.io_type(self.io_bits);
    }

    pub fn refs(self: *const IpcObject) types.io_references_t {
        return types.io_refs(self.io_bits);
    }

    pub fn retain(self: *IpcObject) void {
        _ = @atomicRmw(u32, &self.io_references, .Add, 1, .monotonic);
        self.io_bits = (self.io_bits & ~types.IO_BITS_REF_MASK) |
            (@as(types.io_bits_t, @intCast(self.io_references)) & types.IO_BITS_REF_MASK);
    }

    pub fn release(self: *IpcObject) bool {
        self.io_references -|= 1;
        self.io_bits = (self.io_bits & ~types.IO_BITS_REF_MASK) |
            (@as(types.io_bits_t, @intCast(self.io_references)) & types.IO_BITS_REF_MASK);
        return self.io_references == 0;
    }
};
