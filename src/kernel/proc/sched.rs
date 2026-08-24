//! SMP-safe round-robin scheduler.

use crate::arch::aarch64::context::Frame;
use crate::arch::aarch64::pac;
use crate::drivers::timer;
use crate::mm::mmu::{Region, Table};
use crate::mm::vmm::Vmm;
use crate::proc::task::{Process, Task};
use crate::proc::thread;
use crate::smp::MAX_CPUS;
use spin::Mutex;

pub const MAX_TASKS: usize = 32;

pub const NO_ULOCK_WAIT: u64 = 0;
pub const NO_SLEEP_WAIT: u64 = 0;
pub const NO_FD_WAIT: u64 = !0u64;

pub struct Slot {
    pub task: Option<Task>,
    pub alive: bool,
    pub owner_core: u64,
    pub ulock_addr: u64,
    pub sleep_until_ms: u64,
    pub fd_wait: u64,
}

impl Slot {
    pub const fn empty() -> Self {
        Self {
            task: None,
            alive: false,
            owner_core: 0,
            ulock_addr: NO_ULOCK_WAIT,
            sleep_until_ms: NO_SLEEP_WAIT,
            fd_wait: NO_FD_WAIT,
        }
    }
}

struct SchedState {
    slots: [Slot; MAX_TASKS],
    count: usize,
    running: [Option<usize>; MAX_CPUS as usize],
}

unsafe impl Send for SchedState {}
unsafe impl Sync for SchedState {}
static SCHED: Mutex<SchedState> = Mutex::new(SchedState {
    slots: [const { Slot::empty() }; MAX_TASKS],
    count: 0,
    running: [None; MAX_CPUS as usize],
});

pub fn spawn(user_regions: &[Region], entry: u64, stack_top: u64) -> usize {
    let mut sched = SCHED.lock();
    if sched.count >= MAX_TASKS {
        panic!("sched: out of task slots");
    }
    let idx = sched.count;
    let mut task = Task::create(user_regions, entry, stack_top);
    task.init_process();
    task.init_mach_ports();

    sched.slots[idx] = Slot {
        task: Some(task),
        alive: true,
        owner_core: (idx as u64) % MAX_CPUS,
        ulock_addr: NO_ULOCK_WAIT,
        sleep_until_ms: NO_SLEEP_WAIT,
        fd_wait: NO_FD_WAIT,
    };
    sched.count += 1;
    idx
}

pub fn register_bsd_thread(core_id: u64, thread_start: u64, workqueue_start: u64) -> bool {
    let mut sched = SCHED.lock();
    let Some(cur) = sched.running[core_id as usize] else {
        return false;
    };
    if let Some(task) = &mut sched.slots[cur].task {
        unsafe {
            (*task.process).bsdthread_start = thread_start;
            (*task.process).bsdthread_wqstart = workqueue_start;
        }
    }
    true
}

pub fn create_bsd_thread(
    core_id: u64,
    start_routine: u64,
    arg: u64,
    stack_top: u64,
    pthread: u64,
) -> Option<u64> {
    let mut sched = SCHED.lock();
    let parent_idx = sched.running[core_id as usize]?;
    let parent_task = sched.slots[parent_idx].task.as_ref()?;
    let thread_start = unsafe { (*parent_task.process).bsdthread_start };
    if thread_start == 0 || sched.count >= MAX_TASKS {
        return None;
    }

    let idx = sched.count;
    let mut task = Task::create_thread_like(parent_task, thread_start, stack_top, pthread);
    task.frame.x[1] = start_routine;
    task.frame.x[2] = arg;
    task.init_mach_ports();

    sched.slots[idx] = Slot {
        task: Some(task),
        alive: true,
        owner_core: core_id,
        ulock_addr: NO_ULOCK_WAIT,
        sleep_until_ms: NO_SLEEP_WAIT,
        fd_wait: NO_FD_WAIT,
    };
    sched.count += 1;
    Some((idx as u64) + 1)
}

pub fn block_current_on_ulock(core_id: u64, frame: &mut Frame, addr: u64) -> bool {
    let mut sched = SCHED.lock();
    let Some(cur) = sched.running[core_id as usize] else {
        return false;
    };

    if let Some(next) = next_alive_for_core(&sched, core_id, cur) {
        frame.x[0] = 0;
        if let Some(task) = &mut sched.slots[cur].task {
            task.frame = *frame;
            task.frame.x[0] = 0;
        }
        sched.slots[cur].ulock_addr = addr;
        sched.slots[cur].alive = false;
        restore(&mut sched, frame, core_id, next);
        return true;
    }

    sched.slots[cur].ulock_addr = addr;
    drop(sched);

    loop {
        crate::arch::aarch64::cpu::wfe();
        let sched = SCHED.lock();
        if sched.slots[cur].ulock_addr == NO_ULOCK_WAIT {
            frame.x[0] = 0;
            return true;
        }
    }
}

