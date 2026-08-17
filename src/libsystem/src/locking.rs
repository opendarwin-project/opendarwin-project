//! Locking primitives: os_unfair_lock, OSSpinLock, OSAtomic.

use core::ffi::c_void;
use core::sync::atomic::{AtomicI32, AtomicI64, AtomicU32, AtomicUsize, Ordering};

use crate::pthread::{__ulock_wait2, __ulock_wake};

// ── os_unfair_lock ─────────────────────────────────────────────────────

#[repr(C)]
pub struct os_unfair_lock_s {
    pub _os_unfair_lock_opaque: u32,
}

pub type os_unfair_lock = os_unfair_lock_s;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn os_unfair_lock_lock(lock: *mut os_unfair_lock) {
    if !lock.is_null() {
        let lock_atomic = &*(&raw mut (*lock)._os_unfair_lock_opaque as *mut AtomicU32);
        while lock_atomic
            .compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            let _ = __ulock_wait2(
                0x01,
                &raw mut (*lock)._os_unfair_lock_opaque as *mut c_void,
                0,
                0,
                0,
            );
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn os_unfair_lock_trylock(lock: *mut os_unfair_lock) -> bool {
    if !lock.is_null() {
        let lock_atomic = &*(&raw mut (*lock)._os_unfair_lock_opaque as *mut AtomicU32);
        lock_atomic
            .compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
            .is_ok()
    } else {
        false
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn os_unfair_lock_unlock(lock: *mut os_unfair_lock) {
    if !lock.is_null() {
        let lock_atomic = &*(&raw mut (*lock)._os_unfair_lock_opaque as *mut AtomicU32);
        lock_atomic.store(0, Ordering::Release);
        let _ = __ulock_wake(
            0x01,
            &raw mut (*lock)._os_unfair_lock_opaque as *mut c_void,
            0,
        );
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn os_unfair_lock_assert_held(_lock: *const os_unfair_lock) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn os_unfair_lock_assert_not_held(_lock: *const os_unfair_lock) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn os_unfair_lock_trylock_assert_owner(lock: *mut os_unfair_lock) -> bool {
    os_unfair_lock_trylock(lock)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn os_unfair_lock_trylock_assert_not_owner(
    lock: *mut os_unfair_lock,
) -> bool {
    os_unfair_lock_trylock(lock)
}

// ── OSSpinLock (deprecated but still referenced by some CF paths) ──────

pub type OSSpinLock = u32;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSSpinLockLock(lock: *mut OSSpinLock) {
    if !lock.is_null() {
        os_unfair_lock_lock(lock as *mut os_unfair_lock);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSSpinLockTry(lock: *mut OSSpinLock) -> bool {
    if !lock.is_null() {
        os_unfair_lock_trylock(lock as *mut os_unfair_lock)
    } else {
        false
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSSpinLockUnlock(lock: *mut OSSpinLock) {
    if !lock.is_null() {
        os_unfair_lock_unlock(lock as *mut os_unfair_lock);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSSpinLockLock_DEPRECATED(lock: *mut OSSpinLock) {
    OSSpinLockLock(lock);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSSpinLockTry_DEPRECATED(lock: *mut OSSpinLock) -> bool {
    OSSpinLockTry(lock)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSSpinLockUnlock_DEPRECATED(lock: *mut OSSpinLock) {
    OSSpinLockUnlock(lock);
}

// ── OSAtomic (legacy atomics) ─────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicIncrement32(barrier: *mut i32) -> i32 {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicI32);
        atomic.fetch_add(1, Ordering::SeqCst) + 1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicDecrement32(barrier: *mut i32) -> i32 {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicI32);
        atomic.fetch_sub(1, Ordering::SeqCst) - 1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicIncrement32Barrier(barrier: *mut i32) -> i32 {
    OSAtomicIncrement32(barrier)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicDecrement32Barrier(barrier: *mut i32) -> i32 {
    OSAtomicDecrement32(barrier)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicIncrement64(barrier: *mut i64) -> i64 {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicI64);
        atomic.fetch_add(1, Ordering::SeqCst) + 1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicDecrement64(barrier: *mut i64) -> i64 {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicI64);
        atomic.fetch_sub(1, Ordering::SeqCst) - 1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicAdd32(val: i32, barrier: *mut i32) -> i32 {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicI32);
        atomic.fetch_add(val, Ordering::SeqCst) + val
    } else {
        val
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicAdd32Barrier(val: i32, barrier: *mut i32) -> i32 {
    OSAtomicAdd32(val, barrier)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicCompareAndSwap32(
    oldval: i32,
    newval: i32,
    barrier: *mut i32,
) -> bool {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicI32);
        atomic
            .compare_exchange(oldval, newval, Ordering::SeqCst, Ordering::Relaxed)
            .is_ok()
    } else {
        false
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicCompareAndSwap32Barrier(
    oldval: i32,
    newval: i32,
    barrier: *mut i32,
) -> bool {
    OSAtomicCompareAndSwap32(oldval, newval, barrier)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicCompareAndSwapPtr(
    oldval: *mut c_void,
    newval: *mut c_void,
    barrier: *mut *mut c_void,
) -> bool {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicUsize);
        atomic
            .compare_exchange(
                oldval as usize,
                newval as usize,
                Ordering::SeqCst,
                Ordering::Relaxed,
            )
            .is_ok()
    } else {
        false
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicCompareAndSwapPtrBarrier(
    oldval: *mut c_void,
    newval: *mut c_void,
    barrier: *mut *mut c_void,
) -> bool {
    OSAtomicCompareAndSwapPtr(oldval, newval, barrier)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicCompareAndSwap64(
    oldval: i64,
    newval: i64,
    barrier: *mut i64,
) -> bool {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicI64);
        atomic
            .compare_exchange(oldval, newval, Ordering::SeqCst, Ordering::Relaxed)
            .is_ok()
    } else {
        false
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicCompareAndSwap64Barrier(
    oldval: i64,
    newval: i64,
    barrier: *mut i64,
) -> bool {
    OSAtomicCompareAndSwap64(oldval, newval, barrier)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicAnd32Orig(mask: u32, barrier: *mut u32) -> u32 {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicU32);
        atomic.fetch_and(mask, Ordering::SeqCst)
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicAnd32OrigBarrier(mask: u32, barrier: *mut u32) -> u32 {
    OSAtomicAnd32Orig(mask, barrier)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicOr32Orig(mask: u32, barrier: *mut u32) -> u32 {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicU32);
        atomic.fetch_or(mask, Ordering::SeqCst)
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicOr32OrigBarrier(mask: u32, barrier: *mut u32) -> u32 {
    OSAtomicOr32Orig(mask, barrier)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicXor32Orig(mask: u32, barrier: *mut u32) -> u32 {
    if !barrier.is_null() {
        let atomic = &*(barrier as *mut AtomicU32);
        atomic.fetch_xor(mask, Ordering::SeqCst)
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn OSAtomicXor32OrigBarrier(mask: u32, barrier: *mut u32) -> u32 {
    OSAtomicXor32Orig(mask, barrier)
}
