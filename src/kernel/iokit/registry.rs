//! Central IORegistry: multi-plane services, dictionary matching, and driver catalog.
//!
//! Mirrors Darwin IOKit/IORegistryEntry.h, IOKit/IOService.h, and driver matching mechanics:
//! - Multi-plane hierarchy: `gIOServicePlane`, `gIODTPlane`, `gIOPowerPlane`.
//! - Dictionary matching: `IOProviderClass`, `IONameMatch`, `compatible`, `IOProbeScore`.

use alloc::vec::Vec;
use spin::Mutex;

use crate::iokit::registry_entry::{OSObject, gIOServicePlane};
use crate::iokit::service::IOService;
use crate::iokit::types::{IO_RETURN_SUCCESS, IOReturn, MAX_SERVICES};

#[derive(Clone, Copy)]
pub struct DriverMatcher {
    pub class_name: &'static str,
    pub provider_class: &'static str,
    pub name_match: Option<&'static [&'static str]>,
    pub compatible_match: Option<&'static [&'static str]>,
    pub probe_score: u32,
    pub match_fn: Option<fn(provider: *mut IOService) -> bool>,
    pub probe_fn: Option<fn(provider: *mut IOService) -> i32>,
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
        if (*svc).entry.get_parent(gIOServicePlane).is_none() {
            (*svc)
                .entry
                .attach_to_parent(&mut reg.root_service.entry, gIOServicePlane);
        }
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

pub fn find_by_class(class_name: &str) -> Option<*mut IOService> {
    let reg = REGISTRY.lock();
    for i in 0..reg.published_count {
        if let Some(svc) = reg.published[i] {
            unsafe {
                if (*svc).get_class_name() == class_name
                    || (*svc).entry.get_property_str("IOClass") == Some(class_name)
                {
                    return Some(svc);
                }
            }
        }
    }
    None
}

pub fn find_by_name(name: &str) -> Option<*mut IOService> {
    let reg = REGISTRY.lock();
    for i in 0..reg.published_count {
        if let Some(svc) = reg.published[i] {
            unsafe {
                if (*svc).entry.get_name() == name {
                    return Some(svc);
                }
            }
        }
    }
    None
}

fn matches_provider(matcher: &DriverMatcher, provider: *mut IOService) -> bool {
    unsafe {
        let provider_ref = &*provider;
        let provider_class = provider_ref.get_class_name();

        // 1. Check provider class
        if matcher.provider_class != "IOService" && matcher.provider_class != provider_class {
            return false;
        }

        // 2. Check compatible property match
        if let Some(comp_list) = matcher.compatible_match {
            let mut matched_comp = false;
            if let Some(prop) = provider_ref.entry.get_property("compatible") {
                match prop {
                    OSObject::Array(arr) => {
                        for item in arr {
                            if let Some(s) = item.as_str() {
                                if comp_list.contains(&s) {
                                    matched_comp = true;
                                    break;
                                }
                            }
                        }
                    }
                    OSObject::String(s) => {
                        if comp_list.contains(&s.as_str()) {
                            matched_comp = true;
                        }
                    }
                    _ => {}
                }
            }
            if !matched_comp {
                return false;
            }
        }

        // 3. Check name match
        if let Some(name_list) = matcher.name_match {
            let name = provider_ref.entry.get_name();
            if !name_list.contains(&name) {
                return false;
            }
        }

        // 4. Custom match function
        if let Some(match_fn) = matcher.match_fn {
            if !match_fn(provider) {
                return false;
            }
        }

        // 5. Probe function
        if let Some(probe_fn) = matcher.probe_fn {
            if probe_fn(provider) < 0 {
                return false;
            }
        }

        true
    }
}

pub fn match_and_start_drivers() -> usize {
    let mut started = 0;
    let reg = REGISTRY.lock();

    // Collect drivers sorted by probe_score descending
    let mut active_drivers: Vec<DriverMatcher> = Vec::new();
    for i in 0..reg.driver_count {
        if let Some(m) = reg.drivers[i] {
            active_drivers.push(m);
        }
    }
    active_drivers.sort_by(|a, b| b.probe_score.cmp(&a.probe_score));

    for matcher in &active_drivers {
        for pi in 0..reg.published_count {
            let Some(provider) = reg.published[pi] else {
                continue;
            };

            if matches_provider(matcher, provider) {
                if (matcher.attach_and_start)(provider) == IO_RETURN_SUCCESS {
                    started += 1;
                }
            }
        }
    }

    started
}