pub fn block_current_on_ulock_until(
    core_id: u64,
    frame: &mut Frame,
    addr: u64,
    deadline_ms: u64,
) -> bool {
    let mut sched = SCHED.lock();
    let Some(cur) = sched.running[core_id as usize] else {
        return false;
    };

    wake_expired_sleepers_locked(&mut sched);
    if deadline_ms <= timer::now_ms() {
        frame.x[0] = 0;
        return true;
    }

    if let Some(next) = next_alive_for_core(&sched, core_id, cur) {
        frame.x[0] = 0;
        if let Some(task) = &mut sched.slots[cur].task {
            task.frame = *frame;
            task.frame.x[0] = 0;
        }
        sched.slots[cur].ulock_addr = addr;
        sched.slots[cur].sleep_until_ms = deadline_ms;
        sched.slots[cur].alive = false;
        restore(&mut sched, frame, core_id, next);
        return true;
    }

    sched.slots[cur].ulock_addr = addr;
    drop(sched);

    loop {
        crate::arch::aarch64::cpu::wfe();
        let mut sched = SCHED.lock();
        if sched.slots[cur].ulock_addr == NO_ULOCK_WAIT {
            frame.x[0] = 0;
            return true;
        }
        if timer::now_ms() >= deadline_ms {
            sched.slots[cur].ulock_addr = NO_ULOCK_WAIT;
            frame.x[0] = 0;
            return true;
        }
    }
}

pub fn block_current_until(core_id: u64, frame: &mut Frame, deadline_ms: u64) -> bool {
    let mut sched = SCHED.lock();
    let Some(cur) = sched.running[core_id as usize] else {
        return false;
    };

    wake_expired_sleepers_locked(&mut sched);
    if deadline_ms <= timer::now_ms() {
        frame.x[0] = 0;
        return true;
    }

    if let Some(next) = next_alive_for_core(&sched, core_id, cur) {
        frame.x[0] = 0;
        if let Some(task) = &mut sched.slots[cur].task {
            task.frame = *frame;
            task.frame.x[0] = 0;
        }
        sched.slots[cur].sleep_until_ms = deadline_ms;
        sched.slots[cur].alive = false;
        restore(&mut sched, frame, core_id, next);
        return true;
    }

    drop(sched);
    loop {
        crate::arch::aarch64::cpu::wfe();
        if timer::now_ms() >= deadline_ms {
            frame.x[0] = 0;
            return true;
        }
    }
}

pub fn wake_ulock(addr: u64, max_count: u64) -> u64 {
    let mut sched = SCHED.lock();
    let mut woken = 0u64;
    let count = sched.count;
    for slot in sched.slots[..count].iter_mut() {
        if slot.ulock_addr != addr || (max_count != 0 && woken >= max_count) {
            continue;
        }
        slot.ulock_addr = NO_ULOCK_WAIT;
        slot.sleep_until_ms = NO_SLEEP_WAIT;
        slot.alive = true;
        woken += 1;
    }
    woken
}

pub fn block_current_on_fd(_core_id: u64, _frame: &mut Frame, _fd: u64) -> bool {
    crate::arch::aarch64::cpu::wfe();
    true
}

pub fn wake_fd(fd: u64) -> u64 {
    let mut sched = SCHED.lock();
    let mut woken = 0u64;
    let count = sched.count;
    for slot in sched.slots[..count].iter_mut() {
        if slot.fd_wait != fd {
            continue;
        }
        slot.fd_wait = NO_FD_WAIT;
        slot.alive = true;
        woken += 1;
    }
    woken
}

pub fn signal_thread(thread_id: u64) -> bool {
    if thread_id == 0 {
        return false;
    }
    let mut sched = SCHED.lock();
    let idx = (thread_id - 1) as usize;
    if idx >= sched.count {
        return false;
    }
    wake_slot_locked(&mut sched, idx);
    true
}

fn wake_slot_locked(sched: &mut SchedState, idx: usize) {
    sched.slots[idx].ulock_addr = NO_ULOCK_WAIT;
    sched.slots[idx].sleep_until_ms = NO_SLEEP_WAIT;
    sched.slots[idx].fd_wait = NO_FD_WAIT;
    if let Some(task) = &mut sched.slots[idx].task {
        task.frame.x[0] = (-4i64) as u64; // EINTR
    }
    sched.slots[idx].alive = true;
}

pub fn wake_process_for_signal(proc: *mut Process) {
    let mut sched = SCHED.lock();
    let count = sched.count;
    for i in 0..count {
        if let Some(task) = &sched.slots[i].task {
            if task.process == proc {
                wake_slot_locked(&mut sched, i);
            }
        }
    }
}

pub fn wake_task_for_signal(task_ptr: *mut Task) {
    let mut sched = SCHED.lock();
    let count = sched.count;
    for i in 0..count {
        if let Some(task) = &mut sched.slots[i].task {
            if (task as *mut Task) == task_ptr {
                wake_slot_locked(&mut sched, i);
                return;
            }
        }
    }
}

pub fn task_by_thread_id(thread_id: u64) -> Option<*mut Task> {
    if thread_id == 0 {
        return None;
    }
    let mut sched = SCHED.lock();
    let idx = (thread_id - 1) as usize;
    if idx >= sched.count {
        return None;
    }
    sched.slots[idx].task.as_mut().map(|t| t as *mut Task)
}

