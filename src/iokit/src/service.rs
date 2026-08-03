//! IOService lifecycle: master port, matching lookup, open / close / release.

use alloc::boxed::Box;
use core::ffi::c_void;

use crate::mach::{as_bytes, mach_host_self, rpc, rpc_empty};
use crate::matching::{MatchingBody, MatchingDict};
use crate::types::*;

/// `IOMasterPort` — the master IOKit port.
///
/// On OpenDarwin the master port *is* the host port (obtained via
/// `mach_host_self`), so the bootstrap port is ignored.
#[unsafe(no_mangle)]
pub extern "C" fn IOMasterPort(
    _bootstrap_port: mach_port_t,
    master_port: *mut mach_port_t,
) -> kern_return_t {
    if master_port.is_null() {
        return kIOReturnError;
    }
    let host = mach_host_self();
    if host == 0 {
        return kIOReturnError;
    }
    unsafe {
        *master_port = host;
    }
    KERN_SUCCESS
}

/// `IOServiceGetMatchingService` — first IOService matching `matching`.
///
/// Consumes (frees) the matching dict, like Darwin's consume-once semantics.
/// Returns `0` (MACH_PORT_NULL) when nothing matches or the RPC fails.
#[unsafe(no_mangle)]
pub extern "C" fn IOServiceGetMatchingService(
    master_port: mach_port_t,
    matching: *mut c_void,
) -> io_service_t {
    if matching.is_null() {
        return 0;
    }
    let dict = unsafe { Box::from_raw(matching as *mut MatchingDict) };
    let body = MatchingBody {
        class_len: dict.class_len,
        class_name: dict.class_name,
    };
    drop(dict);

    match rpc(master_port, MSG_GET_MATCHING_SERVICE, as_bytes(&body)) {
        Ok(reply) if reply.ret == KERN_SUCCESS => reply.val0 as io_service_t,
        _ => 0,
    }
}

/// Wire body for `MSG_SERVICE_OPEN` (connection type).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct OpenBody {
    pub kind: u32,
}

/// `IOServiceOpen` — open a user client connection of type `kind` on `service`.
///
/// The owning task is ignored (the OpenDarwin kernel does not check it).
#[unsafe(no_mangle)]
pub extern "C" fn IOServiceOpen(
    service: io_service_t,
    _owning_task: mach_port_t,
    kind: u32,
    connect: *mut io_connect_t,
) -> kern_return_t {
    if connect.is_null() {
        return kIOReturnError;
    }
    let body = OpenBody { kind };
    let reply = match rpc(service, MSG_SERVICE_OPEN, as_bytes(&body)) {
        Ok(r) => r,
        Err(kr) => return kr,
    };
    if reply.ret != KERN_SUCCESS {
        return reply.ret;
    }
    unsafe {
        *connect = reply.val0 as io_connect_t;
    }
    KERN_SUCCESS
}

/// `IOServiceClose` — tear down a user client connection.
#[unsafe(no_mangle)]
pub extern "C" fn IOServiceClose(connect: io_connect_t) -> kern_return_t {
    match rpc_empty(connect, MSG_OBJECT_RELEASE) {
        Ok(reply) => reply.ret,
        Err(kr) => kr,
    }
}

/// `IOObjectRelease` — release a reference on an IOKit object.
///
/// Ports are task-scoped names on OpenDarwin; the kernel reclaims them when
/// the connection closes, so this is a no-op success.
#[unsafe(no_mangle)]
pub extern "C" fn IOObjectRelease(_object: io_object_t) -> kern_return_t {
    KERN_SUCCESS
}
