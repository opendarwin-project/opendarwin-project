const types = @import("types.zig");
const IpcObject = @import("object.zig").IpcObject;

/// A single entry in an IPC space's hash table.
pub const IpcEntry = struct {
    ie_object: ?*IpcObject,
    ie_bits: types.ipc_entry_bits_t,
    ie_index: types.ipc_table_index_t,
    ie_next: ?*IpcEntry,

    pub fn initFree(index: types.ipc_table_index_t, next_free: ?*IpcEntry) IpcEntry {
        return .{
            .ie_object = null,
            .ie_bits = 0,
            .ie_index = index,
            .ie_next = next_free,
        };
    }

    pub fn isFree(self: *const IpcEntry) bool {
        return self.ie_object == null;
    }

    pub fn typeOf(self: *const IpcEntry) u32 {
        return types.ie_bits_type(self.ie_bits);
    }

    pub fn gen(self: *const IpcEntry) u32 {
        return types.ie_bits_gen(self.ie_bits);
    }

    pub fn urefs(self: *const IpcEntry) u32 {
        return types.ie_bits_urefs(self.ie_bits);
    }
};
