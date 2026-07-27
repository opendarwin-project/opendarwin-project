pub const SYS_exit: u16 = 1;
pub const SYS_fork: u16 = 2;
pub const SYS_read: u16 = 3;
pub const SYS_write: u16 = 4;
pub const SYS_open: u16 = 5;
pub const SYS_close: u16 = 6;
pub const SYS_getpid: u16 = 20;
pub const SYS_kill: u16 = 37;
pub const SYS_sigaction: u16 = 46;
pub const SYS_sigprocmask: u16 = 48;
pub const SYS_sigreturn: u16 = 184;
pub const SYS_fstat: u16 = 62;
pub const SYS_socket: u16 = 97;
pub const SYS_getsockname: u16 = 150;
pub const SYS_munmap: u16 = 73;
pub const SYS_mprotect: u16 = 74;
pub const SYS_mmap: u16 = 197;
pub const SYS_socketpair: u16 = 135;

// XNU BSD pthread ABI: bsd/kern/syscalls.master.
pub const SYS_pthread_kill: u16 = 328;
pub const SYS___semwait_signal: u16 = 334;
pub const SYS_bsdthread_create: u16 = 360;
pub const SYS_bsdthread_terminate: u16 = 361;
pub const SYS_bsdthread_register: u16 = 366;
pub const SYS_thread_selfid: u16 = 372;
pub const SYS___semwait_signal_nocancel: u16 = 423;

// Darwin ulock ABI. __ulock_wait2 is the modern five-argument variant
// used by Zig's std.Io synchronization primitives.
pub const SYS_ulock_wake: u16 = 516;
pub const SYS_ulock_wait2: u16 = 544;

pub const MACH__kernelrpc_mach_vm_allocate_trap: u16 = 10;
pub const MACH__kernelrpc_mach_vm_map_trap: u16 = 15;
pub const MACH__kernelrpc_mach_port_allocate_trap: u16 = 16;
pub const MACH__kernelrpc_mach_port_deallocate_trap: u16 = 18;

/// XNU mach_trap_table: mach_reply_port is 26 (37 is semaphore_wait_signal_trap).
pub const MACH_mach_reply_port: u16 = 26;
pub const MACH_thread_self_trap: u16 = 27;
pub const MACH_task_self_trap: u16 = 28;
pub const MACH_host_self_trap: u16 = 29;
pub const MACH_mach_msg_trap: u16 = 31;
pub const MACH_mach_msg_overwrite_trap: u16 = 32;
pub const MACH_thread_get_special_reply_port: u16 = 50;

/// XNU reserves traps 100–107 for IOKit. Trap 100 is iokit_user_client_trap
/// (userspace: IOConnectTrap0…6).
pub const MACH_iokit_user_client_trap: u16 = 100;
