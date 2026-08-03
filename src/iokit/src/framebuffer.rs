//! IOFramebuffer convenience helpers used by Prism and fb-smoke: open the
//! default framebuffer connection and present.

use crate::connect::IOConnectTrap1;
use crate::matching::IOServiceMatching;
use crate::service::{IOMasterPort, IOObjectRelease, IOServiceGetMatchingService, IOServiceOpen};
use crate::types::*;

/// `IOFramebufferOpenDefault` — open the first `IOFramebuffer` service and
/// optionally fetch its info.
///
/// Mirror of the Zig helper: master port → match `"IOFramebuffer"` → open
/// connection type 0 → release the service → getInfo via trap 100.
#[unsafe(no_mangle)]
pub extern "C" fn IOFramebufferOpenDefault(
    connect_out: *mut io_connect_t,
    info_out: *mut IOFramebufferInfo,
) -> kern_return_t {
    if connect_out.is_null() {
        return kIOReturnError;
    }

    let mut master: mach_port_t = 0;
    if IOMasterPort(0, &mut master) != KERN_SUCCESS {
        return kIOReturnError;
    }

    let matching = IOServiceMatching(c"IOFramebuffer".as_ptr());
    if matching.is_null() {
        return kIOReturnError;
    }
    let service = IOServiceGetMatchingService(master, matching);
    if service == 0 {
        return kIOReturnError;
    }

    let mut connect: io_connect_t = 0;
    let okr = IOServiceOpen(service, 0, 0, &mut connect);
    let _ = IOObjectRelease(service);
    if okr != KERN_SUCCESS {
        return okr;
    }

    unsafe {
        *connect_out = connect;
    }
    if !info_out.is_null() {
        let kr = IOConnectTrap1(connect, kIOFBSelectGetInfo, info_out as usize);
        if kr != KERN_SUCCESS {
            return kr;
        }
    }
    KERN_SUCCESS
}

/// `IOFramebufferPresent` — flip the framebuffer (scalar trap 100, selector 1).
#[unsafe(no_mangle)]
pub extern "C" fn IOFramebufferPresent(connect: io_connect_t) -> kern_return_t {
    crate::connect::IOConnectTrap0(connect, kIOFBSelectPresent)
}
