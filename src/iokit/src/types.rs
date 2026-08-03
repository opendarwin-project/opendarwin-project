//! C-facing IOKitLib types and constants (mirrors `include/IOKit/IOKitLib.h`).

/// Mach port name (u32 on all Darwin targets).
pub type mach_port_t = u32;
/// Base type for all IOKit objects.
pub type io_object_t = mach_port_t;
/// A registry entry / IOService handle.
pub type io_service_t = io_object_t;
/// An open user client connection handle.
pub type io_connect_t = io_object_t;
/// Kernel return code.
pub type kern_return_t = i32;
/// IOKit flavor of `kern_return_t`.
pub type IOReturn = kern_return_t;

pub const MACH_PORT_NULL: mach_port_t = 0;

pub const KERN_SUCCESS: kern_return_t = 0;
pub const kIOReturnSuccess: IOReturn = 0;
pub const kIOReturnError: IOReturn = -1;

/// mach_msg option bits / return codes.
pub const MACH_MSG_SUCCESS: u32 = 0;
pub const MACH_SEND_MSG: u32 = 0x1;
pub const MACH_RCV_MSG: u32 = 0x2;
pub const MACH_SEND_TIMEOUT: u32 = 0x10;
pub const MACH_RCV_TIMEOUT: u32 = 0x100;

/// mach_msg2 / `mach_msg2_trap` 64-bit option bits. The low 32 bits are the
/// classic `mach_msg_option_t`; the high bits are 64-bit-only additions.
pub const MACH64_SEND_MSG: u64 = 0x1;
pub const MACH64_RCV_MSG: u64 = 0x2;
pub const MACH64_SEND_TIMEOUT: u64 = 0x10;
pub const MACH64_RCV_TIMEOUT: u64 = 0x100;
/// Destination unknown (old-simulator path): skip mach_msg2 CFI enforcement.
pub const MACH64_SEND_ANY: u64 = 0x0000_0008_0000_0000;
/// The message is sent to a libdispatch message queue (not used here).
pub const MACH64_SEND_MQ_CALL: u64 = 0x0000_0004_0000_0000;

/// `msgh_bits` port-right dispositions (see `MACH_MSGH_BITS_*`).
pub const MACH_MSG_TYPE_COPY_SEND: u32 = 19;
pub const MACH_MSG_TYPE_MAKE_SEND_ONCE: u32 = 21;

pub const MACH_MSGH_BITS_REMOTE_MASK: u32 = 0x1f;
pub const MACH_MSGH_BITS_LOCAL_MASK: u32 = 0x1f00;
pub const MACH_MSGH_BITS_VOUCHER_MASK: u32 = 0x1f0000;
pub const MACH_MSGH_BITS_COMPLEX: u32 = 0x8000_0000;

/// Pack `(remote, local, voucher)` right dispositions into `msgh_bits`.
pub const fn mach_msgh_bits(remote: u32, local: u32, voucher: u32) -> u32 {
    (remote & MACH_MSGH_BITS_REMOTE_MASK)
        | ((local << 8) & MACH_MSGH_BITS_LOCAL_MASK)
        | ((voucher << 16) & MACH_MSGH_BITS_VOUCHER_MASK)
}

/// XNU mach trap numbers, selected via a negated `x16` before `svc #0x80`
/// (the real-macOS encoding used by libsystem_kernel).
pub const MACH_mach_reply_port: usize = 26;
pub const MACH_host_self_trap: usize = 29;
/// `mach_msg2_trap` — the modern message trap (macOS 15+/26). The legacy
/// `mach_msg_trap` (31) kills the process on macOS 26, so it is not used.
pub const MACH_mach_msg2_trap: usize = 47;
/// `iokit_user_client_trap` — the trap behind `IOConnectTrap0..6`.
pub const MACH_iokit_user_client_trap: usize = 100;

/// Simplified MIG-like message ids for match / open / mapMemory / release.
/// These are served by the OpenDarwin kernel's IOKit mach server
/// (`src/kernel/iokit/mach_server.zig`), not by Apple's IOKit MIG.
pub const MSG_GET_MATCHING_SERVICE: u32 = 2900;
pub const MSG_SERVICE_OPEN: u32 = 2901;
pub const MSG_CONNECT_MAP_MEMORY: u32 = 2902;
pub const MSG_OBJECT_RELEASE: u32 = 2904;

/// IOFramebuffer UserClient selectors (dispatched via trap 100).
pub const kIOFBSelectGetInfo: u32 = 0;
pub const kIOFBSelectPresent: u32 = 1;

/// Max length of an `IOClass` / matching name.
pub const CLASS_NAME_MAX: usize = 64;

/// Info returned by the `kIOFBSelectGetInfo` selector.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct IOFramebufferInfo {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    /// 0 = BGRA8 / B8G8R8X8.
    pub format: u32,
    pub size: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framebuffer_info_layout() {
        // width/height/stride/format (16) + size (8), 8-aligned.
        assert_eq!(core::mem::size_of::<IOFramebufferInfo>(), 24);
        assert_eq!(core::mem::align_of::<IOFramebufferInfo>(), 8);
        assert_eq!(core::mem::offset_of!(IOFramebufferInfo, size), 16);
    }
}
