//! IOHIDSystem — IOKit service for human interface devices (mouse, tablet, keyboard).
//! Provides userspace (WindowServer) access to pointer and event state via IOConnectTrap.

const types = @import("../types.zig");
const service = @import("../service.zig");
const registry = @import("../registry.zig");
const virtio_input = @import("../../drivers/virtio_input.zig");
const uart = @import("../../drivers/uart.zig");

pub const CLASS_NAME = "IOHIDSystem";

pub const IOHIDPointState = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    max_x: u32 = 32767,
    max_y: u32 = 32767,
    rel_dx: i32 = 0,
    rel_dy: i32 = 0,
    buttons: u32 = 0,
    device_type: u32 = 0, // 0 = unknown, 1 = tablet, 2 = mouse, 3 = keyboard
    abs_updated: u32 = 0,
};

var hid_service: service.IOService = undefined;
var initialized: bool = false;

pub fn initAndRegister() void {
    if (initialized) return;
    hid_service.init(CLASS_NAME, "iohid-system", "");
    _ = registry.publish(&hid_service);
    initialized = true;
    uart.print("opendarwin: iokit published: IOHIDSystem\n");
}

pub fn getService() *service.IOService {
    return &hid_service;
}

pub fn getPointState(out: *IOHIDPointState) types.IOReturn {
    if (virtio_input.getState()) |st| {
        out.* = .{
            .x = st.abs_x,
            .y = st.abs_y,
            .max_x = st.abs_max_x,
            .max_y = st.abs_max_y,
            .rel_dx = st.rel_dx,
            .rel_dy = st.rel_dy,
            .buttons = st.buttons,
            .device_type = @intFromEnum(st.device_type),
            .abs_updated = if (st.abs_updated) 1 else 0,
        };
        return types.kIOReturnSuccess;
    }
    return types.kIOReturnNotReady;
}

pub fn pollEvents() types.IOReturn {
    _ = virtio_input.poll();
    return types.kIOReturnSuccess;
}
