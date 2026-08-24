//! VirtIO-Input / VirtIO-Tablet driver over virtio-mmio (modern, v2).
//! Supports QEMU `-device virtio-tablet-device` (absolute coordinate pointer),
//! `-device virtio-mouse-device` (relative pointer), and
//! `-device virtio-keyboard-device` (scancodes).

const std = @import("std");
const conduit = @import("conduit");
const provider = @import("../device/provider.zig");
const uart = @import("uart.zig");

pub const MAGIC: u32 = 0x74726976; // 'virt'
pub const DEVICE_ID_INPUT: u32 = 18;

const R_MAGIC: usize = 0x000;
const R_VERSION: usize = 0x004;
const R_DEVICE_ID: usize = 0x008;
const R_DRIVER_FEATURES: usize = 0x020;
const R_DRIVER_FEATURES_SEL: usize = 0x024;
const R_QUEUE_SEL: usize = 0x030;
const R_QUEUE_NUM_MAX: usize = 0x034;
const R_QUEUE_NUM: usize = 0x038;
const R_QUEUE_READY: usize = 0x044;
const R_QUEUE_NOTIFY: usize = 0x050;
const R_INTERRUPT_STATUS: usize = 0x060;
const R_INTERRUPT_ACK: usize = 0x064;
const R_STATUS: usize = 0x070;
const R_QUEUE_DESC_LOW: usize = 0x080;
const R_QUEUE_DESC_HIGH: usize = 0x084;
const R_QUEUE_DRIVER_LOW: usize = 0x090;
const R_QUEUE_DRIVER_HIGH: usize = 0x094;
const R_QUEUE_DEVICE_LOW: usize = 0x0a0;
const R_QUEUE_DEVICE_HIGH: usize = 0x0a4;
const R_CONFIG: usize = 0x100;

const S_ACKNOWLEDGE: u32 = 1;
const S_DRIVER: u32 = 2;
const S_DRIVER_OK: u32 = 4;
const S_FEATURES_OK: u32 = 8;

const F_VERSION_1_HI: u32 = 1; // VIRTIO_F_VERSION_1 = bit 32

pub const VIRTIO_INPUT_CFG_UNSET: u8 = 0x00;
pub const VIRTIO_INPUT_CFG_ID_NAME: u8 = 0x01;
pub const VIRTIO_INPUT_CFG_ID_SERIAL: u8 = 0x02;
pub const VIRTIO_INPUT_CFG_ID_DEVIDS: u8 = 0x03;
pub const VIRTIO_INPUT_CFG_PROP_BITS: u8 = 0x10;
pub const VIRTIO_INPUT_CFG_EV_BITS: u8 = 0x11;
pub const VIRTIO_INPUT_CFG_ABS_INFO: u8 = 0x12;

// Linux input event types
pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

// Relative axes
pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const REL_WHEEL: u16 = 0x08;

// Absolute axes
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const ABS_PRESSURE: u16 = 0x18;

// Key / Button codes
pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_SIDE: u16 = 0x113;
pub const BTN_EXTRA: u16 = 0x114;
pub const BTN_TOUCH: u16 = 0x14a;

pub const VirtioInputEvent = extern struct {
    type: u16 = 0,
    code: u16 = 0,
    value: u32 = 0,
};

pub const VirtioInputAbsInfo = extern struct {
    min: u32 = 0,
    max: u32 = 0,
    fuzz: u32 = 0,
    flat: u32 = 0,
    res: u32 = 0,
};

fn barrier() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

const QSIZE = 64;
const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const Avail = extern struct { flags: u16, idx: u16, ring: [QSIZE]u16, used_event: u16 };
const UsedElem = extern struct { id: u32, len: u32 };
const Used = extern struct { flags: u16, idx: u16, ring: [QSIZE]UsedElem, avail_event: u16 };

pub const DeviceType = enum {
    unknown,
    tablet,
    mouse,
    keyboard,
};

pub const InputState = struct {
    device_type: DeviceType = .unknown,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,

    // Absolute pointer state (e.g. tablet)
    abs_x: u32 = 0,
    abs_y: u32 = 0,
    abs_max_x: u32 = 0,
    abs_max_y: u32 = 0,
    abs_updated: bool = false,

    // Relative pointer delta accumulator (e.g. mouse)
    rel_dx: i32 = 0,
    rel_dy: i32 = 0,

    // Button states (bit 0 = left, bit 1 = right, bit 2 = middle)
    buttons: u32 = 0,
};

