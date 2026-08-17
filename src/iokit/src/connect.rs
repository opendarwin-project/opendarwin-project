//! Connection methods: `IOConnectMapMemory`, `IOConnectCallMethod`, and the
//! raw `IOConnectTrap0..6` trap-100 dispatch.

use core::ffi::c_void;

use crate::mach::{as_bytes, rpc};
use crate::types::*;

/// Wire body for `MSG_CONNECT_MAP_MEMORY`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct MapMemoryBody {
    pub memory_type: u32,
    pub flags: u32,
}

/// `IOConnectMapMemory` — map a user client memory region into `into_task`.
///
/// The target task is ignored on OpenDarwin (mapping goes into the calling
/// task); the kernel reports the mapped address and size via the reply.
#[unsafe(no_mangle)]
pub extern "C" fn IOConnectMapMemory(
    connect: io_connect_t,
    memory_type: u32,
    _into_task: mach_port_t,
    at_address: *mut u64,
    of_size: *mut u64,
    options: u32,
) -> kern_return_t {
    if at_address.is_null() || of_size.is_null() {
        return kIOReturnError;
    }
    let body = MapMemoryBody {
        memory_type,
        flags: options,
    };
    let reply = match rpc(connect, MSG_CONNECT_MAP_MEMORY, as_bytes(&body)) {
        Ok(r) => r,
        Err(kr) => return kr,
    };
    if reply.ret != KERN_SUCCESS {
        return reply.ret;
    }
    unsafe {
        *at_address = reply.val0;
        *of_size = reply.val1;
    }
    KERN_SUCCESS
}

/// `IOConnectTrap6` — raw `iokit_user_client_trap` (mach trap 100).
#[unsafe(no_mangle)]
pub extern "C" fn IOConnectTrap6(
    connect: io_connect_t,
    index: u32,
    p1: usize,
    p2: usize,
    p3: usize,
    p4: usize,
    p5: usize,
    p6: usize,
) -> kern_return_t {
    unsafe { crate::libc::iokit_user_client_trap(connect, index, p1, p2, p3, p4, p5, p6) }
}

/// `IOConnectTrap0` — user client method with no scalar arguments.
#[unsafe(no_mangle)]
pub extern "C" fn IOConnectTrap0(connect: io_connect_t, index: u32) -> kern_return_t {
    IOConnectTrap6(connect, index, 0, 0, 0, 0, 0, 0)
}

/// `IOConnectTrap1` — user client method with one scalar argument.
#[unsafe(no_mangle)]
pub extern "C" fn IOConnectTrap1(connect: io_connect_t, index: u32, p1: usize) -> kern_return_t {
    IOConnectTrap6(connect, index, p1, 0, 0, 0, 0, 0)
}

/// `IOConnectCallMethod` — the modern dispatch entry point.
///
/// On OpenDarwin the supported selectors are IOFramebuffer methods, which
/// route through trap 100:
///
/// - `kIOFBSelectGetInfo` (0): scalar trap with a pointer to
///   `IOFramebufferInfo`, reports `*outputStructCnt` afterwards
/// - `kIOFBSelectPresent` (1): no-argument scalar trap
#[unsafe(no_mangle)]
pub extern "C" fn IOConnectCallMethod(
    connect: io_connect_t,
    selector: u32,
    _input: *const u64,
    _input_cnt: u32,
    _input_struct: *const c_void,
    _input_struct_cnt: usize,
    _output: *mut u64,
    _output_cnt: *mut u32,
    output_struct: *mut c_void,
    output_struct_cnt: *mut usize,
) -> kern_return_t {
    match selector {
        kIOFBSelectGetInfo => {
            if output_struct.is_null() {
                return kIOReturnError;
            }
            let kr = IOConnectTrap1(connect, selector, output_struct as usize);
            if kr == KERN_SUCCESS && !output_struct_cnt.is_null() {
                unsafe {
                    *output_struct_cnt = core::mem::size_of::<IOFramebufferInfo>();
                }
            }
            kr
        }
        kIOFBSelectPresent => IOConnectTrap0(connect, selector),
        _ => kIOReturnError,
    }
}
