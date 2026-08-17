//! POSIX threads: pthread_create, pthread_self, pthread_mutex_*, pthread_key_*,
//! pthread_once, pthread_cond_*, pthread_rwlock_*, and the __ulock_* futex primitives.

use core::ffi::{c_int, c_void};
use core::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicUsize, Ordering};

use crate::common;

// ── Pthread struct and scheduler ───────────────────────────────────────

const MAX_PTHREADS: usize = 4;
const PTHREAD_STACK_SIZE: usize = 16 * 1024 * 1024;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct Pthread {
    pub id: u64,
    pub result: *mut c_void,
}

static mut MAIN_PTHREAD: Pthread = Pthread {
    id: 1,
    result: core::ptr::null_mut(),
};

static mut PTHREADS: [Pthread; MAX_PTHREADS] = [Pthread {
    id: 0,
    result: core::ptr::null_mut(),
}; MAX_PTHREADS];

static NEXT_PTHREAD: AtomicUsize = AtomicUsize::new(0);
static BSDTHREAD_REGISTERED: AtomicBool = AtomicBool::new(false);

unsafe fn currentThreadId() -> u64 {
    common::darwinSyscall3(common::SYS_thread_selfid, 0, 0, 0) as u64
}

unsafe extern "C" fn pthreadStart(pthread_addr: usize, start_addr: usize, arg_addr: usize) -> ! {
    let pthread = pthread_addr as *mut Pthread;
    (*pthread).id = currentThreadId();
    let start: unsafe extern "C" fn(*mut c_void) -> *mut c_void = core::mem::transmute(start_addr);
    (*pthread).result = start(arg_addr as *mut c_void);
    let _ = common::darwinSyscall3(common::SYS_bsdthread_terminate, 0, 0, 0);
    loop {
        #[cfg(target_arch = "aarch64")]
        core::arch::asm!("wfe", options(nomem, nostack));
    }
}

