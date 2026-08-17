//! XNU BSD and Mach syscall numbers.

pub const SYS_EXIT: u16 = 1;
pub const SYS_FORK: u16 = 2;
pub const SYS_READ: u16 = 3;
pub const SYS_WRITE: u16 = 4;
pub const SYS_OPEN: u16 = 5;
pub const SYS_CLOSE: u16 = 6;
pub const SYS_GETPID: u16 = 20;
pub const SYS_KILL: u16 = 37;
pub const SYS_SIGACTION: u16 = 46;
pub const SYS_SIGPROCMASK: u16 = 48;
pub const SYS_SIGRETURN: u16 = 184;
pub const SYS_STAT: u16 = 38;
pub const SYS_FSTAT: u16 = 62;
pub const SYS_LSEEK: u16 = 199;
pub const SYS_STAT64: u16 = 338;
pub const SYS_FSTAT64: u16 = 339;
pub const SYS_LSTAT64: u16 = 340;
pub const SYS_SOCKET: u16 = 97;
pub const SYS_GETSOCKNAME: u16 = 150;
pub const SYS_MUNMAP: u16 = 73;
pub const SYS_MPROTECT: u16 = 74;
pub const SYS_MMAP: u16 = 197;
pub const SYS_SOCKETPAIR: u16 = 135;

pub const SYS_PTHREAD_KILL: u16 = 328;
pub const SYS___SEMWAIT_SIGNAL: u16 = 334;
pub const SYS_BSDTHREAD_CREATE: u16 = 360;
pub const SYS_BSDTHREAD_TERMINATE: u16 = 361;
pub const SYS_BSDTHREAD_REGISTER: u16 = 366;
pub const SYS_THREAD_SELFID: u16 = 372;
pub const SYS___SEMWAIT_SIGNAL_NOCANCEL: u16 = 423;

pub const SYS_ULOCK_WAKE: u16 = 516;
pub const SYS_ULOCK_WAIT2: u16 = 544;

pub const MACH__KERNELRPC_MACH_VM_ALLOCATE_TRAP: u16 = 10;
pub const MACH__KERNELRPC_MACH_VM_MAP_TRAP: u16 = 15;
pub const MACH__KERNELRPC_MACH_PORT_ALLOCATE_TRAP: u16 = 16;
pub const MACH__KERNELRPC_MACH_PORT_DEALLOCATE_TRAP: u16 = 18;

pub const MACH_MACH_REPLY_PORT: u16 = 26;
pub const MACH_THREAD_SELF_TRAP: u16 = 27;
pub const MACH_TASK_SELF_TRAP: u16 = 28;
pub const MACH_HOST_SELF_TRAP: u16 = 29;
pub const MACH_MACH_MSG_TRAP: u16 = 31;
pub const MACH_MACH_MSG_OVERWRITE_TRAP: u16 = 32;
pub const MACH_THREAD_GET_SPECIAL_REPLY_PORT: u16 = 50;

pub const MACH_IOKIT_USER_CLIENT_TRAP: u16 = 100;