pub const VirtioInput = struct {
    mmio: conduit.Mmio,
    present: bool = false,
    last_used: u16 = 0,
    state: InputState = .{},

    desc: [QSIZE]Desc align(16) = undefined,
    avail: Avail align(16) = undefined,
    used: Used align(16) = undefined,
    event_bufs: [QSIZE]VirtioInputEvent align(16) = undefined,

    // Queue 1: statusq (host -> guest status / LED changes)
    status_desc: [QSIZE]Desc align(16) = undefined,
    status_avail: Avail align(16) = undefined,
    status_used: Used align(16) = undefined,
    status_bufs: [QSIZE]VirtioInputEvent align(16) = undefined,

    pub fn start(self: *VirtioInput) bool {
        if (self.mmio.read(u32, R_MAGIC) != MAGIC) return false;
        if (self.mmio.read(u32, R_DEVICE_ID) != DEVICE_ID_INPUT) return false;
        if (self.mmio.read(u32, R_VERSION) != 2) return false;

        self.mmio.write(u32, R_STATUS, 0); // reset
        var status: u32 = S_ACKNOWLEDGE;
        self.mmio.write(u32, R_STATUS, status);
        status |= S_DRIVER;
        self.mmio.write(u32, R_STATUS, status);

        // Feature negotiation (VIRTIO_F_VERSION_1)
        self.mmio.write(u32, R_DRIVER_FEATURES_SEL, 1);
        self.mmio.write(u32, R_DRIVER_FEATURES, F_VERSION_1_HI);
        self.mmio.write(u32, R_DRIVER_FEATURES_SEL, 0);
        self.mmio.write(u32, R_DRIVER_FEATURES, 0);

        status |= S_FEATURES_OK;
        self.mmio.write(u32, R_STATUS, status);
        if (self.mmio.read(u32, R_STATUS) & S_FEATURES_OK == 0) return false;

        // Query device config
        self.queryConfig();

        // Setup Queue 0: eventq
        self.mmio.write(u32, R_QUEUE_SEL, 0);
        const max_q = self.mmio.read(u32, R_QUEUE_NUM_MAX);
        if (max_q < QSIZE) return false;
        self.mmio.write(u32, R_QUEUE_NUM, QSIZE);

        for (0..QSIZE) |i| {
            self.desc[i] = .{
                .addr = @intFromPtr(&self.event_bufs[i]),
                .len = @sizeOf(VirtioInputEvent),
                .flags = VIRTQ_DESC_F_WRITE,
                .next = 0,
            };
            self.avail.ring[i] = @intCast(i);
        }
        self.avail.flags = 0;
        self.avail.idx = QSIZE;
        self.avail.used_event = 0;

        self.used.flags = 0;
        self.used.idx = 0;
        for (0..QSIZE) |i| {
            self.used.ring[i] = .{ .id = 0, .len = 0 };
        }
        self.used.avail_event = 0;
        self.last_used = 0;

        self.setQueueAddr(R_QUEUE_DESC_LOW, @intFromPtr(&self.desc));
        self.setQueueAddr(R_QUEUE_DRIVER_LOW, @intFromPtr(&self.avail));
        self.setQueueAddr(R_QUEUE_DEVICE_LOW, @intFromPtr(&self.used));
        self.mmio.write(u32, R_QUEUE_READY, 1);

        // Setup Queue 1: statusq
        self.mmio.write(u32, R_QUEUE_SEL, 1);
        const max_q1 = self.mmio.read(u32, R_QUEUE_NUM_MAX);
        if (max_q1 >= QSIZE) {
            self.mmio.write(u32, R_QUEUE_NUM, QSIZE);
            for (0..QSIZE) |i| {
                self.status_desc[i] = .{
                    .addr = @intFromPtr(&self.status_bufs[i]),
                    .len = @sizeOf(VirtioInputEvent),
                    .flags = 0,
                    .next = 0,
                };
                self.status_avail.ring[i] = @intCast(i);
            }
            self.status_avail.flags = 0;
            self.status_avail.idx = 0;
            self.status_avail.used_event = 0;
            self.status_used.flags = 0;
            self.status_used.idx = 0;
            for (0..QSIZE) |i| {
                self.status_used.ring[i] = .{ .id = 0, .len = 0 };
            }
            self.status_used.avail_event = 0;

            self.setQueueAddr(R_QUEUE_DESC_LOW, @intFromPtr(&self.status_desc));
            self.setQueueAddr(R_QUEUE_DRIVER_LOW, @intFromPtr(&self.status_avail));
            self.setQueueAddr(R_QUEUE_DEVICE_LOW, @intFromPtr(&self.status_used));
            self.mmio.write(u32, R_QUEUE_READY, 1);
        }

        status |= S_DRIVER_OK;
        self.mmio.write(u32, R_STATUS, status);
        self.present = true;

        barrier();
        self.mmio.write(u32, R_QUEUE_SEL, 0);
        // Kick the device to let it know event buffers are available and activate input handler
        self.mmio.write(u32, R_QUEUE_NOTIFY, 0);
        return true;
    }

    fn setQueueAddr(self: *VirtioInput, off: usize, addr: usize) void {
        self.mmio.write(u32, off, @truncate(addr));
        self.mmio.write(u32, off + 4, @truncate(addr >> 32));
    }

    fn queryConfig(self: *VirtioInput) void {
        // Read device name
        self.mmio.write(u8, R_CONFIG + 0, VIRTIO_INPUT_CFG_ID_NAME);
        self.mmio.write(u8, R_CONFIG + 1, 0);
        const name_size = self.mmio.read(u8, R_CONFIG + 2);
        const copy_len = @min(name_size, self.state.name.len);
        for (0..copy_len) |i| {
            self.state.name[i] = self.mmio.read(u8, R_CONFIG + 8 + i);
        }
        self.state.name_len = copy_len;

        // Read ABS_X info
        self.mmio.write(u8, R_CONFIG + 0, VIRTIO_INPUT_CFG_ABS_INFO);
        self.mmio.write(u8, R_CONFIG + 1, @truncate(ABS_X));
        const abs_x_size = self.mmio.read(u8, R_CONFIG + 2);
        if (abs_x_size >= @sizeOf(VirtioInputAbsInfo)) {
            var abs_x: VirtioInputAbsInfo = undefined;
            const ptr: [*]u8 = @ptrCast(&abs_x);
            for (0..@sizeOf(VirtioInputAbsInfo)) |i| {
                ptr[i] = self.mmio.read(u8, R_CONFIG + 8 + i);
            }
            if (abs_x.max > 0) self.state.abs_max_x = abs_x.max;
        }

        // Read ABS_Y info
        self.mmio.write(u8, R_CONFIG + 0, VIRTIO_INPUT_CFG_ABS_INFO);
        self.mmio.write(u8, R_CONFIG + 1, @truncate(ABS_Y));
        const abs_y_size = self.mmio.read(u8, R_CONFIG + 2);
        if (abs_y_size >= @sizeOf(VirtioInputAbsInfo)) {
            var abs_y: VirtioInputAbsInfo = undefined;
            const ptr: [*]u8 = @ptrCast(&abs_y);
            for (0..@sizeOf(VirtioInputAbsInfo)) |i| {
                ptr[i] = self.mmio.read(u8, R_CONFIG + 8 + i);
            }
            if (abs_y.max > 0) self.state.abs_max_y = abs_y.max;
        }

        // Identify device type by name or properties
        const name_slice = self.state.name[0..self.state.name_len];
        if (std.mem.indexOf(u8, name_slice, "Tablet") != null or std.mem.indexOf(u8, name_slice, "tablet") != null) {
            self.state.device_type = .tablet;
            if (self.state.abs_max_x == 0) self.state.abs_max_x = 32767;
            if (self.state.abs_max_y == 0) self.state.abs_max_y = 32767;
        } else if (std.mem.indexOf(u8, name_slice, "Mouse") != null or std.mem.indexOf(u8, name_slice, "mouse") != null) {
            self.state.device_type = .mouse;
        } else if (std.mem.indexOf(u8, name_slice, "Keyboard") != null or std.mem.indexOf(u8, name_slice, "keyboard") != null) {
            self.state.device_type = .keyboard;
        }
    }

    /// Poll for pending events from the device, updating internal state.
    /// Returns the number of events processed.
    pub fn pollEvents(self: *VirtioInput) usize {
        if (!self.present) return 0;

        var processed: usize = 0;
        barrier();
        const current_used = @atomicLoad(u16, &self.used.idx, .acquire);

        while (self.last_used != current_used) {
            const used_slot = self.last_used % QSIZE;
            const elem = self.used.ring[used_slot];
            const desc_id = elem.id;

            if (desc_id < QSIZE) {
                barrier();
                const event = self.event_bufs[desc_id];
                self.handleEvent(event);

                // Push buffer back onto available ring
                self.avail.ring[self.avail.idx % QSIZE] = @intCast(desc_id);
                barrier();
                @atomicStore(u16, &self.avail.idx, self.avail.idx +% 1, .release);
                barrier();
                processed += 1;
            }

            self.last_used +%= 1;
        }

        if (processed > 0) {
            self.mmio.write(u32, R_INTERRUPT_ACK, self.mmio.read(u32, R_INTERRUPT_STATUS));
            barrier();
            // Notify device of replenished buffers
            self.mmio.write(u32, R_QUEUE_NOTIFY, 0);
        }

        return processed;
    }

    fn handleEvent(self: *VirtioInput, ev: VirtioInputEvent) void {
        switch (ev.type) {
            EV_ABS => {
                switch (ev.code) {
                    ABS_X => {
                        self.state.abs_x = ev.value;
                        self.state.abs_updated = true;
                    },
                    ABS_Y => {
                        self.state.abs_y = ev.value;
                        self.state.abs_updated = true;
                    },
                    else => {},
                }
            },
            EV_REL => {
                switch (ev.code) {
                    REL_X => self.state.rel_dx += @as(i32, @bitCast(ev.value)),
                    REL_Y => self.state.rel_dy += @as(i32, @bitCast(ev.value)),
                    else => {},
                }
            },
            EV_KEY => {
                const pressed: bool = (ev.value != 0);
                const bit: u32 = switch (ev.code) {
                    BTN_LEFT, BTN_TOUCH => 1 << 0,
                    BTN_RIGHT => 1 << 1,
                    BTN_MIDDLE => 1 << 2,
                    BTN_SIDE => 1 << 3,
                    BTN_EXTRA => 1 << 4,
                    else => 0,
                };
                if (bit != 0) {
                    if (pressed) {
                        self.state.buttons |= bit;
                    } else {
                        self.state.buttons &= ~bit;
                    }
                }
            },
            else => {},
        }
    }
};

