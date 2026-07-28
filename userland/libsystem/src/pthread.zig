//! POSIX threads: pthread_create, pthread_self, pthread_mutex_*, pthread_key_*,
//! pthread_once, pthread_cond_*, pthread_rwlock_*, and the __ulock_* futex primitives.

const common = @import("common.zig");
const C = common;

// ── Pthread struct and scheduler ───────────────────────────────────────

const MAX_PTHREADS = 4;
const PTHREAD_STACK_SIZE = 16 * 1024 * 1024;

const Pthread = extern struct {
    id: u64 = 0,
    result: ?*anyopaque = null,
};

var main_pthread: Pthread = .{ .id = 1 };
var pthreads: [MAX_PTHREADS]Pthread = [_]Pthread{.{}} ** MAX_PTHREADS;
var next_pthread: usize = 0;
var bsdthread_registered: bool = false;

fn currentThreadId() u64 {
    return C.darwinSyscall3(C.SYS_thread_selfid, 0, 0, 0);
}

fn pthreadStart(pthread_addr: usize, start_addr: usize, arg_addr: usize) callconv(.c) noreturn {
    const pthread: *Pthread = @ptrFromInt(pthread_addr);
    pthread.id = currentThreadId();
    const start: *const fn (?*anyopaque) callconv(.c) ?*anyopaque = @ptrFromInt(start_addr);
    pthread.result = start(@ptrFromInt(arg_addr));
    _ = C.darwinSyscall3(C.SYS_bsdthread_terminate, 0, 0, 0);
    while (true) asm volatile ("wfe");
}

// ── pthread self / identity ────────────────────────────────────────────

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

pub export fn pthread_main_np() c_int {
    const id = currentThreadId();
    return if (id == 1) 1 else 0;
}

pub export fn pthread_kill(thread: ?*anyopaque, sig: c_int) c_int {
    const tid = if (thread) |p| @as(*const Pthread, @ptrCast(@alignCast(p))).id else currentThreadId();
    const ret = C.darwinSyscall3(C.SYS_pthread_kill, @intCast(tid), @intCast(sig), 0);
    return @intCast(C.setErrnoFromNegative(ret));
}

