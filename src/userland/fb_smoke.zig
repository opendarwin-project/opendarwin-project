//! Guest framebuffer smoke via Darwin IOKitLib (Mach → IOFramebuffer UserClient).

const IOFramebufferInfo = extern struct {
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    size: u64,
};

const kern_return_t = i32;
const mach_port_t = u32;
const io_connect_t = mach_port_t;

extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn IOFramebufferOpenDefault(connect_out: *io_connect_t, info_out: ?*IOFramebufferInfo) kern_return_t;
extern fn IOConnectMapMemory(
    connect: io_connect_t,
    memoryType: u32,
    intoTask: mach_port_t,
    atAddress: *u64,
    ofSize: *u64,
    options: u32,
) kern_return_t;
extern fn IOFramebufferPresent(connect: io_connect_t) kern_return_t;
extern fn IOServiceClose(connect: io_connect_t) kern_return_t;
extern fn mach_task_self() mach_port_t;

fn log(msg: []const u8) void {
    _ = write(1, msg.ptr, msg.len);
}

pub fn main() u8 {
    var connect: io_connect_t = 0;
    var info: IOFramebufferInfo = .{
        .width = 0,
        .height = 0,
        .stride = 0,
        .format = 0,
        .size = 0,
    };
    if (IOFramebufferOpenDefault(&connect, &info) != 0) {
        log("IOFramebufferOpenDefault failed\n");
        return 10;
    }
    if (info.width == 0 or info.height == 0 or info.stride == 0) {
        log("IOFramebuffer info empty\n");
        return 11;
    }

    var addr: u64 = 0;
    var size: u64 = 0;
    if (IOConnectMapMemory(connect, 0, mach_task_self(), &addr, &size, 0) != 0 or addr == 0) {
        log("IOConnectMapMemory failed\n");
        return 20;
    }
    const pixels: [*]u8 = @ptrFromInt(addr);

    var y: u32 = 0;
    while (y < info.height) : (y += 1) {
        const row = pixels + y * info.stride;
        var x: u32 = 0;
        while (x < info.width) : (x += 1) {
            const band = (x * 3) / info.width;
            const px = row + x * 4;
            switch (band) {
                0 => {
                    px[0] = 0;
                    px[1] = 0;
                    px[2] = 0xff;
                    px[3] = 0;
                },
                1 => {
                    px[0] = 0;
                    px[1] = 0xff;
                    px[2] = 0;
                    px[3] = 0;
                },
                else => {
                    px[0] = 0xff;
                    px[1] = 0;
                    px[2] = 0;
                    px[3] = 0;
                },
            }
        }
    }

    if (IOFramebufferPresent(connect) != 0) {
        log("IOFramebufferPresent failed\n");
        return 30;
    }
    _ = IOServiceClose(connect);

    log("IOKit framebuffer present smoke passed\n");
    return 0;
}
