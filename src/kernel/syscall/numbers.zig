pub const SYS_exit: u16 = 1;
pub const SYS_fork: u16 = 2;
pub const SYS_read: u16 = 3;
pub const SYS_write: u16 = 4;
pub const SYS_open: u16 = 5;
pub const SYS_close: u16 = 6;
pub const SYS_fstat: u16 = 62;
pub const SYS_munmap: u16 = 73;
pub const SYS_mprotect: u16 = 74;
pub const SYS_mmap: u16 = 197;

pub const MACH__kernelrpc_mach_vm_allocate_trap: u16 = 10;
pub const MACH__kernelrpc_mach_vm_map_trap: u16 = 15;
pub const MACH_mach_msg_trap: u16 = 31;
pub const MACH_mach_msg_overwrite_trap: u16 = 32;

pub const MACH_thread_self_trap: u16 = 27;
pub const MACH_task_self_trap: u16 = 28;
pub const MACH_host_self_trap: u16 = 29;
pub const MACH_mach_reply_port: u16 = 37;
