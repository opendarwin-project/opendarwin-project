//! Tiny Darwin-target Zig smoke binary for OpenDarwin.
//!
//! Uses Zig's normal hosted Darwin `main` path and verifies that the minimal
//! libSystem/kernel pthread_create path can run a second schedulable thread.

extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn pthread_create(thread: *usize, attr: ?*const anyopaque, start: *const anyopaque, arg: ?*anyopaque) c_int;
extern fn pthread_self() usize;
extern fn pthread_threadid_np(thread: ?*anyopaque, out: *u64) c_int;

var child_done: u32 = 0;
var child_tid: u64 = 0;

fn childMain(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var tid: u64 = 0;
    _ = pthread_threadid_np(null, &tid);
    child_tid = tid;
    const msg = "hello from pthread child\n";
    _ = write(1, msg.ptr, msg.len);
    @atomicStore(u32, &child_done, 1, .release);
    return null;
}

pub fn main() u8 {
    const msg = "hello from Zig hosted main\n";
    _ = write(1, msg.ptr, msg.len);

    var main_tid: u64 = 0;
    _ = pthread_threadid_np(null, &main_tid);
    if (main_tid == 0 or pthread_self() == 0) return 10;

    var thread: usize = 0;
    const rc = pthread_create(&thread, null, @ptrCast(&childMain), null);
    if (rc != 0 or thread == 0) {
        const fail = "pthread_create failed\n";
        _ = write(1, fail.ptr, fail.len);
        return 20;
    }

    var spins: usize = 0;
    while (@atomicLoad(u32, &child_done, .acquire) == 0 and spins < 50_000_000) : (spins += 1) {
        asm volatile ("nop");
    }
    if (@atomicLoad(u32, &child_done, .acquire) == 0) return 30;
    if (child_tid == 0 or child_tid == main_tid) return 31;

    const ok = "pthread_create smoke passed\n";
    _ = write(1, ok.ptr, ok.len);
    return 0;
}
