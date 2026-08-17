//! `mach_msg` plumbing: reply ports, host self, and the simplified
//! request/reply RPC used for match / open / mapMemory.
//!
//! The message layout and the request/reply protocol mirror
//! `src/iokit/iokit.zig`: a 24-byte `mach_msg_header_t` followed by a
//! caller-defined body, exchanged in a single `SEND|RCV` `mach_msg` call
//! against a fresh reply port.

use core::mem::size_of;
use core::ptr;

use crate::types::*;

const MAX_TRAILER_SIZE: usize = 0x60;
const RPC_RCV_TIMEOUT_MS: u32 = 10_000;

/// `mach_msg_header_t` (24 bytes on aarch64).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub(crate) struct MachMsgHeader {
    pub msgh_bits: u32,
    pub msgh_size: u32,
    pub msgh_remote_port: mach_port_t,
    pub msgh_local_port: mach_port_t,
    pub msgh_voucher_port: mach_port_t,
    pub msgh_id: u32,
}

/// Reply body of the simplified RPC protocol. The kernel fills `ret` with an
/// `IOReturn` and `val0..val3` with up to four 64-bit results.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub(crate) struct ReplyBody {
    pub ret: i32,
    pub pad: u32,
    pub val0: u64,
    pub val1: u64,
    pub val2: u64,
    pub val3: u64,
    pub bytes: [u8; 64],
}

impl Default for ReplyBody {
    fn default() -> Self {
        ReplyBody {
            ret: -1,
            pad: 0,
            val0: 0,
            val1: 0,
            val2: 0,
            val3: 0,
            bytes: [0; 64],
        }
    }
}

/// `mach_host_self` — the master IOKit port is the host port on OpenDarwin.
pub(crate) fn mach_host_self() -> mach_port_t {
    unsafe { crate::libc::mach_host_self() }
}

/// `mach_reply_port` — allocate a fresh receive right for RPC replies.
pub(crate) fn mach_reply_port() -> mach_port_t {
    unsafe { crate::libc::mach_reply_port() }
}

/// Raw `mach_msg2_trap` (trap 47) with the packed-argument ABI.
fn mach_msg2(
    msg: *mut u8,
    option: u64,
    bits: u32,
    send_size: u32,
    remote: u32,
    local: u32,
    voucher: u32,
    id: u32,
    rcv_name: u32,
    rcv_size: u32,
    timeout: u32,
) -> u32 {
    unsafe {
        crate::libc::mach_msg2_trap(
            msg,
            option,
            ((send_size as u64) << 32) | (bits as u64),
            ((local as u64) << 32) | (remote as u64),
            ((id as u64) << 32) | (voucher as u64),
            (rcv_name as u64) << 32, // desc_count = 0
            (rcv_size as u64) << 32, // priority = 0
            timeout,
        )
    }
}

/// View any `repr(C)` value as raw bytes for sending.
pub(crate) fn as_bytes<T>(v: &T) -> &[u8] {
    unsafe { core::slice::from_raw_parts((v as *const T) as *const u8, size_of::<T>()) }
}

/// Send `msg_id` with `req_body` to `remote` and block for the reply.
///
/// Returns `Err(kr)` when the mach_msg transport itself failed; otherwise the
/// kernel's `ret` field still has to be checked by the caller.
pub(crate) fn rpc(
    remote: mach_port_t,
    msg_id: u32,
    req_body: &[u8],
) -> Result<ReplyBody, kern_return_t> {
    let reply = mach_reply_port();
    if reply == 0 {
        return Err(kIOReturnError);
    }

    let mut buf: [u64; 64] = [0; 64];
    let buf_ptr = buf.as_mut_ptr() as *mut u8;
    let hdr_size = size_of::<MachMsgHeader>();
    let send_size: u32 = (hdr_size + req_body.len()) as u32;

    let bits = mach_msgh_bits(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0);
    let hdr = MachMsgHeader {
        msgh_bits: bits,
        msgh_size: send_size,
        msgh_remote_port: remote,
        msgh_local_port: reply,
        msgh_voucher_port: 0,
        msgh_id: msg_id,
    };
    unsafe {
        ptr::copy_nonoverlapping(&hdr as *const MachMsgHeader as *const u8, buf_ptr, hdr_size);
        if !req_body.is_empty() {
            ptr::copy_nonoverlapping(req_body.as_ptr(), buf_ptr.add(hdr_size), req_body.len());
        }
    }

    let kr = mach_msg2(
        buf_ptr,
        MACH64_SEND_MSG | MACH64_SEND_ANY,
        bits,
        send_size,
        remote,
        reply,
        0, // voucher
        msg_id,
        0, // rcv_name
        0, // rcv_size
        0, // timeout
    );

    if kr != MACH_MSG_SUCCESS {
        return Err(kr as i32);
    }

    let rcv_size: u32 = (hdr_size + size_of::<ReplyBody>() + MAX_TRAILER_SIZE) as u32;
    let kr = mach_msg2(
        buf_ptr,
        MACH64_RCV_MSG | MACH64_RCV_TIMEOUT,
        0, // bits
        0, // send_size
        0, // remote
        0, // local
        0, // voucher
        0, // id
        reply,
        rcv_size,
        RPC_RCV_TIMEOUT_MS,
    );
    if kr != MACH_MSG_SUCCESS {
        return Err(kr as i32);
    }

    let mut reply_out = ReplyBody::default();
    unsafe {
        let reply_hdr = &*(buf_ptr as *const MachMsgHeader);
        let min_body = size_of::<ReplyBody>() - 64;
        if reply_hdr.msgh_size < (hdr_size + min_body) as u32 {
            return Err(kIOReturnError);
        }
        let body_len = reply_hdr.msgh_size as usize - hdr_size;
        let src = buf_ptr.add(hdr_size);
        ptr::copy_nonoverlapping(
            src,
            &mut reply_out as *mut ReplyBody as *mut u8,
            body_len.min(size_of::<ReplyBody>()),
        );
    }
    Ok(reply_out)
}

/// Convenience for passing `()`-shaped bodies through `rpc`.
pub(crate) fn rpc_empty(remote: mach_port_t, msg_id: u32) -> Result<ReplyBody, kern_return_t> {
    rpc(remote, msg_id, &[])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_layout() {
        assert_eq!(size_of::<MachMsgHeader>(), 24);
        assert_eq!(size_of::<ReplyBody>(), 104);
    }

    #[test]
    fn default_reply_has_error_ret() {
        let r = ReplyBody::default();
        assert_eq!(r.ret, -1);
    }

    #[test]
    fn as_bytes_round_trips() {
        #[repr(C)]
        struct Pair {
            a: u32,
            b: u32,
        }
        let p = Pair {
            a: 0x1122_3344,
            b: 0x5566_7788,
        };
        let bytes = as_bytes(&p);
        assert_eq!(bytes.len(), 8);
        assert_eq!(
            u32::from_le_bytes(bytes[0..4].try_into().unwrap()),
            0x1122_3344
        );
        assert_eq!(
            u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
            0x5566_7788
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn rpc_to_null_port_fails_cleanly() {
        let res = rpc(0, MSG_GET_MATCHING_SERVICE, &[]);
        assert!(res.is_err(), "rpc to a null port should not succeed");
    }
}
