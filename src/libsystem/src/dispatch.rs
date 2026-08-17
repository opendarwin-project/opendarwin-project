//! libdispatch (GCD) stubs: dispatch_queue, dispatch_async, dispatch_sync,
//! dispatch_source, dispatch_once, etc.

use core::ffi::{c_char, c_int, c_void};
use core::sync::atomic::{AtomicIsize, AtomicUsize, Ordering};

pub type DispatchFunction = unsafe extern "C" fn(*mut c_void);
pub type DispatchObject = *mut DispatchObjectStorage;
pub type DispatchQueue = *mut DispatchObjectStorage;
pub type DispatchSource = *mut DispatchSourceStorage;
pub type DispatchSourceType = *const DispatchSourceTypeStorage;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct DispatchObjectStorage {
    pub context: *mut c_void,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct DispatchSourceTypeStorage {
    pub tag: usize,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct DispatchSourceStorage {
    pub object: DispatchObjectStorage,
    pub kind: usize,
    pub queue: DispatchQueue,
    pub event_handler: Option<DispatchFunction>,
    pub cancel_handler: Option<DispatchFunction>,
}

#[unsafe(no_mangle)]
pub static mut _dispatch_main_q: DispatchObjectStorage = DispatchObjectStorage {
    context: core::ptr::null_mut(),
};

#[unsafe(no_mangle)]
pub static mut _dispatch_queue_attr_concurrent: DispatchObjectStorage = DispatchObjectStorage {
    context: core::ptr::null_mut(),
};

#[unsafe(no_mangle)]
pub static _dispatch_source_type_timer: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 1 };
#[unsafe(no_mangle)]
pub static _dispatch_source_type_read: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 2 };
#[unsafe(no_mangle)]
pub static _dispatch_source_type_write: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 3 };
#[unsafe(no_mangle)]
pub static _dispatch_source_type_proc: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 4 };
#[unsafe(no_mangle)]
pub static _dispatch_source_type_signal: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 5 };
#[unsafe(no_mangle)]
pub static _dispatch_source_type_vnode: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 6 };
#[unsafe(no_mangle)]
pub static _dispatch_source_type_interval: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 7 };
#[unsafe(no_mangle)]
pub static _dispatch_source_type_mach_send: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 8 };
#[unsafe(no_mangle)]
pub static _dispatch_source_type_mach_receive: DispatchSourceTypeStorage =
    DispatchSourceTypeStorage { tag: 9 };

const MAX_DISPATCH_QUEUES: usize = 8;
const MAX_DISPATCH_SOURCES: usize = 16;

static mut GLOBAL_DISPATCH_QUEUE: DispatchObjectStorage = DispatchObjectStorage {
    context: core::ptr::null_mut(),
};

static mut DISPATCH_QUEUES: [DispatchObjectStorage; MAX_DISPATCH_QUEUES] = [DispatchObjectStorage {
    context: core::ptr::null_mut(),
}; MAX_DISPATCH_QUEUES];

static mut DISPATCH_SOURCES: [DispatchSourceStorage; MAX_DISPATCH_SOURCES] =
    [DispatchSourceStorage {
        object: DispatchObjectStorage {
            context: core::ptr::null_mut(),
        },
        kind: 0,
        queue: core::ptr::null_mut(),
        event_handler: None,
        cancel_handler: None,
    }; MAX_DISPATCH_SOURCES];

