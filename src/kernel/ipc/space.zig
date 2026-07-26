const types = @import("types.zig");
const IpcObject = @import("object.zig").IpcObject;
const IpcEntry = @import("entry.zig").IpcEntry;
const slab = @import("../mm/slab.zig");
const SpinLock = @import("../sync/spinlock.zig");

const TABLE_INITIAL_SIZE: types.ipc_table_size_t = 16;

pub const IpcSpace = struct {
    lock: SpinLock = .{},
    is_table: []IpcEntry = &.{},
    is_table_size: types.ipc_table_size_t = 0,
    is_table_free: types.ipc_table_index_t = 0,

    pub fn init(self: *IpcSpace) void {
        const size = TABLE_INITIAL_SIZE;
        const raw = slab.alloc(size * @sizeOf(IpcEntry));
        const aligned: *align(8) anyopaque = @alignCast(raw);
        const ptr = @as([*]IpcEntry, @ptrCast(aligned))[0..size];
        for (ptr, 0..) |*e, i| {
            const next: ?*IpcEntry = if (i + 1 < size) &ptr[i + 1] else null;
            e.* = IpcEntry.initFree(@intCast(i), next);
        }
        self.* = .{
            .lock = .{},
            .is_table = ptr,
            .is_table_size = size,
            .is_table_free = 0,
        };
    }

    pub fn allocEntry(self: *IpcSpace) ?*IpcEntry {
        const free_idx = self.is_table_free;
        if (free_idx >= self.is_table_size) {
            // TODO: grow table
            return null;
        }
        const entry = &self.is_table[free_idx];
        self.is_table_free = if (entry.ie_next) |next| @intCast((@intFromPtr(next) - @intFromPtr(self.is_table.ptr)) / @sizeOf(IpcEntry)) else self.is_table_size;
        return entry;
    }

    pub fn freeEntry(self: *IpcSpace, entry: *IpcEntry) void {
        entry.* = IpcEntry.initFree(self.is_table_free, null);
        const idx: types.ipc_table_index_t = @intCast((@intFromPtr(entry) - @intFromPtr(self.is_table.ptr)) / @sizeOf(IpcEntry));
        self.is_table_free = idx;
    }

    pub fn lookupEntry(self: *IpcSpace, name: types.mach_port_name_t) ?*IpcEntry {
        const idx = name & (self.is_table_size - 1);
        if (idx >= self.is_table_size) return null;
        return &self.is_table[idx];
    }
};