pub export fn pthread_sigmask(_: c_int, _: ?*const anyopaque, _: ?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_atfork(_: ?*const anyopaque, _: ?*const anyopaque, _: ?*const anyopaque) c_int {
    return 0;
}

// ── pthread_create / join / detach ─────────────────────────────────────

pub export fn pthread_create(out: ?*usize, _: ?*const anyopaque, start: ?*const anyopaque, arg: ?*anyopaque) c_int {
    const start_addr = @intFromPtr(start orelse return C.EINVAL);
    const slot = @atomicRmw(usize, &next_pthread, .Add, 1, .monotonic);
    if (slot >= MAX_PTHREADS) return C.ENOMEM;
    const pthread = &pthreads[slot];
    pthread.* = .{};
    if (!bsdthread_registered) {
        const registered = C.darwinSyscall5(C.SYS_bsdthread_register, @intFromPtr(&pthreadStart), 0, 0, 0, 0);
        if (registered != 0) return C.ENOTSUP;
        bsdthread_registered = true;
    }
    const stack = @import("mach.zig").mmap(null, PTHREAD_STACK_SIZE, C.VM_PROT_READ_WRITE, C.MAP_PRIVATE_ANON, -1, 0) orelse return C.ENOMEM;
    if (@intFromPtr(stack) == C.usize_max) return C.ENOMEM;
    const stack_top = @intFromPtr(stack) + PTHREAD_STACK_SIZE;
    const result = C.darwinSyscall5(C.SYS_bsdthread_create, start_addr, @intFromPtr(arg), stack_top, @intFromPtr(pthread), 0);
    if (result > C.usize_max - 4096) return @intCast(0 -% result);
    pthread.id = result;
    if (out) |dest| dest.* = @intFromPtr(pthread);
    return 0;
}

pub export fn pthread_join(_: ?*anyopaque, _: ?*?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_detach(_: ?*anyopaque) c_int {
    return 0;
}

// ── pthread_attr ───────────────────────────────────────────────────────

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

pub export fn pthread_attr_getstacksize(_: ?*const anyopaque, out: ?*usize) c_int {
    if (out) |p| p.* = PTHREAD_STACK_SIZE;
    return 0;
}

pub export fn pthread_attr_getguardsize(_: ?*const anyopaque, out: ?*usize) c_int {
    if (out) |p| p.* = 0;
    return 0;
}

pub export fn pthread_get_stackaddr_np(_: ?*anyopaque) ?*anyopaque {
    return null;
}

pub export fn pthread_get_stacksize_np(_: ?*anyopaque) usize {
    return PTHREAD_STACK_SIZE;
}

// ── pthread_mutex ──────────────────────────────────────────────────────

pub const PTHREAD_MUTEX_NORMAL: c_int = 0;
pub const PTHREAD_MUTEX_RECURSIVE: c_int = 1;
pub const PTHREAD_MUTEX_ERRORCHECK: c_int = 2;

const PthreadMutex = extern struct {
    lock: u32 = 0,
    owner: u64 = 0,
    count: u32 = 0,
    kind: c_int = PTHREAD_MUTEX_NORMAL,
};

pub export fn pthread_mutex_init(m: ?*anyopaque, _: ?*const anyopaque) c_int {
    if (m) |p| {
        const mutex: *PthreadMutex = @ptrCast(@alignCast(p));
        mutex.* = .{};
    }
    return 0;
}

pub export fn pthread_mutex_destroy(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_mutex_lock(m: ?*anyopaque) c_int {
    const mutex = m orelse return C.EINVAL;
    const mp: *PthreadMutex = @ptrCast(@alignCast(mutex));
    const tid = currentThreadId();

    if (mp.kind == PTHREAD_MUTEX_RECURSIVE and mp.owner == tid) {
        mp.count += 1;
        return 0;
    }

    // Spin until we acquire the lock via ulock
    while (@cmpxchgStrong(u32, &mp.lock, 0, 1, .acquire, .monotonic) != null) {
        _ = __ulock_wait2(0x01, @ptrCast(&mp.lock), 0, 0, 0); // UL_COMPARE_AND_WAIT
    }
    mp.owner = tid;
    mp.count = 1;
    return 0;
}

pub export fn pthread_mutex_trylock(m: ?*anyopaque) c_int {
    const mutex = m orelse return C.EINVAL;
    const mp: *PthreadMutex = @ptrCast(@alignCast(mutex));
    const tid = currentThreadId();

    if (mp.kind == PTHREAD_MUTEX_RECURSIVE and mp.owner == tid) {
        mp.count += 1;
        return 0;
    }

    if (@cmpxchgStrong(u32, &mp.lock, 0, 1, .acquire, .monotonic) != null) {
        return 16; // EBUSY
    }
    mp.owner = tid;
    mp.count = 1;
    return 0;
}

pub export fn pthread_mutex_unlock(m: ?*anyopaque) c_int {
    const mutex = m orelse return C.EINVAL;
    const mp: *PthreadMutex = @ptrCast(@alignCast(mutex));

    if (mp.kind == PTHREAD_MUTEX_RECURSIVE and mp.count > 1) {
        mp.count -= 1;
        return 0;
    }

    mp.owner = 0;
    mp.count = 0;
    _ = @atomicStore(u32, &mp.lock, 0, .release);
    _ = __ulock_wake(0x01, @ptrCast(&mp.lock), 0); // UL_COMPARE_AND_WAIT
    return 0;
}

pub export fn pthread_mutex_gettype(_: ?*const anyopaque) c_int {
    return PTHREAD_MUTEX_NORMAL;
}

pub export fn pthread_mutex_settype(m: ?*anyopaque, kind: c_int) c_int {
    if (m) |p| {
        const mp: *PthreadMutex = @ptrCast(@alignCast(p));
        mp.kind = kind;
    }
    return 0;
}

pub export fn pthread_mutexattr_init(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_mutexattr_destroy(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_mutexattr_settype(_: ?*anyopaque, _: c_int) c_int {
    return 0;
}

// ── pthread_key (TLS) ──────────────────────────────────────────────────

const MAX_PTHREAD_KEYS = 16;

const PthreadKey = extern struct {
    used: bool = false,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

var pthread_keys: [MAX_PTHREAD_KEYS]PthreadKey = [_]PthreadKey{.{}} ** MAX_PTHREAD_KEYS;

pub export fn pthread_key_create(key_out: ?*usize, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int {
    for (0..MAX_PTHREAD_KEYS) |i| {
        if (!pthread_keys[i].used) {
            pthread_keys[i] = .{ .used = true, .destructor = destructor };
            if (key_out) |out| out.* = i;
            return 0;
        }
    }
    return 11; // EAGAIN
}

pub export fn pthread_key_delete(key: usize) c_int {
    if (key >= MAX_PTHREAD_KEYS) return 22; // EINVAL
    pthread_keys[key] = .{};
    return 0;
}

pub export fn pthread_getspecific(_: usize) ?*anyopaque {
    // Simplified: in this minimal lib, TLS is not fully per-thread yet.
    return null;
}

pub export fn pthread_setspecific(_: usize, _: ?*const anyopaque) c_int {
    return 0;
}

// ── pthread_once ───────────────────────────────────────────────────────

pub export fn pthread_once(predicate: *c_int, init_fn: *const fn () callconv(.c) void) c_int {
    if (@atomicLoad(c_int, predicate, .acquire) == 0) {
        init_fn();
        @atomicStore(c_int, predicate, 1, .release);
    }
    return 0;
}

const PthreadCond = extern struct {
    value: u32 = 0,
};

pub export fn pthread_cond_init(cond: ?*anyopaque, _: ?*const anyopaque) c_int {
    if (cond) |p| {
        const c: *PthreadCond = @ptrCast(@alignCast(p));
        c.* = .{};
    }
    return 0;
}

pub export fn pthread_cond_destroy(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_cond_wait(cond: ?*anyopaque, mutex: ?*anyopaque) c_int {
    _ = cond;
    _ = mutex;
    return 0;
}

pub export fn pthread_cond_signal(cond: ?*anyopaque) c_int {
    if (cond) |p| {
        const c: *PthreadCond = @ptrCast(@alignCast(p));
        c.value +%= 1;
    }
    return 0;
}

pub export fn pthread_cond_broadcast(cond: ?*anyopaque) c_int {
    return pthread_cond_signal(cond);
}

pub export fn pthread_cond_timedwait_relative_np(_: ?*anyopaque, _: ?*anyopaque, _: ?*const anyopaque) c_int {
    return 0;
}

pub export fn pthread_condattr_init(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_condattr_destroy(_: ?*anyopaque) c_int {
    return 0;
}

// ── pthread_rwlock ─────────────────────────────────────────────────────

const PthreadRwlock = extern struct {
    readers: u32 = 0,
    writer_locked: u32 = 0,
};

pub export fn pthread_rwlock_init(_: ?*anyopaque, _: ?*const anyopaque) c_int {
    return 0;
}

pub export fn pthread_rwlock_destroy(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_rwlock_rdlock(lock: ?*anyopaque) c_int {
    if (lock) |p| {
        const rw: *PthreadRwlock = @ptrCast(@alignCast(p));
        while (@atomicLoad(u32, &rw.writer_locked, .acquire) != 0) {}
        _ = @atomicRmw(u32, &rw.readers, .Add, 1, .acq_rel);
    }
    return 0;
}

pub export fn pthread_rwlock_wrlock(lock: ?*anyopaque) c_int {
    if (lock) |p| {
        const rw: *PthreadRwlock = @ptrCast(@alignCast(p));
        while (@cmpxchgStrong(u32, &rw.writer_locked, 0, 1, .acquire, .monotonic) != null) {}
        while (@atomicLoad(u32, &rw.readers, .acquire) != 0) {}
    }
    return 0;
}

pub export fn pthread_rwlock_tryrdlock(lock: ?*anyopaque) c_int {
    if (lock) |p| {
        const rw: *PthreadRwlock = @ptrCast(@alignCast(p));
        if (@atomicLoad(u32, &rw.writer_locked, .acquire) != 0) return 16; // EBUSY
        _ = @atomicRmw(u32, &rw.readers, .Add, 1, .acq_rel);
    }
    return 0;
}

pub export fn pthread_rwlock_trywrlock(lock: ?*anyopaque) c_int {
    if (lock) |p| {
        const rw: *PthreadRwlock = @ptrCast(@alignCast(p));
        if (@cmpxchgStrong(u32, &rw.writer_locked, 0, 1, .acquire, .monotonic) != null) return 16;
        if (@atomicLoad(u32, &rw.readers, .acquire) != 0) {
            @atomicStore(u32, &rw.writer_locked, 0, .release);
            return 16;
        }
    }
    return 0;
}

pub export fn pthread_rwlock_unlock(lock: ?*anyopaque) c_int {
    if (lock) |p| {
        const rw: *PthreadRwlock = @ptrCast(@alignCast(p));
        if (@atomicLoad(u32, &rw.writer_locked, .acquire) != 0) {
            @atomicStore(u32, &rw.writer_locked, 0, .release);
        } else {
            _ = @atomicRmw(u32, &rw.readers, .Sub, 1, .acq_rel);
        }
    }
    return 0;
}

pub export fn pthread_rwlock_init_recursive_np(_: ?*anyopaque, _: ?*const anyopaque) c_int {
    return 0;
}

pub export fn pthread_rwlockattr_init(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn pthread_rwlockattr_destroy(_: ?*anyopaque) c_int {
    return 0;
}

// ── __ulock_wait / __ulock_wake ────────────────────────────────────────

pub export fn __ulock_wait2(operation: u32, addr: ?*anyopaque, value: u64, timeout: u64, value2: u64) c_int {
    const p = addr orelse return -C.EINVAL;
    const ret = C.darwinSyscall5(C.SYS_ulock_wait2, operation, @intFromPtr(p), value, timeout, value2);
    if (ret == C.usize_max - 34) return 0; // -EAGAIN: value changed before sleeping
    return @intCast(@as(isize, @bitCast(ret)));
}

pub export fn __ulock_wake(operation: u32, addr: ?*anyopaque, wake_value: u64) c_int {
    const p = addr orelse return -C.EINVAL;
    const ret = C.darwinSyscall3(C.SYS_ulock_wake, operation, @intFromPtr(p), wake_value);
    return @intCast(@as(isize, @bitCast(ret)));
}

pub export fn __ulock_wait(operation: u32, addr: ?*anyopaque, value: u32, timeout: u32) c_int {
    return __ulock_wait2(operation, addr, value, timeout, 0);
}

// ── pthread miscellaneous ──────────────────────────────────────────────

pub export fn pthread_getugid_np(tid: ?*anyopaque, uid: *u32, gid: *u32) c_int {
    _ = tid;
    uid.* = 0;
    gid.* = 0;
    return 0;
}

pub export fn pthread_is_threaded_np() c_int {
    return 0;
}

pub export fn pthread_mach_thread_np(thread: ?*anyopaque) u32 {
    _ = thread;
    // Return the mach thread ID of the current thread
    // For now, return pthread_self() as a u32 approximation
    return @intCast(currentThreadId());
}
