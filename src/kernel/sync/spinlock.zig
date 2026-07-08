//! A minimal atomic-based spinlock for SMP. Not std.Io.Mutex: that type is
//! part of Zig's async I/O framework and needs an `Io` executor to suspend
//! on - there is none in a freestanding kernel. This is a bare
//! test-and-test-and-set lock over hardware atomics (LDXR/STXR or LSE,
//! whatever the target has), with wfe/sev so spinning cores don't just burn
//! cycles/bus bandwidth.

const SpinLock = @This();

locked: bool = false,

pub fn lock(self: *SpinLock) void {
    while (@cmpxchgWeak(bool, &self.locked, false, true, .acquire, .monotonic) != null) {
        asm volatile ("wfe");
    }
}

pub fn unlock(self: *SpinLock) void {
    @atomicStore(bool, &self.locked, false, .release);
    // Wake any cores parked in lock()'s wfe waiting on this lock.
    asm volatile ("dsb ish");
    asm volatile ("sev");
}