pub fn current_task(core_id: u64) -> &'static mut Task {
    try_current_task(core_id).expect("sched: no running task on core")
}

pub fn try_current_task(core_id: u64) -> Option<&'static mut Task> {
    let mut sched = SCHED.lock();
    let cur = sched.running[core_id as usize]?;
    sched.slots[cur]
        .task
        .as_mut()
        .map(|t| unsafe { &mut *(t as *mut Task) })
}

pub fn current_vmm(core_id: u64) -> &'static mut Vmm {
    let task = current_task(core_id);
    unsafe { &mut (*task.process).vmm }
}

pub fn current_process(core_id: u64) -> &'static mut Process {
    let task = current_task(core_id);
    unsafe { &mut *task.process }
}

pub fn current_thread_id(core_id: u64) -> u64 {
    let sched = SCHED.lock();
    sched.running[core_id as usize]
        .map(|idx| (idx as u64) + 1)
        .unwrap_or(0)
}

pub fn task_table(idx: usize) -> &'static mut Table {
    let sched = SCHED.lock();
    let table_ptr = sched.slots[idx].task.as_ref().unwrap().ttbr0;
    unsafe { &mut *table_ptr }
}

pub fn set_pac_enforcement(idx: usize, enforce: bool) {
    let mut sched = SCHED.lock();
    if let Some(task) = &mut sched.slots[idx].task {
        task.pac_enforce = enforce;
    }
}

pub fn set_initial_register(idx: usize, reg: usize, value: u64) {
    let mut sched = SCHED.lock();
    if let Some(task) = &mut sched.slots[idx].task {
        task.frame.x[reg] = value;
    }
}

pub fn exit_current_task(core_id: u64, frame: &mut Frame) {
    let mut sched = SCHED.lock();
    let Some(cur) = sched.running[core_id as usize] else {
        return;
    };

    sched.slots[cur].alive = false;
    if let Some(next) = next_alive_for_core(&sched, core_id, cur) {
        restore(&mut sched, frame, core_id, next);
        return;
    }

    sched.running[core_id as usize] = None;
    drop(sched);

    loop {
        crate::arch::aarch64::cpu::wfe();
    }
}

pub fn tick(core_id: u64, frame: &mut Frame) {
    let mut sched = SCHED.lock();
    wake_expired_sleepers_locked(&mut sched);
    let Some(cur) = sched.running[core_id as usize] else {
        return;
    };

    let Some(next) = next_alive_for_core(&sched, core_id, cur) else {
        return;
    };

    if cur == next {
        return;
    }

    if let Some(task) = &mut sched.slots[cur].task {
        task.frame = *frame;
    }
    restore(&mut sched, frame, core_id, next);
}

pub fn run_core(core_id: u64) -> ! {
    let mut sched = SCHED.lock();
    for idx in 0..sched.count {
        if sched.slots[idx].owner_core == core_id && sched.slots[idx].alive {
            sched.running[core_id as usize] = Some(idx);
            let task = sched.slots[idx].task.as_ref().unwrap();
            pac::set_enforcement(task.pac_enforce);
            pac::load_keys(&task.pac_keys);
            let task_ptr = task as *const Task;
            drop(sched);
            unsafe {
                thread::enter(&*task_ptr);
            }
        }
    }
    sched.running[core_id as usize] = None;
    drop(sched);

    loop {
        crate::arch::aarch64::cpu::wfe();
    }
}

fn restore(sched: &mut SchedState, frame: &mut Frame, core_id: u64, next_idx: usize) {
    sched.running[core_id as usize] = Some(next_idx);
    let task = sched.slots[next_idx].task.as_ref().unwrap();
    *frame = task.frame;
    pac::set_enforcement(task.pac_enforce);
    pac::load_keys(&task.pac_keys);

    let ttbr0 = task.ttbr0 as u64;
    unsafe {
        core::arch::asm!(
            "msr ttbr0_el1, {ttbr0}",
            "isb",
            "tlbi vmalle1",
            "dsb ish",
            "isb",
            ttbr0 = in(reg) ttbr0,
            options(nomem, nostack)
        );
    }
}

fn next_alive_for_core(sched: &SchedState, core_id: u64, cur_idx: usize) -> Option<usize> {
    for step in 1..=sched.count {
        let idx = (cur_idx + step) % sched.count;
        if sched.slots[idx].owner_core == core_id && sched.slots[idx].alive {
            return Some(idx);
        }
    }
    None
}

fn wake_expired_sleepers_locked(sched: &mut SchedState) {
    let now = timer::now_ms();
    let count = sched.count;
    for slot in sched.slots[..count].iter_mut() {
        if slot.sleep_until_ms != NO_SLEEP_WAIT && now >= slot.sleep_until_ms {
            slot.sleep_until_ms = NO_SLEEP_WAIT;
            slot.ulock_addr = NO_ULOCK_WAIT;
            slot.alive = true;
        }
    }
}