pub const MAX_INPUT_DEVICES: usize = 8;
pub var devices: [MAX_INPUT_DEVICES]VirtioInput = undefined;
pub var device_count: usize = 0;
var candidate_buf: [40]provider.Info = undefined;
var candidate_count: usize = 0;

pub fn probe(base: u64) bool {
    if (base == 0) return false;
    const mmio = conduit.Mmio.direct(base);
    if (mmio.read(u32, R_MAGIC) != MAGIC) return false;
    return mmio.read(u32, R_DEVICE_ID) == DEVICE_ID_INPUT;
}

pub fn stashCandidates(matches: []const provider.Info) void {
    var n: usize = 0;
    for (matches) |m| {
        if (n >= candidate_buf.len) break;
        if (m.pci_vendor_id != 0) continue;
        if (!probe(m.mmio_base)) continue;
        candidate_buf[n] = m;
        n += 1;
    }
    candidate_count = n;
}

pub fn stashedCandidates() []const provider.Info {
    return candidate_buf[0..candidate_count];
}

pub fn init(candidate_matches: []const provider.Info) bool {
    device_count = 0;
    for (candidate_matches) |m| {
        if (device_count >= MAX_INPUT_DEVICES) break;
        var dev = &devices[device_count];
        dev.* = VirtioInput{
            .mmio = conduit.Mmio.direct(m.mmio_base),
        };
        if (dev.start()) {
            uart.print("opendarwin: virtio-input device ready (");
            uart.print(dev.state.name[0..dev.state.name_len]);
            uart.print(")\n");
            device_count += 1;
        }
    }
    return device_count > 0;
}

