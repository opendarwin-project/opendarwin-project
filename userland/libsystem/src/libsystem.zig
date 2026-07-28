//! Minimal FOSS libSystem/libsystem_c replacement for OpenDarwin userland.
//!
//! This is intentionally tiny: enough symbols for the first simple Darwin
//! Mach-O smoke binaries while the kernel grows real dylib loading support.
//! It must not depend on Apple's libSystem.
//!
//! Modules:
//!   common.zig     — internal helpers (syscall wrappers, errno, stubErr)
//!   basics.zig     — compiler-rt, _exit, exit, abort, __stack_chk_fail
//!   mach.zig       — mach_task_self, mach_vm_map, mmap, munmap
//!   malloc.zig     — malloc, calloc, realloc, free, malloc_size, bzero
//!   string.zig     — strlen, strcmp, memcpy, memmove, memset, qsort, bsearch, strtod
//!   stdio.zig      — write, read, open, close, fprintf, snprintf, etc.
//!   time.zig       — clock_gettime, nanosleep, mach_absolute_time, gettimeofday
//!   pthread.zig    — pthread_create, pthread_mutex_*, pthread_key_*, __ulock_*
//!   locking.zig    — os_unfair_lock, OSSpinLock, OSAtomic
//!   signal.zig     — sigaction, sigprocmask, sigaltstack, __sigtramp
//!   process.zig    — getpid, kill, fork, execve, wait4
//!   tlv.zig        — __tlv_bootstrap, sys_icache_invalidate
//!
//! dyld introspection (_dyld_image_count, dlopen, dlsym, ...) lives in the
//! separate `dyld` package (../dyld/src/dyld.zig), force-linked below so it
//! travels with libSystem.B.dylib as a dependent dylib, mirroring how real
//! macOS reexports /usr/lib/system/libdyld.dylib from libSystem.
//!   socket.zig     — socket, socketpair, connect, getaddrinfo
//!   dispatch.zig   — dispatch_queue, dispatch_async, dispatch_source
//!   sysctl.zig     — sysctlbyname, confstr, sysconf
//!   misc.zig       — getenv, environ, uuid_generate, pow, fmod, atexit, etc.

// Pull all sub-modules into the compilation.  Each module's `pub export fn`
// and `pub export var` declarations become symbols of the shared library.
comptime {
    _ = @import("basics.zig");
    _ = @import("mach.zig");
    _ = @import("malloc.zig");
    _ = @import("string.zig");
    _ = @import("stdio.zig");
    _ = @import("time.zig");
    _ = @import("pthread.zig");
    _ = @import("locking.zig");
    _ = @import("signal.zig");
    _ = @import("process.zig");
    _ = @import("tlv.zig");
    _ = @import("socket.zig");
    _ = @import("dispatch.zig");
    _ = @import("sysctl.zig");
    _ = @import("misc.zig");
    _ = @import("blocks.zig");
    _ = @import("ctype.zig");
    _ = @import("termios.zig");
    _ = @import("resource.zig");
}

// Re-export the common errno as a top-level symbol (some clients reference
// it directly).
pub const errno = &@import("common.zig").errno;
