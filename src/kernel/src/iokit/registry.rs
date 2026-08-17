//! Central IORegistry: published services and driver matching.

use crate::iokit::service::IOService;
use crate::iokit::types::{IO_RETURN_SUCCESS, IOReturn, MAX_SERVICES};
use spin::Mutex;

#[derive(Clone, Copy)]
pub struct DriverMatcher {
    pub class_name: &'static str,
    pub provider_class: &'static str,
    pub match_fn: fn(provider: *mut IOService) -> bool,
    pub attach_and_start: fn(provider: *mut IOService) -> IOReturn,
}

struct RegistryState {
    root_service: IOService,
    published: [Option<*mut IOService>; MAX_SERVICES],
    published_count: usize,
    drivers: [Option<DriverMatcher>; MAX_SERVICES],
    driver_count: usize,
}

unsafe impl Send for RegistryState {}
unsafe impl Sync for RegistryState {}
static REGISTRY: Mutex<RegistryState> = Mutex::new(RegistryState {
    root_service: IOService::new(),
    published: [None; MAX_SERVICES],
    published_count: 0,
    drivers: [None; MAX_SERVICES],
    driver_count: 0,
});

pub fn init() {
    let mut reg = REGISTRY.lock();
    reg.root_service.init("IORegistryEntry", "Root", "");
    reg.published_count = 0;
    reg.driver_count = 0;
}

pub fn root() -> *mut IOService {
    let mut reg = REGISTRY.lock();
    &mut reg.root_service as *mut IOService
}

pub fn publish(svc: *mut IOService) -> bool {
    let mut reg = REGISTRY.lock();
    if reg.published_count >= MAX_SERVICES {
        return false;
    }
    let idx = reg.published_count;
    reg.published[idx] = Some(svc);
    reg.published_count += 1;
    unsafe {
        (*svc).entry.parent = Some(&mut reg.root_service.entry);
        reg.root_service.entry.add_child(&mut (*svc).entry);
    }
    true
}

pub fn register_driver(matcher: DriverMatcher) -> bool {
    let mut reg = REGISTRY.lock();
    if reg.driver_count >= MAX_SERVICES {
        return false;
    }
    let idx = reg.driver_count;
    reg.drivers[idx] = Some(matcher);
    reg.driver_count += 1;
    true
}

pub fn published_count() -> usize {
    REGISTRY.lock().published_count
}

pub fn published_at(idx: usize) -> Option<*mut IOService> {
    let reg = REGISTRY.lock();
    if idx < reg.published_count {
        reg.published[idx]
    } else {
        None
    }
}

pub fn match_and_start_drivers() -> usize {
    let mut started = 0;
    let reg = REGISTRY.lock();
    for di in 0..reg.driver_count {
        let Some(matcher) = reg.drivers[di] else {
            continue;
        };
        for pi in 0..reg.published_count {
            let Some(provider) = reg.published[pi] else {
                continue;
            };
            if (matcher.match_fn)(provider) {
                if (matcher.attach_and_start)(provider) == IO_RETURN_SUCCESS {
                    started += 1;
                }
            }
        }
    }
    started
}