pub fn primaryPointer() ?*VirtioInput {
    for (devices[0..device_count]) |*dev| {
        if (dev.state.device_type == .tablet or dev.state.abs_max_x > 0) return dev;
    }
    for (devices[0..device_count]) |*dev| {
        if (dev.state.device_type == .mouse) return dev;
    }
    if (device_count > 0) return &devices[0];
    return null;
}

pub fn ready() bool {
    return device_count > 0;
}

pub fn poll() usize {
    var total: usize = 0;
    for (devices[0..device_count]) |*dev| {
        total += dev.pollEvents();
    }
    return total;
}

pub fn getState() ?InputState {
    if (device_count == 0) return null;
    var agg = InputState{};
    var found_pointer = false;

    for (devices[0..device_count]) |*dev| {
        _ = dev.pollEvents();
        agg.buttons |= dev.state.buttons;

        if (dev.state.device_type == .tablet or dev.state.abs_max_x > 0) {
            agg.abs_x = dev.state.abs_x;
            agg.abs_y = dev.state.abs_y;
            agg.abs_max_x = dev.state.abs_max_x;
            agg.abs_max_y = dev.state.abs_max_y;
            agg.abs_updated = agg.abs_updated or dev.state.abs_updated;
            dev.state.abs_updated = false;
            agg.device_type = .tablet;
            found_pointer = true;
        } else if (dev.state.device_type == .mouse) {
            if (dev.state.rel_dx != 0 or dev.state.rel_dy != 0) {
                agg.rel_dx += dev.state.rel_dx;
                agg.rel_dy += dev.state.rel_dy;
                dev.state.rel_dx = 0;
                dev.state.rel_dy = 0;
                if (!found_pointer) agg.device_type = .mouse;
                found_pointer = true;
            }
        }
    }

    if (!found_pointer and device_count > 0) {
        if (primaryPointer()) |ptr_dev| {
            return ptr_dev.state;
        }
        return devices[0].state;
    }
    return agg;
}