// ── pthread self / identity ────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_self() -> usize {
    let id = currentThreadId();
    if id == 0 || id == 1 {
        return &raw mut MAIN_PTHREAD as usize;
    }
    for i in 0..MAX_PTHREADS {
        if PTHREADS[i].id == id {
            return &raw mut PTHREADS[i] as usize;
        }
    }
    &raw mut MAIN_PTHREAD as usize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_threadid_np(thread: *mut c_void, out: *mut u64) -> c_int {
    if !thread.is_null() {
        *out = (*(thread as *const Pthread)).id;
    } else {
        *out = currentThreadId();
    }
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn pthread_equal(a: usize, b: usize) -> c_int {
    if a == b { 1 } else { 0 }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_main_np() -> c_int {
    let id = currentThreadId();
    if id == 1 { 1 } else { 0 }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_kill(thread: *mut c_void, sig: c_int) -> c_int {
    let tid = if !thread.is_null() {
        (*(thread as *const Pthread)).id
    } else {
        currentThreadId()
    };
    let ret = common::darwinSyscall3(common::SYS_pthread_kill, tid as usize, sig as usize, 0);
    common::setErrnoFromNegative(ret)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_sigmask(
    _how: c_int,
    _set: *const c_void,
    _oldset: *mut c_void,
) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_atfork(
    _prepare: *const c_void,
    _parent: *const c_void,
    _child: *const c_void,
) -> c_int {
    0
}

// ── pthread_create / join / detach ─────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_create(
    out: *mut usize,
    _attr: *const c_void,
    start: *const c_void,
    arg: *mut c_void,
) -> c_int {
    if start.is_null() {
        return common::EINVAL;
    }
    let start_addr = start as usize;
    let slot = NEXT_PTHREAD.fetch_add(1, Ordering::Relaxed);
    if slot >= MAX_PTHREADS {
        return common::ENOMEM;
    }
    let pthread = &raw mut PTHREADS[slot];
    *pthread = Pthread {
        id: 0,
        result: core::ptr::null_mut(),
    };
    if !BSDTHREAD_REGISTERED.load(Ordering::Acquire) {
        let registered = common::darwinSyscall5(
            common::SYS_bsdthread_register,
            pthreadStart as *const () as usize,
            0,
            0,
            0,
            0,
        );
        if registered != 0 {
            return common::ENOTSUP;
        }
        BSDTHREAD_REGISTERED.store(true, Ordering::Release);
    }
    let stack = crate::mach::mmap(
        core::ptr::null_mut(),
        PTHREAD_STACK_SIZE,
        common::VM_PROT_READ_WRITE,
        common::MAP_PRIVATE_ANON,
        -1,
        0,
    );
    if stack.is_null() || stack as usize == common::usize_max {
        return common::ENOMEM;
    }
    let stack_top = stack as usize + PTHREAD_STACK_SIZE;
    let result = common::darwinSyscall5(
        common::SYS_bsdthread_create,
        start_addr,
        arg as usize,
        stack_top,
        pthread as usize,
        0,
    );
    if result > common::usize_max - 4096 {
        return (0usize.wrapping_sub(result)) as c_int;
    }
    (*pthread).id = result as u64;
    if !out.is_null() {
        *out = pthread as usize;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_join(_thread: *mut c_void, _value_ptr: *mut *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_detach(_thread: *mut c_void) -> c_int {
    0
}

// ── pthread_attr ───────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_attr_init(attr: *mut c_void) -> c_int {
    if !attr.is_null() {
        core::ptr::write_bytes(attr as *mut u8, 0, 64);
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_attr_destroy(_attr: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_attr_setstacksize(_attr: *mut c_void, _stacksize: usize) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_attr_setguardsize(_attr: *mut c_void, _guardsize: usize) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_attr_getstacksize(_attr: *const c_void, out: *mut usize) -> c_int {
    if !out.is_null() {
        *out = PTHREAD_STACK_SIZE;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_attr_getguardsize(_attr: *const c_void, out: *mut usize) -> c_int {
    if !out.is_null() {
        *out = 0;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_get_stackaddr_np(_thread: *mut c_void) -> *mut c_void {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_get_stacksize_np(_thread: *mut c_void) -> usize {
    PTHREAD_STACK_SIZE
}

// ── pthread_mutex ──────────────────────────────────────────────────────

pub const PTHREAD_MUTEX_NORMAL: c_int = 0;
pub const PTHREAD_MUTEX_RECURSIVE: c_int = 1;
pub const PTHREAD_MUTEX_ERRORCHECK: c_int = 2;

#[repr(C)]
pub struct PthreadMutex {
    pub lock: u32,
    pub owner: u64,
    pub count: u32,
    pub kind: c_int,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutex_init(m: *mut c_void, _attr: *const c_void) -> c_int {
    if !m.is_null() {
        let mutex = m as *mut PthreadMutex;
        *mutex = PthreadMutex {
            lock: 0,
            owner: 0,
            count: 0,
            kind: PTHREAD_MUTEX_NORMAL,
        };
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutex_destroy(_m: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutex_lock(m: *mut c_void) -> c_int {
    if m.is_null() {
        return common::EINVAL;
    }
    let mp = m as *mut PthreadMutex;
    let tid = currentThreadId();

    if (*mp).kind == PTHREAD_MUTEX_RECURSIVE && (*mp).owner == tid {
        (*mp).count += 1;
        return 0;
    }

    let lock_atomic = &*(&raw mut (*mp).lock as *mut AtomicU32);
    while lock_atomic
        .compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
        .is_err()
    {
        let _ = __ulock_wait2(0x01, &raw mut (*mp).lock as *mut c_void, 0, 0, 0);
    }
    (*mp).owner = tid;
    (*mp).count = 1;
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutex_trylock(m: *mut c_void) -> c_int {
    if m.is_null() {
        return common::EINVAL;
    }
    let mp = m as *mut PthreadMutex;
    let tid = currentThreadId();

    if (*mp).kind == PTHREAD_MUTEX_RECURSIVE && (*mp).owner == tid {
        (*mp).count += 1;
        return 0;
    }

    let lock_atomic = &*(&raw mut (*mp).lock as *mut AtomicU32);
    if lock_atomic
        .compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
        .is_err()
    {
        return common::EBUSY;
    }
    (*mp).owner = tid;
    (*mp).count = 1;
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutex_unlock(m: *mut c_void) -> c_int {
    if m.is_null() {
        return common::EINVAL;
    }
    let mp = m as *mut PthreadMutex;

    if (*mp).kind == PTHREAD_MUTEX_RECURSIVE && (*mp).count > 1 {
        (*mp).count -= 1;
        return 0;
    }

    (*mp).owner = 0;
    (*mp).count = 0;
    let lock_atomic = &*(&raw mut (*mp).lock as *mut AtomicU32);
    lock_atomic.store(0, Ordering::Release);
    let _ = __ulock_wake(0x01, &raw mut (*mp).lock as *mut c_void, 0);
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutex_gettype(_m: *const c_void) -> c_int {
    PTHREAD_MUTEX_NORMAL
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutex_settype(m: *mut c_void, kind: c_int) -> c_int {
    if !m.is_null() {
        let mp = m as *mut PthreadMutex;
        (*mp).kind = kind;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutexattr_init(_attr: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutexattr_destroy(_attr: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mutexattr_settype(_attr: *mut c_void, _kind: c_int) -> c_int {
    0
}

// ── pthread_key (TLS) ──────────────────────────────────────────────────

const MAX_PTHREAD_KEYS: usize = 16;

#[derive(Copy, Clone)]
struct PthreadKey {
    used: bool,
    _destructor: Option<unsafe extern "C" fn(*mut c_void)>,
}

static mut PTHREAD_KEYS: [PthreadKey; MAX_PTHREAD_KEYS] = [PthreadKey {
    used: false,
    _destructor: None,
}; MAX_PTHREAD_KEYS];

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_key_create(
    key_out: *mut usize,
    destructor: Option<unsafe extern "C" fn(*mut c_void)>,
) -> c_int {
    for i in 0..MAX_PTHREAD_KEYS {
        if !PTHREAD_KEYS[i].used {
            PTHREAD_KEYS[i] = PthreadKey {
                used: true,
                _destructor: destructor,
            };
            if !key_out.is_null() {
                *key_out = i;
            }
            return 0;
        }
    }
    common::EAGAIN
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_key_delete(key: usize) -> c_int {
    if key >= MAX_PTHREAD_KEYS {
        return common::EINVAL;
    }
    PTHREAD_KEYS[key] = PthreadKey {
        used: false,
        _destructor: None,
    };
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_getspecific(_key: usize) -> *mut c_void {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_setspecific(_key: usize, _value: *const c_void) -> c_int {
    0
}

// ── pthread_once ───────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_once(
    predicate: *mut c_int,
    init_fn: Option<unsafe extern "C" fn()>,
) -> c_int {
    let pred_atomic = &*(predicate as *mut AtomicI32);
    if pred_atomic.load(Ordering::Acquire) == 0 {
        if let Some(f) = init_fn {
            f();
        }
        pred_atomic.store(1, Ordering::Release);
    }
    0
}

#[repr(C)]
pub struct PthreadCond {
    pub value: u32,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_cond_init(cond: *mut c_void, _attr: *const c_void) -> c_int {
    if !cond.is_null() {
        let c = cond as *mut PthreadCond;
        *c = PthreadCond { value: 0 };
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_cond_destroy(_cond: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_cond_wait(_cond: *mut c_void, _mutex: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_cond_signal(cond: *mut c_void) -> c_int {
    if !cond.is_null() {
        let c = cond as *mut PthreadCond;
        (*c).value = (*c).value.wrapping_add(1);
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_cond_broadcast(cond: *mut c_void) -> c_int {
    pthread_cond_signal(cond)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_cond_timedwait_relative_np(
    _cond: *mut c_void,
    _mutex: *mut c_void,
    _abstime: *const c_void,
) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_condattr_init(_attr: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_condattr_destroy(_attr: *mut c_void) -> c_int {
    0
}

// ── pthread_rwlock ─────────────────────────────────────────────────────

#[repr(C)]
pub struct PthreadRwlock {
    pub readers: u32,
    pub writer_locked: u32,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlock_init(_lock: *mut c_void, _attr: *const c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlock_destroy(_lock: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlock_rdlock(lock: *mut c_void) -> c_int {
    if !lock.is_null() {
        let rw = lock as *mut PthreadRwlock;
        let writer_atomic = &*(&raw mut (*rw).writer_locked as *mut AtomicU32);
        while writer_atomic.load(Ordering::Acquire) != 0 {}
        let readers_atomic = &*(&raw mut (*rw).readers as *mut AtomicU32);
        readers_atomic.fetch_add(1, Ordering::AcqRel);
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlock_wrlock(lock: *mut c_void) -> c_int {
    if !lock.is_null() {
        let rw = lock as *mut PthreadRwlock;
        let writer_atomic = &*(&raw mut (*rw).writer_locked as *mut AtomicU32);
        while writer_atomic
            .compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {}
        let readers_atomic = &*(&raw mut (*rw).readers as *mut AtomicU32);
        while readers_atomic.load(Ordering::Acquire) != 0 {}
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlock_tryrdlock(lock: *mut c_void) -> c_int {
    if !lock.is_null() {
        let rw = lock as *mut PthreadRwlock;
        let writer_atomic = &*(&raw mut (*rw).writer_locked as *mut AtomicU32);
        if writer_atomic.load(Ordering::Acquire) != 0 {
            return common::EBUSY;
        }
        let readers_atomic = &*(&raw mut (*rw).readers as *mut AtomicU32);
        readers_atomic.fetch_add(1, Ordering::AcqRel);
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlock_trywrlock(lock: *mut c_void) -> c_int {
    if !lock.is_null() {
        let rw = lock as *mut PthreadRwlock;
        let writer_atomic = &*(&raw mut (*rw).writer_locked as *mut AtomicU32);
        if writer_atomic
            .compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            return common::EBUSY;
        }
        let readers_atomic = &*(&raw mut (*rw).readers as *mut AtomicU32);
        if readers_atomic.load(Ordering::Acquire) != 0 {
            writer_atomic.store(0, Ordering::Release);
            return common::EBUSY;
        }
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlock_unlock(lock: *mut c_void) -> c_int {
    if !lock.is_null() {
        let rw = lock as *mut PthreadRwlock;
        let writer_atomic = &*(&raw mut (*rw).writer_locked as *mut AtomicU32);
        if writer_atomic.load(Ordering::Acquire) != 0 {
            writer_atomic.store(0, Ordering::Release);
        } else {
            let readers_atomic = &*(&raw mut (*rw).readers as *mut AtomicU32);
            readers_atomic.fetch_sub(1, Ordering::AcqRel);
        }
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlock_init_recursive_np(
    _lock: *mut c_void,
    _attr: *const c_void,
) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlockattr_init(_attr: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_rwlockattr_destroy(_attr: *mut c_void) -> c_int {
    0
}

// ── __ulock_wait / __ulock_wake ────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __ulock_wait2(
    operation: u32,
    addr: *mut c_void,
    value: u64,
    timeout: u64,
    value2: u64,
) -> c_int {
    if addr.is_null() {
        return -common::EINVAL;
    }
    let ret = common::darwinSyscall5(
        common::SYS_ulock_wait2,
        operation as usize,
        addr as usize,
        value as usize,
        timeout as usize,
        value2 as usize,
    );
    if ret == common::usize_max - 34 {
        return 0; // -EAGAIN: value changed before sleeping
    }
    ret as isize as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __ulock_wake(operation: u32, addr: *mut c_void, wake_value: u64) -> c_int {
    if addr.is_null() {
        return -common::EINVAL;
    }
    let ret = common::darwinSyscall3(
        common::SYS_ulock_wake,
        operation as usize,
        addr as usize,
        wake_value as usize,
    );
    ret as isize as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __ulock_wait(
    operation: u32,
    addr: *mut c_void,
    value: u32,
    timeout: u32,
) -> c_int {
    __ulock_wait2(operation, addr, value as u64, timeout as u64, 0)
}

// ── pthread miscellaneous ──────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_getugid_np(
    _tid: *mut c_void,
    uid: *mut u32,
    gid: *mut u32,
) -> c_int {
    if !uid.is_null() {
        *uid = 0;
    }
    if !gid.is_null() {
        *gid = 0;
    }
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn pthread_is_threaded_np() -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pthread_mach_thread_np(_thread: *mut c_void) -> u32 {
    currentThreadId() as u32
}
