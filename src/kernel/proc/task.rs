//! Task and Process structures for Darwin tasks/threads.

use crate::arch::aarch64::context::Frame;
use crate::arch::aarch64::pac::{self, Keys};
use crate::ipc::IpcPort;
use crate::ipc::right;
use crate::ipc::space::IpcSpace;
use crate::ipc::tt;
use crate::ipc::types::{IE_BITS_TYPE_RECEIVE, MACH_PORT_NULL, MachPortNameT};
use crate::mm::mmu::{self, Region, Table};
use crate::mm::vmm::Vmm;
use core::sync::atomic::{AtomicU64, Ordering};

static NEXT_PAC_SEED: AtomicU64 = AtomicU64::new(0x5EED_5EED_5EED_5EED);

pub const NSIG: usize = 32;
pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;
pub const SIGKILL: u32 = 9;
pub const SIGSTOP: u32 = 17;

#[inline(always)]
pub const fn sig_bit(sig: u32) -> u32 {
    1 << (sig - 1)
}

pub const SIGCANTMASK: u32 = sig_bit(SIGKILL) | sig_bit(SIGSTOP);

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SigAction {
    pub handler: u64,
    pub sa_tramp: u64,
    pub sa_mask: u32,
    pub sa_flags: i32,
}

pub struct Process {
    pub vmm: Vmm,
    pub bsdthread_start: u64,
    pub bsdthread_wqstart: u64,
    pub sig_actions: [SigAction; NSIG],
    pub sig_pending: u32,
    pub sig_ignore: u32,
    pub sig_catch: u32,
}

impl Process {
    pub fn new(ttbr0: *mut Table) -> Self {
        Self {
            vmm: Vmm::init(ttbr0),
            bsdthread_start: 0,
            bsdthread_wqstart: 0,
            sig_actions: [SigAction::default(); NSIG],
            sig_pending: 0,
            sig_ignore: 0,
            sig_catch: 0,
        }
    }
}

pub struct Task {
    pub ttbr0: *mut Table,
    pub frame: Frame,
    pub pac_keys: Keys,
    pub ipc_space: IpcSpace,
    pub task_self_name: MachPortNameT,
    pub thread_self_name: MachPortNameT,
    pub reply_port_name: MachPortNameT,
    pub iokit_master_name: MachPortNameT,
    pub owned_process: Process,
    pub process: *mut Process,
    pub pac_enforce: bool,
    pub sig_mask: u32,
    pub sig_pending: u32,
    pub sig_oldmask: u32,
}

impl Task {
    pub fn create(user_regions: &[Region], entry: u64, stack_top: u64) -> Self {
        let mut frame = Frame::default();
        frame.sp_el0 = stack_top;
        frame.elr_el1 = entry;
        frame.spsr_el1 = 0; // EL0t

        let ttbr0 = mmu::new_task_table(user_regions) as *mut Table;
        let seed = NEXT_PAC_SEED.fetch_add(1, Ordering::Relaxed);

        let mut task = Self {
            ttbr0,
            frame,
            pac_keys: pac::derive_keys(seed),
            ipc_space: IpcSpace::new(),
            task_self_name: MACH_PORT_NULL,
            thread_self_name: MACH_PORT_NULL,
            reply_port_name: MACH_PORT_NULL,
            iokit_master_name: MACH_PORT_NULL,
            owned_process: Process::new(ttbr0),
            process: core::ptr::null_mut(),
            pac_enforce: true,
            sig_mask: 0,
            sig_pending: 0,
            sig_oldmask: 0,
        };
        task.ipc_space.init();
        task
    }

    pub fn init_process(&mut self) {
        self.owned_process = Process::new(self.ttbr0);
        self.process = core::ptr::addr_of_mut!(self.owned_process);
    }

    pub fn create_thread_like(parent: &Task, entry: u64, stack_top: u64, arg: u64) -> Self {
        let mut frame = Frame::default();
        frame.sp_el0 = stack_top;
        frame.elr_el1 = entry;
        frame.spsr_el1 = 0;
        frame.x[0] = arg;

        let mut task = Self {
            ttbr0: parent.ttbr0,
            frame,
            pac_keys: parent.pac_keys,
            ipc_space: IpcSpace::new(),
            task_self_name: MACH_PORT_NULL,
            thread_self_name: MACH_PORT_NULL,
            reply_port_name: MACH_PORT_NULL,
            iokit_master_name: MACH_PORT_NULL,
            owned_process: Process::new(parent.ttbr0),
            process: parent.process,
            pac_enforce: parent.pac_enforce,
            sig_mask: 0,
            sig_pending: 0,
            sig_oldmask: 0,
        };
        task.ipc_space.init();
        task
    }

    pub fn init_mach_ports(&mut self) {
        let task_ptr = self as *mut Task as *mut u8;
        tt::task_self(&mut self.ipc_space, task_ptr, &mut self.task_self_name);
        tt::thread_self(&mut self.ipc_space, task_ptr, &mut self.thread_self_name);

        let port = IpcPort::alloc();
        unsafe {
            (*port).ip_receiver = core::ptr::addr_of_mut!(self.ipc_space);
        }
        let result = right::alloc(&mut self.ipc_space, port, IE_BITS_TYPE_RECEIVE);
        self.reply_port_name = result.name;
        unsafe {
            (*port).ip_receiver_name = self.reply_port_name;
        }
    }
}
