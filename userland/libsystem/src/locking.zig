//! Locking primitives: os_unfair_lock, OSSpinLock, OSAtomic.

const common = @import("common.zig");
const C = common;

// ── os_unfair_lock ─────────────────────────────────────────────────────

pub const os_unfair_lock_s = extern struct {
    _os_unfair_lock_opaque: u32 = 0,
};

pub const os_unfair_lock = os_unfair_lock_s;

pub export fn os_unfair_lock_lock(lock: ?*os_unfair_lock) void {
    if (lock) |p| {
        while (@cmpxchgStrong(u32, &p._os_unfair_lock_opaque, 0, 1, .acquire, .monotonic) != null) {
            _ = __ulock_wait2(0x01, @ptrCast(&p._os_unfair_lock_opaque), 0, 0, 0);
        }
    }
}

pub export fn os_unfair_lock_trylock(lock: ?*os_unfair_lock) bool {
    if (lock) |p| {
        return @cmpxchgStrong(u32, &p._os_unfair_lock_opaque, 0, 1, .acquire, .monotonic) == null;
    }
    return false;
}

pub export fn os_unfair_lock_unlock(lock: ?*os_unfair_lock) void {
    if (lock) |p| {
        @atomicStore(u32, &p._os_unfair_lock_opaque, 0, .release);
        _ = __ulock_wake(0x01, @ptrCast(&p._os_unfair_lock_opaque), 0);
    }
}

pub export fn os_unfair_lock_assert_held(lock: ?*const os_unfair_lock) void {
    _ = lock;
}

pub export fn os_unfair_lock_assert_not_held(lock: ?*const os_unfair_lock) void {
    _ = lock;
}

pub export fn os_unfair_lock_trylock_assert_owner(lock: ?*os_unfair_lock) bool {
    return os_unfair_lock_trylock(lock);
}

pub export fn os_unfair_lock_trylock_assert_not_owner(lock: ?*os_unfair_lock) bool {
    return os_unfair_lock_trylock(lock);
}

// ── OSSpinLock (deprecated but still referenced by some CF paths) ──────

pub const OSSpinLock = u32;

pub export fn OSSpinLockLock(lock: ?*OSSpinLock) void {
    if (lock) |p| {
        os_unfair_lock_lock(@ptrCast(p));
    }
}

pub export fn OSSpinLockTry(lock: ?*OSSpinLock) bool {
    if (lock) |p| {
        return os_unfair_lock_trylock(@ptrCast(p));
    }
    return false;
}

pub export fn OSSpinLockUnlock(lock: ?*OSSpinLock) void {
    if (lock) |p| {
        os_unfair_lock_unlock(@ptrCast(p));
    }
}

pub export fn OSSpinLockLock_DEPRECATED(lock: ?*OSSpinLock) void {
    OSSpinLockLock(lock);
}

pub export fn OSSpinLockTry_DEPRECATED(lock: ?*OSSpinLock) bool {
    return OSSpinLockTry(lock);
}

pub export fn OSSpinLockUnlock_DEPRECATED(lock: ?*OSSpinLock) void {
    OSSpinLockUnlock(lock);
}

// ── OSAtomic (legacy atomics) ─────────────────────────────────────────

pub export fn OSAtomicIncrement32(barrier: ?*volatile i32) i32 {
    if (barrier) |p| {
        return @atomicRmw(i32, p, .Add, 1, .seq_cst) + 1;
    }
    return 0;
}

pub export fn OSAtomicDecrement32(barrier: ?*volatile i32) i32 {
    if (barrier) |p| {
        return @atomicRmw(i32, p, .Sub, 1, .seq_cst) - 1;
    }
    return 0;
}

pub export fn OSAtomicIncrement32Barrier(barrier: ?*volatile i32) i32 {
    return OSAtomicIncrement32(barrier);
}

pub export fn OSAtomicDecrement32Barrier(barrier: ?*volatile i32) i32 {
    return OSAtomicDecrement32(barrier);
}