static NEXT_DISPATCH_QUEUE: AtomicUsize = AtomicUsize::new(0);
static NEXT_DISPATCH_SOURCE: AtomicUsize = AtomicUsize::new(0);

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_retain(_object: DispatchObject) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_release(_object: DispatchObject) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_get_context(object: DispatchObject) -> *mut c_void {
    if !object.is_null() {
        (*object).context
    } else {
        core::ptr::null_mut()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_set_context(object: DispatchObject, context: *mut c_void) {
    if !object.is_null() {
        (*object).context = context;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_set_finalizer_f(
    _object: DispatchObject,
    _finalizer: Option<DispatchFunction>,
) {
}

unsafe extern "C" fn dispatchSourceRun(arg: *mut c_void) -> *mut c_void {
    if arg.is_null() {
        return core::ptr::null_mut();
    }
    let source = arg as DispatchSource;
    if let Some(handler) = (*source).event_handler {
        handler((*source).object.context);
    }
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_activate(object: DispatchObject) {
    let source = object as DispatchSource;
    if (*source).kind != 1 || (*source).event_handler.is_none() {
        return;
    }
    let _ = crate::pthread::pthread_create(
        core::ptr::null_mut(),
        core::ptr::null(),
        dispatchSourceRun as *const c_void,
        source as *mut c_void,
    );
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_suspend(_object: DispatchObject) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_resume(_object: DispatchObject) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_once_f(
    predicate: *mut isize,
    context: *mut c_void,
    function: DispatchFunction,
) {
    if *predicate == -1 {
        return;
    }
    function(context);
    *predicate = -1;
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_get_global_queue(
    _identifier: isize,
    _flags: usize,
) -> DispatchQueue {
    &raw mut GLOBAL_DISPATCH_QUEUE
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_queue_attr_make_initially_inactive(
    attr: DispatchObject,
) -> DispatchObject {
    attr
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_queue_create_with_target(
    _label: *const c_char,
    _attr: DispatchObject,
    target: DispatchQueue,
) -> DispatchQueue {
    if !target.is_null() {
        return target;
    }
    let slot = NEXT_DISPATCH_QUEUE.fetch_add(1, Ordering::Relaxed);
    if slot >= MAX_DISPATCH_QUEUES {
        return core::ptr::null_mut();
    }
    DISPATCH_QUEUES[slot] = DispatchObjectStorage {
        context: core::ptr::null_mut(),
    };
    &raw mut DISPATCH_QUEUES[slot]
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_queue_create(
    label: *const c_char,
    attr: DispatchObject,
) -> DispatchQueue {
    dispatch_queue_create_with_target(label, attr, core::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_queue_get_label(_queue: DispatchQueue) -> *const c_char {
    c"opendarwin".as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_set_target_queue(_object: DispatchObject, _queue: DispatchQueue) {
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_async_f(
    _queue: DispatchQueue,
    context: *mut c_void,
    work: DispatchFunction,
) {
    work(context);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_sync_f(
    queue: DispatchQueue,
    context: *mut c_void,
    work: DispatchFunction,
) {
    dispatch_async_f(queue, context, work);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_async_and_wait_f(
    queue: DispatchQueue,
    context: *mut c_void,
    work: DispatchFunction,
) {
    dispatch_async_f(queue, context, work);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_async(_queue: DispatchQueue, _block: *mut c_void) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_sync(_queue: DispatchQueue, _block: *mut c_void) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_async_and_wait(_queue: DispatchQueue, _block: *mut c_void) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_create(
    source_type: DispatchSourceType,
    _handle: usize,
    _mask: usize,
    queue: DispatchQueue,
) -> DispatchSource {
    let slot = NEXT_DISPATCH_SOURCE.fetch_add(1, Ordering::Relaxed);
    if slot >= MAX_DISPATCH_SOURCES {
        return core::ptr::null_mut();
    }
    let kind = if !source_type.is_null() {
        (*source_type).tag
    } else {
        0
    };
    DISPATCH_SOURCES[slot] = DispatchSourceStorage {
        object: DispatchObjectStorage {
            context: core::ptr::null_mut(),
        },
        kind,
        queue,
        event_handler: None,
        cancel_handler: None,
    };
    &raw mut DISPATCH_SOURCES[slot]
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_set_event_handler_f(
    source: DispatchSource,
    handler: Option<DispatchFunction>,
) {
    if !source.is_null() {
        (*source).event_handler = handler;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_set_cancel_handler_f(
    source: DispatchSource,
    handler: Option<DispatchFunction>,
) {
    if !source.is_null() {
        (*source).cancel_handler = handler;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_cancel(source: DispatchSource) {
    if !source.is_null() {
        if let Some(handler) = (*source).cancel_handler {
            handler((*source).object.context);
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_testcancel(_source: DispatchSource) -> isize {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_get_handle(_source: DispatchSource) -> usize {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_get_mask(_source: DispatchSource) -> usize {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_get_data(_source: DispatchSource) -> usize {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_merge_data(_source: DispatchSource, _value: usize) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_set_timer(
    _source: DispatchSource,
    _start: u64,
    _interval: u64,
    _leeway: u64,
) {
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_source_set_registration_handler_f(
    _source: DispatchSource,
    _handler: Option<DispatchFunction>,
) {
}

#[unsafe(no_mangle)]
pub extern "C" fn dispatch_time(_when: u64, delta: i64) -> u64 {
    delta as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn dispatch_walltime(_when: *const c_void, delta: i64) -> u64 {
    delta as u64
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_block_notify(
    _block: *mut c_void,
    _queue: DispatchQueue,
    _notification_block: *mut c_void,
) {
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_block_cancel(_block: *mut c_void) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_block_testcancel(_block: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn dispatch_group_create() -> *mut c_void {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_group_enter(_group: *mut c_void) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_group_leave(_group: *mut c_void) {}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_group_wait(_group: *mut c_void, _timeout: u64) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn dispatch_semaphore_create(_value: isize) -> *mut c_void {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_semaphore_wait(_dsema: *mut c_void, _timeout: u64) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_semaphore_signal(_dsema: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_once(predicate: *mut isize, block: *mut c_void) {
    if !block.is_null() {
        // A block is a pointer to a struct with an `invoke` function pointer at offset 0
        #[repr(C)]
        struct BlockStruct {
            _reserved: *mut c_void,
            _flags: c_int,
            _reserved2: c_int,
            invoke: unsafe extern "C" fn(*mut c_void),
        }
        let bs = &*(block as *const BlockStruct);
        dispatch_once_f(predicate, block, bs.invoke);
    } else {
        let pred_atomic = &*(predicate as *mut AtomicIsize);
        if pred_atomic.load(Ordering::Acquire) != !0isize {
            pred_atomic.store(!0isize, Ordering::Release);
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dispatch_apply(
    iterations: usize,
    _queue: *mut c_void,
    block: *mut c_void,
) {
    if !block.is_null() {
        let block_fn: unsafe extern "C" fn(usize) = core::mem::transmute(block);
        for i in 0..iterations {
            block_fn(i);
        }
    }
}