pub export fn OSAtomicIncrement64(barrier: ?*volatile i64) i64 {
    if (barrier) |p| {
        return @atomicRmw(i64, p, .Add, 1, .seq_cst) + 1;
    }
    return 0;
}

pub export fn OSAtomicDecrement64(barrier: ?*volatile i64) i64 {
    if (barrier) |p| {
        return @atomicRmw(i64, p, .Sub, 1, .seq_cst) - 1;
    }
    return 0;
}

pub export fn OSAtomicAdd32(val: i32, barrier: ?*volatile i32) i32 {
    if (barrier) |p| {
        return @atomicRmw(i32, p, .Add, val, .seq_cst) + val;
    }
    return val;
}

pub export fn OSAtomicAdd32Barrier(val: i32, barrier: ?*volatile i32) i32 {
    return OSAtomicAdd32(val, barrier);
}

pub export fn OSAtomicCompareAndSwap32(oldval: i32, newval: i32, barrier: ?*volatile i32) bool {
    if (barrier) |p| {
        return @cmpxchgStrong(i32, p, oldval, newval, .seq_cst, .monotonic) == null;
    }
    return false;
}

pub export fn OSAtomicCompareAndSwap32Barrier(oldval: i32, newval: i32, barrier: ?*volatile i32) bool {
    return OSAtomicCompareAndSwap32(oldval, newval, barrier);
}

pub export fn OSAtomicCompareAndSwapPtr(oldval: ?*anyopaque, newval: ?*anyopaque, barrier: ?*volatile ?*anyopaque) bool {
    if (barrier) |p| {
        return @cmpxchgStrong(?*anyopaque, p, oldval, newval, .seq_cst, .monotonic) == null;
    }
    return false;
}

pub export fn OSAtomicCompareAndSwapPtrBarrier(oldval: ?*anyopaque, newval: ?*anyopaque, barrier: ?*volatile ?*anyopaque) bool {
    return OSAtomicCompareAndSwapPtr(oldval, newval, barrier);
}

pub export fn OSAtomicCompareAndSwap64(oldval: i64, newval: i64, barrier: ?*volatile i64) bool {
    if (barrier) |p| {
        return @cmpxchgStrong(i64, p, oldval, newval, .seq_cst, .monotonic) == null;
    }
    return false;
}

pub export fn OSAtomicCompareAndSwap64Barrier(oldval: i64, newval: i64, barrier: ?*volatile i64) bool {
    return OSAtomicCompareAndSwap64(oldval, newval, barrier);
}

pub export fn OSAtomicAnd32Orig(mask: u32, barrier: ?*volatile u32) u32 {
    if (barrier) |p| {
        return @atomicRmw(u32, p, .And, mask, .seq_cst);
    }
    return 0;
}

pub export fn OSAtomicAnd32OrigBarrier(mask: u32, barrier: ?*volatile u32) u32 {
    return OSAtomicAnd32Orig(mask, barrier);
}

pub export fn OSAtomicOr32Orig(mask: u32, barrier: ?*volatile u32) u32 {
    if (barrier) |p| {
        return @atomicRmw(u32, p, .Or, mask, .seq_cst);
    }
    return 0;
}

pub export fn OSAtomicOr32OrigBarrier(mask: u32, barrier: ?*volatile u32) u32 {
    return OSAtomicOr32Orig(mask, barrier);
}

pub export fn OSAtomicXor32Orig(mask: u32, barrier: ?*volatile u32) u32 {
    if (barrier) |p| {
        return @atomicRmw(u32, p, .Xor, mask, .seq_cst);
    }
    return 0;
}

pub export fn OSAtomicXor32OrigBarrier(mask: u32, barrier: ?*volatile u32) u32 {
    return OSAtomicXor32Orig(mask, barrier);
}

// ── re-exports for the futex primitives ────────────────────────────────

const __ulock_wait2 = @import("pthread.zig").__ulock_wait2;
const __ulock_wake = @import("pthread.zig").__ulock_wake;
